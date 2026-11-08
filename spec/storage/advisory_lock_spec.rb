# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "sequel"
require "open3"
require "rbconfig"
require "timeout"

# The generalized cross-process advisory lock: the primitive Storage::Dialect's migration
# lock uses, opened up to any caller needing mutual exclusion around a block. One contract
# runs against every backend, since the promise (only one holder of a name at a time,
# released on error, a loser told rather than blocked forever) has to hold everywhere.
RSpec.shared_examples "an advisory lock" do
  # Fail connection setup on the example thread, before any queue handoff.
  before { store }

  it "runs the block while holding the lock and returns its value" do
    expect(store.with_advisory_lock("demo") { 42 }).to eq(42)
  end

  it "releases the lock even when the block raises, so a later caller is never wedged" do
    expect { store.with_advisory_lock("demo") { raise "boom" } }.to raise_error("boom")
    expect(store.with_advisory_lock("demo", timeout: 1) { :ok }).to eq(:ok)
  end

  it "keeps distinct lock names independent, so an unrelated caller is never blocked" do
    inside_a = Queue.new
    release_a = Queue.new
    a = Thread.new do
      store.with_advisory_lock("a") do
        inside_a << :in
        release_a.pop
      end
    end
    expect(inside_a.pop(timeout: 5)).to eq(:in)

    # "b" is a different named lock, so it must not wait for "a" to release.
    expect(store.with_advisory_lock("b", timeout: 1) { :ran }).to eq(:ran)
    release_a << :go
    a.join
  ensure
    release_a << :go if release_a
    a&.join(6)
    a&.kill&.join
  end

  # The property the whole primitive exists for: two threads contending for the
  # SAME name never both run the guarded block at once.
  it "lets only one holder into the block at a time for the same name" do
    active = 0
    max_active = 0
    mutex = Mutex.new
    threads = Array.new(6) do
      Thread.new do
        store.with_advisory_lock("shared", timeout: 5) do
          mutex.synchronize do
            active += 1
            max_active = active if active > max_active
          end
          sleep 0.02
          mutex.synchronize { active -= 1 }
        end
      end
    end
    threads.each(&:join)
    expect(max_active).to eq(1)
  end

  # The passive-standby half the Telegram poller relies on: a caller that loses the
  # race is told quickly, rather than blocking forever or proceeding unlocked.
  it "raises LockUnavailable rather than blocking forever when another caller already holds it" do
    holding = Queue.new
    release = Queue.new
    holder = Thread.new do
      store.with_advisory_lock("busy", timeout: 5) do
        holding << :in
        release.pop
      end
    end
    expect(holding.pop(timeout: 5)).to eq(:in)

    entered = false
    expect { store.with_advisory_lock("busy", timeout: 0.1) { entered = true } }
      .to raise_error(Rubotty::LockUnavailable)
    expect(entered).to be(false)

    release << :go
    holder.join
  ensure
    release << :go if release
    holder&.join(6)
    holder&.kill&.join
  end
end

RSpec.describe Rubotty::Storage::Memory do
  subject(:store) { described_class.new }

  it_behaves_like "an advisory lock"
end

RSpec.describe Rubotty::Storage::PStoreStore do
  let(:tmpdir) { Dir.mktmpdir("rubotty-pstore-lock") }
  subject(:store) do
    Rubotty::Storage::Factory.build({ driver: :pstore, path: File.join(tmpdir, "lock.pstore") })
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  it_behaves_like "an advisory lock"
end

