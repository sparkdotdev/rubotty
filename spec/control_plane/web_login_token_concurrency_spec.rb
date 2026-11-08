# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"

RSpec.describe Rubotty::ControlPlane::WebLoginTokens, "concurrent single-use transitions" do
  # Use the real Memory backend's per-name locks. Two services share the same
  # datastore, just as independent callers share a durable token record.
  let(:store) do
    Class.new(Rubotty::Storage::Memory) do
      attr_reader :read_held, :lock_attempts

      def initialize
        super
        @read_held = Queue.new
        @resume_read = Queue.new
        @lock_attempts = Queue.new
        @hold_guard = Mutex.new
        @critical_depth = Hash.new(0)
      end

      def hold_next_read(key)
        @hold_guard.synchronize { @held_key = key }
      end

      def resume_read = @resume_read << true

      def get_state(key)
        value = super
        hold = @hold_guard.synchronize do
          next false unless @held_key == key && @critical_depth[Thread.current].positive?

          @held_key = nil
          true
        end
        if hold
          @read_held << true
          @resume_read.pop
        end
        value
      end

      def with_advisory_lock(name, **options, &block)
        @lock_attempts << [Thread.current, name]
        super(name, **options) do
          @hold_guard.synchronize { @critical_depth[Thread.current] += 1 }
          begin
            block.call
          ensure
            @hold_guard.synchronize { @critical_depth[Thread.current] -= 1 }
          end
        end
      end
    end.new
  end

  let(:first) { described_class.new(store: store) }
  let(:second) { described_class.new(store: store) }
  let(:issued) do
    first.issue(identity_key: "single-use-fixture", operator: { adapter: "telegram", native_id: "900001" },
                communities: [{ id: 1 }], single_use: true)
  end
  let(:digest) { described_class.digest(issued.token) }
  let(:token_key) { "#{described_class::TOKEN_PREFIX}:#{digest}" }

  def bounded_pop(queue) = Timeout.timeout(3) { queue.pop }

  def start_worker(&block)
    Thread.new do
      Thread.current.report_on_exception = false
      block.call
    end.tap { |thread| (@workers ||= []) << thread }
  end

  def finish_worker(thread)
    raise "token transition did not finish" unless thread.join(3)

    thread.value
  end

  def next_lock_attempt_by(thread)
    Timeout.timeout(3) do
      loop do
        caller, name = store.lock_attempts.pop
        return name if caller == thread
      end
    end
  end

  after do
    # An assertion failure must never leave a held read or lock in another
    # example. All waits and joins are bounded; no timing sleeps drive the race.
    2.times { store.resume_read }
    Array(@workers).each do |thread|
      thread.kill if thread.alive?
      thread.join(1)
    end
  end

  it "keeps a single-use session revoked when revocation starts during its first redemption" do
    store.hold_next_read(token_key)
    redeeming = start_worker { first.redeem(token: issued.token) }
    bounded_pop(store.read_held)
    redemption_lock = next_lock_attempt_by(redeeming)

    revoking = start_worker { second.revoke(id: digest) }
    expect(next_lock_attempt_by(revoking)).to eq(redemption_lock)
    store.resume_read

    expect(finish_worker(redeeming)).to be_ok
    expect(finish_worker(revoking)).to be(true)
    expect(first.session_claims(id: digest)).not_to be_ok
    expect(second.session_claims(id: digest)).not_to be_ok
    expect(first.redeem(token: issued.token)).not_to be_ok
    expect(JSON.parse(store.get_state(token_key))).to include("consumed" => true, "session_revoked" => true)
  end

  it "permits exactly one of two simultaneous redemptions across service instances" do
    store.hold_next_read(token_key)
    redeeming = start_worker { first.redeem(token: issued.token) }
    bounded_pop(store.read_held)
    redemption_lock = next_lock_attempt_by(redeeming)

    competing = start_worker { second.redeem(token: issued.token) }
    expect(next_lock_attempt_by(competing)).to eq(redemption_lock)
    store.resume_read

    results = [finish_worker(redeeming), finish_worker(competing)]
    expect(results.map(&:status)).to eq(%i[ok invalid])
    expect(results.count(&:ok?)).to eq(1)
    expect(second.session_claims(id: digest)).to be_ok
    expect(second.active_tokens).to be_empty
  end
end

