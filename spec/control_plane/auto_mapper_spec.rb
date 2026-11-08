# frozen_string_literal: true

require "spec_helper"

# Proposing room bindings for discovered channels by name. Pure comparison with
# no writes, so these assert only what is proposed and what is refused.
RSpec.describe Rubotty::ControlPlane::AutoMapper, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:connection) { models.platform_connection.where(community_id: community.id, adapter: "telegram").first }

  subject(:mapper) { described_class.new(models: models, logger: Rubotty::Log.null) }

  def channel(label, route: label.downcase.gsub(/\W+/, ""))
    now = Time.now
    models.channel.create(
      community_id: community.id, platform_connection_id: connection.id,
      adapter: "telegram", account: "telegram", route_key: "auto-#{route}",
      endpoint_key: "discovered:telegram:telegram:auto-#{route}", label: label,
      created_at: now, updated_at: now
    )
  end

  def room(key, label = nil)
    now = Time.now
    models.room.create(community_id: community.id, room_key: key, label: label,
                       display_name: "{}", created_at: now, updated_at: now)
  end

  def propose(channels, rooms)
    mapper.propose(channels: channels, rooms: rooms)
  end

  it "binds when the room's words all appear in the channel's, whatever the order" do
    target = room("scheduling-gaming", "Scheduling Gaming")
    result = propose([channel("Gaming & Scheduling")], [target]).first

    expect(result).to be_bind
    expect(result.room_key).to eq("scheduling-gaming")
  end

  it "lets a short room name claim a longer, more specific channel name" do
    target = room("residency", "Residency")
    result = propose([channel("ARI Permanent Residency")], [target]).first

    expect(result).to be_bind
    expect(result.room_key).to eq("residency")
  end

  # Binding either would be a guess about merging two conversations.
  it "skips every channel when two of them claim the same room" do
    target = room("residency", "Residency")
    results = propose([channel("Permanent Residency"), channel("ARI Permanent Residency")], [target])

    expect(results.map(&:action)).to eq(%i[skip skip])
    expect(results.first.reason).to include("Residency")
  end

  it "skips a channel that matches more than one room" do
    results = propose([channel("Portugal Banking")], [room("portugal"), room("banking")])

    expect(results.first).to be_skip
    expect(results.first.reason).to include("2 rooms")
  end

  it "proposes creating a room when nothing matches" do
    result = propose([channel("Awaiting Biometrics")], []).first

    expect(result).to be_create
    expect(result.room_key).to eq("awaiting-biometrics")
    expect(result.room_label).to eq("Awaiting Biometrics")
  end

  it "ignores emoji, punctuation and filler words when comparing" do
    target = room("banking-portugal", "Banking Portugal")
    result = propose([channel("🏦 Banking in Portugal")], [target]).first

    expect(result).to be_bind
  end

  it "keeps emoji and filler out of a created room key too" do
    result = propose([channel("🏦 Banking in Portugal")], []).first

    expect(result.room_key).to eq("banking-portugal")
  end

  it "skips a channel whose name has nothing to match on" do
    result = propose([channel("🎉", route: "emojionly")], []).first

    expect(result).to be_skip
    expect(result.reason).to include("no words")
  end

  it "never matches on a room whose name reduces to nothing, rather than matching everything" do
    # An empty needed-set is a subset of everything, so without a guard this
    # room claims every channel in the community.
    results = propose([channel("Legal Action"), channel("Media PR")], [room("x", "&&&")])

    expect(results.map(&:action)).to eq(%i[create create])
  end

  # A discovered topic keeps the adapter's stand-in until somebody names it, and
  # those stand-ins are all the parent chat title, so they match each other.
  describe "a channel still carrying the adapter's placeholder" do
    it "is skipped, with a reason that says how to give it a real name" do
      result = propose([channel("Example Travel - ARI & D Visas (topic 46)", route: "ph46")], []).first

      expect(result).to be_skip
      expect(result.reason).to include("/identify-topic")
    end

    it "is skipped even when it would otherwise match an existing room" do
      target = room("example-travel", "Example Travel")
      result = propose([channel("Example Travel (topic 12)", route: "ph12")], [target]).first

      expect(result).to be_skip
    end

    it "never suppresses a real name that merely mentions a topic" do
      result = propose([channel("Topic Ideas", route: "real")], []).first

      expect(result).to be_create
    end

    # Pins the mapper's pattern to the string the adapter actually invents, so a
    # change to #topic_placeholder fails here rather than in production.
    it "matches exactly what Adapters::Telegram::Adapter#topic_placeholder produces" do
      adapter = Rubotty::Adapters::Telegram::Adapter.new(
        account: "telegram", settings: { token: "123:abc", token_env: "TG_TOKEN" },
        dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null
      )
      placeholder = adapter.send(:topic_placeholder, { "title" => "Example Travel" }, 46)

      expect(placeholder).to eq("Example Travel (topic 46)")
      expect(placeholder).to match(described_class::PLACEHOLDER_LABEL)
    end
  end

  it "returns one proposal per channel, in the order given" do
    results = propose([channel("First Thing"), channel("Second Thing")], [])
    expect(results.map { |r| r.channel.label }).to eq(["First Thing", "Second Thing"])
  end
end