# SQLite has no advisory lock of its own, so Dialect::Sqlite backs the same promise
# with a process-wide mutex table, which keeps this contract provable without a
# server on every laptop and on any CI job with no database service.
RSpec.describe Rubotty::Storage::SequelStore, "on sqlite" do
  let(:tmpdir) { Dir.mktmpdir("rubotty-sqlite-lock") }
  subject(:store) do
    Rubotty::Storage::Factory.build({ driver: :sqlite, path: File.join(tmpdir, "lock.sqlite3") })
  end

  after { FileUtils.remove_entry(tmpdir) if File.directory?(tmpdir) }

  it_behaves_like "an advisory lock"

  # Two SequelStore instances over the SAME sqlite file stand in for two rubotty
  # processes sharing one database file, rather than two callers sharing one object.
  it "serializes two separate store instances over the same database file" do
    other = Rubotty::Storage::SequelStore.new(db: store.db)

    active = 0
    max_active = 0
    mutex = Mutex.new
    run = lambda do |instance|
      instance.with_advisory_lock("shared", timeout: 5) do
        mutex.synchronize do
          active += 1
          max_active = active if active > max_active
        end
        sleep 0.02
        mutex.synchronize { active -= 1 }
      end
    end

    threads = [Thread.new { run.call(store) }, Thread.new { run.call(other) }]
    threads.each(&:join)
    expect(max_active).to eq(1)
  end

  context "file locks shared with independent processes" do
    let(:workers) { [] }
    let(:worker_program) do
      <<~'RUBY'
        require "rubotty"
        STDOUT.sync = true
        store = Rubotty::Storage::Factory.build({ driver: :sqlite, path: ARGV[0], auto_migrate: false })
        puts "ready"
        begin
          store.with_advisory_lock(ARGV[1], timeout: ARGV[2].to_f) do
            puts "acquired"
            STDIN.gets
          end
          puts "released"
        rescue Rubotty::LockUnavailable
          puts "timeout"
        ensure
          store.close
        end
      RUBY
    end

    def worker_line(worker)
      Timeout.timeout(10) { worker[1].readline.strip }
    end

    def start_worker(name, timeout: 5)
      database = store.db.fetch("PRAGMA database_list").all.find { |row| row[:name] == "main" }.fetch(:file)
      worker = Open3.popen3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
                           "-e", worker_program, database, name, timeout.to_s)
      workers << worker
      expect(worker_line(worker)).to eq("ready")
      worker
    end

    def release_worker(worker)
      worker[0].puts "release"
      expect(worker_line(worker)).to eq("released")
      expect(worker[3].join(5)&.value&.success?).to be(true)
    end

    def lock_directory
      "#{File.realpath(File.join(tmpdir, 'lock.sqlite3'))}.rubotty-locks"
    end

    after do
      workers.each do |input, output, error, waiter|
        begin
          input.puts "release" unless input.closed?
        rescue Errno::EPIPE, IOError
          nil
        end
        unless waiter.join(2)
          Process.kill("KILL", waiter.pid)
          waiter.join(2)
        end
        [input, output, error].each { |io| io.close unless io.closed? }
      end
      store.close
    end

    it "holds one name across processes while allowing ordinary database writes" do
      first = start_worker("shared-process")
      expect(worker_line(first)).to eq("acquired")
      second = start_worker("shared-process")
      expect(IO.select([second[1]], nil, nil, 0.1)).to be_nil
      store.put_state("outside-write", "permitted")
      expect(store.get_state("outside-write")).to eq("permitted")

      release_worker(first)
      expect(worker_line(second)).to eq("acquired")
      release_worker(second)
    end

    it "times out a separate process and leaves the persistent inode reusable" do
      first = start_worker("timeout-process")
      expect(worker_line(first)).to eq("acquired")
      second = start_worker("timeout-process", timeout: 0.05)
      expect(worker_line(second)).to eq("timeout")
      expect(second[3].join(5)&.value&.success?).to be(true)
      inode = File.stat(Dir.glob(File.join(lock_directory, "*.lock")).first).ino
      release_worker(first)
      expect(store.with_advisory_lock("timeout-process") { :ok }).to eq(:ok)
      expect(File.stat(Dir.glob(File.join(lock_directory, "*.lock")).first).ino).to eq(inode)
    end

    it "lets different names run concurrently across processes" do
      first = start_worker("outer")
      expect(worker_line(first)).to eq("acquired")
      second = start_worker("other")
      expect(worker_line(second)).to eq("acquired")
      release_worker(second)
      release_worker(first)
    end

    it "releases the OS lock when its holder is killed" do
      first = start_worker("crash")
      expect(worker_line(first)).to eq("acquired")
      second = start_worker("crash")
      expect(IO.select([second[1]], nil, nil, 0.1)).to be_nil
      Process.kill("KILL", first[3].pid)
      expect(first[3].join(5)&.value&.signaled?).to be(true)
      expect(worker_line(second)).to eq("acquired")
      release_worker(second)
    end

    it "uses the same lock through a symlink to the database" do
      first = start_worker("canonical")
      expect(worker_line(first)).to eq("acquired")
      alias_path = File.join(tmpdir, "database-alias.sqlite3")
      File.symlink(File.join(tmpdir, "lock.sqlite3"), alias_path)
      other = Rubotty::Storage::Factory.build({ driver: :sqlite, path: alias_path, auto_migrate: false })
      expect { other.with_advisory_lock("canonical", timeout: 0.05) { raise "must not enter" } }
        .to raise_error(Rubotty::LockUnavailable)
      release_worker(first)
    ensure
      other&.close
    end

    it "keeps nested different names independent and preserves callback IO errors" do
      value = store.with_advisory_lock("parent") do
        store.with_advisory_lock("child") { :nested }
      end
      expect(value).to eq(:nested)
      expect { store.with_advisory_lock("error") { raise Errno::ECONNRESET } }
        .to raise_error(Errno::ECONNRESET)
      expect(store.with_advisory_lock("error") { :released }).to eq(:released)
    end

    it "times out a nested same-name acquisition without releasing the outer lock" do
      store.with_advisory_lock("recursive") do
        expect { store.with_advisory_lock("recursive", timeout: 0.02) {} }
          .to raise_error(Rubotty::LockUnavailable)
        contender = start_worker("recursive", timeout: 0.02)
        expect(worker_line(contender)).to eq("timeout")
      end
      expect(store.with_advisory_lock("recursive", timeout: 0) { :free }).to eq(:free)
    end

    it "refuses a symlinked lock directory" do
      store
      destination = File.join(tmpdir, "other-directory")
      Dir.mkdir(destination, 0o700)
      File.symlink(destination, lock_directory)
      expect { store.with_advisory_lock("unsafe") {} }.to raise_error(Rubotty::StorageError, /private/)
    end

    it "refuses nonprivate directories and files without changing their permissions" do
      store.with_advisory_lock("private") {}
      path = Dir.glob(File.join(lock_directory, "*.lock")).first
      File.chmod(0o755, lock_directory)
      expect { store.with_advisory_lock("private") {} }.to raise_error(Rubotty::StorageError, /private/)
      expect(File.stat(lock_directory).mode & 0o777).to eq(0o755)
      File.chmod(0o700, lock_directory)
      File.chmod(0o644, path)
      expect { store.with_advisory_lock("private") {} }.to raise_error(Rubotty::StorageError, /private/)
      expect(File.stat(path).mode & 0o777).to eq(0o644)
    end

    it "refuses symlinked and multiply linked lock files" do
      store.with_advisory_lock("bootstrap") {}
      target = File.join(tmpdir, "target")
      File.open(target, File::WRONLY | File::CREAT, 0o600) { |file| file.write("preserve") }
      symlink = File.join(lock_directory, "#{Digest::SHA256.hexdigest('symlink')}.lock")
      File.symlink(target, symlink)
      expect { store.with_advisory_lock("symlink") {} }.to raise_error(Rubotty::StorageError)
      hardlink = File.join(lock_directory, "#{Digest::SHA256.hexdigest('hardlink')}.lock")
      File.link(target, hardlink)
      expect { store.with_advisory_lock("hardlink") {} }.to raise_error(Rubotty::StorageError, /singly linked/)
      expect(File.read(target)).to eq("preserve")
    end
  end
