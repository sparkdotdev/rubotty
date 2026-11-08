# frozen_string_literal: true

require "spec_helper"

# The bidirectional table the guest web app and the bot share. A guest's view
# is confined to the invite's room and never reaches below the join cursor.
RSpec.describe Rubotty::ControlPlane::GuestFeed, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:channel) { models.channel.where(community_id: community.id, endpoint_key: "dc-general").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  # A DIFFERENT room, for the room-scoping test.
  let(:other_room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models) }
  # A room admits guests only where the guest_portal feature is on.
  before do
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "general", feature: "guest_portal")
  end
  let(:invite) do
    invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600).invite
  end

  subject(:feed) { described_class.new(models: models) }

  describe "#record_out" do
    it "appends a pending guest send tagged with the guest domain, scoped to the room, no single channel" do
      row = feed.record_out(invite: invite, body: "hi there")
      expect(row.direction).to eq("out")
      expect(row.invite_id).to eq(invite.id)
      expect(row.room_id).to eq(room.id)
      expect(row.channel_id).to be_nil
      expect(row.author_label).to eq("Sam@guest-user")
      expect(row.body).to eq("hi there")
      expect(row.relayed_at).to be_nil
    end

    it "carries an uploaded file's attachment descriptor for the adapter to relay (issue #136)" do
      descriptor = { "kind" => "document", "url" => "https://host/uploads/tok", "filename" => "notes.pdf" }
      row = feed.record_out(invite: invite, body: "", attachments: [descriptor])
      expect(JSON.parse(row.attachments)).to eq([descriptor])
    end
  end

  describe "#record_in" do
    it "appends an incoming row carrying the rendered author and JSON attachments" do
      row = feed.record_in(
        community_id: community.id, room_id: room.id, author_label: "Ada [ada@discord]",
        body: "hello", attachments: [{ "kind" => "photo", "url" => "https://x/y.png" }]
      )
      expect(row.direction).to eq("in")
      expect(row.invite_id).to be_nil
      expect(JSON.parse(row.attachments)).to eq([{ "kind" => "photo", "url" => "https://x/y.png" }])
    end

    it "carries the real platform channel_id as an optional, informational marker (issue #156)" do
      row = feed.record_in(
        community_id: community.id, room_id: room.id, channel_id: channel.id,
        author_label: "Ada", body: "hello"
      )
      expect(row.room_id).to eq(room.id)
      expect(row.channel_id).to eq(channel.id)
    end
  end

  describe "#record_event" do
    it "appends a rich-inbound event naming the feed row it acts on (issue #136)" do
      target = feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "hi")
      row = feed.record_event(community_id: community.id, room_id: room.id,
                              ref_id: target.id, kind: described_class::EDIT, body: "hi (fixed)")
      expect(row.direction).to eq("in")
      expect(row.kind).to eq("edit")
      expect(row.ref_id).to eq(target.id)
      expect(row.body).to eq("hi (fixed)")
    end

    it "surfaces an event to a live guest, with its ref_id, through for_guest" do
      invites.record_join(invite: invite, cursor: feed.latest_id(room_id: room.id))
      target = feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "hi")
      feed.record_event(community_id: community.id, room_id: room.id,
                        ref_id: target.id, kind: described_class::REACTION, body: "\u{1F44D}")

      events = feed.for_guest(invite: invite.refresh, since: 0).select { |e| e.kind == "reaction" }
      expect(events.size).to eq(1)
      expect(events.first.ref_id).to eq(target.id)
      expect(events.first.body).to eq("\u{1F44D}")
    end
  end

  describe "#latest_id" do
    it "is zero for an empty room and the max id afterwards" do
      expect(feed.latest_id(room_id: room.id)).to eq(0)
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "1")
      expect(feed.latest_id(room_id: room.id)).to eq(row.id)
    end
  end

  describe "#for_guest" do
    before { invites.record_join(invite: invite, cursor: feed.latest_id(room_id: room.id)) }

    it "returns the guest's own sends and the room's incoming messages, oldest first" do
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "hi")
      feed.record_out(invite: invite, body: "hey")
      bodies = feed.for_guest(invite: invite.refresh, since: 0).map(&:body)
      expect(bodies).to eq(%w[hi hey])
    end

    it "merges messages from every channel bridged into the room (issue #156)" do
      dc_channel = models.channel.where(community_id: community.id, endpoint_key: "dc-general").first
      tg_channel = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first
      feed.record_in(community_id: community.id, room_id: room.id, channel_id: dc_channel.id,
                     author_label: "Ada", body: "from discord")
      feed.record_in(community_id: community.id, room_id: room.id, channel_id: tg_channel.id,
                     author_label: "Bob", body: "from telegram")
      bodies = feed.for_guest(invite: invite.refresh, since: 0).map(&:body)
      expect(bodies).to eq(["from discord", "from telegram"])
    end

    it "never returns a row from another room (room scoping)" do
      feed.record_in(community_id: community.id, room_id: other_room.id,
                     author_label: "Eve", body: "in the other room")
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "Ada", body: "mine")
      bodies = feed.for_guest(invite: invite.refresh, since: 0).map(&:body)
      expect(bodies).to eq(["mine"])
    end

    # A row written before the guest adapter filtered credentialed urls on
    # write still has one stored verbatim; for_guest must not hand it back.
    it "strips a credentialed url stored by a row written before the write side filtered it" do
      credentialed = "https://api.telegram.org/file/bot123456:AAH0ffP-secret/photos/f.jpg"
      feed.record_in(
        community_id: community.id, room_id: room.id, author_label: "Ada", body: "look",
        attachments: [{ "kind" => "photo", "url" => credentialed, "filename" => "f.jpg" }]
      )
      entry = feed.for_guest(invite: invite.refresh, since: 0).first
      expect(entry.attachments.first).not_to have_key("url")
      expect(entry.attachments.first["filename"]).to eq("f.jpg")
    end

    it "carries an ordinary stored url through untouched" do
      feed.record_in(
        community_id: community.id, room_id: room.id, author_label: "Ada", body: "look",
        attachments: [{ "kind" => "photo", "url" => "https://cdn.example/f.jpg" }]
      )
      entry = feed.for_guest(invite: invite.refresh, since: 0).first
      expect(entry.attachments.first["url"]).to eq("https://cdn.example/f.jpg")
    end

    it "excludes everything at or below the join cursor (no history before join)" do
      # The two below are backlog for an invite that joins after them, and must
      # stay hidden even when the client polls from since 0.
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "old-1")
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "old-2")
      late = invites.issue(community: community, room: room, nickname: "Late", ttl_seconds: 3600).invite
      invites.record_join(invite: late, cursor: feed.latest_id(room_id: room.id))

      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "new")
      bodies = feed.for_guest(invite: late.refresh, since: 0).map(&:body)
      expect(bodies).to eq(["new"])
    end

    # join_cursor is NULL until GuestPortal::App#join! pins it, which only ever
    # runs from GET /g/:token. Hitting messages.json (or the stream) straight
    # away, before that page ever loaded, must not fall through to floor 0 and
    # hand back the whole room's history.
    it "shows nothing to an invite that has never joined, rather than the whole room's history" do
      feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "before")
      never_joined = invites.issue(community: community, room: room, nickname: "Cold", ttl_seconds: 3600).invite
      expect(never_joined.join_cursor).to be_nil

      expect(feed.for_guest(invite: never_joined, since: 0)).to be_empty
    end
  end

  describe "relay bookkeeping" do
    it "lists only unrelayed out rows and stops listing one once relayed" do
      row = feed.record_out(invite: invite, body: "queued")
      expect(feed.pending_out.map(&:id)).to include(row.id)
      feed.mark_relayed(row)
      expect(feed.pending_out.map(&:id)).not_to include(row.id)
      expect(row.refresh.relayed_at).not_to be_nil
    end
  end

  # Without this bound the relay re-picks up an unroutable send every second for
  # as long as the invite lives, matching what the api adapters already do.
  describe "#expired?" do
    let(:start) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }

    it "gives up on a guest send that has waited past the ceiling, and not before" do
      fixed = described_class.new(models: models, clock: -> { start })
      row = fixed.record_out(invite: invite, body: "queued")

      expect(fixed.expired?(row, now: start + described_class::MAX_WAIT_SECONDS)).to be(false)
      expect(fixed.expired?(row, now: start + described_class::MAX_WAIT_SECONDS + 1)).to be(true)
    end
  end

  describe "#out_count_since" do
    it "counts the invite's sends inside the window" do
      3.times { |i| feed.record_out(invite: invite, body: "m#{i}") }
      expect(feed.out_count_since(invite: invite, since: Time.now - 3600)).to eq(3)
      expect(feed.out_count_since(invite: invite, since: Time.now + 3600)).to eq(0)
    end
  end
end
