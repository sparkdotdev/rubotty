# frozen_string_literal: true

require "spec_helper"

# The guest portal modelled as a platform adapter: queued guest sends enter the
# pipeline from the room's one guest endpoint, and #deliver writes messages from
# every platform bridged into the room back into that same room-scoped feed.
RSpec.describe Rubotty::Adapters::Guest::Adapter, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:dc_channel) { models.channel.where(community_id: community.id, endpoint_key: "dc-general").first }
  let(:tg_channel) { models.channel.where(community_id: community.id, endpoint_key: "tg-general").first }

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models) }
  let(:feed) { Rubotty::ControlPlane::GuestFeed.new(models: models) }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }

  subject(:adapter) do
    described_class.new(dispatcher: dispatcher, feed: feed, invites: invites, models: models,
                        registry: registry, logger: Rubotty::Log.null)
  end

  def allow_guests!
    controls.enable(community: community, selector: "general", feature: "guest_portal")
    registry.reload
  end

  def issue!(nickname: "Sam")
    invites.issue(community: community, room: room, nickname: nickname, ttl_seconds: 3600).invite
  end

  # The single synthesised guest endpoint for the "general" room in the live topology.
  def guest_endpoint = registry.current.topology.endpoint(Rubotty::Adapters::Guest.endpoint_key_for(room.id))

  describe "receiving (guest -> room)" do
    before { allow_guests! }

    it "emits a pending guest send as a chat message from the room's guest endpoint" do
      invite = issue!(nickname: "Visiting Reviewer")
      feed.record_out(invite: invite, body: "hello everyone")

      adapter.receive_pending

      message = dispatcher.last
      expect(message).not_to be_nil
      expect(message.origin.id).to eq(Rubotty::Adapters::Guest.endpoint_key_for(room.id))
      expect(message.body.text).to eq("hello everyone")
      expect(message.sender_label).to be_a(Rubotty::Core::SenderLabel)
      expect(message.sender_label.guest?).to be(true)
      expect(message.sender_label.to_s).to eq("Visiting Reviewer@guest-user")
    end

    it "stamps the send relayed so it is never emitted twice" do
      invite = issue!
      feed.record_out(invite: invite, body: "once")
      adapter.receive_pending
      adapter.receive_pending
      expect(dispatcher.messages.length).to eq(1)
      expect(feed.pending_out).to be_empty
    end

    it "drops, without emitting, a send whose invite has been revoked" do
      invite = issue!
      feed.record_out(invite: invite, body: "too late")
      invites.revoke(invite: invite)

      adapter.receive_pending
      expect(dispatcher.messages).to be_empty
      expect(feed.pending_out).to be_empty
    end

    # An unroutable send waits for the endpoint to come back rather than being
    # lost, but the wait is bounded: the relay re-reads it every second.
    it "keeps a waiting send queued until it passes the ceiling, then gives up on it" do
      invite = issue!
      row = feed.record_out(invite: invite, body: "stuck")
      controls.disable(community: community, selector: "general", feature: "guest_portal")
      registry.reload

      adapter.receive_pending
      expect(feed.pending_out.map(&:id)).to eq([row.id])

      row.update(created_at: Time.now - Rubotty::ControlPlane::GuestFeed::MAX_WAIT_SECONDS - 60)
      adapter.receive_pending

      expect(feed.pending_out).to be_empty
      expect(dispatcher.messages).to be_empty
    end

    it "drops a send for a room that no longer allows guests" do
      invite = issue!
      feed.record_out(invite: invite, body: "gone")
      controls.disable(community: community, selector: "general", feature: "guest_portal")
      registry.reload

      adapter.receive_pending
      expect(dispatcher.messages).to be_empty
    end
  end

  describe "delivering (room -> guest), merged across every platform (issue #156)" do
    before { allow_guests! }

    def relayed_message(text, from: "tg-general")
      Rubotty::Core::Message.new(
        kind: :chat, ref: Rubotty::Core::MessageRef.new(from, "99"),
        origin: registry.current.topology.endpoint(from),
        author: Rubotty::Core::Author.new(username: "ada"),
        body: Rubotty::Core::RichText.plain(text),
        sender_label: Rubotty::Core::SenderLabel.new(username: "ada", platform: "telegram")
      )
    end

    it "writes an incoming feed row, scoped to the room, when a guest is live" do
      issue!
      receipt = adapter.deliver(relayed_message("hi from telegram"), guest_endpoint)
      row = models.guest_message.where(direction: "in").first
      expect(row.body).to eq("hi from telegram")
      expect(row.room_id).to eq(room.id)
      expect(receipt.native_id).to eq(row.id.to_s)
    end

    it "records the real originating channel as an optional, informational marker" do
      issue!
      adapter.deliver(relayed_message("from telegram", from: "tg-general"), guest_endpoint)
      adapter.deliver(relayed_message("from discord", from: "dc-general"), guest_endpoint)

      rows = models.guest_message.where(direction: "in").order(:id).all
      expect(rows.map(&:channel_id)).to eq([tg_channel.id, dc_channel.id])
    end

    it "merges messages from every platform bridged into the room into ONE feed a guest reads" do
      invite = issue!
      invites.record_join(invite: invite, cursor: feed.latest_id(room_id: room.id))
      adapter.deliver(relayed_message("from telegram", from: "tg-general"), guest_endpoint)
      adapter.deliver(relayed_message("from discord", from: "dc-general"), guest_endpoint)

      bodies = feed.for_guest(invite: invite.refresh, since: 0).map(&:body)
      expect(bodies).to eq(["from telegram", "from discord"])
    end

    it "declines (writes nothing) when no guest is live in the room" do
      expect { adapter.deliver(relayed_message("nobody home"), guest_endpoint) }
        .not_to change { models.guest_message.where(direction: "in").count }
    end

    # Routine, not a loss: Features::Bridge tells this apart from a copy that
    # was attempted and produced nothing.
    it "signals the decline as NOT_APPLICABLE rather than a bare nil" do
      receipt = adapter.deliver(relayed_message("nobody home"), guest_endpoint)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
    end
  end

  describe "receiving an uploaded file (issue #136)" do
    before { allow_guests! }

    it "emits a guest upload as a chat carrying the file as an attachment" do
      invite = issue!
      feed.record_out(invite: invite, body: "have a look", attachments: [
                        { "kind" => "photo", "url" => "https://host/uploads/tok",
                          "filename" => "shot.png", "mime_type" => "image/png" }
                      ])

      adapter.receive_pending

      message = dispatcher.last
      expect(message.body.text).to eq("have a look")
      expect(message.attachments.size).to eq(1)
      attachment = message.attachments.first
      expect(attachment.kind).to eq(:photo)
      expect(attachment.url).to eq("https://host/uploads/tok")
      expect(attachment.filename).to eq("shot.png")
    end
  end

  describe "#delete" do
    before { allow_guests! }

    it "removes a guest feed row by id" do
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "x")
      adapter.delete(guest_endpoint, row.id.to_s)
      expect(models.guest_message[row.id]).to be_nil
    end

    it "appends a delete event a live guest can apply, naming the removed row (issue #136)" do
      issue! # a live guest is in the room
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "x")
      adapter.delete(guest_endpoint, row.id.to_s)

      event = models.guest_message.where(kind: "delete").first
      expect(event).not_to be_nil
      expect(event.ref_id).to eq(row.id)
    end
  end

  # An operator's /delete gates on moderates?, the automatic filters gate on
  # deletes?, and the adapter declared only the second. The guest feed was
  # therefore cleaned by a word filter hit and left alone by a moderator, so
  # guests kept reading a message the moderator saw go everywhere else.
  describe "#moderate" do
    before { allow_guests! }

    def delete_command(native_id)
      Rubotty::Core::Moderation::Command.new(
        action: :delete, issuer: nil, origin: guest_endpoint,
        target_ref: Rubotty::Core::MessageRef.new(guest_endpoint.id, native_id)
      )
    end

    it "declares delete as a moderation action it can carry out" do
      expect(adapter.capabilities_for(guest_endpoint).moderates?(:delete)).to be(true)
    end

    it "removes the row on an operator's delete" do
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "x")

      result = adapter.moderate(delete_command(row.id.to_s), guest_endpoint, row.id.to_s)

      expect(result.status).to eq(:done)
      expect(models.guest_message[row.id]).to be_nil
    end

    # A guest holds a session rather than an account, so there is nobody to ban
    # and nothing to pin. Those stay honestly unsupported.
    it "declares nothing else, since a session is not an account" do
      capabilities = adapter.capabilities_for(guest_endpoint)

      expect(%i[ban kick mute pin unpin].map { |a| capabilities.moderates?(a) }).to all(be(false))
    end
  end

  describe "#edit (issue #136)" do
    before { allow_guests! }

    def relayed_edit(text)
      Rubotty::Core::Message.new(
        kind: :edit, ref: Rubotty::Core::MessageRef.new("tg-general", "99"),
        origin: registry.current.topology.endpoint("tg-general"),
        body: Rubotty::Core::RichText.plain(text)
      )
    end

    it "rewrites the row and, for a live guest, appends an edit event naming it" do
      issue!
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "old")
      adapter.edit(relayed_edit("new"), guest_endpoint, row.id.to_s)

      expect(models.guest_message[row.id].body).to eq("new")
      event = models.guest_message.where(kind: "edit").first
      expect(event.ref_id).to eq(row.id)
      expect(event.body).to eq("new")
    end

    it "does not append an event when no guest is live" do
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "old")
      expect { adapter.edit(relayed_edit("new"), guest_endpoint, row.id.to_s) }
        .not_to change { models.guest_message.where(kind: "edit").count }
      expect(models.guest_message[row.id].body).to eq("new")
    end
  end

  describe "#sync_reactions (issue #136)" do
    before { allow_guests! }

    it "appends a reaction event carrying the rendered summary for a live guest" do
      issue!
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "x")
      desired = [Rubotty::Core::Reaction.new(emoji: "\u{1F44D}"), Rubotty::Core::Reaction.new(emoji: "❤")]
      adapter.sync_reactions(guest_endpoint, row.id.to_s, desired: desired, previous: [])

      event = models.guest_message.where(kind: "reaction").first
      expect(event.ref_id).to eq(row.id)
      expect(event.body).to eq("\u{1F44D} ❤")
    end

    it "writes nothing when no guest is live in the room" do
      row = feed.record_in(community_id: community.id, room_id: room.id, author_label: "a", body: "x")
      expect do
        adapter.sync_reactions(guest_endpoint, row.id.to_s,
                               desired: [Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")], previous: [])
      end.not_to change { models.guest_message.where(kind: "reaction").count }
    end
  end

  describe "identity" do
    it "reports the guest domain as its origin label and a stable own id" do
      expect(adapter.origin_label).to eq("guest-user")
      expect(adapter.own_account_id).to eq(Rubotty::Adapters::Guest::OWN_ID)
    end
  end

  describe "#start and #stop" do
    before { allow_guests! }

    it "joins the poll thread rather than killing it, so a send already claimed still reaches the dispatcher" do
      stub_const("#{described_class}::POLL_INTERVAL", 0.02)
      claimed = Queue.new
      release = Queue.new
      allow(feed).to receive(:mark_relayed).and_wrap_original do |original, row|
        original.call(row)
        claimed << :claimed
        release.pop
      end

      adapter.start
      feed.record_out(invite: issue!, body: "in flight")
      claimed.pop # the poll thread has claimed the row and is now stuck before emit

      stopper = Thread.new { adapter.stop }
      sleep 0.05 # give the old kill-first behaviour a chance to land before we let it proceed
      release << :go
      stopper.join

      expect(dispatcher.messages.map { |m| m.body.text }).to eq(["in flight"])
      expect(adapter.running?).to be(false)
    end
  end
end
