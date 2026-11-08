# frozen_string_literal: true

require "spec_helper"

# One loop drives every subscriber, a subscriber failure cannot take the thread with
# it, a dead thread is reported rather than silent, and a push nudge has an explicit
# entry point.
RSpec.describe Rubotty::ControlPlane::Watcher do
  # A subscriber is anything answering #check.
  class CountingSource
    attr_reader :calls

    def initialize(result: true, raising: nil)
      @result = result
      @raising = raising
      @calls = 0
      @mutex = Mutex.new
    end

    def check
      @mutex.synchronize { @calls += 1 }
      raise @raising if @raising

      @result
    end
  end

  subject(:watcher) { described_class.new(interval: 0.02) }

  after { watcher.stop }

  describe "#subscribe" do
    it "records subscribers in tick order" do
      watcher.subscribe("snapshot", CountingSource.new)
      watcher.subscribe("events", CountingSource.new)
      expect(watcher.subscribers).to eq(%w[snapshot events])
    end

    it "replaces rather than duplicates a subscriber registered twice" do
      watcher.subscribe("snapshot", CountingSource.new)
      watcher.subscribe("snapshot", CountingSource.new)
      expect(watcher.subscribers).to eq(%w[snapshot])
    end

    it "ignores a nil source, so a runtime with no events lifecycle registers nothing for it" do
      watcher.subscribe("events", nil)
      expect(watcher.subscribers).to be_empty
    end
  end

  describe "#tick" do
    it "runs every subscriber once and returns each result under its name" do
      snapshot = CountingSource.new(result: true)
      events = CountingSource.new(result: 3)
      watcher.subscribe("snapshot", snapshot)
      watcher.subscribe("events", events)

      expect(watcher.tick).to eq("snapshot" => true, "events" => 3)
      expect(snapshot.calls).to eq(1)
      expect(events.calls).to eq(1)
    end

    # One bad subscriber must not cost the others their liveness.
    it "isolates a raising subscriber, still running the ones after it" do
      broken = CountingSource.new(raising: RuntimeError.new("boom"))
      healthy = CountingSource.new
      watcher.subscribe("broken", broken)
      watcher.subscribe("healthy", healthy)

      results = watcher.tick

      expect(results["broken"]).to be_nil
      expect(results["healthy"]).to be(true)
      expect(healthy.calls).to eq(1)
    end
  end

  describe "the shared loop" do
    it "drives every subscriber from ONE thread, not one thread each" do
      snapshot = CountingSource.new
      events = CountingSource.new
      watcher.subscribe("snapshot", snapshot).subscribe("events", events)

      before = Thread.list.select { |thread| thread.name == "control-plane-watcher" }.size
      watcher.start
      sleep(0.2)
      named = Thread.list.select { |thread| thread.name == "control-plane-watcher" }

      expect(named.size - before).to eq(1)
      expect(snapshot.calls).to be_positive
      expect(events.calls).to be_positive
    end

    it "is idempotent to start and prompt to stop" do
      watcher.subscribe("snapshot", CountingSource.new)
      watcher.start
      watcher.start
      expect(watcher.running?).to be(true)

      # The wait is woken rather than waited out, so the loop thread ends on its own
      # and stop never reaches the kill fallback a wall-clock bound here was watching.
      loop_thread = watcher.instance_variable_get(:@thread)
      expect(loop_thread).not_to receive(:kill)

      watcher.stop

      expect(loop_thread.status).to be(false)
      expect(watcher.running?).to be(false)
    end
  end

  describe "#reload_now, the push seam for issue #224" do
    it "checks immediately rather than waiting for the next tick" do
      source = CountingSource.new
      watcher.subscribe("snapshot", source)

      expect(watcher.reload_now(reason: "nudge")).to eq("snapshot" => true)
      expect(source.calls).to eq(1)
    end

    it "works before the loop is ever started, so a nudge needs no lifecycle knowledge" do
      source = CountingSource.new
      watcher.subscribe("snapshot", source)
      watcher.reload_now
      expect(source.calls).to eq(1)
      expect(watcher.running?).to be(false)
    end

    it "names the reason in the log, so an out-of-band reload is distinguishable" do
      lines = []
      logger = instance_double(Logger)
      allow(logger).to receive(:info) { |&block| lines << block.call }
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      nudged = described_class.new(logger: logger, interval: 60)
      nudged.subscribe("snapshot", CountingSource.new)

      nudged.reload_now(reason: "http nudge")

      expect(lines.join("\n")).to include("http nudge")
    end
  end

  # When more than one rubotty process shares a control-plane store, only one may be
  # mid-tick at a time, so a dashboard edit is never applied or announced twice.
  describe "cross-process mutual exclusion via the advisory lock" do
    it "runs unlocked, exactly as before #226, when built with no storage" do
      unlocked = described_class.new(interval: 60)
      source = CountingSource.new
      unlocked.subscribe("snapshot", source)

      expect(unlocked.tick).to eq("snapshot" => true)
    end

    it "takes the tick lock, by name, when storage supports one" do
      storage = Rubotty::Storage::Memory.new
      names = []
      allow(storage).to receive(:with_advisory_lock).and_wrap_original do |original, name, **kwargs, &block|
        names << name
        original.call(name, **kwargs, &block)
      end
      locked = described_class.new(interval: 60, storage: storage)
      locked.subscribe("snapshot", CountingSource.new)

      locked.tick

      expect(names).to eq([described_class::LOCK_NAME])
    end

    # A watcher that loses the lock race skips the tick cleanly, and the other process's
    # tick covers what would have run.
    it "skips a tick, without raising or checking any subscriber, when another instance holds the lock" do
      storage = instance_double(Rubotty::Storage::Memory)
      allow(storage).to receive(:with_advisory_lock).and_raise(Rubotty::LockUnavailable, "busy")
      source = CountingSource.new
      locked = described_class.new(interval: 60, storage: storage)
      locked.subscribe("snapshot", source)

      expect(locked.tick).to eq({})
      expect(source.calls).to eq(0)
    end

    it "logs a specific, named reason for a skipped tick" do
      lines = []
      logger = instance_double(Logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)
      allow(logger).to receive(:debug) { |&block| lines << block.call }
      storage = instance_double(Rubotty::Storage::Memory)
      allow(storage).to receive(:with_advisory_lock).and_raise(Rubotty::LockUnavailable, "busy")
      locked = described_class.new(interval: 60, logger: logger, storage: storage)
      locked.subscribe("snapshot", CountingSource.new)

      locked.tick

      expect(lines.join("\n")).to include("another instance already has the lock")
    end

    # Two watchers sharing one store, standing in for two processes on one database,
    # must never have a subscriber check running at the same moment.
    it "never lets two watchers' ticks run concurrently over the same store" do
      storage = Rubotty::Storage::Memory.new
      entered = Queue.new
      release = Queue.new
      active = 0
      max_active = 0
      guard = Mutex.new

      slow = CountingSource.new
      def slow.check
        @mutex.synchronize { @calls += 1 }
        @entered << :in
        @release.pop
        @result
      end
      slow.instance_variable_set(:@entered, entered)
      slow.instance_variable_set(:@release, release)

      quick = CountingSource.new

      a = described_class.new(interval: 60, storage: storage)
      b = described_class.new(interval: 60, storage: storage)
      a.subscribe("slow", slow)
      b.subscribe("quick", quick)

      # Wrap both subscribers' #check so overlap is detected directly, not inferred.
      [slow, quick].each do |source|
        original = source.method(:check)
        source.define_singleton_method(:check) do
          guard.synchronize { active += 1; max_active = [max_active, active].max }
          begin
            original.call
          ensure
            guard.synchronize { active -= 1 }
          end
        end
      end

      thread = Thread.new { a.tick }
      entered.pop # a is now mid-tick, blocked inside "slow", holding the lock

      releaser = Thread.new { sleep 0.1; release << :go }
      # Contends for the same lock a holds, so it must wait rather than run alongside.
      result_b = b.tick
      thread.join
      releaser.join

      expect(max_active).to eq(1)
      # b was delayed, not skipped: its tick ran once a released the lock.
      expect(result_b).to eq("quick" => true)
    end
  end

  # Unsupervised, a dead poll thread and "nothing has changed" look identical outside.
  describe "supervision" do
    it "is healthy before it is ever started, since a backend with no plane runs no watcher" do
      expect(watcher.healthy?).to be(true)
      expect(watcher.failure).to be_nil
    end

    it "is healthy while its thread is alive" do
      watcher.subscribe("snapshot", CountingSource.new)
      watcher.start
      sleep(0.05)
      expect(watcher.healthy?).to be(true)
    end

    it "reports UNHEALTHY when the thread is gone, instead of failing silently" do
      watcher.subscribe("snapshot", CountingSource.new)
      watcher.start
      sleep(0.05)
      # A lost thread looks like this from outside: still marked running, nothing on it.
      watcher.instance_variable_get(:@thread).kill
      sleep(0.05)

      expect(watcher.running?).to be(true)
      expect(watcher.healthy?).to be(false)
    end

    it "records and logs the reason when something no rescue catches unwinds the thread" do
      lines = []
      logger = instance_double(Logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error) { |&block| lines << block.call }
      dying = described_class.new(logger: logger, interval: 0.02)
      # NotImplementedError descends from ScriptError, so no ordinary rescue in the
      # tick path catches it.
      dying.subscribe("snapshot", CountingSource.new(raising: NotImplementedError.new("gone")))
      allow(dying).to receive(:tick).and_raise(NotImplementedError, "gone")

      dying.start
      sleep(0.2)

      expect(dying.healthy?).to be(false)
      expect(dying.failure).to include("NotImplementedError")
      expect(lines.join("\n")).to include("control-plane watcher thread died")
      dying.stop
    end
  end
end
