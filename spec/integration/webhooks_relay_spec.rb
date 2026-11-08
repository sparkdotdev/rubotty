# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"

# Webhooks from the relay's own point of view: exactly one event per room per
# message, and a relay that carries on regardless of what the webhook tables do.
# The unit specs drive Webhooks#emit directly; this drives a real message through
# a real router, on the harness spec/integration/api_messaging_spec.rb uses.
RSpec.describe "webhooks from the relay path", :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:config) { sample_model }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: config.accounts) }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new }
  let(:messages) { Rubotty::ControlPlane::ApiMessages.new(models: models) }
  let(:webhooks) { Rubotty::ControlPlane::Webhooks.new(models: models, logger: Rubotty::Log.null) }

  let(:key) do
    Rubotty::ControlPlane::ApiKeys.new(models: models)
                                 .issue(scope: "developer", community: community, label: "ops").key_row
  end

  def adapters(snapshot)
    snapshot.topology.endpoints
            .reject { |e| %i[guest api].include?(e.adapter_name) }
            .each_with_object({}) do |e, map|
      map[[e.adapter_name, e.account]] ||= Fakes::RecordingAdapter.new(account: e.account)
    end
  end

  def router(snapshot, adapter_map)
    Rubotty::Core::Router.new(
      topology: snapshot.topology, adapters: adapter_map, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, registry: registry,
      webhooks: webhooks
    )
  end

  def api_adapter(route)
    Rubotty::Adapters::Api::Adapter.new(
      dispatcher: ->(message) { route.handle(message) },
      messages: messages, models: models, registry: registry, logger: Rubotty::Log.null
    )
  end

  def relay!(text)
    messages.enqueue(community: community, room: room, key: key, body: text)
    snapshot = registry.current
    api_adapter(router(snapshot, adapters(snapshot))).receive_pending
  end

  def subscribe(event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED], **rest)
    webhooks.create(community_id: community.id, url: "https://example.invalid/hook",
                    event_types: event_types, **rest)
  end

  # A live router and its fake adapters, held across several #handle calls in
  # one example so an edit or a delete can reach a message a first call
  # already relayed.
  def live_router
    snapshot = registry.current
    router(snapshot, adapters(snapshot))
  end

  def api_origin
    registry.current.topology.endpoint(Rubotty::Adapters::Api.endpoint_key_for(room.id))
  end

  it "queues one delivery per subscription per ROOM, not one per platform reached" do
    subscribe
    relay!("everybody hears this")

    rows = models.webhook_delivery.all
    expect(rows.length).to eq(1)
    envelope = YAMLCamel.load(rows.first.payload)
    expect(envelope["type"]).to eq("message.relayed")
    expect(envelope.dig("data", "body")).to eq("everybody hears this")
    expect(envelope.dig("data", "room_key")).to eq("general")
  end

  it "queues one delivery for each of two subscribers" do
    subscribe(label: "one")
    subscribe(label: "two")
    relay!("two listeners")

    expect(models.webhook_delivery.count).to eq(2)
  end

  # Same rule the live buffer keeps: a message the word filter screened did not
  # happen in this room, and a subscriber must not be told otherwise.
  it "queues nothing for a message the word filter screened" do
    subscribe
    controls.enable(community: community, selector: "general", feature: "word_filter")
    controls.set(community: community, selector: "general", feature: "word_filter",
                 key: "entries", value: '["badword"]')
    relay!("badword in here")

    expect(models.webhook_delivery.count).to eq(0)
  end

  it "queues nothing at all when nobody has subscribed" do
    relay!("nobody is listening")

    expect(models.webhook_delivery.count).to eq(0)
  end

  # A broken webhook table or an unreachable subscriber must never cost a room
  # its bridging: delivery is the scheduler's job.
  it "relays the message even when queueing the webhook fails outright" do
    subscribe
    allow(models.webhook_delivery).to receive(:create).and_raise(Sequel::Error, "table is gone")

    snapshot = registry.current
    adapter_map = adapters(snapshot)
    messages.enqueue(community: community, room: room, key: key, body: "still relayed")
    expect { api_adapter(router(snapshot, adapter_map)).receive_pending }.not_to raise_error

    delivered = adapter_map.values.flat_map(&:delivered).map { |_endpoint, message| message.body.text.to_s }
    expect(delivered.any? { |text| text.include?("still relayed") }).to be(true)
    expect(models.webhook_delivery.count).to eq(0)
  end

  # EVENT_TYPES widened beyond message.relayed alone, so a subscriber can hear about an
  # edit, a delete, a reaction and a membership change too.
  describe "the widened event types (#793)" do
    it "queues message.edited when an edit reaches a message already relayed" do
      subscribe(event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_EDITED])
      route = live_router
      origin = api_origin
      author = Rubotty::Core::Author.new(native_id: "u1", username: "ada")
      route.handle(message(origin, text: "first draft", native_id: "seed-1", author: author))

      route.handle(message(origin, text: "fixed", native_id: "seed-1", kind: :edit, author: author))

      envelope = YAMLCamel.load(models.webhook_delivery.order(:id).last.payload)
      expect(envelope["type"]).to eq("message.edited")
      expect(envelope.dig("data", "body")).to eq("fixed")
      expect(envelope.dig("data", "room_key")).to eq("general")
    end

    it "queues nothing for message.edited when nobody asked for it, even though message.relayed still fires" do
      subscribe(event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED])
      route = live_router
      origin = api_origin
      author = Rubotty::Core::Author.new(native_id: "u1", username: "ada")
      route.handle(message(origin, text: "first draft", native_id: "seed-1", author: author))
      route.handle(message(origin, text: "fixed", native_id: "seed-1", kind: :edit, author: author))

      types = models.webhook_delivery.all.map { |row| YAMLCamel.load(row.payload)["type"] }
      expect(types).to eq(["message.relayed"])
    end

    it "queues message.deleted when a delete reaches a message already relayed" do
      subscribe(event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_DELETED])
      route = live_router
      origin = api_origin
      author = Rubotty::Core::Author.new(native_id: "u1", username: "ada")
      route.handle(message(origin, text: "going away", native_id: "seed-2", author: author))

      route.handle(message(origin, native_id: "seed-2", kind: :delete, author: author))

      envelope = YAMLCamel.load(models.webhook_delivery.order(:id).last.payload)
      expect(envelope["type"]).to eq("message.deleted")
      expect(envelope.dig("data", "room_key")).to eq("general")
    end

    it "queues reaction.added and reaction.removed as an actor reacts and un-reacts" do
      subscribe(event_types: [Rubotty::ControlPlane::Webhooks::REACTION_ADDED,
                              Rubotty::ControlPlane::Webhooks::REACTION_REMOVED])
      route = live_router
      origin = api_origin
      author = Rubotty::Core::Author.new(native_id: "u1", username: "ada")
      route.handle(message(origin, text: "react to me", native_id: "seed-3", author: author))
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")

      route.handle(message(origin, native_id: "seed-3", kind: :reaction_add, author: author, reaction: thumbs))
      route.handle(message(origin, native_id: "seed-3", kind: :reaction_remove, author: author, reaction: thumbs))

      types = models.webhook_delivery.order(:id).all.map { |row| YAMLCamel.load(row.payload)["type"] }
      expect(types).to eq(["reaction.added", "reaction.removed"])
    end

    it "queues member.joined and member.left rather than message.relayed for a membership change" do
      subscribe(event_types: [Rubotty::ControlPlane::Webhooks::MEMBER_JOINED,
                              Rubotty::ControlPlane::Webhooks::MEMBER_LEFT])
      route = live_router
      origin = api_origin
      author = Rubotty::Core::Author.new(native_id: "u1", username: "ada")

      route.handle(message(origin, text: "", native_id: "join-1", kind: :join, author: author))
      route.handle(message(origin, text: "", native_id: "leave-1", kind: :leave, author: author))

      types = models.webhook_delivery.order(:id).all.map { |row| YAMLCamel.load(row.payload)["type"] }
      expect(types).to eq(["member.joined", "member.left"])
    end
  end
end
