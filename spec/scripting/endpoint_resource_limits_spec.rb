# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

RSpec.describe Rubotty::Scripting::Endpoints, "resource limits", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:resolver) { ->(_) { ["93.184.216.34"] } }
  let(:row) do
    now = Time.now
    models.script_endpoint.create(community_id: community.id, name: "bounded",
      url: "https://public.example/bounded", http_method: "GET", timeout_seconds: 2,
      enabled: true, created_at: now, updated_at: now)
  end
  let(:endpoints) { build(executor: ->(work) { work.call }) }

  def build(**options)
    service = described_class.new(models: models, logger: Rubotty::Log.null, resolver: resolver, **options)
    (@services ||= []) << service
    service
  end

  after { @services&.each { |service| service.close(timeout: 0.1) } }

  def response
    Net::HTTPOK.new("1.1", "200", "OK").tap { |reply| reply["content-type"] = "text/plain" }
  end

  def fake_http(reply, closed: nil)
    http = Object.new
    http.define_singleton_method(:request) do |_request, &block|
      begin
        block.call(reply)
      ensure
        closed&.push(true)
      end
    end
    allow(Rubotty::Util::MediaFetcher).to receive(:pinned_http).and_return(http)
    http
  end

  it "includes DNS resolution in the operation's deadline" do
    slow = described_class.new(models: models, resolver: ->(_) { sleep 5 }, executor: ->(work) { work.call })
    allow(slow).to receive(:request_timeout).and_return(0.05)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect { slow.send(:perform, row, {}) }.to raise_error(described_class::Refused, /time limit/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.7
  ensure
    slow&.close
  end

  it "interrupts a body that keeps making progress and releases its request" do
    allow(endpoints).to receive(:request_timeout).and_return(0.05)
    reply = response
    reply.define_singleton_method(:read_body) do |&block|
      100.times { sleep 0.02; block.call("x") }
    end
    closed = []
    fake_http(reply, closed: closed)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect { endpoints.send(:perform, row, {}) }.to raise_error(described_class::Refused, /time limit/)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.7
    expect(closed).to eq([true])
  end

  it "shares the remaining budget across address candidates" do
    time = [0.0]
    service = build(clock: -> { time[0] }, executor: ->(work) { work.call })
    allow(service).to receive(:request_timeout).and_return(1)
    attempts = []
    allow(Rubotty::Util::MediaFetcher).to receive(:pinned_http) do |_uri, address, **limits|
      attempts << [address, limits]
      http = Object.new
      http.define_singleton_method(:request) do |_request, &block|
        time[0] += 0.7
        raise Net::OpenTimeout if attempts.length == 1

        reply = Net::HTTPOK.new("1.1", "200", "OK")
        reply["content-type"] = "text/plain"
        reply.define_singleton_method(:read_body) { |&reader| reader.call("x") }
        block.call(reply)
      end
      http
    end
    allow(resolver).to receive(:call).and_return(["93.184.216.34", "93.184.216.35"])

    expect { service.send(:perform, row, {}) }.to raise_error(described_class::Refused, /time limit/)
    expect(attempts.length).to eq(2)
    expect(attempts.last[1][:read_timeout]).to be_within(0.001).of(0.3)
  end

  it "escapes real HTTPResponse body draining once the byte cap is reached" do
    stub_const("Rubotty::Scripting::Endpoints::MAX_BYTES", 32)
    socket = Class.new do
      attr_reader :pulled
      def initialize = @pulled = 0
      def closed? = false
      def read(_length, destination, *_args)
        while @pulled < 128
          @pulled += 16
          destination << ("x" * 16)
        end
        destination
      end
    end.new
    reply = response
    reply["content-length"] = "128"
    closed = []
    http = Object.new
    http.define_singleton_method(:request) do |_request, &block|
      begin
        reply.reading_body(socket, true) { block.call(reply) }
      ensure
        closed << true
      end
    end
    allow(Rubotty::Util::MediaFetcher).to receive(:pinned_http).and_return(http)

    result = endpoints.send(:perform, row, {})

    expect(result.body.bytesize).to eq(32)
    expect(result).to have_attributes(status: 200, ok: true, format: "text")
    expect(socket.pulled).to eq(32)
    expect(reply.instance_variable_get(:@body)).to be_nil
    expect(closed).to eq([true])
  end

  it "runs a production-shaped callback away from the enqueueing room worker" do
    row
    service = build(workers: 1)
    entered, release, completed = Queue.new, Queue.new, Queue.new
    allow(service).to receive(:perform) do
      entered << true
      release.pop(timeout: 2)
      :answer
    end

    expect(service.enqueue(community, "bounded") { |job| completed << [Thread.current, job.call] }).to be(true)
    expect(entered.pop(timeout: 2)).to be(true)
    expect(completed.pop(timeout: 0.01)).to be_nil
    release << true
    thread, answer = completed.pop(timeout: 2)

    expect(thread).not_to eq(Thread.current)
    expect(answer).to eq(:answer)
  ensure
    release << true if release
  end

  it "bounds active workers and pending calls without silently accepting overflow" do
    row
    service = build(workers: 2, queue_size: 2)
    entered, release, completed = Queue.new, Queue.new, Queue.new
    allow(service).to receive(:perform) do |_row, params, **_options|
      entered << [Thread.current, params["id"]]
      release.pop(timeout: 2)
      completed << params["id"]
    end
    2.times { |id| service.enqueue(community, "bounded", { "id" => id }) }
    active = 2.times.map { entered.pop(timeout: 2) }
    2.times { |id| expect(service.enqueue(community, "bounded", { "id" => id + 2 })).to be(true) }

    expect { service.enqueue(community, "bounded", { "id" => 9 }) }.to raise_error(described_class::Refused, /busy/)
    expect(active.map(&:first).uniq.length).to eq(2)
    expect(entered.pop(timeout: 0.01)).to be_nil
    2.times { release << true }
    more = 2.times.map { entered.pop(timeout: 2) }
    expect((active + more).map(&:first).uniq.length).to eq(2)
    2.times { release << true }
    expect(4.times.map { completed.pop(timeout: 2) }.sort).to eq([0, 1, 2, 3])
  ensure
    4.times { release << true } if release
  end

  it "preserves FIFO work order on a single worker and survives callback failure" do
    row
    service = build(workers: 1)
    entered, release, completed = Queue.new, Queue.new, Queue.new
    allow(service).to receive(:perform) do |_row, params, **_options|
      if params["id"] == 0
        entered << true
        release.pop(timeout: 2)
      end
      params["id"]
    end
    service.enqueue(community, "bounded", { "id" => 0 }) { |job| completed << job.call; raise "callback failed" }
    entered.pop(timeout: 2)
    [1, 2].each { |id| service.enqueue(community, "bounded", { "id" => id }) { |job| completed << job.call } }
    release << true

    expect(3.times.map { completed.pop(timeout: 2) }).to eq([0, 1, 2])
  ensure
    release << true if release
  end

  it "still delivers request failure to the runner's callback path" do
    row
    service = build(workers: 1)
    completed = Queue.new
    allow(service).to receive(:perform).and_raise(described_class::Refused, "synthetic timeout")

    service.enqueue(community, "bounded") do |job|
      begin
        completed << job.call
      rescue described_class::Refused => error
        completed << error.message
      end
    end

    expect(completed.pop(timeout: 2)).to eq("synthetic timeout")
  end

  it "does not spend network time on a queued call whose admission deadline has expired" do
    row
    time = [0.0]
    service = build(workers: 1, clock: -> { time[0] })
    allow(service).to receive(:request_timeout).and_return(10)
    entered, release, completed = Queue.new, Queue.new, Queue.new
    calls = []
    reply = response
    reply.define_singleton_method(:read_body) do |&block|
      entered << true
      release.pop(timeout: 2)
      block.call("x")
    end
    http = fake_http(reply)
    allow(http).to receive(:request).and_wrap_original { |original, *args, &block| calls << true; original.call(*args, &block) }
    callback = lambda do |job|
      begin
        job.call
      rescue described_class::Refused
        completed << :expired
      end
    end
    service.enqueue(community, "bounded", &callback)
    entered.pop(timeout: 2)
    service.enqueue(community, "bounded", &callback)
    time[0] = 11
    release << true

    expect(2.times.map { completed.pop(timeout: 2) }).to eq(%i[expired expired])
    expect(calls.length).to eq(1)
  ensure
    release << true if release
  end

  it "closes within its grace period and refuses new calls" do
    row
    service = build(workers: 1)
    entered = Queue.new
    allow(service).to receive(:perform) { entered << Thread.current; sleep 5 }
    service.enqueue(community, "bounded")
    worker = entered.pop(timeout: 2)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    service.close(timeout: 0.02)

    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.7
    expect { service.enqueue(community, "bounded") }.to raise_error(described_class::Refused, /closed/)
    expect(worker.join(0.2)).to eq(worker)
  end
end
