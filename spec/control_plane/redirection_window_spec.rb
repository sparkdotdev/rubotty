# frozen_string_literal: true

require "spec_helper"

# The one place outside the guest portal where ordinary chat outlives a send, so what
# the table refuses to hold matters more than what it keeps: the time window, the
# daily purge, the forget path and the per-community scoping.
RSpec.describe Rubotty::ControlPlane::RedirectionWindow, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:other) do
    now = Time.now
    models.community.create(slug: "other-co", name: "Other Co", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  let(:window) { described_class.new(models: models) }

  def keep(text, native_id: "1", community_id: community.id, room_key: "general",
           endpoint_id: "tg-general", store: window, **rest)
    store.record(
      community_id: community_id, room_key: room_key, endpoint_id: endpoint_id,
      native_id: native_id, body: Rubotty::Core::RichText.plain(text),
      author_handle: "ada", author_name: "Ada", author_id: "u1", **rest
    )
  end

  def texts(community_id: community.id, room_key: "general")
    window.for_room(community_id: community_id, room_key: room_key).map { |entry| entry.body.text }
  end

  describe "#record" do
    it "keeps what was said, under the endpoint it was said on" do
      keep("hello", native_id: "10")
      entry = window.for_room(community_id: community.id, room_key: "general").first

      expect(entry.body.text).to eq("hello")
      expect(entry.endpoint_id).to eq("tg-general")
      expect(entry.native_id).to eq("10")
      expect(entry.author_handle).to eq("ada")
    end

    # A repost has to read as the original did, so styling and files make the round trip.
    it "brings the styling and the files back out again" do
      window.record(
        community_id: community.id, room_key: "general", endpoint_id: "tg-general", native_id: "11",
        body: Rubotty::Core::RichText.new("bold word", [Rubotty::Core::Span.new(kind: :bold, begin_index: 0, end_index: 4)]),
        attachments: [Rubotty::Core::Attachment.new(kind: :photo, url: "https://example.test/a.png", filename: "a.png")]
      )
      entry = window.for_room(community_id: community.id, room_key: "general").first

      expect(entry.body.spans.map { |span| [span.kind, span.begin_index, span.end_index] }).to eq([[:bold, 0, 4]])
      expect(entry.attachments.map(&:filename)).to eq(["a.png"])
      expect(entry.attachments.first.kind).to eq(:photo)
    end

    # Features::Bridge relies on the swallow, so a failed write cannot lose a message.
    it "answers nil rather than raising when the write fails" do
      allow(models.redirection_window_message).to receive(:create).and_raise(Sequel::DatabaseError, "boom")

      expect { expect(keep("hello")).to be_nil }.not_to raise_error
    end
  end

  describe "the per-room range" do
    it "keeps more than the former 100-message ceiling in a busy room" do
      105.times { |index| keep("m#{index}", native_id: index.to_s) }

      kept = window.for_room(community_id: community.id, room_key: "general")
      expect(kept.length).to eq(105)
      expect(kept.first.body.text).to eq("m0")
      expect(kept.last.body.text).to eq("m104")
    end

    it "keeps each room separately" do
      keep("quiet", native_id: "q", room_key: "gaming")
      105.times { |index| keep("m#{index}", native_id: index.to_s) }

      expect(texts(room_key: "gaming")).to eq(["quiet"])
    end
  end

  describe "the TTL" do
    it "refuses a row past the TTL even when nothing has pruned it" do
      row = keep("stale")
      row.update(created_at: Time.now - (described_class::TTL_SECONDS + 1))

      expect(texts).to be_empty
      expect(models.redirection_window_message.count).to eq(1)
    end

    it "drops everything past the TTL on a prune and keeps what is still live" do
      stale = keep("stale", native_id: "1")
      stale.update(created_at: Time.now - (described_class::TTL_SECONDS + 1))
      keep("fresh", native_id: "2")

      expect(window.prune).to eq(1)
      expect(models.redirection_window_message.select_map(:body)).to eq(["fresh"])
    end

  end

  describe "#forget" do
    it "drops what was kept for one message and leaves the rest" do
      keep("one", native_id: "10")
      keep("two", native_id: "11")

      expect(window.forget(community_id: community.id, endpoint_id: "tg-general", native_id: "11")).to eq(1)
      expect(texts).to eq(["one"])
    end

    it "will not reach into another community's row of the same id" do
      keep("ours", native_id: "10")
      keep("theirs", native_id: "10", community_id: other.id)

      window.forget(community_id: other.id, endpoint_id: "tg-general", native_id: "10")

      expect(texts).to eq(["ours"])
    end
  end

  describe "multi-tenant scoping" do
    it "never returns another community's rows for a room_key they both have" do
      keep("ours", native_id: "1")
      keep("theirs", native_id: "1", community_id: other.id)

      expect(texts).to eq(["ours"])
      expect(texts(community_id: other.id)).to eq(["theirs"])
    end

    it "never returns another room's rows in the same community" do
      keep("in general", native_id: "1")
      keep("in gaming", native_id: "2", room_key: "gaming")

      expect(texts).to eq(["in general"])
    end
  end
end
