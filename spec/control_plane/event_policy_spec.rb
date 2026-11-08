# frozen_string_literal: true

require "spec_helper"

# The read side of a room's "events" feature_settings row: whether the feature
# is on, and who may create an event there.
RSpec.describe Rubotty::ControlPlane::EventPolicy, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:other_room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  subject(:policy) { described_class.new(models: models) }

  describe "#room_policy" do
    it "is disabled with the operators default when the feature has never been touched" do
      resolved = policy.room_policy(community: community, room: room)
      expect(resolved).to eq(enabled: false, who_can_create: "operators")
    end

    it "resolves enabled once the room's events feature is turned on" do
      controls.enable(community: community, selector: room.room_key, feature: "events")
      resolved = policy.room_policy(community: community, room: room)
      expect(resolved[:enabled]).to be(true)
    end

    it "falls back to the community-wide default when the room has no row of its own" do
      controls.enable(community: community, selector: "all", feature: "events")
      controls.set(community: community, selector: "all", feature: "events",
                   key: "who_can_create", value: "everyone")
      resolved = policy.room_policy(community: community, room: other_room)
      expect(resolved).to eq(enabled: true, who_can_create: "everyone")
    end

    it "lets a room override the community default" do
      controls.enable(community: community, selector: "all", feature: "events")
      controls.set(community: community, selector: "all", feature: "events",
                   key: "who_can_create", value: "everyone")
      controls.enable(community: community, selector: room.room_key, feature: "events")
      controls.set(community: community, selector: room.room_key, feature: "events",
                   key: "who_can_create", value: "operators")

      resolved = policy.room_policy(community: community, room: room)
      expect(resolved).to eq(enabled: true, who_can_create: "operators")

      # The other room still sees the community default.
      other_resolved = policy.room_policy(community: community, room: other_room)
      expect(other_resolved).to eq(enabled: true, who_can_create: "everyone")
    end

    it "treats an unrecognised who_can_create value as operators, not a crash" do
      controls.enable(community: community, selector: room.room_key, feature: "events")
      controls.set(community: community, selector: room.room_key, feature: "events",
                   key: "who_can_create", value: "literally anyone")
      resolved = policy.room_policy(community: community, room: room)
      expect(resolved[:who_can_create]).to eq("operators")
    end

    it "resolves the community default alone when room is nil" do
      controls.enable(community: community, selector: "all", feature: "events")
      resolved = policy.room_policy(community: community, room: nil)
      expect(resolved[:enabled]).to be(true)
    end
  end

  describe "#reminder_intervals_for" do
    it "falls back to the feature's hardcoded default when nothing is configured" do
      resolved = policy.reminder_intervals_for(community_id: community.id, room_id: room.id)
      expect(resolved).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS)
    end

    it "uses the community-wide default once configured" do
      controls.enable(community: community, selector: "all", feature: "events")
      controls.set(community: community, selector: "all", feature: "events",
                   key: "default_reminder_intervals", value: [3600, 900])
      resolved = policy.reminder_intervals_for(community_id: community.id, room_id: room.id)
      expect(resolved).to eq([3600, 900])
    end

    it "lets a room override the community default" do
      controls.enable(community: community, selector: "all", feature: "events")
      controls.set(community: community, selector: "all", feature: "events",
                   key: "default_reminder_intervals", value: [3600, 900])
      controls.enable(community: community, selector: room.room_key, feature: "events")
      controls.set(community: community, selector: room.room_key, feature: "events",
                   key: "default_reminder_intervals", value: [1800])

      expect(policy.reminder_intervals_for(community_id: community.id, room_id: room.id)).to eq([1800])
      # The other room still sees the community default.
      expect(policy.reminder_intervals_for(community_id: community.id, room_id: other_room.id)).to eq([3600, 900])
    end

    it "honours a deliberately configured empty ladder rather than falling back to the hardcoded default" do
      controls.enable(community: community, selector: "all", feature: "events")
      controls.set(community: community, selector: "all", feature: "events",
                   key: "default_reminder_intervals", value: [])
      resolved = policy.reminder_intervals_for(community_id: community.id, room_id: room.id)
      expect(resolved).to eq([])
    end

    it "resolves the community default alone when room_id is nil" do
      controls.enable(community: community, selector: "all", feature: "events")
      controls.set(community: community, selector: "all", feature: "events",
                   key: "default_reminder_intervals", value: [900])
      resolved = policy.reminder_intervals_for(community_id: community.id, room_id: nil)
      expect(resolved).to eq([900])
    end
  end

  describe "#permitted?" do
    it "lets an operator create regardless of the who_can_create value" do
      expect(policy.permitted?("operators", :operator)).to be(true)
      expect(policy.permitted?("everyone", :operator)).to be(true)
    end

    it "refuses a normal member when who_can_create is operators" do
      expect(policy.permitted?("operators", :member)).to be(false)
    end

    it "lets a normal member create when who_can_create is everyone" do
      expect(policy.permitted?("everyone", :member)).to be(true)
    end
  end
end
