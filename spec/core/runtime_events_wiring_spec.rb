# frozen_string_literal: true

require "spec_helper"

# Only whether the runtime builds and connects the real things; the announcer's
# own broadcast behaviour is spec/events/announcer_spec.rb's job.
RSpec.describe Rubotty::Core::Runtime, "event announcer and reminders wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  # Runtime no longer reads a control-plane deployment's accounts out of the
  # config, so the accounts table has to carry them here the way a real
  # deployment's one-time seed already would have, before the boot this
  # helper drives resolves them into adapters.
  def build_runtime(store:, env: ControlPlaneHelpers::CONFIG_ENV)
    if Rubotty::ControlPlane::Boot.available?(store)
      Rubotty::ControlPlane.migrate!(store.db)
      Rubotty::ControlPlane::Accounts.new(models: Rubotty::ControlPlane.models(store.db)).seed_from_config(config)
    end
    described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env).build
  end

  describe "construction, with a control plane" do
    let(:runtime) { build_runtime(store: sequel_store) }

    it "builds a real event announcer" do
      expect(runtime.event_announcer).to be_a(Rubotty::Events::Announcer)
    end

    it "builds a real reminder engine and registers its job kind on the durable scheduler" do
      expect(runtime.event_reminders).to be_a(Rubotty::Events::Reminders)
      expect(runtime.durable_scheduler.handler?(Rubotty::Events::Reminders::KIND)).to be(true)
    end

    it "keeps event_scheduling a pure writer, holding no announcer or reminders (issue #184, #198)" do
      expect(runtime.event_scheduling.instance_variable_get(:@announcer)).to be_nil
      expect(runtime.event_scheduling.instance_variable_get(:@reminders)).to be_nil
    end

    it "builds the lifecycle detector, wired to the SAME announcer, reminders and state store" do
      lifecycle = runtime.event_lifecycle
      expect(lifecycle).to be_a(Rubotty::Events::Lifecycle)
      expect(lifecycle.instance_variable_get(:@announcer)).to be(runtime.event_announcer)
      expect(lifecycle.instance_variable_get(:@reminders)).to be(runtime.event_reminders)
      expect(lifecycle.instance_variable_get(:@store)).to be(runtime.storage)
    end

    it "builds the inbound native mirror, wired to the SAME pure event_scheduling writer" do
      mirror = runtime.native_mirror
      expect(mirror).to be_a(Rubotty::Events::NativeMirror)
      expect(mirror.instance_variable_get(:@event_scheduling)).to be(runtime.event_scheduling)
    end

    it "builds the recurrence advancer, wired to the SAME pure event_scheduling writer" do
      recurrence = runtime.event_recurrence
      expect(recurrence).to be_a(Rubotty::Events::Recurrence)
      expect(recurrence.instance_variable_get(:@event_scheduling)).to be(runtime.event_scheduling)
    end

    it "resolves the reminder engine's default_intervals through EventPolicy, not the hardcoded constant" do
      resolver = runtime.event_reminders.instance_variable_get(:@default_intervals)
      expect(resolver).to respond_to(:call)

      models = Rubotty::ControlPlane.models(runtime.storage.db)
      community = models.community.where(slug: "sample").first
      room = models.room.where(community_id: community.id, room_key: "gaming").first
      Rubotty::ControlPlane::FeatureControls.new(models: models).tap do |controls|
        controls.enable(community: community, selector: "gaming", feature: "events")
        controls.set(community: community, selector: "gaming", feature: "events",
                     key: "default_reminder_intervals", value: [1800])
      end

      ev = Rubotty::Events::Event.new(id: 1, community_id: community.id, room_id: room.id, starts_at: Time.now.iso8601)
      expect(resolver.call(ev)).to eq([1800])
    end

    it "subscribes the native mirror to every adapter's native-event stream" do
      # Proven on Discord, the only adapter that ever fires a native event.
      discord = runtime.adapters[[:discord, "discord"]]
      listeners = discord.instance_variable_get(:@native_event_listeners)
      expect(listeners).to be_an(Array)
      expect(listeners.size).to eq(1)
    end

    it "wires the reminder engine's on_fire seam to the announcer" do
      events = []
      allow(runtime.event_announcer).to receive(:announce_reminder) { |event, interval| events << [event, interval] }

      ev = Rubotty::Events::Event.new(
        id: 1, community_id: 1, room_id: 1, title: "t", starts_at: (Time.now + 3600).iso8601,
        timezone: nil, kind: "general", game_title: nil, server_address: nil, url: nil,
        rsvp_mode: "none", status: "scheduled", created_by: nil, ends_at: nil
      )
      runtime.event_reminders.instance_variable_get(:@on_fire).call(ev, 900)
      expect(events).to eq([[ev, 900]])
    end

    it "builds a real RSVP ledger (issue #184, wave 3b)" do
      expect(runtime.event_rsvp_ledger).to be_a(Rubotty::Events::RsvpLedger)
    end

    it "wires Features::EventRsvp into the pipeline with the SAME ledger, announcer and event_scheduling" do
      pipeline_features = runtime.router.instance_variable_get(:@pipeline).features
      feature = pipeline_features.find { |candidate| candidate.is_a?(Rubotty::Features::EventRsvp) }

      expect(feature).not_to be_nil
      expect(feature.instance_variable_get(:@ledger)).to be(runtime.event_rsvp_ledger)
      expect(feature.instance_variable_get(:@announcer)).to be(runtime.event_announcer)
      expect(feature.instance_variable_get(:@event_scheduling)).to be(runtime.event_scheduling)
    end
  end

  describe "the real Reminders <-> DurableScheduler round trip, driven by the lifecycle detector" do
    let(:runtime) { build_runtime(store: sequel_store) }
    let(:models) { Rubotty::ControlPlane.models(runtime.storage.db) }
    let(:community) { models.community.where(slug: "sample").first }
    let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }

    before do
      Rubotty::ControlPlane::FeatureControls.new(models: models).tap do |controls|
        controls.enable(community: community, selector: "gaming", feature: "events")
      end
      # Driving real, unstarted adapters here would only reach for the network.
      allow(runtime.event_announcer).to receive(:announce_created)
      allow(runtime.event_announcer).to receive(:announce_cancelled)
    end

    # Counts only the reminder ladder. Asked directly rather than by taking
    # every prune kind off the total: that list had to grow by hand for each
    # new scheduled job, and broke the moment one was added elsewhere.
    def reminders_pending(runtime)
      runtime.durable_scheduler.pending(kind: Rubotty::Events::Reminders::KIND)
    end

    it "the WRITE surface alone schedules NOTHING; the detector schedules the ladder" do
      # A row written by either surface is pure, so nothing schedules at write time.
      event = runtime.event_scheduling.create(
        community: community, room: room, as: :operator, title: "Raid Night",
        starts_at: Time.now + (10 * 86_400), kind: "gaming"
      )
      expect(reminders_pending(runtime)).to eq(0)

      # The detector picks the row up and schedules its whole reminder ladder.
      runtime.event_lifecycle.check
      expect(reminders_pending(runtime)).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)

      # A cancel is likewise pure, then the detector withdraws the ladder.
      runtime.event_scheduling.cancel(event: event)
      runtime.event_lifecycle.check
      expect(reminders_pending(runtime)).to eq(0)
    end
  end

  describe "without a control plane" do
    it "leaves every events service nil, including the lifecycle detector and native mirror" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.event_announcer).to be_nil
      expect(runtime.event_reminders).to be_nil
      expect(runtime.event_scheduling).to be_nil
      expect(runtime.event_rsvp_ledger).to be_nil
      expect(runtime.event_lifecycle).to be_nil
      expect(runtime.native_mirror).to be_nil
      expect(runtime.event_recurrence).to be_nil
    end
  end
end
