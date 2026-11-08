# frozen_string_literal: true

require "spec_helper"

# Issue #1788, over the two communities from #1767 that each own a room keyed
# "general". The bridge reads the MERGED boot topology, so a hub addressed
# message naming a room key had every tenant's rooms to choose from.
RSpec.describe Rubotty::Features::Bridge, "scoped to the message's own community" do
  let(:snapshot) { colliding_snapshot }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }

  def endpoint_named(id) = snapshot.topology.endpoint(id)

  subject(:bridge) do
    described_class.new(
      topology: snapshot.topology, adapters: Hash.new(adapter), storage: storage,
      loop_guard: loop_guard, logger: logger, ttl: 3600
    )
  end

  def relay(origin_id, community_id, hub_target: nil)
    msg = message(endpoint_named(origin_id), text: "hello", hub_target_room_id: hub_target)
    community = snapshot.communities.find { |candidate| candidate.id == community_id }
    bridge.call(Rubotty::Features::Context.new(message: msg, community: community))
  end

  # Alpha holds the lower id and is loaded first, so it is the room a
  # first-match-wins search over the merged topology hands to everybody.
  it "the fixture really does put alpha's general first in the merged topology" do
    expect(snapshot.topology.rooms.map(&:community_id)).to eq([1, 2])
  end

  describe "a hub short code resolved to the literal room key" do
    it "reaches only the addressing community's own room" do
      outcome = relay("beta-telegram", 2, hub_target: "general")
      expect(outcome.value.map(&:endpoint_id)).to eq(["beta-discord"])
    end

    it "reaches nothing of the other tenant's, which is the leak" do
      outcome = relay("beta-telegram", 2, hub_target: "general")
      expect(outcome.value.map(&:endpoint_id)).not_to include("alpha-telegram", "alpha-discord")
    end

    it "answers alpha its own general for the identical key" do
      outcome = relay("alpha-telegram", 1, hub_target: "general")
      expect(outcome.value.map(&:endpoint_id)).to eq(["alpha-discord"])
    end

    it "will not reach a stranger's room addressed by one of its endpoint ids" do
      outcome = relay("beta-telegram", 2, hub_target: "alpha-discord")
      expect(outcome.value.map(&:endpoint_id)).to eq(["beta-discord"])
    end
  end

  # The defect itself. community_scope: defaulted to nil the whole way down, and
  # a nil pool meant the merged topology, whose first "general" is alpha's.
  describe "a message arriving with no community resolved for it" do
    def unscoped_relay(hub_target)
      msg = message(endpoint_named("beta-telegram"), text: "hello", hub_target_room_id: hub_target)
      bridge.call(Rubotty::Features::Context.new(message: msg))
    end

    it "falls back to the origin's own rooms rather than searching every tenant" do
      expect(unscoped_relay("general").value.map(&:endpoint_id)).to eq(["beta-discord"])
    end

    it "reaches none of alpha's endpoints, which is what the merged search handed it" do
      expect(unscoped_relay("general").value.map(&:endpoint_id)).not_to include("alpha-discord")
    end
  end

  # The point of the change is that the unsafe call can no longer be written,
  # so the signatures themselves are asserted.
  describe "the signatures a caller has to satisfy" do
    it "gives room resolution no arity that omits the community" do
      expect(described_class.instance_method(:target_rooms_for).parameters)
        .to eq([%i[req message], %i[req community]])
    end

    it "requires both community keywords on the new-message path" do
      expect(described_class.instance_method(:handle_new).parameters)
        .to include(%i[keyreq community], %i[keyreq community_scope])
    end

    it "requires them at the fan-out into a room as well" do
      expect(described_class.instance_method(:deliver_to_room).parameters)
        .to include(%i[keyreq community_id], %i[keyreq community_scope])
    end
  end

  # Belt and braces: even handed a room holding a foreign endpoint, nothing
  # posts into it. This is the delivery point the audit asked to defend.
  describe "the delivery point itself" do
    let(:mixed_room) do
      Rubotty::Core::Room.owned_by(
        2, id: "general", endpoints: [endpoint_named("beta-telegram"), endpoint_named("beta-discord"),
                                      endpoint_named("alpha-discord")]
      )
    end

    subject(:bridge) do
      described_class.new(
        topology: Rubotty::Core::Topology.new([mixed_room]), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: logger, ttl: 3600
      )
    end

    it "refuses the foreign endpoint and keeps the rest of the fan-out" do
      outcome = relay("beta-telegram", 2)
      expect(outcome.value.map(&:endpoint_id)).to eq(["beta-discord"])
    end

    it "says so at error level rather than posting quietly" do
      relay("beta-telegram", 2)
      expect(logs.string).to match(/REFUSED.*alpha-discord.*community 1, not 2/)
    end
  end

  # The config path has one community and no ids anywhere, and must keep
  # resolving a hub code exactly as it did.
  describe "the single-community config path" do
    let(:irc) { endpoint("irc-hub") }
    let(:tg) { endpoint("tg") }
    let(:dc) { endpoint("dc") }

    subject(:bridge) do
      described_class.new(
        topology: topology(room("default", irc), room("gaming", tg, dc)),
        adapters: Hash.new(adapter), storage: storage, loop_guard: loop_guard,
        logger: logger, ttl: 3600
      )
    end

    it "still resolves a hub-addressed room key with no community anywhere" do
      msg = message(irc, text: "hello", hub_target_room_id: "gaming")
      outcome = bridge.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome.value.map(&:endpoint_id)).to contain_exactly("tg", "dc")
    end
  end
end
