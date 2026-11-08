# frozen_string_literal: true

require "spec_helper"

# The merged topology, operators and people views have to generalise to many
# communities sharing a runtime without one community's fan-out leaking into another.
RSpec.describe Rubotty::ControlPlane::Snapshot, "aggregate views across communities" do
  def endpoint(id, adapter: :telegram)
    Rubotty::Core::Endpoint.new(id: id, adapter_name: adapter, account: adapter.to_s, settings: {})
  end

  def community(id:, slug:, rooms:, operators: [], people: [], status: "active")
    channels = rooms.flat_map(&:endpoints).uniq(&:id).map do |ep|
      Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: id, route_key: ep.id)
    end
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: id, slug: slug, name: slug, status: status, settings: {},
      topology: Rubotty::Core::Topology.new(rooms), channels: channels,
      operators: Rubotty::Core::Moderation::Directory.new(operators),
      people: Rubotty::Core::Directory.new(people)
    )
  end

  let(:c1_room) { Rubotty::Core::Room.new(id: "c1-room", endpoints: [endpoint("c1-a"), endpoint("c1-b")]) }
  let(:c2_room) { Rubotty::Core::Room.new(id: "c2-room", endpoints: [endpoint("c2-a"), endpoint("c2-b")]) }

  let(:alex) { Rubotty::Core::Person.new(name: "alex", identities: { telegram: ["1"] }) }
  let(:sam)  { Rubotty::Core::Person.new(name: "sam", identities: { telegram: ["2"] }) }
  let(:op1)  { Rubotty::Core::Moderation::Operator.new(name: "alex", identities: { telegram: ["1"] }) }
  let(:op2)  { Rubotty::Core::Moderation::Operator.new(name: "sam", identities: { telegram: ["2"] }) }

  let(:c1) { community(id: 1, slug: "one", rooms: [c1_room], operators: [op1], people: [alex]) }
  let(:c2) { community(id: 2, slug: "two", rooms: [c2_room], operators: [op2], people: [sam]) }

  subject(:snapshot) { described_class.new(communities: [c1, c2]) }

  describe "#topology unions every community's rooms" do
    it "carries both communities' rooms in one Core::Topology" do
      expect(snapshot.topology.rooms.map(&:id)).to contain_exactly("c1-room", "c2-room")
    end

    it "confines fan-out to the origin's own community" do
      origin = snapshot.topology.endpoint("c1-a")
      rooms = snapshot.topology.rooms_for("c1-a")
      targets = rooms.flat_map { |room| room.targets_for(origin) }.map(&:id)
      expect(targets).to contain_exactly("c1-b")
    end
  end

  describe "#operators and #people union the communities' directories" do
    it "resolves an operator from either community" do
      expect(snapshot.operators.resolve(:telegram, "1")&.name).to eq("alex")
      expect(snapshot.operators.resolve(:telegram, "2")&.name).to eq("sam")
    end

    it "resolves a mentionable person from either community" do
      expect(snapshot.people.by_identity(:telegram, "1")&.name).to eq("alex")
      expect(snapshot.people.by_identity(:telegram, "2")&.name).to eq("sam")
    end
  end

  # The deployment-wide default: no community and no room at all, the tier
  # below every community's own feature_config, read by name rather than by
  # which community happens to be asking.
  describe "#feature_config_default" do
    def global_setting(feature, config)
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(feature: feature, enabled: true, config: config)
    end

    it "answers {} for a feature nothing has ever set" do
      snapshot = described_class.new(communities: [c1])

      expect(snapshot.feature_config_default("moderation")).to eq({})
    end

    it "answers the deployment-wide row's config, shared by every community" do
      snapshot = described_class.new(
        communities: [c1, c2],
        feature_settings: [global_setting("moderation", ack_ttl_seconds: 30, acknowledge: true)]
      )

      expect(snapshot.feature_config_default("moderation")).to eq(ack_ttl_seconds: 30, acknowledge: true)
    end

    it "keeps one feature's default from leaking onto another's lookup" do
      snapshot = described_class.new(
        communities: [c1],
        feature_settings: [global_setting("moderation", ack_ttl_seconds: 30)]
      )

      expect(snapshot.feature_config_default("word_filter")).to eq({})
    end
  end

  describe "one community" do
    subject(:single) { described_class.new(communities: [c1]) }

    it "yields exactly that community's topology" do
      expect(single.topology.rooms.map(&:id)).to eq(["c1-room"])
    end
  end

  # A suspended community stays in the Snapshot for lookups, but its channels leave the
  # inbound route index, so an event on one no longer resolves and the adapter drops it.
  describe "a suspended community goes quiet" do
    let(:stopped) { community(id: 2, slug: "two", rooms: [c2_room], operators: [op2], people: [sam], status: "suspended") }

    subject(:snapshot) { described_class.new(communities: [c1, stopped]) }

    it "does not resolve an inbound address on a suspended community's channel" do
      expect(snapshot.resolve(:telegram, "telegram", "c2-a")).to be_nil
    end

    it "still resolves an active community's channel" do
      expect(snapshot.resolve(:telegram, "telegram", "c1-a")&.endpoint_key).to eq("c1-a")
    end

    it "keeps the suspended community queryable by slug and id, so it can be restarted" do
      expect(snapshot.community("two")).to eq(stopped)
      expect(snapshot.community_by_id(2)).to eq(stopped)
    end
  end

  # Falling back to the bare chat_id's channel on a miss resolves a forum message to
  # General's origin id, and Room#targets_for keys echo-exclusion off that, so the bot
  # relays the message back into the topic it came from. A miss stays a miss.
  describe "a thread-qualified route_key with no exact mapping" do
    let(:general) { endpoint("c1-general", adapter: :telegram) }
    let(:topic) { endpoint("c1-topic", adapter: :telegram) }
    let(:forum_room) { Rubotty::Core::Room.new(id: "c1-forum", endpoints: [general, topic]) }

    def forum_community(topic_route_key:)
      channels = [
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: general, community_id: 1, route_key: "-100"),
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: topic, community_id: 1, route_key: topic_route_key)
      ]
      Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "forum", name: "forum", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([forum_room]), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new([]),
        people: Rubotty::Core::Directory.new([])
      )
    end

    it "does not fall back to the bare chat_id's channel when the exact topic key is mapped but different" do
      snapshot = described_class.new(communities: [forum_community(topic_route_key: "-100/555")])

      expect(snapshot.resolve(:telegram, "telegram", "-100/999")).to be_nil
      expect(snapshot.resolve(:telegram, "telegram", "-100/555")&.endpoint_key).to eq("c1-topic")
      expect(snapshot.resolve(:telegram, "telegram", "-100")&.endpoint_key).to eq("c1-general")
    end
  end
end
