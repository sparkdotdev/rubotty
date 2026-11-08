# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The /reschedule chat command against the real seeded SAMPLE control plane, so
# parse, authorization and the write all run through the actual
# ControlPlane::EventScheduling. The "Event updated" card is left entirely to
# Events::Lifecycle, covered below with a real one rather than a stub.
RSpec.describe Rubotty::Features::RescheduleCommand, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:now) { Time.utc(2026, 8, 11, 10, 0, 0) } # a Tuesday
  let(:scheduling) do
    Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
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
      event_scheduling: scheduling, ephemeral: ephemeral
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def community = registry.current.community("sample")

  def creator
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

  def run(text, author:)
    channel = registry.current.channel_by_endpoint_key("tg-gaming")
    msg = message(origin, text: text, native_id: "m#{rand(100_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel, config: {}))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  def turn_on!
    controls.enable(community: community, selector: "gaming", feature: "events")
    controls.set(community: community, selector: "gaming", feature: "events", key: "who_can_create", value: "everyone")
  end

  # created_by defaults to the "creator" author above, so a bare call is ready
  # for the authorization examples without repeating the label everywhere.
  def create_event(overrides = {})
    turn_on!
    room = models.room.where(community_id: community.id, room_key: "gaming").first
    scheduling.create(
      **{
        community: community, room: room, as: :operator, title: "Raid Night",
        starts_at: now + (2 * 86_400), kind: "gaming", timezone: "Europe/Lisbon",
        description: "Original plans", game_title: "Old Game", server_address: "1.1.1.1",
        created_by: "telegram:newbie"
      }.merge(overrides)
    )
  end

  describe "the feature contract" do
    it "shares Features::Events' own feature_name, is off by code default, and observes only chat" do
      expect(described_class.feature_name).to eq(Rubotty::Features::Events.feature_name)
      expect(described_class.feature_name).to eq("events")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "refuses rather than relays a recognised /reschedule without a control plane" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "/reschedule 1 title=x")))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("a").last.body.text).to include("/reschedule")
    end

    it "still lets an unrecognised message continue with no control plane at all" do
      bare = described_class.new(
        topology: topology(room("r", endpoint("a"))), adapters: adapters, logger: Rubotty::Log.null
      )
      outcome = bare.call(Rubotty::Features::Context.new(message: message(endpoint("a"), text: "just chatting")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "ignores an ordinary message, letting it continue down the pipeline" do
      expect(run("just chatting about the game", author: creator)).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "authorization" do
    it "lets the event's own creator reschedule it" do
      event = create_event
      run(%(/reschedule #{event.id} title="Raid Night II"), author: creator)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Raid Night II")
    end

    it "lets a room operator reschedule an event they did not create" do
      event = create_event
      run(%(/reschedule #{event.id} title="Ops Reschedule"), author: boss)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Ops Reschedule")
    end

    it "refuses a non-creator, non-operator, naming who can act, and changes nothing" do
      event = create_event
      run(%(/reschedule #{event.id} title="Nope"), author: someone_else)

      expect(ack_on("tg-gaming")).to match(/only event ##{event.id}'s creator or a room operator can reschedule it/i)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Raid Night")
    end

    it "refuses an id that does not resolve to a real event here, rather than raising" do
      turn_on!
      expect { run("/reschedule 999999 title=X", author: boss) }.not_to raise_error
      expect(ack_on("tg-gaming")).to match(/Could not find that event here/)
    end
  end

  describe "a well-formed reschedule" do
    it "changes only the fields given, leaving every other field exactly as it was" do
      event = create_event
      run(%(/reschedule #{event.id} title="Raid Night II" start="2026-08-20 21:00"), author: creator)

      updated = scheduling.find(community: community, id: event.id)
      expect(updated.title).to eq("Raid Night II")
      # 21:00 Europe/Lisbon in August (UTC+1) is 20:00 UTC.
      expect(updated.starts_at).to eq(Time.utc(2026, 8, 20, 20, 0, 0))
      expect(updated.description).to eq("Original plans")
      expect(updated.timezone).to eq("Europe/Lisbon")
      expect(updated.game_title).to eq("Old Game")
      expect(updated.server_address).to eq("1.1.1.1")
      expect(updated.kind).to eq("gaming")
      expect(updated.ends_at).to be_nil
    end

    it "reads tz, end, description and url together" do
      event = create_event
      run(
        %(/reschedule #{event.id} tz=UTC end="2026-08-13 12:00" description="New plan" url=https://example.test),
        author: creator
      )

      updated = scheduling.find(community: community, id: event.id)
      expect(updated.timezone).to eq("UTC")
      expect(updated.ends_at).to eq(Time.utc(2026, 8, 13, 12, 0, 0))
      expect(updated.description).to eq("New plan")
      # EventScheduling#update writes url unconditionally: unlike #create it
      # does not re-derive kind, and kind cannot be changed through /reschedule.
      expect(updated.url).to eq("https://example.test")
    end

    it "acknowledges naming the fields that were actually given" do
      event = create_event
      run(%(/reschedule #{event.id} title="Raid Night II"), author: creator)
      expect(ack_on("tg-gaming")).to match(/Rescheduled ##{event.id}: Raid Night II/)
      expect(ack_on("tg-gaming")).to match(/updated: title/)
    end

    it "sets a recurrence cadence with repeat=" do
      event = create_event
      run("/reschedule #{event.id} repeat=weekly", author: creator)
      expect(scheduling.find(community: community, id: event.id).recurrence_interval).to eq(604_800)
    end

    it "clears an existing recurrence with repeat=none" do
      event = create_event(recurrence_interval: 86_400)
      run("/reschedule #{event.id} repeat=none", author: creator)
      expect(scheduling.find(community: community, id: event.id)).not_to be_recurring
    end

    it "sets an explicit reminder ladder with reminders=" do
      event = create_event
      run("/reschedule #{event.id} reminders=3600,900", author: creator)
      expect(scheduling.find(community: community, id: event.id).reminder_intervals).to eq([3600, 900])
    end

    it "reads an unquoted multi-word value up to the next key, instead of demanding quotes" do
      event = create_event
      run("/reschedule #{event.id} title=Raid Night II start=\"2026-08-20 21:00\"", author: creator)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Raid Night II")
    end

    it "does not let an apostrophe in a value break the parse" do
      event = create_event
      run("/reschedule #{event.id} title=Alex's Raid Night", author: creator)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Alex's Raid Night")
    end

    it "reads a quoted value verbatim, even one holding text that looks like another key" do
      event = create_event
      run(%(/reschedule #{event.id} title="Raid Night start=now"), author: creator)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Raid Night start=now")
    end
  end

  describe "bad input" do
    before { turn_on! }

    it "replies with usage for a bare /reschedule" do
      run("/reschedule", author: creator)
      expect(ack_on("tg-gaming")).to match(/Could not find that event here/)
    end

    it "reports unmatched quoting rather than raising" do
      event = create_event
      expect { run(%(/reschedule #{event.id} title="Unterminated), author: creator) }.not_to raise_error
      expect(ack_on("tg-gaming")).to match(/quoting/i)
    end

    it "names a field it cannot change rather than silently dropping it" do
      event = create_event
      run("/reschedule #{event.id} kind=general", author: creator)
      expect(ack_on("tg-gaming")).to match(/kind=.*cannot be changed/i)
      expect(scheduling.find(community: community, id: event.id).kind).to eq("gaming")
    end

    it "names a field this command has never heard of, distinct from one it just cannot change yet" do
      event = create_event
      run("/reschedule #{event.id} typo=oops", author: creator)
      expect(ack_on("tg-gaming")).to match(/typo=.*is not a field/i)
      expect(scheduling.find(community: community, id: event.id).title).to eq("Raid Night")
    end

    it "says there is nothing to change for an id with no fields after it" do
      event = create_event
      run("/reschedule #{event.id}", author: creator)
      expect(ack_on("tg-gaming")).to match(/Nothing to change/)
    end

    it "rejects a start time it cannot parse, changing nothing" do
      event = create_event
      run(%(/reschedule #{event.id} start="not a time"), author: creator)
      expect(ack_on("tg-gaming")).to match(/Could not reschedule/i)
      expect(scheduling.find(community: community, id: event.id).starts_at).to eq(event.starts_at)
    end

    it "rejects an unparsable repeat=, changing nothing" do
      event = create_event
      run("/reschedule #{event.id} repeat=fortnightly", author: creator)
      expect(ack_on("tg-gaming")).to match(/Could not understand repeat=fortnightly/)
      expect(scheduling.find(community: community, id: event.id)).not_to be_recurring
    end
  end

  # The row write and the room broadcast are two different mechanisms: this
  # command only writes fields, and Events::Lifecycle is what notices
  # updated_at moved and posts "Event updated", the same reconciler
  # spec/events/lifecycle_spec.rb drives directly against a plain update.
  describe "the announcement path" do
    let(:announcer) do
      Rubotty::Events::Announcer.new(
        registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null, clock: -> { now }
      )
    end
    let(:sched_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
    let(:scheduler) do
      Rubotty::Core::DurableScheduler.new(store: sched_store, session_id: "s", logger: Rubotty::Log.null)
    end
    let(:reminders) { Rubotty::Events::Reminders.new(scheduler: scheduler, logger: Rubotty::Log.null) }
    let(:kv_store) { Rubotty::Storage::SequelStore.new(db: db, description: "test") }
    let(:lifecycle) do
      Rubotty::Events::Lifecycle.new(
        models: models, announcer: announcer, reminders: reminders, store: kv_store, logger: Rubotty::Log.null
      )
    end

    before { kv_store.migrate! }

    it "does not post the 'Event updated' card itself; only Lifecycle's own poll does" do
      event = create_event
      lifecycle.check # announces the create first, so only what follows counts
      adapter.delivered.clear

      run(%(/reschedule #{event.id} title="Raid Night II"), author: creator)
      texts = adapter.delivered_to("tg-gaming").map { |m| m.body.text }
      expect(texts).not_to include(a_string_matching(/Event updated/))

      lifecycle.check
      expect(adapter.delivered_to("tg-gaming").last.body.text).to start_with("Event updated: Raid Night II")
    end
  end
end
