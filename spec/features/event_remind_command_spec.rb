# frozen_string_literal: true

require "spec_helper"

# The /remind chat command: an operator's manual escape hatch that posts an
# event's reminder into its own room right now, reusing
# Events::Announcer#announce_reminder_now rather than a second template.
RSpec.describe Rubotty::Features::EventRemindCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:now) { Time.utc(2026, 8, 11, 10, 0, 0) }
  let(:scheduling) do
    Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end
  let(:announcer) do
    Rubotty::Events::Announcer.new(registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null,
                                   clock: -> { now })
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

  # The seeded bootstrap operator on Telegram (sample_owner), same author
  # spec/features/event_command_spec.rb uses for its own operator checks.
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  def run(text, author:)
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key("tg-gaming")
    msg = message(origin, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: {}))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  def turn_on!
    controls.enable(community: registry.current.community("sample"), selector: "gaming", feature: "events")
    controls.set(community: registry.current.community("sample"), selector: "gaming", feature: "events",
                 key: "who_can_create", value: "everyone")
  end

  def create!(overrides = {})
    turn_on!
    community = registry.current.community("sample")
    room = models.room.where(community_id: community.id, room_key: "gaming").first
    scheduling.create(
      **{
        community: community, room: room, as: :operator, title: "Raid Night",
        starts_at: now + 3600, kind: "gaming"
      }.merge(overrides)
    )
  end

  describe "the feature contract" do
    it "shares Features::Events' own feature_name, is off by code default, and observes only chat" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Events.feature_name)
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "refuses rather than relays a recognised /remind without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/remind 1")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/remind")
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
      expect(run("just chatting", author: boss)).to be_continue
    end
  end

  describe "permission" do
    it "refuses a normal member" do
      event = create!
      run("/remind #{event.id}", author: newcomer)
      expect(ack_on("tg-gaming")).to match(/Only a room operator/i)
    end

    it "lets an operator trigger it" do
      event = create!
      run("/remind #{event.id}", author: boss)
      expect(ack_on("tg-gaming")).to match(/Posted a reminder/)
    end
  end

  describe "posting the reminder" do
    it "posts into the room, reusing Announcer's own reminder text" do
      event = create!
      run("/remind #{event.id}", author: boss)

      # The reminder itself posts before the command's own self-deleting
      # acknowledgement, both to the same endpoint.
      posted = adapter.delivered_to("tg-gaming").first.body.text
      expect(posted).to start_with("Raid Night starts in 1 hour")
    end

    it "does not DM anybody: it is a channel post, unlike the automated ladder" do
      event = create!(rsvp_mode: "full")
      models.event_rsvp.create(event_id: event.id, identity: "u1", platform: "telegram",
                               response: "yes", responded_at: now)
      run("/remind #{event.id}", author: boss)

      expect(adapter.delivered_to("tg-gaming")).not_to be_empty
      expect(adapter.dms_sent).to be_empty
    end

    it "reports it cannot find an unknown id" do
      turn_on!
      run("/remind 999999", author: boss)
      expect(ack_on("tg-gaming")).to match(/Could not find that event/)
    end

    it "reports a cancelled event has nothing to remind" do
      event = create!
      scheduling.cancel(event: event)
      run("/remind #{event.id}", author: boss)
      expect(ack_on("tg-gaming")).to match(/cancelled; nothing to remind/)
    end

    it "resolves an event by id across rooms in the same community, like /rsvp does" do
      controls.enable(community: registry.current.community("sample"), selector: "general", feature: "events")
      controls.set(community: registry.current.community("sample"), selector: "general", feature: "events",
                   key: "who_can_create", value: "everyone")
      general_room = models.room.where(community_id: registry.current.community("sample").id, room_key: "general").first
      event = scheduling.create(
        community: registry.current.community("sample"), room: general_room, as: :operator,
        title: "General Meetup", starts_at: now + 3600, kind: "general"
      )

      run("/remind #{event.id}", author: boss)
      expect(ack_on("tg-gaming")).to match(/Posted a reminder/)
      expect(adapter.delivered_to("tg-general").last.body.text).to start_with("General Meetup starts in 1 hour")
    end
  end
end
