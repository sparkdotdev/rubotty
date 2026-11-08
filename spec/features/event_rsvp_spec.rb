# frozen_string_literal: true

require "spec_helper"

# Cross-platform RSVP capture, by reaction on the event card and by the /rsvp fallback,
# against the real seeded SAMPLE control plane.
RSpec.describe Rubotty::Features::EventRsvp, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:announcer) do
    Rubotty::Events::Announcer.new(registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null)
  end
  let(:ledger) { Rubotty::Events::RsvpLedger.new(models: models, logger: Rubotty::Log.null) }

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, announcer: announcer, ledger: ledger, ephemeral: ephemeral
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New", last_name: "Bie")
  end

  def someone_else
    Rubotty::Core::Author.new(native_id: "111222", username: "otheruser", first_name: "Other")
  end

  # The seeded bootstrap operator on Telegram (sample_owner), same author
  # spec/features/event_command_spec.rb uses for its own operator checks.
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  def turn_on!(selector: "gaming")
    controls.enable(community: registry.current.community("sample"), selector: selector, feature: "events")
    controls.set(community: registry.current.community("sample"), selector: selector, feature: "events",
                 key: "who_can_create", value: "everyone")
  end

  def create_event(rsvp_mode:, created_by: nil)
    turn_on!
    community = registry.current.community("sample")
    room = models.room.where(community_id: community.id, room_key: "gaming").first
    event = scheduling.create(
      community: community, room: room, as: :operator, title: "Raid Night",
      starts_at: Time.now + (2 * 86_400), kind: "gaming", rsvp_mode: rsvp_mode, created_by: created_by
    )
    announcer.announce_created(event)
    event
  end

  def card_native_id(event, endpoint_id: "tg-gaming")
    models.event_card.where(event_id: event.id, endpoint_id: endpoint_id).first.native_id
  end

  def run(message, config: {})
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key("tg-gaming")
    feature.call(Rubotty::Features::Context.new(message: message, community: community, channel: channel,
                                                config: config))
  end

  def react(event, reaction:, kind: :reaction_add, author: newcomer)
    run(message(origin, kind: kind, native_id: card_native_id(event), reaction: reaction, author: author))
  end

  def rsvp_command(text, author: newcomer)
    run(message(origin, text: text, native_id: "cmd#{rand(100_000)}", author: author))
  end

  def reply(event, text, author: newcomer)
    run(
      message(origin, text: text, native_id: "r-#{rand(100_000)}", author: author,
                      reply_to: ref("tg-gaming", card_native_id(event)))
    )
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  # What the passive directory holds after somebody has been seen in the room.
  def observed(native_id:, username: nil, display_name: nil, adapter_name: "telegram")
    now = Time.now
    models.observed_identity.create(
      community_id: registry.current.community("sample").id, adapter: adapter_name,
      native_id: native_id, username: username, display_name: display_name,
      first_seen_at: now, last_seen_at: now
    )
  end

  describe "the feature contract" do
    it "shares Features::Events' own feature_name, is off by code default" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Events.feature_name)
      expect(described_class.default_enabled?).to be(false)
    end

    it "observes chat, both reaction kinds, and the anonymous reaction sync" do
      expect(described_class.observes).to eq(%i[chat reaction_add reaction_remove reaction_sync])
    end

    it "is a no-op on a reaction without a control plane: nothing to recognise it by" do
      bare = described_class.new(topology: topology(room("r", endpoint("a"))), adapters: adapters,
                                 logger: Rubotty::Log.null)
      msg = message(endpoint("a"), kind: :reaction_add, reaction: Rubotty::Events::RsvpReactions::GOING)
      expect(bare.call(Rubotty::Features::Context.new(message: msg))).to be_continue
    end

    it "refuses rather than relays a recognised /rsvp without a control plane" do
      bare = described_class.new(topology: topology(room("r", endpoint("a"))), adapters: adapters,
                                 logger: Rubotty::Log.null)
      msg = message(endpoint("a"), text: "/rsvp 1 yes")
      outcome = bare.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/rsvp")
    end

    it "still lets an unrecognised chat message continue with no control plane at all" do
      bare = described_class.new(topology: topology(room("r", endpoint("a"))), adapters: adapters,
                                 logger: Rubotty::Log.null)
      msg = message(endpoint("a"), text: "just chatting")
      outcome = bare.call(Rubotty::Features::Context.new(message: msg))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "continues on a reaction that names no tracked card" do
      msg = message(origin, kind: :reaction_add, native_id: "not-a-card",
                            reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer)
      expect(run(msg)).to be_continue
    end
  end

  # Every example elsewhere in this file calls #call directly, so it keeps passing
  # whatever the observes list says. These drive one real message per observed kind
  # through a real Pipeline, with the bridge behind it so a swallow is observable.
  describe "every kind it observes, driven through the real pipeline" do
    let(:map) { Rubotty::Storage::Memory.new }
    let(:bridge) do
      Rubotty::Features::Bridge.new(
        topology: registry.current.topology, adapters: adapters, storage: map,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: map), logger: Rubotty::Log.null, ttl: 3600
      )
    end

    # The snapshot is built once, so the row that switched events on has to be read
    # back in before the pipeline can see this feature as enabled at all.
    let(:pipeline) do
      registry.reload
      Rubotty::Features::Pipeline.new(features: [feature, bridge], registry: registry, logger: Rubotty::Log.null)
    end

    # The card as the BRIDGE knows it, a copy on the far platform being what its
    # aggregate mirror reaches for.
    def relayed_card!(event)
      map.record(source: ref("tg-gaming", card_native_id(event)),
                 destination: ref("dc-gaming", "copy"), room_id: "gaming")
    end

    def on_card(event, kind:, **rest)
      message(origin, kind: kind, native_id: card_native_id(event), **rest)
    end

    def responses = models.event_rsvp.all.map(&:response)

    observes_kind :chat, "an /rsvp naming an event id is answered from anywhere in the room" do
      event = create_event(rsvp_mode: "full")
      pipeline.handle(message(origin, text: "/rsvp #{event.id} yes", native_id: "cmd", author: newcomer))
      responses
    end

    observes_kind :reaction_add, "a reaction on the card is the cross-platform way to answer it" do
      event = create_event(rsvp_mode: "full")
      pipeline.handle(
        on_card(event, kind: :reaction_add, reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer)
      )
      responses
    end

    observes_kind :reaction_remove, "taking that reaction back withdraws the response again" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer)
      held = responses
      pipeline.handle(
        on_card(event, kind: :reaction_remove, reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer)
      )
      held - responses
    end

    swallows_kind :reaction_sync, "an anonymous count on the card is kept off the bridge's aggregate mirror" do
      event = create_event(rsvp_mode: "full")
      relayed_card!(event)
      # Announcing the card places its own RSVP keycaps, so only what follows counts.
      already_placed = adapter.syncs.size
      pipeline.handle(
        on_card(event, kind: :reaction_sync, author: nil, reaction_set: [Rubotty::Events::RsvpReactions::GOING])
      )
      adapter.syncs.drop(already_placed)
    end

    covers_every_observed_kind
  end

  describe "an anonymous reaction sync (issue: Telegram reports no author here)" do
    # Telegram reports message_reaction_count instead of a per-user update
    # in a channel or large supergroup with anonymous reactions on; before
    # :reaction_sync was observed, a tap there never reached this feature,
    # so it silently mirrored as a reaction instead of registering an RSVP.
    it "swallows a sync on the event's own card rather than recording anything" do
      event = create_event(rsvp_mode: "full")
      msg = message(origin, kind: :reaction_sync, native_id: card_native_id(event),
                            reaction_set: [Rubotty::Events::RsvpReactions::GOING], author: nil)
      expect(run(msg)).to be_halt
      expect(models.event_rsvp.count).to eq(0)
    end

    it "still continues a sync on a message that names no tracked card" do
      msg = message(origin, kind: :reaction_sync, native_id: "not-a-card",
                            reaction_set: [Rubotty::Events::RsvpReactions::GOING], author: nil)
      expect(run(msg)).to be_continue
    end
  end

  describe "reactions, mode enforcement" do
    it "records nothing for a none-mode event, but still swallows the reaction" do
      event = create_event(rsvp_mode: "none")
      outcome = react(event, reaction: Rubotty::Events::RsvpReactions::GOING)
      expect(outcome).to be_halt
      expect(models.event_rsvp.count).to eq(0)
    end

    it "records 'in' for the one going reaction on an affirm-mode event" do
      event = create_event(rsvp_mode: "affirm")
      react(event, reaction: Rubotty::Events::RsvpReactions::GOING)
      expect(models.event_rsvp.first.response).to eq("in")
    end

    it "ignores the maybe/no reactions on an affirm-mode event" do
      event = create_event(rsvp_mode: "affirm")
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE)
      expect(models.event_rsvp.count).to eq(0)
    end

    it "records yes, maybe or no on a full-mode event" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE)
      expect(models.event_rsvp.first.response).to eq("maybe")
    end

    it "maps the going reaction to 'yes' on a full-mode event, not 'in'" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::GOING)
      expect(models.event_rsvp.first.response).to eq("yes")
    end

    it "ignores an unrelated emoji" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Core::Reaction.new(emoji: "🔥"))
      expect(models.event_rsvp.count).to eq(0)
    end
  end

  describe "reactions, one response per identity" do
    it "moves an identity to a second reaction rather than adding a second row" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE, author: newcomer)
      react(event, reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer)

      expect(models.event_rsvp.count).to eq(1)
      expect(models.event_rsvp.first.response).to eq("yes")
    end

    it "keeps two different identities' responses independent" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer)
      react(event, reaction: Rubotty::Events::RsvpReactions::NO, author: someone_else)

      expect(models.event_rsvp.count).to eq(2)
    end

    it "clears the response when the CURRENT reaction is removed" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE, author: newcomer)
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE, kind: :reaction_remove, author: newcomer)

      expect(models.event_rsvp.count).to eq(0)
    end

    it "does nothing when a STALE (already superseded) reaction is removed" do
      event = create_event(rsvp_mode: "full")
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE, author: newcomer) # -> maybe
      react(event, reaction: Rubotty::Events::RsvpReactions::GOING, author: newcomer) # moves to yes
      react(event, reaction: Rubotty::Events::RsvpReactions::MAYBE, kind: :reaction_remove, author: newcomer)

      expect(models.event_rsvp.first.response).to eq("yes")
    end
  end

  describe "reactions refresh the card" do
    it "edits the tracked card copy after a response is recorded, naming who answered" do
      event = create_event(rsvp_mode: "affirm")
      observed(native_id: "999888", username: "newbie", display_name: "New Bie")
      adapter.edited.clear

      react(event, reaction: Rubotty::Events::RsvpReactions::GOING)

      expect(adapter.edited).not_to be_empty
      expect(adapter.edited.last.last.body.text).to include("Attending: @newbie@telegram")
    end

    # Setting a Telegram username is optional, and plenty of people never do.
    it "names somebody who never set a handle rather than printing their id" do
      event = create_event(rsvp_mode: "affirm")
      observed(native_id: "999888", display_name: "New Bie")
      adapter.edited.clear

      react(event, reaction: Rubotty::Events::RsvpReactions::GOING)

      text = adapter.edited.last.last.body.text
      expect(text).to include("Attending: New Bie (telegram)")
      expect(text).not_to include("999888")
    end

    it "does not edit the card when the reaction changed nothing" do
      event = create_event(rsvp_mode: "affirm")
      adapter.edited.clear

      react(event, reaction: Rubotty::Core::Reaction.new(emoji: "🔥")) # unrelated

      expect(adapter.edited).to be_empty
    end
  end

  describe "the /rsvp command" do
    it "ignores an ordinary message, letting it continue down the pipeline" do
      expect(rsvp_command("just chatting about the game")).to be_continue
    end

    it "records a valid response and acknowledges it" do
      event = create_event(rsvp_mode: "full")
      outcome = rsvp_command("/rsvp #{event.id} yes")
      expect(outcome).to be_halt
      expect(models.event_rsvp.first.response).to eq("yes")
      expect(ack_on("tg-gaming")).to match(/Recorded/)
    end

    it "is case-insensitive on the response" do
      event = create_event(rsvp_mode: "full")
      rsvp_command("/rsvp #{event.id} YES")
      expect(models.event_rsvp.first.response).to eq("yes")
    end

    it "refreshes the card too" do
      event = create_event(rsvp_mode: "full")
      adapter.edited.clear
      rsvp_command("/rsvp #{event.id} no")
      expect(adapter.edited).not_to be_empty
    end

    it "declines a response the event's mode does not accept" do
      event = create_event(rsvp_mode: "affirm")
      rsvp_command("/rsvp #{event.id} yes")
      expect(ack_on("tg-gaming")).to match(/response must be/i)
      expect(models.event_rsvp.count).to eq(0)
    end

    it "declines an event with rsvp off entirely" do
      event = create_event(rsvp_mode: "none")
      rsvp_command("/rsvp #{event.id} in")
      expect(ack_on("tg-gaming")).to match(/not enabled/i)
    end

    it "replies politely for an unknown event id" do
      create_event(rsvp_mode: "full") # so the community has at least one row
      rsvp_command("/rsvp 999999 yes")
      expect(ack_on("tg-gaming")).to match(/Could not find/i)
      expect(models.event_rsvp.count).to eq(0)
    end

    it "replies with usage for a bare /rsvp" do
      rsvp_command("/rsvp")
      expect(ack_on("tg-gaming")).to match(/Usage: \/rsvp/)
    end

    it "recognises the alternate ! prefix as well as /" do
      event = create_event(rsvp_mode: "full")
      outcome = rsvp_command("!rsvp #{event.id} maybe")
      expect(outcome).to be_halt
      expect(models.event_rsvp.first.response).to eq("maybe")
    end

    it "lets a second /rsvp move the same identity's response" do
      event = create_event(rsvp_mode: "full")
      rsvp_command("/rsvp #{event.id} maybe", author: newcomer)
      rsvp_command("/rsvp #{event.id} yes", author: newcomer)
      expect(models.event_rsvp.count).to eq(1)
      expect(models.event_rsvp.first.response).to eq("yes")
    end
  end

  # The invocation and its acknowledgement are one exchange (Core::CommandAck), the same
  # contract UtilityCommands already carries; see spec/features/command_cleanup_durability_spec.rb.
  # Only the /rsvp command posts an acknowledgement at all: a reaction never gets a text
  # reply, so there is nothing of its own for a reaction to pair with.
  describe "the /rsvp command's acknowledgement pairs with its own invocation (also_delete)" do
    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    def advance(seconds) = (@now = (@now || base) + seconds)

    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
    let(:ephemeral) do
      Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null,
        clock: clock
      )
    end
    let(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        event_scheduling: scheduling, announcer: announcer, ledger: ledger, ephemeral: ephemeral,
        cleanup: scheduler
      )
    end

    after { scheduler.stop }

    def rsvp_command_fixed(text, native_id:, author: newcomer, config: {})
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-gaming")
      msg = message(origin, text: text, native_id: native_id, author: author)
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel,
                                                   config: config))
    end

    # The event card the announcer posts on create claims an earlier native id than
    # the /rsvp ack, so the ack's own id is read back rather than assumed to be "d1".
    def next_native_id = "d#{adapter.delivered.size + 1}"

    it "takes the invoking /rsvp message with it when the ack self-deletes" do
      event = create_event(rsvp_mode: "full")
      ack_id = next_native_id
      rsvp_command_fixed("/rsvp #{event.id} yes", native_id: "77")

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id], %w[tg-gaming 77])
    end

    it "leaves the invocation alone when the scope opts out" do
      event = create_event(rsvp_mode: "full")
      ack_id = next_native_id
      rsvp_command_fixed("/rsvp #{event.id} yes", native_id: "77", config: { delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end

    # A native Discord slash-command interaction is reconstructed for the pipeline; its
    # ref names no real posted message, so Core::CommandAck.pair_with must never pair it.
    it "never pairs a synthetic (Discord slash-command) invocation" do
      event = create_event(rsvp_mode: "full")
      ack_id = next_native_id
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-gaming")
      msg = message(origin, text: "/rsvp #{event.id} yes", native_id: "77", author: newcomer, synthetic: true)
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: {}))

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg-gaming", ack_id])
      expect(adapter.deleted).not_to include(%w[tg-gaming 77])
    end
  end

  describe "canceling by replying to the card" do
    it "lets the event's own creator cancel it" do
      event = create_event(rsvp_mode: "full", created_by: "telegram:newbie")
      outcome = reply(event, "/cancel", author: newcomer)

      expect(outcome).to be_halt
      expect(scheduling.find(community: registry.current.community("sample"), id: event.id)).to be_cancelled
      expect(ack_on("tg-gaming")).to include("canceled by newbie")
    end

    it "lets a room operator cancel an event they did not create" do
      event = create_event(rsvp_mode: "full", created_by: "telegram:newbie")
      outcome = reply(event, "/cancel", author: boss)

      expect(outcome).to be_halt
      expect(scheduling.find(community: registry.current.community("sample"), id: event.id)).to be_cancelled
    end

    it "refuses a non-creator, non-operator, and leaves the event scheduled" do
      event = create_event(rsvp_mode: "full", created_by: "telegram:newbie")
      outcome = reply(event, "/cancel", author: someone_else)

      expect(outcome).to be_halt
      expect(scheduling.find(community: registry.current.community("sample"), id: event.id)).to be_scheduled
      expect(ack_on("tg-gaming")).to match(/only event #\d+'s creator or a room operator/i)
    end

    it "answers gracefully rather than erroring on a duplicate cancel" do
      event = create_event(rsvp_mode: "full", created_by: "telegram:newbie")
      reply(event, "/cancel", author: newcomer)
      outcome = reply(event, "/cancel", author: newcomer)

      expect(outcome).to be_halt
      expect(ack_on("tg-gaming")).to include("already canceled")
    end

    it "reads a bare 'cancel' with no prefix the same way" do
      event = create_event(rsvp_mode: "full", created_by: "telegram:newbie")
      reply(event, "cancel", author: newcomer)

      expect(scheduling.find(community: registry.current.community("sample"), id: event.id)).to be_cancelled
    end

    it "leaves an ordinary reply on the card alone, so it still crosses to the other rooms" do
      event = create_event(rsvp_mode: "full")

      expect(reply(event, "looking forward to this")).to be_continue
    end
  end
end
