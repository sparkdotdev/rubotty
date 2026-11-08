# frozen_string_literal: true

require "spec_helper"

# A thin composition over FeatureControls, so the dashboard's word-filter route and the
# admin API share one custom word list.
RSpec.describe Rubotty::ControlPlane::WordFilterEntries, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  subject(:entries) { described_class.new(feature_controls: controls) }

  def config_for(room_id: nil)
    models.feature_setting.where(community_id: community.id, room_id: room_id, feature: "word_filter")
          .first&.json_value(:config)
  end

  describe "#list" do
    it "returns an empty array for a scope with no word_filter row yet" do
      expect(entries.list(community: community, selector: "all")).to eq([])
    end

    it "returns the stored custom list for the community scope" do
      controls.set(community: community, selector: "all", feature: "word_filter",
                   key: "custom", value: '["housebanned","other thing"]')
      expect(entries.list(community: community, selector: "all")).to eq(["housebanned", "other thing"])
    end

    it "returns the stored custom list for a room scope, resolved by room key" do
      controls.set(community: community, selector: "general", feature: "word_filter",
                   key: "custom", value: '["local word"]')
      expect(entries.list(community: community, selector: "general")).to eq(["local word"])
      # The community scope is a different row entirely.
      expect(entries.list(community: community, selector: "all")).to eq([])
    end

    it "returns an empty array when the row's custom key is not an array" do
      controls.set(community: community, selector: "all", feature: "word_filter",
                   key: "custom", value: "native")
      expect(entries.list(community: community, selector: "all")).to eq([])
    end
  end

  describe "#replace" do
    it "writes the whole list under the custom key, as a JSON array" do
      entries.replace(community: community, selector: "all", entries: %w[foo bar])
      expect(config_for["custom"]).to eq(%w[foo bar])
    end

    it "returns the stored list" do
      result = entries.replace(community: community, selector: "general", entries: ["one word"])
      expect(result).to eq(["one word"])
    end

    it "overwrites a previous list rather than merging into it" do
      entries.replace(community: community, selector: "all", entries: %w[foo bar])
      entries.replace(community: community, selector: "all", entries: %w[baz])
      expect(config_for["custom"]).to eq(%w[baz])
    end

    it "writes an empty list when given no entries, clearing whatever was there" do
      entries.replace(community: community, selector: "all", entries: %w[foo])
      entries.replace(community: community, selector: "all", entries: [])
      expect(config_for["custom"]).to eq([])
    end

    it "does not disturb the mode or other config keys already on the row" do
      controls.set(community: community, selector: "all", feature: "word_filter", key: "mode", value: "slurs")
      entries.replace(community: community, selector: "all", entries: %w[foo])
      config = config_for
      expect(config["mode"]).to eq("slurs")
      expect(config["custom"]).to eq(%w[foo])
    end

    it "leaves an existing room row's enabled state untouched" do
      controls.enable(community: community, selector: "general", feature: "word_filter")
      entries.replace(community: community, selector: "general", entries: %w[foo])
      row = models.feature_setting.where(community_id: community.id,
                                         room_id: models.room.where(community_id: community.id,
                                                                    room_key: "general").first.id,
                                         feature: "word_filter").first
      expect([true, 1]).to include(row.enabled)
    end
  end

  describe "#remove" do
    it "removes the named word and leaves the rest" do
      entries.replace(community: community, selector: "all", entries: %w[foo bar baz])
      result = entries.remove(community: community, selector: "all", value: "bar")
      expect(result).to eq(%w[foo baz])
      expect(config_for["custom"]).to eq(%w[foo baz])
    end

    it "removes only one occurrence of a duplicated value" do
      entries.replace(community: community, selector: "all", entries: %w[foo foo bar])
      result = entries.remove(community: community, selector: "all", value: "foo")
      expect(result).to eq(%w[foo bar])
    end

    it "raises Invalid when the value is not in the list" do
      entries.replace(community: community, selector: "all", entries: %w[foo])
      expect { entries.remove(community: community, selector: "all", value: "missing") }
        .to raise_error(described_class::Invalid, /no such word or phrase/)
    end

    it "raises Invalid for a scope with no custom list at all" do
      expect { entries.remove(community: community, selector: "all", value: "anything") }
        .to raise_error(described_class::Invalid)
    end

    it "operates on the scope it is given, not some other room's list" do
      entries.replace(community: community, selector: "general", entries: %w[room-word])
      expect { entries.remove(community: community, selector: "all", value: "room-word") }
        .to raise_error(described_class::Invalid)
      expect(entries.list(community: community, selector: "general")).to eq(%w[room-word])
    end
  end
end
