# frozen_string_literal: true

require "spec_helper"

# The one normalizer the dashboard's write path and Features::UtilityCommands' read
# path share, so the url-less-row and default-label rules cannot drift apart.
RSpec.describe Rubotty::ControlPlane::PlatformLinks, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:feature_controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  subject(:links) { described_class.new(feature_controls: feature_controls) }

  def community = feature_controls.community!("sample")

  def row_for(room_id:)
    models.feature_setting.where(community_id: community.id, room_id: room_id, feature: "utility_commands").first
  end

  def room_id_for(room_key)
    models.room.where(community_id: community.id, room_key: room_key).first.id
  end

  describe ".normalize" do
    it "drops an entry with a blank or missing url" do
      expect(described_class.normalize([{ platform: "discord", label: "Our Discord", url: "" }])).to eq([])
      expect(described_class.normalize([{ platform: "discord", label: "Our Discord" }])).to eq([])
    end

    it "keeps an entry with a usable url" do
      entries = [{ platform: "discord", label: "Our Discord", url: "https://discord.gg/abc" }]
      expect(described_class.normalize(entries)).to eq(entries)
    end

    it "defaults a missing or blank label to the capitalised platform name" do
      expect(described_class.normalize([{ platform: "matrix", url: "https://matrix.to/#/room" }]))
        .to eq([{ platform: "matrix", label: "Matrix", url: "https://matrix.to/#/room" }])
      expect(described_class.normalize([{ platform: "matrix", label: "  ", url: "https://matrix.to/#/room" }]))
        .to eq([{ platform: "matrix", label: "Matrix", url: "https://matrix.to/#/room" }])
    end

    it "defaults the label to 'Join' when the platform is blank too" do
      expect(described_class.normalize([{ platform: "", url: "https://example.org/join" }]))
        .to eq([{ platform: "", label: "Join", url: "https://example.org/join" }])
      expect(described_class.normalize([{ url: "https://example.org/join" }]))
        .to eq([{ platform: "", label: "Join", url: "https://example.org/join" }])
    end

    it "accepts string keys, the shape a JSON-parsed FeatureControls config arrives in" do
      raw = [{ "platform" => "discord", "label" => "Our Discord", "url" => "https://discord.gg/abc" }]
      expect(described_class.normalize(raw))
        .to eq([{ platform: "discord", label: "Our Discord", url: "https://discord.gg/abc" }])
    end

    it "accepts symbol keys, the shape a hand-built config hash arrives in" do
      expect(described_class.normalize([{ platform: "telegram", url: "https://t.me/xyz" }]))
        .to eq([{ platform: "telegram", label: "Telegram", url: "https://t.me/xyz" }])
    end

    it "accepts a :name key as an alias for :platform" do
      expect(described_class.normalize([{ name: "irc", url: "irc://example.org/room" }]))
        .to eq([{ platform: "irc", label: "Irc", url: "irc://example.org/room" }])
    end

    it "accepts a \"name\" string key as an alias for \"platform\"" do
      expect(described_class.normalize([{ "name" => "irc", "url" => "irc://example.org/room" }]))
        .to eq([{ platform: "irc", label: "Irc", url: "irc://example.org/room" }])
    end

    it "returns an empty array for nil, and drops a non-Hash entry rather than raising" do
      expect(described_class.normalize(nil)).to eq([])
      expect(described_class.normalize(["not a hash", 42])).to eq([])
    end
  end

  describe "#list" do
    it "is empty for a scope with nothing configured" do
      expect(links.list(community: community, selector: "all")).to eq([])
    end

    it "returns the normalized entries a previous #replace wrote" do
      links.replace(
        community: community, selector: "all",
        entries: [{ "platform" => "discord", "label" => "Our Discord", "url" => "https://discord.gg/abc" }]
      )
      expect(links.list(community: community, selector: "all"))
        .to eq([{ platform: "discord", label: "Our Discord", url: "https://discord.gg/abc" }])
    end

    it "normalizes a config written some other way (a raw feature set), not only one #replace wrote" do
      raw = [{ "platform" => "matrix", "url" => "https://matrix.to/#/room" }, { "platform" => "irc" }]
      feature_controls.set(community: community, selector: "all", feature: "utility_commands",
                            key: "platforms", value: JSON.generate(raw))
      expect(links.list(community: community, selector: "all"))
        .to eq([{ platform: "matrix", label: "Matrix", url: "https://matrix.to/#/room" }])
    end

    it "scopes to one room, leaving the community default untouched" do
      links.replace(community: community, selector: "general",
                     entries: [{ "platform" => "discord", "url" => "https://discord.gg/abc" }])
      expect(links.list(community: community, selector: "all")).to eq([])
      expect(links.list(community: community, selector: "general"))
        .to eq([{ platform: "discord", label: "Discord", url: "https://discord.gg/abc" }])
    end
  end

  describe "#replace" do
    it "writes the normalized entries under utility_commands' platforms config key" do
      links.replace(community: community, selector: "all",
                     entries: [{ "platform" => "discord", "label" => "", "url" => "https://discord.gg/abc" }])
      expect(row_for(room_id: nil).json_value(:config)).to eq(
        "platforms" => [{ "platform" => "discord", "label" => "Discord", "url" => "https://discord.gg/abc" }]
      )
    end

    it "drops a url-less row before it ever reaches storage" do
      links.replace(
        community: community, selector: "all",
        entries: [{ "platform" => "matrix", "url" => "" }, { "platform" => "irc", "url" => "irc://example.org/room" }]
      )
      expect(row_for(room_id: nil).json_value(:config)).to eq(
        "platforms" => [{ "platform" => "irc", "label" => "Irc", "url" => "irc://example.org/room" }]
      )
    end

    it "returns the normalized entries, for a caller's own reporting" do
      result = links.replace(
        community: community, selector: "all",
        entries: [
          { "platform" => "discord", "url" => "https://discord.gg/abc" },
          { "platform" => "matrix", "url" => "" }
        ]
      )
      expect(result).to eq([{ platform: "discord", label: "Discord", url: "https://discord.gg/abc" }])
    end

    it "targets a room by its room_key, writing a single row, community default untouched" do
      links.replace(community: community, selector: "general",
                     entries: [{ "platform" => "discord", "url" => "https://discord.gg/abc" }])
      expect(row_for(room_id: room_id_for("general"))).not_to be_nil
      expect(row_for(room_id: nil)).to be_nil
    end

    it "does not enable utility_commands, only stages the config, matching FeatureControls#set's own contract" do
      links.replace(community: community, selector: "all",
                     entries: [{ "platform" => "discord", "url" => "https://discord.gg/abc" }])
      expect([false, 0]).to include(row_for(room_id: nil).enabled)
    end

    it "lets a FeatureControls::Invalid for an unresolved selector surface rather than swallowing it" do
      expect { links.replace(community: community, selector: "zzz", entries: []) }
        .to raise_error(Rubotty::ControlPlane::FeatureControls::Invalid, /matched "zzz"/)
    end
  end
end
