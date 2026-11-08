# frozen_string_literal: true

require "spec_helper"

# A stand-in for a gateway adapter, the same shape gateway_cycle_spec.rb uses.
class QuietFakeAdapter
  attr_reader :calls

  def initialize(persistent: true)
    @calls = []
    @persistent = persistent
  end

  def adapter_name = :fake

  def persistent_connection? = @persistent

  def stop
    @calls << :stop
    self
  end

  def start
    @calls << :start
    self
  end
end

RSpec.describe Rubotty::Core::QuietGatewayWatchdog do
  # A single mutable clock shared by the activity tracker and every watchdog
  # built in this spec, so touching an endpoint and then advancing time (or
  # the other way round) always agrees between the two.
  before { @now = Time.utc(2026, 8, 3, 12, 0) }

  def now = @now

  def travel(seconds) = @now += seconds

  let(:activity) { Rubotty::Core::InboundActivity.new(clock: -> { now }) }
  let(:threshold) { 1800 }

  # tg-a and dc-a bridge the same room on two different gateways, so sibling
  # comparison sees two connections mirroring each other's traffic; tg-b sits
  # alone with no sibling. guest-a and api-a share the room too, but their
  # adapters hold no connection at all.
  let(:tg_a) { endpoint("tg-a", adapter: :telegram, account: "tg") }
  let(:dc_a) { endpoint("dc-a", adapter: :discord, account: "dc") }
  let(:tg_b) { endpoint("tg-b", adapter: :telegram, account: "tg") }
  let(:guest_a) { endpoint("guest:1", adapter: :guest, account: "guest") }
  let(:api_a) { endpoint("api:1", adapter: :api, account: "api") }
  let(:rooms) { [room("bridge", tg_a, dc_a, guest_a, api_a), room("solo", tg_b)] }

  let(:tg_key) { [:telegram, "tg"] }
  let(:dc_key) { [:discord, "dc"] }
  let(:guest_key) { [:guest, "guest"] }
  let(:api_key) { [:api, "api"] }
  let(:tg_adapter) { QuietFakeAdapter.new }
  let(:dc_adapter) { QuietFakeAdapter.new }
  let(:guest_adapter) { QuietFakeAdapter.new(persistent: false) }
  let(:api_adapter) { QuietFakeAdapter.new(persistent: false) }
  let(:adapters) do
    { tg_key => tg_adapter, dc_key => dc_adapter, guest_key => guest_adapter, api_key => api_adapter }
  end

  let(:reconnected) { [] }
  let(:reconnect) { ->(list, reason:) { reconnected << [list, reason] } }
  let(:logger) { instance_spy(Logger) }

  def build(**rest)
    described_class.new(
      topology: topology(*rooms), activity: activity, adapters: adapters, logger: logger,
      threshold: threshold, clock: -> { now }, reconnect: reconnect, **rest
    )
  end

  # Leaves tg-a stale (quiet since the moment this is called) and, once time
  # has moved on, dc-a fresh (quiet for zero), the one shape that proves a
  # stall rather than a shared quiet spell: an independent sibling still
  # receiving while tg-a's own connection has not.
  def stall_tg_a!
    activity.touch(tg_a.id)
    travel(threshold + 600)
    activity.touch(dc_a.id)
  end

  describe "a connection with recent activity" do
    it "is not flagged" do
      activity.touch(tg_a.id)
      activity.touch(dc_a.id)

      verdicts = build.tick

      expect(verdicts).to be_empty
      expect(reconnected).to be_empty
    end
  end

  describe "a connection past the threshold with no activity, while a sibling stayed busy" do
    it "is flagged, and the stalled adapter is reconnected" do
      stall_tg_a!

      verdicts = build.tick

      expect(verdicts.keys).to eq([tg_key])
      expect(verdicts.fetch(tg_key).endpoint).to eq(tg_a)
      expect(reconnected).to eq([[[tg_adapter], "quiet gateway: tg-a stalled"]])
    end
  end

  describe "a genuinely idle but demonstrably alive room" do
    it "does not flag either side when both have simply gone quiet together" do
      activity.touch(tg_a.id)
      activity.touch(dc_a.id)
      travel(threshold + 1) # neither side has said anything since, symmetrically

      verdicts = build.tick

      expect(verdicts).to be_empty
      expect(reconnected).to be_empty
    end

    it "does not flag an endpoint with no sibling to corroborate against" do
      travel(threshold + 1) # tg-b has never received anything, and is alone in its room

      verdicts = build.tick

      expect(verdicts).to be_empty
      expect(reconnected).to be_empty
    end

    it "does not corroborate off a sibling on the SAME gateway connection" do
      # tg-b shares tg-a's own adapter/account; if that connection is the one
      # that is dead, both go quiet together and neither proves the other alive.
      shared_room = [room("shared", tg_a, tg_b)]
      activity.touch(tg_a.id)
      activity.touch(tg_b.id)
      travel(threshold + 1)
      activity.touch(tg_b.id) # tg-b looks fresh, but it is the SAME gateway as tg-a

      watchdog = described_class.new(
        topology: topology(*shared_room), activity: activity, adapters: adapters, logger: logger,
        threshold: threshold, clock: -> { now }, reconnect: reconnect
      )

      expect(watchdog.tick).to be_empty
    end
  end

  describe "the configured threshold" do
    it "is honoured rather than a hardcoded value" do
      activity.touch(tg_a.id)
      travel(120)
      activity.touch(dc_a.id) # dc-a fresh, tg-a quiet for exactly 120s

      lenient = build(threshold: 60)
      expect(lenient.tick.keys).to eq([tg_key])

      strict = build(threshold: 3600)
      expect(strict.tick).to be_empty
    end
  end

  describe "acting on a verdict" do
    it "reconnects exactly once while the condition persists across repeated passes" do
      stall_tg_a!

      watchdog = build
      3.times { watchdog.tick }

      expect(reconnected.size).to eq(1)
      expect(tg_adapter.calls).to be_empty # the fake reconnect callable never touches the adapter itself
    end

    it "logs the stall loudly exactly once while the condition persists" do
      stall_tg_a!

      watchdog = build
      3.times { watchdog.tick }

      expect(logger).to have_received(:error).once
    end

    it "keeps reporting the stall on the health-facing #stalled read even though the action fired once" do
      stall_tg_a!

      watchdog = build
      3.times { watchdog.tick }

      expect(watchdog).to be_stalled
    end

    it "acts again after a genuine recovery, rather than being a one-shot forever" do
      stall_tg_a!
      watchdog = build
      watchdog.tick
      expect(reconnected.size).to eq(1)

      activity.touch(tg_a.id) # tg-a recovers
      watchdog.tick
      expect(watchdog).not_to be_stalled

      travel(threshold + 600)
      activity.touch(dc_a.id) # dc-a stays busy while tg-a goes quiet again
      watchdog.tick

      expect(reconnected.size).to eq(2)
    end
  end

  describe "without a reconnect callable" do
    it "still detects and logs, and simply takes no reconnect action" do
      stall_tg_a!

      watchdog = described_class.new(
        topology: topology(*rooms), activity: activity, adapters: adapters, logger: logger,
        threshold: threshold, clock: -> { now }
      )

      expect(watchdog.tick).not_to be_empty
      expect(watchdog).to be_stalled
      expect(logger).to have_received(:error)
    end
  end

  describe "an adapter that holds no gateway open" do
    it "never reports a guest endpoint, however long it stays silent" do
      activity.touch(guest_a.id)
      travel(43_200) # twelve hours, the resting state of a portal nobody walked through
      activity.touch(dc_a.id)

      expect(build.tick).to be_empty
      expect(reconnected).to be_empty
    end

    it "never reports an API endpoint, however long it stays silent" do
      activity.touch(api_a.id)
      travel(43_200)
      activity.touch(dc_a.id)

      expect(build.tick).to be_empty
      expect(reconnected).to be_empty
    end

    it "still reports a real gateway sharing the room with them" do
      activity.touch(guest_a.id)
      activity.touch(api_a.id)
      stall_tg_a!

      expect(build.tick.keys).to eq([tg_key])
    end

    it "cannot corroborate a gateway's silence with a post of its own" do
      activity.touch(tg_a.id)
      travel(threshold + 600)
      activity.touch(guest_a.id) # a guest reached the room, and no platform delivered anything

      expect(build.tick).to be_empty
    end
  end

  describe "a room whose two sides carry lopsided traffic" do
    # tg-a has always trickled, one message every two hours, while dc-a carries
    # the conversation. Silence on tg-a past the bare threshold is its normal.
    def establish_slow_cadence!
      activity.touch(tg_a.id)
      travel(7200)
      activity.touch(tg_a.id)
      travel(7200)
      activity.touch(tg_a.id)
    end

    it "leaves the quiet side alone while its silence keeps to its own rhythm" do
      establish_slow_cadence!
      travel(10_800) # three hours, six times the threshold and unremarkable for tg-a
      activity.touch(dc_a.id)

      expect(build.tick).to be_empty
      expect(reconnected).to be_empty
    end

    it "reports the quiet side once the silence outruns the rhythm it always kept" do
      establish_slow_cadence!
      travel(36_000) # ten hours, past four times tg-a's two hour cadence
      activity.touch(dc_a.id)

      expect(build.tick.keys).to eq([tg_key])
    end
  end

  describe "an endpoint that has never delivered anything" do
    it "gives no verdict, having no working state it could have lost" do
      watchdog = build
      travel(43_200) # half a day of silence on tg-a while dc-a stays fresh
      activity.touch(dc_a.id)

      expect(watchdog.tick).to be_empty
      expect(reconnected).to be_empty
    end

    it "is judged on the ordinary terms once it has delivered even once" do
      watchdog = build
      activity.touch(tg_a.id)
      travel(threshold + 1)
      activity.touch(dc_a.id)

      expect(watchdog.tick.keys).to eq([tg_key])
    end
  end

  describe "the thread" do
    it "is healthy before it is started and while it is running" do
      watchdog = build
      expect(watchdog).to be_healthy

      watchdog.start
      expect(watchdog).to be_healthy
      watchdog.stop
    end

    it "stops promptly rather than waiting out the interval" do
      watchdog = build(interval: 60)
      watchdog.start

      expect { watchdog.stop }.to change(watchdog, :running?).from(true).to(false)
    end

    it "is safe to stop when it was never started, and to stop twice" do
      watchdog = build
      expect { watchdog.stop.stop }.not_to raise_error
    end

    it "runs a pass when the loop wakes on its interval" do
      activity.touch(tg_a.id)
      watchdog = build(interval: 0.05)
      watchdog.start
      travel(threshold + 600)
      activity.touch(dc_a.id)

      wait_for { watchdog.ticks.positive? }
      watchdog.stop

      expect(watchdog).to be_stalled
    end
  end

  # Polls a condition for up to a second, so a thread test is not a fixed sleep.
  def wait_for(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep(0.02) until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
