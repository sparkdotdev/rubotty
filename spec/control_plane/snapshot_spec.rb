# frozen_string_literal: true

require "spec_helper"

# Enablement resolves a room row, then a community row, then the feature
# class's own code default, asked through the catalog rather than one
# hardcoded feature name.
RSpec.describe Rubotty::ControlPlane::Snapshot::Community, "#feature_enabled?" do
  def setting(feature, enabled:, room_key: nil)
    Rubotty::ControlPlane::Snapshot::FeatureSetting.new(room_key: room_key, feature: feature, enabled: enabled)
  end

  def community_with(feature_settings)
    general = endpoint("general")
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: 1, slug: "acme", name: "acme", status: "active", settings: {},
      topology: topology(room("general", general)),
      channels: [
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: general, community_id: 1, route_key: general.id)
      ],
      operators: Rubotty::Core::Moderation::Directory.new([]),
      people: Rubotty::Core::Directory.new([]),
      feature_settings: feature_settings
    )
  end

  it "prefers a room row over a community row for the same feature" do
    community = community_with([
      setting("word_filter", enabled: false),
      setting("word_filter", enabled: true, room_key: "general")
    ])

    expect(community.feature_enabled?("general", "word_filter")).to be(true)
  end

  it "prefers a community row over the code default" do
    community = community_with([setting("word_filter", enabled: true)])

    expect(community.feature_enabled?("general", "word_filter")).to be(true)
  end

  it "falls back to the code default, on, when a feature declares itself on and no row exists" do
    community = community_with([])

    expect(community.feature_enabled?("general", "moderation")).to be(true)
  end

  it "falls back to the code default, off, when a feature declares itself off and no row exists" do
    community = community_with([])

    expect(community.feature_enabled?("general", "word_filter")).to be(false)
  end

  it "answers false for an unknown feature name rather than raising" do
    community = community_with([])

    expect { community.feature_enabled?("general", "not_a_real_feature") }.not_to raise_error
    expect(community.feature_enabled?("general", "not_a_real_feature")).to be(false)
  end

  it "still enables bridge by default with no row, as before the fix" do
    community = community_with([])

    expect(community.feature_enabled?("general", "bridge")).to be(true)
  end

  it "still lets a community row turn bridge off" do
    community = community_with([setting("bridge", enabled: false)])

    expect(community.feature_enabled?("general", "bridge")).to be(false)
  end
end