RSpec.describe Rubotty::ControlPlane::WebLoginTokens, "file-backed SQLite process transitions" do
  let(:directory) { Dir.mktmpdir("rubotty-token-processes") }
  let(:database_path) { File.join(directory, "tokens.sqlite3") }
  let(:store) { Rubotty::Storage::Factory.build({ driver: :sqlite, path: database_path }) }
  let(:tokens) { described_class.new(store: store) }
  let(:issued) do
    tokens.issue(identity_key: "single-use-process-fixture",
                 operator: { adapter: "telegram", native_id: "900002" },
                 communities: [{ id: 1 }], single_use: true)
  end
  let(:digest) { described_class.digest(issued.token) }
  let(:processes) { [] }
  let(:worker_program) do
    <<~'RUBY'
      require "rubotty"
      require "sequel"
      require "json"
      STDOUT.sync = true
      Rubotty::Storage::Factory.use_utc!

      paused_store = Class.new(Rubotty::Storage::SequelStore) do
        def initialize(token_key:, **options)
          super(**options)
          @token_key = token_key
        end

        def get_state(key)
          value = super
          if key == @token_key && !@paused && @critical_depth.to_i.positive?
            @paused = true
            puts "loaded"
            raise "missing release" unless STDIN.gets&.strip == "continue"
          end
          value
        end

        def with_advisory_lock(name, **options)
          super(name, **options) do
            @critical_depth = @critical_depth.to_i + 1
            begin
              yield
            ensure
              @critical_depth -= 1
            end
          end
        end
      end

      # Observe a real unsuccessful flock, without changing its return value,
      # so the parent knows the peer is excluded before releasing the holder.
      observed_contention = Module.new do
        def try_file_lock(lock)
          acquired = super
          unless acquired || @reported_contention
            @reported_contention = true
            puts "blocked"
          end
          acquired
        end
      end

      database, token, action = ARGV
      digest = Rubotty::ControlPlane::WebLoginTokens.digest(token)
      store = paused_store.new(db: Sequel.sqlite(database), token_key: "web_login:token:#{digest}")
      store.instance_variable_get(:@dialect).singleton_class.prepend(observed_contention)
      service = Rubotty::ControlPlane::WebLoginTokens.new(store: store)
      result = action == "revoke" ? service.revoke(id: digest) : service.redeem(token: token).status
      puts JSON.generate(result: result)
      store.close
    RUBY
  end

  def process_line(worker)
    Timeout.timeout(10) { worker[1].readline.strip }
  rescue EOFError
    raise "token worker exited early: #{worker[2].read}"
  end

  def start_process(action)
    worker = Open3.popen3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", worker_program,
                         database_path, issued.token, action)
    processes << worker
    worker
  end

  def release_process(worker)
    worker[0].puts "continue"
    worker[0].flush
  end

  def ordered_process_transitions(first_action, second_action)
    first = start_process(first_action)
    expect(process_line(first)).to eq("loaded")
    second = start_process(second_action)
    expect(process_line(second)).to eq("blocked")
    release_process(first)
    first_result = JSON.parse(process_line(first)).fetch("result")

    # The peer's SELECT can only run after the first transition released the
    # lock; its captured payload must include that completed transition.
    expect(process_line(second)).to eq("loaded")
    release_process(second)
    second_result = JSON.parse(process_line(second)).fetch("result")
    processes.each { |worker| expect(worker[3].join(5)&.value&.success?).to be(true) }
    [first_result, second_result]
  end

  after do
    processes.each do |input, output, error, waiter|
      if waiter.alive?
        Process.kill("TERM", waiter.pid) rescue nil
        unless waiter.join(1)
          Process.kill("KILL", waiter.pid) rescue nil
          waiter.join(1)
        end
      end
      [input, output, error].each { |io| io.close unless io.closed? }
    end
    store.close
    FileUtils.remove_entry(directory) if File.directory?(directory)
  end

  it "keeps a session revoked when another process starts revoking during redemption" do
    expect(ordered_process_transitions("redeem", "revoke")).to eq(["ok", true])

    expect(tokens.session_claims(id: digest)).not_to be_ok
    expect(tokens.redeem(token: issued.token)).not_to be_ok
  end

  it "denies a redemption that starts while another process is revoking" do
    expect(ordered_process_transitions("revoke", "redeem")).to eq([true, "invalid"])

    expect(tokens.session_claims(id: digest)).not_to be_ok
    expect(tokens.redeem(token: issued.token)).not_to be_ok
  end

  it "consumes a single-use token exactly once across separate processes" do
    expect(ordered_process_transitions("redeem", "redeem")).to eq(%w[ok invalid])

    expect(tokens.session_claims(id: digest)).to be_ok
    expect(tokens.redeem(token: issued.token)).not_to be_ok
  end

  it "does not allocate persistent lock files for unknown tokens or revocation ids" do
    store
    lock_files = -> { Dir.glob("#{File.realpath(database_path)}.rubotty-locks/*.lock").sort }
    before = lock_files.call

    results = 10.times.map { |number| tokens.redeem(token: "unknown-process-fixture-#{number}").status }

    expect(results).to all(eq(:invalid))
    expect(tokens.revoke(id: "a" * 64)).to be(false)
    expect(lock_files.call).to eq(before)
  end

  it "does not allocate a persistent token lock for an expired issued token" do
    expired = described_class.new(store: store, ttl: -10)
    token = expired.issue(identity_key: "expired-process-fixture", operator: {}, communities: []).token
    lock_files = -> { Dir.glob("#{File.realpath(database_path)}.rubotty-locks/*.lock").sort }
    before = lock_files.call

    expect(expired.redeem(token: token)).not_to be_ok
    expect(expired.revoke(id: described_class.digest(token))).to be(false)
    expect(lock_files.call).to eq(before)
  end
end
