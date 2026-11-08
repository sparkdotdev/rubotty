# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Dispatcher do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:rooms) { [room("r", tg, dc)] }
  let(:router) { instance_spy(Rubotty::Core::Router) }

  subject(:dispatcher) do
    described_class.new(
      topology: topology(*rooms), router: router,
      logger: Rubotty::Log.null, queue_limit: 3
    )
  end

  after { dispatcher.stop }

  # A room whose delivery has stalled shows here before anything else says so,
  # which is the whole point: during the Fluxer outage nothing reported that
  # every sample room was minutes behind.
  describe "#queue_depths" do
    it "is empty when every worker has caught up" do
      dispatcher.start
      dispatcher.call(message(tg, text: "one"))
      dispatcher.drain

      expect(dispatcher.queue_depths).to eq({})
    end

    it "reports what is still waiting while a worker is parked mid-delivery" do
      parked = Queue.new
      allow(router).to receive(:handle) { parked.pop }
      dispatcher.start
      3.times { |index| dispatcher.call(message(tg, text: "m#{index}", native_id: index.to_s)) }

      # One is in the worker's hands; the rest are behind it.
      expect(dispatcher.queue_depths.values.sum).to be_positive

      3.times { parked << :go }
      dispatcher.drain
    end

    it "is empty before anything has been dispatched at all" do
      dispatcher.start

      expect(dispatcher.queue_depths).to eq({})
    end
  end

  it "hands enqueued messages to the router" do
    dispatcher.start
    dispatcher.call(message(tg, text: "one"))
    dispatcher.drain
    expect(router).to have_received(:handle).once
  end

  # An adapter's receive loop must never wait on delivery, or a slow platform
  # stalls every other platform.
  it "returns to the caller without waiting for delivery" do
    slow = Queue.new
    allow(router).to receive(:handle) { slow.pop }
    dispatcher.start
    # The router stays parked in its first handle until the last line, so a
    # #call that waited on delivery could not come back at all.
    sender = Thread.new { 5.times { |i| dispatcher.call(message(tg, text: "m#{i}", native_id: i.to_s)) } }

    expect(sender.join(5)).to be(sender)
    expect(router).to have_received(:handle).at_most(:once)

    5.times { slow << :go }
  end

  it "preserves order within a room" do
    seen = []
    allow(router).to receive(:handle) { |m| seen << m.body.text }
    dispatcher.start
    %w[a b c].each_with_index { |t, i| dispatcher.call(message(tg, text: t, native_id: i.to_s)) }
    dispatcher.drain
    expect(seen).to eq(%w[a b c])
  end

  it "runs the inbound pipeline once when an endpoint belongs to several rooms" do
    hub = endpoint("hub")
    multi = described_class.new(
      topology: topology(room("r1", hub, tg), room("r2", hub, dc)),
      router: router, logger: Rubotty::Log.null
    )
    multi.start
    multi.call(message(hub, text: "hi"))
    multi.drain
    multi.stop
    expect(router).to have_received(:handle).once
  end

  it "drops the oldest message rather than blocking when a room falls behind" do
    gate = Queue.new
    allow(router).to receive(:handle) { gate.pop }
    dispatcher.start
    10.times { |i| dispatcher.call(message(tg, text: "m#{i}", native_id: i.to_s)) }
    expect { dispatcher.call(message(tg, text: "latest", native_id: "99")) }.not_to raise_error
    11.times { gate << :go }
  end

  it "keeps a room worker alive after the router raises" do
    calls = 0
    allow(router).to receive(:handle) do
      calls += 1
      raise "kaboom" if calls == 1
    end
    dispatcher.start
    dispatcher.call(message(tg, text: "one", native_id: "1"))
    dispatcher.call(message(tg, text: "two", native_id: "2"))
    dispatcher.drain
    expect(calls).to eq(2)
  end

  it "ignores a message from an endpoint in no room" do
    dispatcher.start
    dispatcher.call(message(endpoint("orphan"), text: "hi"))
    dispatcher.drain
    expect(router).not_to have_received(:handle)
  end

  it "is safe to stop twice" do
    dispatcher.start
    expect { 2.times { dispatcher.stop } }.not_to raise_error
  end

  # Queue#close does not drop what a worker is already mid-pop for, so a
  # worker blocked in a slow delivery can still be alive once #stop's join
  # times out. #stop has to kill it rather than let it keep running (and
  # keep writing to storage) after shutdown.
  it "kills a room worker that is still alive after stop's join times out" do
    entered = Queue.new
    hang = Queue.new
    allow(router).to receive(:handle) do
      entered << :go
      hang.pop
    end
    before_threads = Thread.list
    dispatcher.start
    worker = (Thread.list - before_threads).first
    dispatcher.call(message(tg, text: "stuck"))
    entered.pop

    dispatcher.stop(timeout: 0.05)

    # Thread#kill lands asynchronously, so give it a moment to actually die
    # rather than asserting the instant #stop returns.
    worker.join(1)
    expect(worker).not_to be_alive
  end

  # The record Core::QuietGatewayWatchdog compares a room's endpoints
  # against: every message that reaches #call touches it, whether or not it
  # ends up routed anywhere.
  describe "inbound activity" do
    let(:activity) { instance_spy(Rubotty::Core::InboundActivity) }
    let(:tracked) do
      described_class.new(
        topology: topology(*rooms), router: router, logger: Rubotty::Log.null, activity: activity
      )
    end

    after { tracked.stop }

    it "touches the origin endpoint for a message that gets routed" do
      tracked.start
      tracked.call(message(tg, text: "hi"))
      tracked.drain

      expect(activity).to have_received(:touch).with(tg.id)
    end

    it "touches the origin endpoint even for a message that belongs to no room" do
      orphan = endpoint("orphan")
      tracked.start
      tracked.call(message(orphan, text: "hi"))
      tracked.drain

      expect(activity).to have_received(:touch).with(orphan.id)
    end

    it "works with no activity tracker at all" do
      untracked = described_class.new(topology: topology(*rooms), router: router, logger: Rubotty::Log.null)
      untracked.start

      expect { untracked.call(message(tg, text: "hi")) }.not_to raise_error
      untracked.stop
    end
  end

  # A router that only returns when the spec lets it, kept as a plain object
  # since the worker holding it can outlive the example that stopped its
  # dispatcher.
  class BlockingRouter
    def initialize(gate) = @gate = gate

    def handle(_message) = @gate.pop
  end

  # A topology that takes a moment to answer, so the dispatcher has the message
  # while no queue has it yet.
  class SlowTopology
    def initialize(rooms, entered:, delay:)
      @rooms = rooms
      @entered = entered
      @delay = delay
    end

    def slow_next_read! = (@slow_next = true)

    def rooms
      if @slow_next
        @slow_next = false
        @entered << :in
        sleep @delay
      end
      @rooms
    end

    def rooms_for(endpoint_id)
      @entered << :in
      sleep @delay
      @rooms.select { |r| r.endpoints.any? { |e| e.id == endpoint_id } }
    end
  end

  describe "#drain (issue #145: a mirrored reaction that had not landed yet)" do
    it "reports that everything it was handed has been delivered" do
      dispatcher.start
      dispatcher.call(message(tg, text: "one"))

      expect(dispatcher.drain).to be(true)
    end

    # Answering from the SHAPE of the queues left a message an adapter had
    # already handed over invisible until it reached a queue, so a caller could
    # drain and assert against a bridge that had delivered nothing.
    it "covers a message from the handover rather than from the moment it reaches a queue" do
      entered = Thread::Queue.new
      slow = described_class.new(
        topology: SlowTopology.new([room("r", tg, dc)], entered: entered, delay: 0.05),
        router: router, logger: Rubotty::Log.null
      )
      slow.start
      slow.topology.slow_next_read!
      producer = Thread.new { slow.call(message(tg, text: "one")) }
      # The adapter is inside #call and nothing is queued anywhere yet.
      entered.pop

      settled = slow.drain

      expect(router).to have_received(:handle).once
      expect(settled).to be(true)
      producer.join
      slow.stop
    end

    # A platform write that never returns must not hang whoever drained.
    it "gives up with a warning rather than reporting a delivery that never happened" do
      logger = instance_spy(Logger)
      gate = Thread::Queue.new
      stuck = described_class.new(
        topology: topology(*rooms), router: BlockingRouter.new(gate), logger: logger
      )
      stuck.start
      stuck.call(message(tg, text: "one"))

      expect(stuck.drain(timeout: 0.05)).to be(false)
      expect(logger).to have_received(:warn)
      gate << :go
      stuck.stop
    end

    it "settles after a queue overflow rather than waiting on a message it threw away" do
      gate = Thread::Queue.new
      allow(router).to receive(:handle) { gate.pop }
      dispatcher.start
      10.times { |i| dispatcher.call(message(tg, text: "m#{i}", native_id: i.to_s)) }
      10.times { gate << :go }

      expect(dispatcher.drain(timeout: 2)).to be(true)
    end

    it "does not wait on messages that were stopped along with their queues" do
      gate = Thread::Queue.new
      stopped = described_class.new(
        topology: topology(*rooms), router: BlockingRouter.new(gate), logger: Rubotty::Log.null
      )
      stopped.start
      # The first wedges the worker, the second is still sitting in the queue
      # when the dispatcher goes away underneath it.
      2.times { |i| stopped.call(message(tg, text: "m#{i}", native_id: i.to_s)) }
      stopped.stop(timeout: 0.1)

      expect(stopped.drain(timeout: 0.5)).to be(true)
      2.times { gate << :go }
    end
  end

  # A stand-in for LiveTopology: #rooms and #rooms_for reflect whatever is
  # CURRENTLY in @rooms, as LiveTopology delegates to the live registry's
  # current snapshot.
  class MutableTopology
    def initialize(rooms) = @rooms = rooms
    def rooms = @rooms
    def add(room) = @rooms += [room]
    def rooms_for(endpoint_id) = @rooms.select { |r| r.endpoints.any? { |e| e.id == endpoint_id } }
  end

  # Building one queue and worker per room by iterating @topology.rooms once at
  # boot dropped every message for a room a live control plane grew afterward,
  # with no worker spawned for it short of a full process restart.
  describe "a room that appears after #start (issue: live-onboarded rooms never dispatched)" do
    it "spawns that room's queue and worker on first message rather than dropping it" do
      mutable = MutableTopology.new([room("r", tg, dc)])
      live_dispatcher = described_class.new(topology: mutable, router: router, logger: Rubotty::Log.null)
      live_dispatcher.start

      later = room("later", endpoint("later-ep"))
      mutable.add(later)

      live_dispatcher.call(message(endpoint("later-ep"), text: "hi"))
      live_dispatcher.drain
      live_dispatcher.stop

      expect(router).to have_received(:handle).once
    end

    it "still drops and logs when the dispatcher was genuinely never started" do
      logger = instance_spy(Logger)
      mutable = MutableTopology.new([room("r", tg, dc)])
      never_started = described_class.new(topology: mutable, router: router, logger: logger)

      later = room("later", endpoint("later-ep"))
      mutable.add(later)
      never_started.call(message(endpoint("later-ep"), text: "hi"))

      expect(router).not_to have_received(:handle)
      expect(logger).to have_received(:warn)
    end
  end
end
