# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Irc::HubRouter do
  let(:gaming) { endpoint("irc-hub-gaming", adapter: :irc, settings: { channel: "#sample", room_label: "gaming" }) }
  let(:travel) { endpoint("irc-hub-travel", adapter: :irc, settings: { channel: "#sample", room_label: "travel" }) }
  let(:solo) { endpoint("irc-general", adapter: :irc, settings: { channel: "#general" }) }

  # The config path has no communities at all, so every key carries nil and the
  # router behaves exactly as it did before the community joined the key.
  subject(:router) do
    described_class.new(
      channel_groups: { described_class.key_for(nil, "#sample") => [gaming, travel],
                        described_class.key_for(nil, "#general") => [solo] }
    )
  end

  describe ".key_for" do
    it "pairs the community with the channel, downcased" do
      expect(described_class.key_for(7, "#SAMPLE")).to eq([7, "#sample"])
    end
  end

  it "refuses a group keyed on a bare channel name, which is the cross-tenant shape" do
    expect { described_class.new(channel_groups: { "#sample" => [gaming, travel] }) }
      .to raise_error(ArgumentError, /keyed by \[community_id, channel\]/)
  end

  describe "#hub?" do
    it "is true for a channel with more than one of the community's rooms mapped into it" do
      expect(router.hub?(nil, "#sample")).to be(true)
    end

    it "is false for a channel with only one, even though it went through the same construction" do
      expect(router.hub?(nil, "#general")).to be(false)
    end

    it "matches case-insensitively, like IRC channel names generally are treated" do
      expect(router.hub?(nil, "#SAMPLE")).to be(true)
    end
  end

  describe "#code_for" do
    it "gives each hub endpoint its derived code" do
      expect(router.code_for(gaming)).to eq("ga")
      expect(router.code_for(travel)).to eq("tr")
    end

    it "is nil for an endpoint on a non-hub channel" do
      expect(router.code_for(solo)).to be_nil
    end
  end

  describe "#resolve" do
    it "resolves a valid code to the target endpoint, with the prefix stripped" do
      resolution = router.resolve(nil, "#sample", "!ga who's on?")
      expect(resolution.kind).to eq(:addressed)
      expect(resolution.target_endpoint_id).to eq("irc-hub-gaming")
      expect(resolution.text).to eq("who's on?")
    end

    it "reports every other hub endpoint on the channel as excluded, so no self-echo" do
      resolution = router.resolve(nil, "#sample", "!ga hi")
      expect(resolution.exclude_ids).to contain_exactly("irc-hub-gaming", "irc-hub-travel")
    end

    it "reports an unknown code rather than guessing" do
      resolution = router.resolve(nil, "#sample", "!zz hi")
      expect(resolution.kind).to eq(:unknown_code)
      expect(resolution.code).to eq("zz")
    end

    it "reports a listing request for the discoverability word, any sigil" do
      %w[! . > :].each do |sigil|
        expect(router.resolve(nil, "#sample", "#{sigil}rooms").kind).to eq(:listing)
      end
    end

    it "returns nil for a message with no sigil at all" do
      expect(router.resolve(nil, "#sample", "just chatting")).to be_nil
    end

    it "returns nil for a channel with no hub codes" do
      expect(router.resolve(nil, "#general", "!ga hi")).to be_nil
    end

    it "returns nil (never a room) for a word longer than two letters, e.g. a real command" do
      expect(router.resolve(nil, "#sample", "!delete")).to be_nil
    end

    it "strips a bare sigil with nothing after it to an empty word, and returns nil" do
      expect(router.resolve(nil, "#sample", "!")).to be_nil
    end
  end

  describe "#listing_text" do
    it "lists every room and its code, sorted by code" do
      expect(router.listing_text(nil, "#sample")).to eq("ga: gaming, tr: travel")
    end

    it "says plainly there is nothing mapped for a non-hub channel" do
      expect(router.listing_text(nil, "#general")).to eq("no rooms are mapped into this channel")
    end
  end

  # Issue #1789: one IRC account serving two tenants, both mapping #general.
  # Before the community joined the key this built ONE group of four, handed
  # every label to whoever typed the listing word, and let either side address
  # the other's rooms by code.
  describe "two communities sharing one physical channel" do
    let(:alpha_news) do
      endpoint("alpha-news", adapter: :irc, settings: { channel: "#general", room_label: "news" }, community_id: 1)
    end
    let(:alpha_games) do
      endpoint("alpha-games", adapter: :irc, settings: { channel: "#general", room_label: "games" }, community_id: 1)
    end
    let(:beta_secret) do
      endpoint("beta-secret", adapter: :irc, settings: { channel: "#general", room_label: "secret" }, community_id: 2)
    end
    let(:beta_plans) do
      endpoint("beta-plans", adapter: :irc, settings: { channel: "#general", room_label: "plans" }, community_id: 2)
    end

    subject(:router) do
      described_class.new(
        channel_groups: {
          described_class.key_for(1, "#general") => [alpha_news, alpha_games],
          described_class.key_for(2, "#general") => [beta_secret, beta_plans]
        }
      )
    end

    it "lists only the asking community's own rooms" do
      expect(router.listing_text(1, "#general")).to eq("ga: games, ne: news")
      expect(router.listing_text(2, "#general")).to eq("pl: plans, se: secret")
    end

    it "does not resolve the other community's code to its endpoint" do
      expect(router.resolve(1, "#general", "!se hi").kind).to eq(:unknown_code)
    end

    it "resolves a code that exists in both to the asking community's own endpoint" do
      expect(router.resolve(2, "#general", "!pl hi").target_endpoint_id).to eq("beta-plans")
    end

    it "gives an endpoint the code its own community assigned it" do
      expect([router.code_for(alpha_news), router.code_for(beta_secret)]).to eq(%w[ne se])
    end

    # The exclusion is deliberately the whole physical channel, not one group:
    # it exists to stop a relay echoing back into the channel it arrived on,
    # and the channel is shared even when the addressable rooms are not.
    it "still excludes every endpoint on the physical channel from the fan-out" do
      resolution = router.resolve(1, "#general", "!ga hi")
      expect(resolution.exclude_ids)
        .to contain_exactly("alpha-news", "alpha-games", "beta-secret", "beta-plans")
    end

    it "is no hub at all for a community with only one room on the shared channel" do
      one_each = described_class.new(
        channel_groups: { described_class.key_for(1, "#general") => [alpha_news],
                          described_class.key_for(2, "#general") => [beta_secret] }
      )
      expect([one_each.hub?(1, "#general"), one_each.hub?(2, "#general")]).to eq([false, false])
    end
  end

  describe "an explicit short_code override" do
    let(:gaming_override) do
      endpoint("irc-hub-gaming", adapter: :irc, settings: { channel: "#sample", room_label: "gaming", short_code: "GX" })
    end
    subject(:router) do
      described_class.new(channel_groups: { described_class.key_for(nil, "#sample") => [gaming_override, travel] })
    end

    it "is taken as given, lowercased" do
      expect(router.code_for(gaming_override)).to eq("gx")
      expect(router.resolve(nil, "#sample", "!gx hi").target_endpoint_id).to eq("irc-hub-gaming")
    end
  end

  describe "reserved codes default to every real moderation action word" do
    it "never lets a collision with a command word reach #resolve, structurally" do
      # No real action is two letters, so the reservation is a defensive floor
      # for a future shorter action name.
      expect(Rubotty::Core::Moderation::ACTIONS.map(&:length)).to all(be >= 3)
    end
  end
end
