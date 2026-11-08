# frozen_string_literal: true

require "spec_helper"

# The clock is injectable and #run_due is public, so these drive the background
# thread synchronously with a fake clock rather than sleeping on wall time.
RSpec.describe Rubotty::Core::Scheduler do
  let(:base) { Time.now }
  let(:clock) { -> { @now ||= base } }

  subject(:scheduler) { described_class.new(logger: Rubotty::Log.null, clock: clock) }

  def advance(seconds) = (@now = (@now || base) + seconds)

  after { scheduler.stop }

  it "does not run an action before its time has arrived" do
    ran = []
    scheduler.after(15) { ran << :done }

    expect(scheduler.run_due).to eq(0)
    expect(ran).to be_empty
  end

  it "runs an action once its delay has elapsed" do
    ran = []
    scheduler.after(15) { ran << :done }

    advance(15)
    expect(scheduler.run_due).to eq(1)
    expect(ran).to eq([:done])
  end

  it "runs a zero delay action on the next drain" do
    ran = []
    scheduler.after(0) { ran << :now }

    expect(scheduler.run_due).to eq(1)
    expect(ran).to eq([:now])
  end

  it "runs due actions oldest first" do
    order = []
    scheduler.after(20) { order << :later }
    scheduler.after(10) { order << :sooner }

    advance(20)
    scheduler.run_due
    expect(order).to eq(%i[sooner later])
  end

  # A follow up scheduled from inside an action is relative to the clock then.
  it "lets an action schedule a follow up that fires on a later drain" do
    order = []
    scheduler.after(15) do
      order << :first
      scheduler.after(15) { order << :second }
    end

    advance(15)
    scheduler.run_due
    expect(order).to eq([:first])

    advance(15)
    scheduler.run_due
    expect(order).to eq(%i[first second])
  end

  # A cleanup that fails must not take the thread down or strand the rest.
  it "swallows a failing action and still runs the rest" do
    ran = []
    scheduler.after(1) { raise "boom" }
    scheduler.after(1) { ran << :ok }

    advance(1)
    expect { scheduler.run_due }.not_to raise_error
    expect(ran).to eq([:ok])
  end

  it "reports how many actions are waiting" do
    scheduler.after(5) { nil }
    scheduler.after(5) { nil }
    expect(scheduler.pending).to eq(2)
  end

  it "requires a block to schedule anything" do
    expect { scheduler.after(5) }.to raise_error(ArgumentError)
  end

  it "starts and stops cleanly and tolerates being called twice" do
    scheduler.start
    expect(scheduler.running?).to be(true)
    scheduler.start
    scheduler.stop
    expect(scheduler.running?).to be(false)
    expect { scheduler.stop }.not_to raise_error
  end

  it "is safe to stop when never started" do
    expect { scheduler.stop }.not_to raise_error
  end

  # Nothing supervises this thread, so once it goes every later #after is
  # accepted, queued and never run, for the rest of the process's life.
  describe "#healthy?" do
    it "is healthy when it was never started, because there is no thread to lose" do
      expect(scheduler.healthy?).to be(true)
      expect(scheduler.failure).to be_nil
    end

    it "is healthy while the sweep thread is alive" do
      scheduler.start
      expect(scheduler.healthy?).to be(true)
    end

    it "is unhealthy once the sweep thread has died" do
      scheduler.start
      thread = scheduler.instance_variable_get(:@thread)
      thread.kill
      thread.join

      expect(scheduler.healthy?).to be(false)
    end

    it "is healthy again after a restart" do
      scheduler.start
      thread = scheduler.instance_variable_get(:@thread)
      thread.kill
      thread.join
      scheduler.stop
      scheduler.start

      expect(scheduler.healthy?).to be(true)
    end

    # Pending actions are abandoned on purpose at shutdown, so a stopped
    # scheduler must not turn the health endpoint red.
    it "is healthy after a deliberate stop" do
      scheduler.start
      scheduler.stop
      expect(scheduler.healthy?).to be(true)
    end
  end
end
