# frozen_string_literal: true

require "spec_helper"

# The /events chat command: bare, lists this room's upcoming events; pointed
# at an id, shows who's signed up. Exercised against the real seeded SAMPLE
# control plane, the same house style spec/features/event_command_spec.rb uses.
RSpec.describe Rubotty::Features::EventsCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:now) { Time.utc(2026, 8, 11, 10, 0, 0) }
  let(:scheduling) do
    Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end
  let(:announcer) do
    Rubotty::Events::Announcer.new(registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null)
  end
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    described_class.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, announcer: announcer, ephemeral: ephemeral
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New", last_name: "Bie")
  end

  def run(text, author: newcomer, endpoint_key: "tg-gaming")
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key(endpoint_key)
    msg = message(origin, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: {}))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  def turn_on!(selector: "gaming")
    controls.enable(community: registry.current.community("sample"), selector: selector, feature: "events")
    controls.set(community: registry.current.community("sample"), selector: selector, feature: "events",
                 key: "who_can_create", value: "everyone")
  end

  def create!(overrides = {})
    turn_on!
    community = registry.current.community("sample")
    room = models.room.where(community_id: community.id, room_key: "gaming").first
    scheduling.create(
      **{
        community: community, room: room, as: :operator, title: "Raid Night",
        starts_at: now + (2 * 86_400), kind: "gaming"
      }.merge(overrides)
    )
  end

  describe "the feature contract" do
    it "shares Features::Events' own feature_name, is off by code default, and observes only chat" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Events.feature_name)
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "refuses rather than relays a recognised /events without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/events")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/events")
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "ignores an ordinary message" do
      expect(run("just chatting")).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "acknowledges rather than staying silent when the channel has no room mapping yet" do
      turn_on!
      allow(scheduling).to receive(:room_for_endpoint_key).and_return(nil)

      run("/events")
      expect(ack_on("tg-gaming")).to match(/isn't linked/i)
    end
  end

  describe "bare /events: listing" do
    it "says so when the room has no upcoming events" do
      turn_on!
      run("/events")
      expect(ack_on("tg-gaming")).to match(/No upcoming events/)
    end

    it "lists scheduled events soonest first, with id, title and start" do
      later = create!(title: "Later", starts_at: now + (3 * 86_400))
      sooner = create!(title: "Sooner", starts_at: now + 86_400)
      run("/events")
      text = ack_on("tg-gaming")
      expect(text.index("##{sooner.id}: Sooner")).to be < text.index("##{later.id}: Later")
    end

    it "excludes a cancelled event" do
      event = create!
      scheduling.cancel(event: event)
      run("/events")
      expect(ack_on("tg-gaming")).to match(/No upcoming events/)
    end

    it "narrows to the room the command was typed in, not the whole community" do
      controls.enable(community: registry.current.community("sample"), selector: "general", feature: "events")
      controls.set(community: registry.current.community("sample"), selector: "general", feature: "events",
                   key: "who_can_create", value: "everyone")
      general_room = models.room.where(community_id: registry.current.community("sample").id, room_key: "general").first
      in_general = scheduling.create(
        community: registry.current.community("sample"), room: general_room, as: :operator,
        title: "General Meetup", starts_at: now + 86_400, kind: "general"
      )
      create!(title: "Gaming Night")

      run("/events")
      text = ack_on("tg-gaming")
      expect(text).to include("Gaming Night")
      expect(text).not_to include("##{in_general.id}:")
    end
  end

  describe "/events <id>: the roster" do
    it "reports it cannot find an unknown id" do
      turn_on!
      run("/events 999999")
      expect(ack_on("tg-gaming")).to match(/Could not find that event/)
    end

    it "says RSVP is off for a none-mode event" do
      event = create!(rsvp_mode: "none")
      run("/events #{event.id}")
      expect(ack_on("tg-gaming")).to match(/RSVP is not enabled/)
    end

    it "shows the one attendee of an affirm-mode event under the card's own wording" do
      event = create!(rsvp_mode: "affirm")
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "in", responded_at: now)
      run("/events #{event.id}")
      expect(ack_on("tg-gaming")).to include("Attending: @u1")
    end

    it "lists every attendee of an affirm-mode event, untruncated" do
      event = create!(rsvp_mode: "affirm")
      5.times do |i|
        models.event_rsvp.create(event_id: event.id, identity: "u#{i}", platform: "telegram",
                                 response: "in", responded_at: now)
      end
      run("/events #{event.id}")
      expect(ack_on("tg-gaming")).to include("Attending: @u0, @u1, @u2, @u3, @u4")
    end

    it "says nobody yet, not a zero, when nobody has answered an affirm-mode event" do
      event = create!(rsvp_mode: "affirm")
      run("/events #{event.id}")
      expect(ack_on("tg-gaming")).to include("Attending: nobody yet")
    end

    it "shows Going/Maybe/No for a full-mode event, untruncated unlike the card's own summary line" do
      event = create!(rsvp_mode: "full")
      5.times do |i|
        models.event_rsvp.create(event_id: event.id, identity: "u#{i}", platform: "telegram",
                                 response: "yes", responded_at: now)
      end
      text = run("/events #{event.id}") && ack_on("tg-gaming")
      expect(text).to include("Going: @u0, @u1, @u2, @u3, @u4")
      expect(text).to include("Maybe: nobody yet")
      expect(text).to include("No: nobody yet")
    end

    it "resolves an event by id across rooms in the same community, like /rsvp does" do
      controls.enable(community: registry.current.community("sample"), selector: "general", feature: "events")
      controls.set(community: registry.current.community("sample"), selector: "general", feature: "events",
                   key: "who_can_create", value: "everyone")
      general_room = models.room.where(community_id: registry.current.community("sample").id, room_key: "general").first
      event = scheduling.create(
        community: registry.current.community("sample"), room: general_room, as: :operator,
        title: "General Meetup", starts_at: now + 86_400, kind: "general", rsvp_mode: "affirm"
      )

      run("/events #{event.id}")
      expect(ack_on("tg-gaming")).to include("General Meetup")
    end
  end
end
