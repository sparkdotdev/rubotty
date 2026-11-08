# frozen_string_literal: true

require "spec_helper"

# A stand-in for a gateway adapter: records the stop/start pairs so a spec can
# assert the connection was actually dropped before it was re-established.
class CycleFakeAdapter
  attr_reader :calls, :account

  def initialize(persistent: true, account: "one", fail_on_start: false, fail_on_stop: false)
    @persistent = persistent
    @account = account
    @fail_on_start = fail_on_start
    @fail_on_stop = fail_on_stop
    @calls = []
  end

  def adapter_name = :fake

  def persistent_connection? = @persistent

  def stop
    @calls << :stop
    raise Rubotty::AdapterError.new("cannot stop", adapter: :fake) if @fail_on_stop

    self
  end

  def start
    @calls << :start
    raise Rubotty::AdapterError.new("cannot start", adapter: :fake) if @fail_on_start

    self
  end
end

RSpec.describe Rubotty::Core::GatewayCycle do
  let(:gateway) { CycleFakeAdapter.new }
  let(:poller) { CycleFakeAdapter.new(persistent: false, account: "two") }
  let(:adapters) { { %i[fake one] => gateway, %i[fake two] => poller } }
  let(:now) { Time.utc(2026, 8, 2, 9, 30) }

  def build(at: described_class::DEFAULT_AT, clock: -> { now }, **rest)
    described_class.new(adapters: adapters, at: at, clock: clock, **rest)
  end

  describe "which connections it touches" do
    it "cycles only the adapters that hold a connection open" do
      cycle = build
      expect(cycle.targets).to eq([gateway])

      cycle.cycle

      expect(gateway.calls).to eq(%i[stop start])
      expect(poller.calls).to be_empty
    end

    it "drops the connection before re-establishing it, rather than the other way round" do
      build.cycle

      expect(gateway.calls.first).to eq(:stop)
    end

    it "ignores an adapter too old to answer the capability at all" do
      legacy = Object.new
      cycle = described_class.new(adapters: { %i[old one] => legacy }, clock: -> { now })

      expect(cycle.targets).to be_empty
      expect(cycle.cycle).to eq([])
    end
  end

  describe "the clock" do
    it "reads midnight UTC by default" do
      expect(build.at).to eq("00:00")
    end

    it "measures the wait in UTC whatever the local zone is" do
      cycle = build(clock: -> { Time.utc(2026, 8, 2, 23, 0) })

      expect(cycle.seconds_until_next).to eq(3600)
    end

    it "takes the offset off an aware clock rather than its wall-clock digits" do
      # 20:00 in a +05:00 zone is 15:00 UTC, so the wait to midnight UTC is nine
      # hours, not four. A container TZ cannot move the schedule.
      eastern = Time.new(2026, 8, 2, 20, 0, 0, "+05:00")
      cycle = build(clock: -> { eastern })

      expect(cycle.seconds_until_next).to eq(9 * 3600)
    end

    it "waits a full day when asked at the moment of the slot" do
      cycle = build(clock: -> { Time.utc(2026, 8, 2, 0, 0) })

      expect(cycle.seconds_until_next).to eq(86_400)
    end

    it "honours a configured time other than midnight" do
      cycle = build(at: "03:30", clock: -> { Time.utc(2026, 8, 2, 3, 0) })

      expect(cycle.seconds_until_next).to eq(1800)
    end

    it "refuses a time it cannot read as HH:MM in UTC" do
      expect { build(at: "midnight") }.to raise_error(ArgumentError, /HH:MM in UTC/)
      expect { build(at: "24:00") }.to raise_error(ArgumentError)
    end
  end

  describe "when it is due" do
    it "is not due before the slot" do
      cycle = build(at: "03:00", clock: -> { Time.utc(2026, 8, 2, 2, 59) })

      expect(cycle).not_to be_due
    end

    it "is due once the slot has passed and nothing has served it" do
      cycle = build(at: "03:00", clock: -> { Time.utc(2026, 8, 2, 3, 1) })

      expect(cycle).to be_due
    end

    it "is not due again on the same day once it has run" do
      cycle = build(at: "03:00", clock: -> { Time.utc(2026, 8, 2, 3, 1) })
      cycle.cycle

      expect(cycle).not_to be_due
    end

    it "is due again the next day" do
      time = Time.utc(2026, 8, 2, 3, 1)
      cycle = build(at: "03:00", clock: -> { time })
      cycle.cycle
      time = Time.utc(2026, 8, 3, 3, 1)

      expect(cycle).to be_due
    end

    it "does not fire on boot when today's slot has already gone by" do
      cycle = build(at: "00:00", clock: -> { now })
      cycle.start

      expect(cycle).not_to be_due
      expect(gateway.calls).to be_empty
      cycle.stop
    end
  end

  describe "when a gateway will not come back" do
    it "reports the ones that did and leaves the rest to their own reconnect" do
      broken = CycleFakeAdapter.new(account: "broken", fail_on_start: true)
      cycle = described_class.new(
        adapters: { %i[fake one] => gateway, %i[fake broken] => broken }, clock: -> { now }
      )

      expect(cycle.cycle).to eq([gateway])
    end

    it "still starts an adapter whose stop raised" do
      stubborn = CycleFakeAdapter.new(fail_on_stop: true)
      cycle = described_class.new(adapters: { %i[fake one] => stubborn }, clock: -> { now })

      expect(cycle.cycle).to eq([stubborn])
      expect(stubborn.calls).to eq(%i[stop start])
    end
  end

  describe "the backfill that follows" do
    it "hands the reconnected adapters to the sweep" do
      swept = nil
      cycle = build(after_cycle: ->(recovered) { swept = recovered })

      cycle.cycle

      expect(swept).to eq([gateway])
    end

    it "does not sweep when nothing came back up" do
      broken = CycleFakeAdapter.new(fail_on_start: true)
      swept = false
      cycle = described_class.new(
        adapters: { %i[fake one] => broken }, clock: -> { now },
        after_cycle: ->(_recovered) { swept = true }
      )

      cycle.cycle

      expect(swept).to be(false)
    end

    it "survives a sweep that raises" do
      cycle = build(after_cycle: ->(_recovered) { raise "no storage" })

      expect { cycle.cycle }.not_to raise_error
      expect(cycle.cycles).to eq(1)
    end
  end

  describe "logging" do
    it "says the backfill is coming, so the sweep below it is not a mystery" do
      lines = []
      logger = instance_double(Logger, info: nil, warn: nil, error: nil)
      allow(logger).to receive(:info) { |&block| lines << block.call }
      build(logger: logger).cycle

      expect(lines.first).to match(/dropping 1 gateway connection/)
      expect(lines.first).to match(/backfill sweep that follows/)
      expect(lines.last).to match(/1 of 1 gateway\(s\) reconnected/)
    end
  end

  # Core::QuietGatewayWatchdog's out-of-band trigger.
  describe "#reconnect" do
    it "drops and re-establishes just the adapter it is given" do
      build.reconnect([gateway], reason: "quiet: tg-a stalled")

      expect(gateway.calls).to eq(%i[stop start])
      expect(poller.calls).to be_empty
    end

    it "ignores an adapter that is not one of its own targets" do
      stray = CycleFakeAdapter.new(account: "stray")
      build.reconnect([stray], reason: "quiet")

      expect(stray.calls).to be_empty
    end

    it "does not count toward the nightly cycle total" do
      cycle = build
      cycle.reconnect([gateway], reason: "quiet")

      expect(cycle.cycles).to eq(0)
    end

    it "does not move the nightly schedule" do
      cycle = build(at: "03:00", clock: -> { Time.utc(2026, 8, 2, 3, 1) })
      cycle.reconnect([gateway], reason: "quiet")

      expect(cycle).to be_due
    end

    it "reads as cycling while it runs, the same signal the nightly cycle gives the health check" do
      gate = Thread::Queue.new
      slow = CycleFakeAdapter.new(account: "slow")
      allow(slow).to receive(:stop) { gate.pop }
      cycle = described_class.new(adapters: { %i[fake slow] => slow }, clock: -> { now })

      thread = Thread.new { cycle.reconnect([slow], reason: "quiet") }
      sleep 0.02
      mid_flight = cycle.cycling?
      gate << :go
      thread.join

      expect(mid_flight).to be(true)
      expect(cycle.cycling?).to be(false)
    end

    it "hands what came back to the same backfill sweep the nightly cycle uses" do
      swept = nil
      cycle = build(after_cycle: ->(recovered) { swept = recovered })

      cycle.reconnect([gateway], reason: "quiet")

      expect(swept).to eq([gateway])
    end
  end

  describe "the thread" do
    it "starts no thread when nothing holds a connection open" do
      cycle = described_class.new(adapters: { %i[fake two] => poller }, clock: -> { now })

      expect(cycle.start.running?).to be(false)
    end

    it "is healthy before it is started and while it is running" do
      cycle = build
      expect(cycle).to be_healthy

      cycle.start
      expect(cycle).to be_healthy
      cycle.stop
    end

    it "stops promptly rather than waiting out the sleep" do
      cycle = build
      cycle.start

      expect { cycle.stop }.to change(cycle, :running?).from(true).to(false)
    end

    it "is safe to stop when it was never started, and to stop twice" do
      cycle = build
      expect { cycle.stop.stop }.not_to raise_error
    end

    it "cycles when the loop finds the slot has arrived" do
      time = Time.utc(2026, 8, 2, 23, 59, 59.7)
      cycle = build(clock: -> { time })
      cycle.start
      time = Time.utc(2026, 8, 3, 0, 0, 1)

      # The wait is bounded, so the loop rechecks rather than sleeping through.
      wait_for { cycle.cycles.positive? }
      cycle.stop

      expect(gateway.calls).to eq(%i[stop start])
    end
  end

  # Polls a condition for up to a second, so a thread test is not a fixed sleep.
  def wait_for(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(0.02) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
