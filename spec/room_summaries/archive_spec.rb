# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::RoomSummaries::Archive, :control_plane do
  include Builders

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.utc(2026, 8, 16, 12) }
  let(:archive) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }
  let(:endpoint) do
    Rubotty::Core::Endpoint.new(id: "telegram-general", adapter_name: :telegram, account: "default",
                                settings: { room_key: "k" })
  end

  def create_community(slug)
    models.community.create(
      slug: slug, name: slug, status: "active", settings: "{}", created_at: now, updated_at: now
    )
  end

  def retain(community:, room_key:, native_id:, text: "hello")
    archive.record(
      community_id: community.id, room_key: room_key,
      message: message(endpoint, native_id: native_id, text: text)
    )
  end

  it "keeps source text inside its exact community and room" do
    first = create_community("first")
    second = create_community("second")
    retain(community: first, room_key: "general", native_id: "one", text: "first room")
    retain(community: first, room_key: "other", native_id: "two", text: "other room")
    retain(community: second, room_key: "general", native_id: "three", text: "other community")

    entries = archive.messages(community_id: first.id, room_key: "general")

    expect(entries.map(&:body)).to eq(["first room"])
  end

  it "moves the watermark and removes only consumed source text after completion" do
    community = create_community("first")
    retain(community: community, room_key: "general", native_id: "one")
    retain(community: community, room_key: "general", native_id: "two")
    entries = archive.messages(community_id: community.id, room_key: "general")

    archive.complete(community_id: community.id, room_key: "general", last_message_id: entries.last.id)

    expect(archive.messages(community_id: community.id, room_key: "general")).to be_empty
    watermark = models.room_summary_watermark.where(community_id: community.id, room_key: "general").first
    expect(watermark.last_message_id).to eq(entries.last.id)
  end

  it "does not retain bot-authored or synthetic messages" do
    community = create_community("first")
    bot_message = message(endpoint, native_id: "bot", text: "notice", author: author(bot: true))
    synthetic_message = message(endpoint, native_id: "synthetic", text: "command", synthetic: true)

    archive.record(community_id: community.id, room_key: "general", message: bot_message)
    archive.record(community_id: community.id, room_key: "general", message: synthetic_message)

    expect(archive.messages(community_id: community.id, room_key: "general")).to be_empty
  end

  describe "#posted? and #mark_posted" do
    it "is not posted until #mark_posted claims that message id" do
      community = create_community("first")
      retain(community: community, room_key: "general", native_id: "one")
      entries = archive.messages(community_id: community.id, room_key: "general")

      expect(archive.posted?(community_id: community.id, room_key: "general", last_message_id: entries.last.id)).to be(false)

      archive.mark_posted(community_id: community.id, room_key: "general", last_message_id: entries.last.id)

      expect(archive.posted?(community_id: community.id, room_key: "general", last_message_id: entries.last.id)).to be(true)
    end

    it "claims delivery without moving the watermark or touching retained text" do
      community = create_community("first")
      retain(community: community, room_key: "general", native_id: "one")
      entries = archive.messages(community_id: community.id, room_key: "general")

      archive.mark_posted(community_id: community.id, room_key: "general", last_message_id: entries.last.id)

      expect(archive.messages(community_id: community.id, room_key: "general")).not_to be_empty
      expect(models.room_summary_watermark.where(community_id: community.id, room_key: "general").first.last_message_id).to eq(0)
    end

    it "leaves an earlier claim in place against a lower or equal message id" do
      community = create_community("first")
      retain(community: community, room_key: "general", native_id: "one")
      retain(community: community, room_key: "general", native_id: "two")
      entries = archive.messages(community_id: community.id, room_key: "general")

      archive.mark_posted(community_id: community.id, room_key: "general", last_message_id: entries.last.id)
      archive.mark_posted(community_id: community.id, room_key: "general", last_message_id: entries.first.id)

      expect(archive.posted?(community_id: community.id, room_key: "general", last_message_id: entries.last.id)).to be(true)
    end
  end

  describe "#pending_count" do
    it "counts unconsumed messages without loading them, and drops after completion" do
      community = create_community("first")
      retain(community: community, room_key: "general", native_id: "one")
      retain(community: community, room_key: "general", native_id: "two")

      expect(archive.pending_count(community_id: community.id, room_key: "general")).to eq(2)

      entries = archive.messages(community_id: community.id, room_key: "general")
      archive.complete(community_id: community.id, room_key: "general", last_message_id: entries.last.id)

      expect(archive.pending_count(community_id: community.id, room_key: "general")).to eq(0)
    end
  end

  describe "pin tracking" do
    it "has no pinned native id for a room that has never pinned one" do
      community = create_community("first")

      expect(
        archive.pinned_native_id(community_id: community.id, room_key: "general", endpoint_id: endpoint.id)
      ).to be_nil
    end

    it "remembers and replaces the last pinned native id per community, room and endpoint" do
      community = create_community("first")

      archive.track_pin(community_id: community.id, room_key: "general", endpoint_id: endpoint.id, native_id: "s1")
      expect(
        archive.pinned_native_id(community_id: community.id, room_key: "general", endpoint_id: endpoint.id)
      ).to eq("s1")

      archive.track_pin(community_id: community.id, room_key: "general", endpoint_id: endpoint.id, native_id: "s2")
      expect(
        archive.pinned_native_id(community_id: community.id, room_key: "general", endpoint_id: endpoint.id)
      ).to eq("s2")
      expect(
        models.room_summary_pin.where(community_id: community.id, room_key: "general", endpoint_id: endpoint.id).count
      ).to eq(1)
    end

    it "keeps a room's tracked pin separate per endpoint" do
      community = create_community("first")
      other_endpoint_id = "discord-general"

      archive.track_pin(community_id: community.id, room_key: "general", endpoint_id: endpoint.id, native_id: "s1")
      archive.track_pin(community_id: community.id, room_key: "general", endpoint_id: other_endpoint_id, native_id: "s2")

      expect(
        archive.pinned_native_id(community_id: community.id, room_key: "general", endpoint_id: endpoint.id)
      ).to eq("s1")
      expect(
        archive.pinned_native_id(community_id: community.id, room_key: "general", endpoint_id: other_endpoint_id)
      ).to eq("s2")
    end
  end
end