end

RSpec.describe Rubotty::Storage::SequelStore, "on in-memory sqlite" do
  subject(:store) { described_class.new(db: Sequel.sqlite).migrate! }

  after { store.close }

  it_behaves_like "an advisory lock"
end

# Runs only when a PostgreSQL is available. Proves the real pg_advisory_lock path
# end to end, where dialect_spec.rb only checks the SQL it generates on a mock.
RSpec.describe Rubotty::Storage::SequelStore, "on postgres", if: ENV["TEST_DATABASE_URL"] do
  subject(:store) do
    Rubotty::Storage::Factory.build(
      { driver: :pg, url_env: "TEST_DATABASE_URL", auto_migrate: false }, env: ENV
    )
  end

  it_behaves_like "an advisory lock"
end

# Runs only when a MariaDB is available, proving the real GET_LOCK/RELEASE_LOCK
# path end to end.
RSpec.describe Rubotty::Storage::SequelStore, "on mariadb", if: ENV["TEST_MYSQL_DATABASE_URL"] do
  subject(:store) do
    Rubotty::Storage::Factory.build(
      { driver: :mdb, url_env: "TEST_MYSQL_DATABASE_URL", auto_migrate: false }, env: ENV
    )
  end

  it_behaves_like "an advisory lock"
end
