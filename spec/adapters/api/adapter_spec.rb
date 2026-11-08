# frozen_string_literal: true

require "spec_helper"

# The bot-side half of posting through the REST API: queued posts enter the
# pipeline from the room's synthetic API endpoint, so the ordinary fan-out and
# every moderation feature see them like any other message.
RSpec.describe Rubotty::Adapters::Api::Adapter, :control_plane do

  # The ref the API route resolves before queueing: a meta-level action names
  # a message by the room it was minted in, never by a bare id.
  def message_ref(room, native_id)
    Rubotty::Core::MessageRef.new(Rubotty::Adapters::Api.endpoint_key_for(room.id), native_id)
  end
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:messages) { Rubotty::ControlPlane::ApiMessages.new(models: models) }
  let(:actions) { Rubotty::ControlPlane::ApiMessageActions.new(models: models) }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }

  let(:key) do
    Rubotty::ControlPlane::ApiKeys.new(models: models)
                                 .issue(scope: "developer", community: community, label: "ops console").key_row
  end

  subject(:adapter) do
    described_class.new(dispatcher: dispatcher, messages: messages, actions: actions, models: models,
                        registry: registry, logger: Rubotty::Log.null)
  end

  def enqueue(text, on: room)
    messages.enqueue(community: community, room: on, key: key, body: text)
  end

  describe "the room's synthetic endpoint" do
    it "exists in every room with a channel, with no feature to turn on first" do
      endpoint = registry.current.topology.endpoint(Rubotty::Adapters::Api.endpoint_key_for(room.id))

      expect(endpoint).not_to be_nil
      expect(endpoint.adapter_name).to eq(:api)
      # Receives so the dispatcher routes posts into the room; never sends, so
      # the fan-out still reaches every real channel.
      expect(endpoint.receives?).to be(true)
      expect(endpoint.sends?).to be(false)
    end

    it "is keyed on the room's database id, so two communities' rooms cannot collide" do
      expect(Rubotty::Adapters::Api.endpoint_key_for(room.id)).to eq("api:#{room.id}")
      expect(Rubotty::Adapters::Api.api_key?("api:7")).to be(true)
      expect(Rubotty::Adapters::Api.api_key?("tg-general")).to be(false)
    end
  end

  describe "#receive_pending" do
    it "emits a queued post as a chat message from the room's API endpoint" do
      enqueue("deploy finished")

      adapter.receive_pending

      message = dispatcher.last
      expect(message).not_to be_nil
      expect(message.origin.id).to eq(Rubotty::Adapters::Api.endpoint_key_for(room.id))
      expect(message.kind).to eq(:chat)
      expect(message.body.text).to eq("deploy finished")
      expect(message.sender_label).to be_a(Rubotty::Core::SenderLabel)
      expect(message.sender_label.to_s).to eq("ops console@api-client")
    end

    # An API post must never read as guest content in moderation or an audit line.
    it "tags the sender as an API client and never as a guest" do
      enqueue("hello")

      adapter.receive_pending

      expect(dispatcher.last.sender_label.api?).to be(true)
      expect(dispatcher.last.sender_label.guest?).to be(false)
    end

    it "takes the row as it emits, so a second pass never posts it twice" do
      enqueue("once only")

      adapter.receive_pending
      adapter.receive_pending

      expect(dispatcher.messages.size).to eq(1)
      expect(models.api_pending_message.count).to eq(0)
    end

    it "emits several queued posts in the order they were written" do
      enqueue("first")
      enqueue("second")

      adapter.receive_pending

      expect(dispatcher.messages.map { |m| m.body.text }).to eq(%w[first second])
    end

    # A claimed row never comes back, so a post the snapshot cannot route yet has
    # to stay queued.
    it "leaves a post pending when the room has no API endpoint in the current snapshot" do
      empty = models.room.create(
        community_id: community.id, room_key: "brand-new", label: "Brand New",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      registry.reload
      enqueue("waiting for a channel", on: empty)

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_pending_message.count).to eq(1)
    end

    it "relays a waiting post on the next pass once the room's endpoint appears" do
      empty = models.room.create(
        community_id: community.id, room_key: "brand-new", label: "Brand New",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      registry.reload
      enqueue("waiting for a channel", on: empty)
      adapter.receive_pending

      channel = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first
      models.room_channel.create(room_id: empty.id, channel_id: channel.id, created_at: Time.now)
      registry.reload
      adapter.receive_pending

      expect(dispatcher.messages.map { |m| m.body.text }).to eq(["waiting for a channel"])
    end

    # But not forever: a room that has lost its last channel is never coming back.
    it "drops a post unsent once it has waited past the maximum" do
      empty = models.room.create(
        community_id: community.id, room_key: "brand-new", label: "Brand New",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      registry.reload
      row = enqueue("waited too long", on: empty)
      row.update(created_at: Time.now - (Rubotty::ControlPlane::ApiMessages::MAX_WAIT_SECONDS + 1))

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_pending_message[row.id]).to be_nil
    end

    # Deleting a room normally takes its queued posts with it, since room_id cascades.
    it "loses a queued post with its room, through the foreign key's own cascade" do
      doomed = models.room.create(
        community_id: community.id, room_key: "temporary", label: "Temporary",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      row = enqueue("nowhere to go", on: doomed)
      doomed.delete

      expect(models.api_pending_message[row.id]).to be_nil
    end

    # With the constraint unenforced the row is orphaned instead, and without the
    # adapter's own guard it would be re-read from the pending set forever.
    it "retires an orphaned post rather than retrying it for good" do
      db.run("PRAGMA foreign_keys = OFF")
      doomed = models.room.create(
        community_id: community.id, room_key: "temporary", label: "Temporary",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      row = enqueue("nowhere to go", on: doomed)
      doomed.delete
      registry.reload

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_pending_message[row.id]).to be_nil
    end

    it "does not raise when a pass fails, so the receive loop survives it" do
      allow(messages).to receive(:pending).and_raise(Sequel::DatabaseError, "boom")

      expect { adapter.receive_pending }.not_to raise_error
    end

    it "still drains actions when the messages pass itself fails" do
      allow(messages).to receive(:pending).and_raise(Sequel::DatabaseError, "boom")
      actions.enqueue_delete(community: community, room: room, message: message_ref(room, "1"), key: key)

      adapter.receive_pending

      expect(dispatcher.last.kind).to eq(:delete)
    end
  end

  describe "#receive_pending draining a queued react, edit or delete" do
    let(:thumbs_up) { { emoji: "\u{1F44D}" } }

    it "emits a queued edit from the room's API endpoint, addressed by the message id" do
      actions.enqueue_edit(community: community, room: room, message: message_ref(room, "42"), body: "fixed now", key: key)

      adapter.receive_pending

      message = dispatcher.last
      expect(message.kind).to eq(:edit)
      expect(message.origin.id).to eq(Rubotty::Adapters::Api.endpoint_key_for(room.id))
      expect(message.ref).to eq(Rubotty::Core::MessageRef.new(Rubotty::Adapters::Api.endpoint_key_for(room.id), "42"))
      expect(message.body.text).to eq("fixed now")
      expect(message.sender_label.api?).to be(true)
    end

    it "emits a queued delete addressed by the message id, with no body" do
      actions.enqueue_delete(community: community, room: room, message: message_ref(room, "42"), key: key)

      adapter.receive_pending

      message = dispatcher.last
      expect(message.kind).to eq(:delete)
      expect(message.ref.native_id).to eq("42")
    end

    it "emits a queued reaction add carrying the reaction" do
      actions.enqueue_reaction_add(community: community, room: room, message: message_ref(room, "42"), reaction: thumbs_up, key: key)

      adapter.receive_pending

      message = dispatcher.last
      expect(message.kind).to eq(:reaction_add)
      expect(message.reaction.emoji).to eq("\u{1F44D}")
    end

    it "emits a queued reaction remove carrying the reaction" do
      actions.enqueue_reaction_remove(community: community, room: room, message: message_ref(room, "42"), reaction: thumbs_up,
                                      key: key)

      adapter.receive_pending

      expect(dispatcher.last.kind).to eq(:reaction_remove)
    end

    it "tags the actor as the posting credential, never a foreign author" do
      actions.enqueue_delete(community: community, room: room, message: message_ref(room, "42"), key: key)

      adapter.receive_pending

      expect(dispatcher.last.author.native_id).to eq("api-#{key.id}")
      expect(dispatcher.last.author.display_name).to eq("ops console@api-client")
    end

    it "takes the row as it emits, so a second pass never emits it twice" do
      actions.enqueue_delete(community: community, room: room, message: message_ref(room, "42"), key: key)

      adapter.receive_pending
      adapter.receive_pending

      expect(dispatcher.messages.size).to eq(1)
      expect(models.api_pending_message_action.count).to eq(0)
    end

    it "leaves an action pending when the room has no API endpoint in the current snapshot" do
      empty = models.room.create(
        community_id: community.id, room_key: "brand-new-2", label: "Brand New",
        display_name: "{}", created_at: Time.now, updated_at: Time.now
      )
      registry.reload
      actions.enqueue_delete(community: community, room: empty, message: message_ref(empty, "42"), key: key)

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_pending_message_action.count).to eq(1)
    end

    it "drops an action unsent once it has waited past the maximum" do
      row = actions.enqueue_delete(community: community, room: room, message: message_ref(room, "42"), key: key)
      row.update(created_at: Time.now - (Rubotty::ControlPlane::ApiMessageActions::MAX_WAIT_SECONDS + 1))

      adapter.receive_pending

      expect(dispatcher.messages).to be_empty
      expect(models.api_pending_message_action[row.id]).to be_nil
    end

    it "does not raise when the actions pass fails, so the receive loop survives it" do
      allow(actions).to receive(:pending).and_raise(Sequel::DatabaseError, "boom")

      expect { adapter.receive_pending }.not_to raise_error
    end

    it "still drains messages when the actions pass itself fails" do
      allow(actions).to receive(:pending).and_raise(Sequel::DatabaseError, "boom")
      enqueue("still gets through")

      adapter.receive_pending

      expect(dispatcher.last.kind).to eq(:chat)
    end

    context "with no actions queue configured" do
      subject(:adapter) do
        described_class.new(dispatcher: dispatcher, messages: messages, actions: nil, models: models,
                            registry: registry, logger: Rubotty::Log.null)
      end

      it "drains messages fine and never raises over the missing queue" do
        enqueue("no actions queue here")

        expect { adapter.receive_pending }.not_to raise_error
        expect(dispatcher.last.body.text).to eq("no actions queue here")
      end
    end
  end

  describe "#deliver" do
    it "declines quietly, since an API endpoint has nobody on the other side" do
      endpoint = registry.current.topology.endpoint(Rubotty::Adapters::Api.endpoint_key_for(room.id))

      expect(adapter.deliver(nil, endpoint)).to be_nil
    end
  end

  describe "#start and #stop" do
    it "drains once on start and is safe to stop twice" do
      enqueue("drained at start")

      adapter.start
      expect(dispatcher.messages.map { |m| m.body.text }).to eq(["drained at start"])

      adapter.stop
      expect { adapter.stop }.not_to raise_error
      expect(adapter.running?).to be(false)
    end

    it "joins the poll thread rather than killing it, so a post already claimed still reaches the dispatcher" do
      stub_const("#{described_class}::POLL_INTERVAL", 0.02)
      claimed = Queue.new
      release = Queue.new
      allow(messages).to receive(:retire).and_wrap_original do |original, row|
        original.call(row)
        claimed << :claimed
        release.pop
      end

      adapter.start
      enqueue("in flight")
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
