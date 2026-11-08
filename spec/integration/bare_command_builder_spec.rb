# frozen_string_literal: true

require "spec_helper"

# A bare /event against the real seeded control plane: the builder asks for
# each field, then hands the assembled line to the real EventCommand, which
# parses and creates through the actual EventScheduling. This is where the
# form's own command line meets the parser that has to read it back.
RSpec.describe "a bare /event answered one field at a time", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:now) { Time.utc(2026, 8, 11, 10, 0, 0) }
  let(:scheduling) do
    Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
  end
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  let(:event_command) do
    Rubotty::Features::EventCommand.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, ephemeral: ephemeral
    )
  end

  let(:reschedule_command) do
    Rubotty::Features::RescheduleCommand.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, ephemeral: ephemeral
    )
  end

  let(:announcer) do
    Rubotty::Events::Announcer.new(registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null)
  end
  let(:ledger) { Rubotty::Events::RsvpLedger.new(models: models, logger: Rubotty::Log.null) }
  let(:event_rsvp) do
    Rubotty::Features::EventRsvp.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, announcer: announcer, ledger: ledger, ephemeral: ephemeral
    )
  end

  # Which real command a finished form's assembled line reaches, the same
  # dispatch a live deployment's command dispatcher does by word.
  def dispatch(message)
    case message.body.text
    when /\A\/reschedule\b/ then reschedule_command.call(context_for(message))
    when /\A\/rsvp\b/ then event_rsvp.call(context_for(message))
    else event_command.call(context_for(message))
    end
  end

  let(:builder) do
    Rubotty::Features::CommandBuilder.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      ephemeral: ephemeral, run: ->(message) { dispatch(message) }
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  # The seeded bootstrap operator on Telegram.
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  def context_for(message)
    Rubotty::Features::Context.new(
      message: message, community: registry.current.community("sample"),
      channel: registry.current.channel_by_endpoint_key("tg-gaming")
    )
  end

  def say(text)
    @said = (@said || 0) + 1
    builder.call(context_for(message(origin, text: text, native_id: "m#{@said}", author: boss)))
  end

  def posted = adapter.delivered_to(origin.id).map { |message| message.body.text }

  def turn_on!
    community = registry.current.community("sample")
    controls.enable(community: community, selector: "gaming", feature: "events")
    controls.set(community: community, selector: "gaming", feature: "events",
                 key: "who_can_create", value: "operators")
  end

  before { turn_on! }

  it "asks for the fields instead of printing the usage wall" do
    outcome = say("/event")

    expect(outcome.halt?).to be(true)
    expect(posted.last).to include("/event (1 of 10)", "title.")
    expect(posted.join).not_to include("Usage:")
  end

  it "creates the event the answers describe, through the ordinary parser" do
    say("/event")
    say("Game night")
    say("2026-08-12 20:00")
    say("gaming")
    say("/done")

    event = Rubotty::Events::Event.new(models.event.first)
    expect(event.title).to eq("Game night")
    expect(event.kind).to eq("gaming")
    expect(posted.last).to include("Scheduled ##{event.id}: Game night")
  end

  # The confirmation is the command's own and stays; everything the form said
  # and everything the invoker typed goes.
  it "leaves only the command's own answer behind" do
    say("/event")
    say("Game night")
    say("2026-08-12 20:00")
    say("gaming")
    say("/done")

    removed = adapter.deleted.map(&:last)
    expect(removed).to include("m1", "m2", "m3", "m4", "m5")
    expect(adapter.delivered_to(origin.id).length - removed.count { |id| id.start_with?("d") }).to eq(1)
  end

  # id is a plain, unkeyed argument, the same as /rsvp's own two: the two
  # commands below prove the assembled line still reaches RescheduleCommand
  # and EventRsvp correctly, not only that CommandForm writes it.
  describe "a bare /reschedule against an event the same operator created" do
    def existing_event
      say("/event")
      say("Game night")
      say("2026-08-12 20:00")
      say("gaming")
      say("/done")
      Rubotty::Events::Event.new(models.event.first)
    end

    it "asks for the id, then applies the one field answered" do
      event = existing_event

      outcome = say("/reschedule")
      expect(outcome.halt?).to be(true)
      expect(posted.last).to include("/reschedule (1 of 9)", "id.")

      say(event.id.to_s)
      say("Raid night")
      say("/done")

      expect(Rubotty::Events::Event.new(models.event.first).title).to eq("Raid night")
      expect(posted.last).to match(/updated/i)
    end
  end

  describe "a bare /rsvp against a full-RSVP event" do
    let(:room) { models.room.where(community_id: registry.current.community("sample").id, room_key: "gaming").first }

    def full_rsvp_event
      scheduling.create(
        community: registry.current.community("sample"), room: room, as: :operator, title: "Raid Night",
        starts_at: now + (2 * 86_400), kind: "gaming", rsvp_mode: Rubotty::Events::Event::RSVP_FULL
      )
    end

    it "asks for id then response, in that order, and records the response" do
      event = full_rsvp_event

      outcome = say("/rsvp")
      expect(outcome.halt?).to be(true)
      expect(posted.last).to include("/rsvp (1 of 2)", "id.")

      say(event.id.to_s)
      expect(posted.last).to include("(2 of 2)", "response.")

      say("yes")

      row = models.event_rsvp.where(event_id: event.id).first
      expect(row[:response]).to eq("yes")
      expect(posted.last).to include("Recorded ##{event.id}")
    end
  end
end
