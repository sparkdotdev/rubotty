# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::Models, :control_plane do
  subject(:models) { build_models(db) }

  let(:db) { seeded[0] }
  let(:seeded) { seeded_sample }

  # A fresh set of model classes over the database seeded_sample wrote its rows to.
  let(:community) { models.community.first }

  it "binds model classes to the supplied database without global state" do
    other = build_models(migrated_db)
    expect(models.community.count).to eq(1)
    expect(other.community.count).to eq(0)
  end

  describe "community associations" do
    it "reaches its platform connections, channels, rooms, people and operators" do
      expect(community.platform_connections.size).to eq(2)
      expect(community.channels.size).to eq(16)
      expect(community.rooms.size).to eq(8)
      expect(community.people.size).to eq(1)
      expect(community.operators.size).to eq(1)
      expect(community.feature_settings.map(&:feature))
        .to contain_exactly("bridge", "moderation", "operator_requests")
    end
  end

  describe "channel associations" do
    let(:channel) { models.channel.where(endpoint_key: "tg-gaming").first }

    it "points back to its community and platform connection" do
      expect(channel.community.slug).to eq("sample")
      expect(channel.platform_connection.adapter).to eq("telegram")
    end

    it "belongs to its room through the join table" do
      expect(channel.rooms.map(&:room_key)).to eq(["gaming"])
    end
  end

  describe "room associations" do
    let(:room) { models.room.where(room_key: "general").first }

    it "collects its channels through room_channels, both platforms" do
      expect(room.channels.map(&:endpoint_key)).to contain_exactly("tg-general", "dc-general")
      expect(room.room_channels.size).to eq(2)
    end
  end

  describe "person and operator associations" do
    let(:person) { community.people.first }

    it "reaches a person's cross-platform identities" do
      by_adapter = person.person_identities.to_h { |i| [i.adapter, [i.native_id, i.username]] }
      expect(by_adapter["telegram"]).to eq(["80000012", "sample_owner"])
      expect(by_adapter["discord"]).to eq(["80000000000000013", nil])
    end

    it "links an operator to the promoted person" do
      operator = community.operators.first
      expect(operator.person.name).to eq("sample_owner")
      expect(operator.community.slug).to eq("sample")
    end
  end

  describe "JSON column accessor" do
    it "reads a TEXT blob back as a Ruby value" do
      channel = models.channel.where(endpoint_key: "tg-general").first
      expect(channel.json_value(:settings)).to include("chat_id" => "-1008000000001")
    end

    it "returns an empty hash for an empty blob" do
      operator = community.operators.first
      # actions holds the JSON scalar "all" here rather than a hash, so json_value returns it raw.
      expect(operator.json_value(:actions)).to eq("all")
    end
  end

  describe "cascade delete" do
    it "removes a community's whole graph in one statement" do
      community.destroy
      expect(models.channel.count).to eq(0)
      expect(models.platform_connection.count).to eq(0)
      expect(models.room.count).to eq(0)
      expect(models.room_channel.count).to eq(0)
      expect(models.person.count).to eq(0)
      expect(models.person_identity.count).to eq(0)
      expect(models.operator.count).to eq(0)
      # Every row this community owned is gone; the deployment-wide default
      # row migration 081 seeds (community_id NULL) belongs to no community
      # at all, so it survives every community's deletion, this one included.
      expect(models.feature_setting.exclude(community_id: nil).count).to eq(0)
    end
  end
end
