# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The single driver of event side-effects: the detector that watches the events table and,
# for both write surfaces alike (the /event command and the dashboard form), announces a
# new event, re-announces a changed one, retracts a cancelled one, drives the native mirror
# and rebuilds the reminder ladder. Exercised over the seeded SAMPLE "gaming" room throughout.
RSpec.describe Rubotty::Events::Lifecycle, :control_plane do
  # A Telegram-ish adapter: no native events, the shared fallback renderer.
  class LifecyclePlainAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :telegram
    end

    CAPS = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: false, replies: false, reactions: true
    ).freeze

    def initialize
      super(account: "telegram", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @delivered = []
      @edited = []
      @synced = []
    end

    attr_reader :delivered, :edited, :synced

    def capabilities = CAPS
    def own_account_id = "tg-bot"
    def start = self
    def stop = self
    def running? = true

    def deliver(message, endpoint)
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "tg#{@delivered.size}")
    end

    def edit(message, endpoint, native_id)
      @edited << [endpoint.id, native_id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
    end

    def sync_reactions(endpoint, native_id, desired:, previous: [])
      @synced << { endpoint_id: endpoint.id, native_id: native_id, desired: desired }
      nil
    end
  end

  # A Discord-ish adapter: native-event capable.
  class LifecycleNativeAdapter < Rubotty::Adapters::Base
    class << self
      def adapter_name = :discord
    end

    CAPS = LifecyclePlainAdapter::CAPS

    def initialize
      super(account: "discord", settings: {}, dispatcher: nil, logger: Rubotty::Log.null)
      @delivered = []
      @edited = []
      @synced = []
      @created = []
      @updated = []
      @deleted = []
      @next_id = 0
    end

    attr_reader :delivered, :edited, :synced, :created, :updated, :deleted

    def capabilities = CAPS
    def own_account_id = "dc-bot"
    def start = self
    def stop = self
    def running? = true

    def deliver(message, endpoint)
      @delivered << [endpoint.id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: "dc#{@delivered.size}")
    end

    def edit(message, endpoint, native_id)
      @edited << [endpoint.id, native_id, message]
      Rubotty::Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
    end

    def sync_reactions(endpoint, native_id, desired:, previous: [])
      @synced << { endpoint_id: endpoint.id, native_id: native_id, desired: desired }
      nil
    end

    def supports_native_events? = true

    def create_scheduled_event(event, _endpoint)
      @next_id += 1
      @created << event
      @next_id.to_s
    end

    def update_scheduled_event(native_id, event, _endpoint) = (@updated << [native_id, event])
    def delete_scheduled_event(native_id, _endpoint) = (@deleted << native_id)

    def render_timestamp(time, style: :full, tz: nil, now: nil)
      "<t:#{time.to_i}:#{style}>"
    end
  end

  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite") }
  let(:models) { Rubotty::ControlPlane.models(db) }
  let(:registry) { Rubotty::ControlPlane::Registry.new(models: models) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  let(:tg) { LifecyclePlainAdapter.new }
  let(:dc) { LifecycleNativeAdapter.new }
  let(:adapters) { { [:telegram, "telegram"] => tg, [:discord, "discord"] => dc } }

  let(:announcer) do
    Rubotty::Events::Announcer.new(registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null)
  end

  let(:sched_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: sched_store, session_id: "s", logger: Rubotty::Log.null)
  end
  let(:reminders) { Rubotty::Events::Reminders.new(scheduler: scheduler, logger: Rubotty::Log.null) }

  let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }

  subject(:detector) do
    described_class.new(models: models, announcer: announcer, reminders: reminders,
                        store: store, logger: Rubotty::Log.null)
  end

  before do
    store.migrate!
    Rubotty::ControlPlane.migrate!(db)
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "sample")
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "gaming", feature: "events")
  end

  # A plain EventScheduling create, standing in for the dashboard form, which
  # announces nothing by itself.
  def web_create(**overrides)
    scheduling.create(
      **{ community: community, room: room, as: :operator, title: "Raid Night",
          starts_at: Time.now + (10 * 86_400), kind: "gaming",
          game_title: "Counter-Strike 2", server_address: "1.2.3.4:7777" }.merge(overrides)
    )
  end

  def reload(event) = Rubotty::Events::Event.new(event.row.refresh)

  describe "a written-but-unannounced event (issue #198)" do
    it "is picked up and announced, reminded and native-mirrored on the next poll" do
      event = web_create
      # The write alone did nothing: no cards, no native, no reminders.
      expect(tg.delivered).to be_empty
      expect(dc.created).to be_empty
      expect(scheduler.pending).to eq(0)

      detector.check

      # Announced to every endpoint in the room.
      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      expect(dc.delivered.map(&:first)).to eq(["dc-gaming"])
      # Native event created and its id stored back on the row.
      expect(dc.created.map(&:id)).to eq([event.id])
      expect(reload(event).native_ref("discord")).to eq("1")
      # The whole reminder ladder scheduled.
      expect(scheduler.pending).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)
    end

    it "never double-announces across repeated polls" do
      web_create
      detector.check
      detector.check
      detector.check

      expect(tg.delivered.size).to eq(1)
      expect(dc.created.size).to eq(1)
      expect(scheduler.pending).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)
    end

    it "adopts an event that already carries a tracked card, rather than re-announcing it" do
      event = web_create
      models.event_card.create(event_id: event.id, endpoint_id: "tg-gaming", native_id: "old", created_at: Time.now)

      detector.check

      expect(tg.delivered).to be_empty # not re-announced
      expect(dc.created).to be_empty
      # but the reminder ladder is still ensured on adoption
      expect(scheduler.pending).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)
    end
  end

  describe "an update to an already-announced event" do
    it "replaces the durable ladder after a reminder-only edit" do
      event = web_create(reminder_intervals: [1800])
      detector.check
      scheduling.update(event: event, reminder_intervals: [60])
      detector.check
      payloads = db[:scheduled_jobs].where(kind: Rubotty::Events::Reminders::KIND, status: "pending")
                   .select_map(:payload).map { |payload| JSON.parse(payload) }
      expect(payloads.map { |payload| payload["interval"] }).to eq([60])
    end

    it "distinguishes inherited reminders from an explicit empty ladder in both directions" do
      event = web_create
      detector.check
      expect(scheduler.pending).to be_positive
      scheduling.update(event: event, reminder_intervals: [])
      detector.check
      expect(scheduler.pending).to eq(0)
      scheduling.update(event: event, reminder_intervals: nil)
      detector.check
      expect(scheduler.pending).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)
    end

    it "re-announces the card, updates the native mirror and reschedules reminders" do
      event = web_create
      detector.check
      expect(tg.delivered.size).to eq(1)

      # Far enough out that every rung stays in the future and the rescheduled ladder
      # is the full size.
      scheduling.update(event: event, title: "Raid Night (moved)", starts_at: Time.now + (20 * 86_400))
      detector.check

      expect(tg.delivered.size).to eq(2)
      expect(tg.delivered.last.last.body.text).to include("Raid Night (moved)")
      expect(dc.updated.size).to eq(1)
      expect(scheduler.pending).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)
    end

    it "ignores a re-poll that changes nothing" do
      event = web_create
      detector.check
      scheduling.update(event: event, title: "Raid Night (moved)")
      detector.check
      before_deliveries = tg.delivered.size

      detector.check
      expect(tg.delivered.size).to eq(before_deliveries)
    end
  end

  describe "a cancellation" do
    it "posts the notice, deletes the native mirror and withdraws the reminders" do
      event = web_create
      detector.check
      tg.delivered.clear
      dc.delivered.clear

      scheduling.cancel(event: event)
      detector.check

      expect(tg.delivered.first.last.body.text).to include("cancelled")
      expect(dc.deleted).to eq(["1"])
      expect(scheduler.pending).to eq(0)
    end

    it "does not retract an event that was cancelled before it was ever announced" do
      event = web_create
      scheduling.cancel(event: event) # created and cancelled entirely before any poll
      detector.check

      expect(tg.delivered).to be_empty # nothing to retract
      expect(dc.deleted).to be_empty
    end
  end

  describe "loop prevention for a mirrored-in event" do
    it "broadcasts the card but never re-creates the native event it came from" do
      # An event stamped with an existing Discord native id, as NativeMirror writes.
      web_create(native_refs: { "discord" => "555000" })
      detector.check

      # Cards fan out to the room (the other platforms learn about it),
      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      # but the native mirror is NOT re-created back onto Discord.
      expect(dc.created).to be_empty
    end
  end

  describe "restart recovery of the cursor and fingerprints" do
    it "does not re-announce an already-processed event, but does pick up a new one" do
      first = web_create
      detector.check
      expect(tg.delivered.size).to eq(1)

      # A fresh detector over the SAME store, standing in for a process restart: its
      # cursor and fingerprints come back from the KV.
      restarted = described_class.new(models: models, announcer: announcer, reminders: reminders,
                                      store: store, logger: Rubotty::Log.null)
      tg.delivered.clear
      dc.created.clear

      restarted.check
      expect(tg.delivered).to be_empty # `first` is recognised as already done
      expect(reload(first).scheduled?).to be(true)

      second = web_create(title: "Second Event")
      restarted.check
      expect(tg.delivered.size).to eq(1)
      expect(tg.delivered.first.last.body.text).to include("Second Event")
      expect(second.id).not_to eq(first.id)
    end
  end

  describe "an inbound Discord-native event, end to end (mirror then detector)" do
    let(:guild_id) { "9000000000001" }
    let(:mirror) do
      Rubotty::Events::NativeMirror.new(models: models, event_scheduling: scheduling, logger: Rubotty::Log.null)
    end

    before { models.platform_connection.where(adapter: "discord").update(external_id: guild_id) }

    def native_created(native_id)
      Rubotty::Events::NativeEventChange.new(
        adapter: :discord, account: "discord", action: :created, native_id: native_id,
        guild_id: guild_id, title: "Discord Movie Night", starts_at: Time.now + (3 * 86_400),
        raw: { "description" => "byo popcorn", "entity_metadata" => { "location" => "https://zoom.us/j/9" } }
      )
    end

    it "mirrors the native event in, then broadcasts it to the OTHER platforms without a second native copy" do
      mirror.handle(native_created("origin-1"))
      detector.check

      # The chat card reaches Telegram (the other platform learns about it)...
      expect(tg.delivered.map(&:first)).to eq(["tg-gaming"])
      expect(tg.delivered.first.last.body.text).to include("Discord Movie Night")
      # ...and Discord's own chat channel, but NO second native Guild
      # Scheduled Event is created back on Discord (the loop guard).
      expect(dc.created).to be_empty
    end

    # Issue #1702: Discord fires GUILD_SCHEDULED_EVENT_UPDATE the moment an
    # event's own SCHEDULED status flips to ACTIVE at its start time. The
    # payload here carries only id/guild_id/name/scheduled_start_time/status,
    # nothing that differs from what the event already has.
    it "does not re-announce an already-live event on a bare Discord status transition" do
      mirror.handle(native_created("origin-2"))
      detector.check
      expect(tg.delivered.size).to eq(1)
      tg.delivered.clear
      dc.delivered.clear
      dc.updated.clear

      event = Rubotty::Events::Event.new(models.event.where(community_id: community.id).order(Sequel.desc(:id)).first)
      status_transition = Rubotty::Events::NativeEventChange.new(
        adapter: :discord, account: "discord", action: :updated, native_id: "origin-2", guild_id: guild_id,
        title: "Discord Movie Night", starts_at: event.starts_at, status: :active,
        raw: {
          "id" => "origin-2", "guild_id" => guild_id, "name" => "Discord Movie Night",
          "scheduled_start_time" => event.starts_at.iso8601, "status" => 2
        }
      )
      mirror.handle(status_transition)
      detector.check

      expect(tg.delivered).to be_empty
      expect(dc.delivered).to be_empty
      expect(dc.updated).to be_empty
    end
  end

  describe "#check with nothing to do" do
    it "is a harmless no-op on an empty table" do
      expect { detector.check }.not_to raise_error
      expect(tg.delivered).to be_empty
    end
  end
end
