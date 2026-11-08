# frozen_string_literal: true

require "spec_helper"

# A process that dies between sweeps leaves rows behind, so the TTL has to bound what
# a read returns and not just what the sweep deletes. Reads scope by community as well
# as room_key, since room_key is unique only within a community.
RSpec.describe Rubotty::ControlPlane::LiveRoomFeed, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:other) do
    now = Time.now
    models.community.create(slug: "other-co", name: "Other Co", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  let(:feed) { described_class.new(models: models) }

  def record(text, community_id: community.id, room_key: "general")
    feed.record(community_id: community_id, room_key: room_key, body: text,
                origin_key: "tg-general", author_label: "ada@telegram")
  end

  describe "#record" do
    it "stores what the room saw and hands back the row" do
      row = record("hello")

      expect(row.body).to eq("hello")
      expect(row.room_key).to eq("general")
      expect(row.kind).to eq("chat")
      expect(row.origin_key).to eq("tg-general")
    end

    # Features::Bridge relies on the swallow, so a failed buffer write cannot lose
    # a delivery.
    it "answers nil rather than raising when the write fails" do
      allow(models.live_room_message).to receive(:create).and_raise(Sequel::DatabaseError, "boom")

      expect { expect(record("hello")).to be_nil }.not_to raise_error
    end
  end

  describe "#since" do
    it "returns a room's rows above the cursor, oldest first" do
      first = record("one")
      record("two")

      expect(feed.since(community_id: community.id, room_key: "general", since: first.id).map(&:body))
        .to eq(["two"])
    end

    it "never returns another community's rows for a room_key they both have" do
      record("ours")
      record("theirs", community_id: other.id)

      expect(feed.since(community_id: community.id, room_key: "general").map(&:body)).to eq(["ours"])
      expect(feed.since(community_id: other.id, room_key: "general").map(&:body)).to eq(["theirs"])
    end

    it "never returns another room's rows in the same community" do
      record("in general")
      record("in lounge", room_key: "lounge")

      expect(feed.since(community_id: community.id, room_key: "general").map(&:body)).to eq(["in general"])
    end

    it "refuses a row past the TTL even when nothing has pruned it" do
      row = record("stale")
      row.update(created_at: Time.now - (described_class::TTL_SECONDS + 1))

      expect(feed.since(community_id: community.id, room_key: "general")).to be_empty
      expect(models.live_room_message.count).to eq(1)
    end
  end

  describe "#latest_id" do
    it "is 0 for a room with nothing buffered, so a fresh stream starts at the beginning of nothing" do
      expect(feed.latest_id(community_id: community.id, room_key: "general")).to eq(0)
    end

    it "is the head of that room's own rows, not another community's" do
      record("theirs", community_id: other.id)
      ours = record("ours")

      expect(feed.latest_id(community_id: community.id, room_key: "general")).to eq(ours.id)
    end
  end

  describe "#prune" do
    it "drops everything past the TTL and keeps what is still live" do
      stale = record("stale")
      stale.update(created_at: Time.now - (described_class::TTL_SECONDS + 1))
      record("fresh")

      expect(feed.prune).to eq(1)
      expect(models.live_room_message.select_map(:body)).to eq(["fresh"])
    end

    # The write path sweeps too, throttled so a busy room does not delete per message.
    it "runs from the write path once the throttle interval has passed" do
      now = Time.now
      clock = -> { now }
      throttled = described_class.new(models: models, clock: clock)
      throttled.record(community_id: community.id, room_key: "general", body: "first")

      now += described_class::TTL_SECONDS + described_class::PRUNE_INTERVAL + 1
      throttled.record(community_id: community.id, room_key: "general", body: "second")

      expect(models.live_room_message.select_map(:body)).to eq(["second"])
    end
  end
end
