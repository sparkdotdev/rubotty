# frozen_string_literal: true

require "spec_helper"

# A control-plane edit made from ANOTHER process has to reach the RUNNING
# bridge, and the break was that the router held the boot-time Topology by
# value, keeping its original endpoints however often the snapshot was rebuilt.
RSpec.describe Rubotty::Core::Runtime, "live control-plane change pickup", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  let(:store) { sequel_store }

  let(:runtime) do
    described_class.new(
      config: config, logger: Rubotty::Log.null, storage: store, env: ControlPlaneHelpers::CONFIG_ENV
    ).build
  end

  # Driven directly, since #start would bring up real adapters and bind a port.
  def start_watcher(runtime)
    runtime.send(:start_control_watcher)
    runtime.control_watcher
  end

  # The dashboard's own path, over its OWN Models instance: nothing here touches
  # the runtime's registry, so the running bot has to find out by looking.
  def dashboard_enables(feature:, selector:)
    models = Rubotty::ControlPlane.models(store.db)
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models, clock: -> { Time.now + 3600 })
    controls.enable(community: controls.community!("sample"), selector: selector, feature: feature)
  end

  def guest_endpoint_ids(topology)
    topology.rooms.flat_map(&:endpoints).select { |e| e.adapter_name == :guest }.map(&:id)
  end

  # Keyed by the room's database id rather than the community-scoped room_key.
  def general_room_guest_key
    models = Rubotty::ControlPlane.models(store.db)
    community = models.community.where(slug: "sample").first
    room = models.room.where(community_id: community.id, room_key: "general").first
    Rubotty::Adapters::Guest.endpoint_key_for(room.id)
  end

  describe "the watcher the runtime starts" do
    it "is ONE supervised watcher, carrying every control-plane check" do
      watcher = start_watcher(runtime)

      expect(watcher).to be_a(Rubotty::ControlPlane::Watcher)
      expect(watcher.subscribers).to eq(
        %w[snapshot events_recurrence events polls script_recurrence announcement_settings]
      )
      expect(watcher.running?).to be(true)
      runtime.control_watcher.stop
    end

    it "adds exactly one long-running thread, not one per concern" do
      named = -> { Thread.list.count { |thread| thread.name == "control-plane-watcher" } }
      before = named.call

      start_watcher(runtime)
      sleep(0.05)

      expect(named.call - before).to eq(1)
      # The detectors own no threads themselves.
      expect(runtime.change_detector).not_to respond_to(:start)
      expect(runtime.event_lifecycle).not_to respond_to(:start)
      runtime.control_watcher.stop
    end

    it "starts no watcher at all on a backend with no control plane" do
      plain = described_class.new(
        config: config, logger: Rubotty::Log.null,
        storage: Rubotty::Storage::Memory.new, env: ControlPlaneHelpers::CONFIG_ENV
      ).build

      expect(start_watcher(plain)).to be_nil
      expect(plain.healthy?).to be(false) # no adapters started, but not because of the watcher
      expect(plain.control_watcher_healthy?).to be(true)
    end
  end

  describe "a feature_settings write made from the dashboard" do
    before { start_watcher(runtime) }
    after { runtime.control_watcher&.stop }

    it "is observed, and the reloaded snapshot synthesises the guest endpoint" do
      expect(guest_endpoint_ids(runtime.registry.current.topology)).to be_empty

      dashboard_enables(feature: "guest_portal", selector: "general")
      expect(runtime.control_watcher.tick["snapshot"]).to be(true)

      expect(guest_endpoint_ids(runtime.registry.current.topology)).to eq([general_room_guest_key])
    end

    # A guest endpoint that exists only in registry.current is invisible to the
    # bridge: Dispatcher#call and Features::Bridge both ask the ROUTER's topology.
    it "reaches the ROUTER's topology, so the bridge can actually fan out to it" do
      dashboard_enables(feature: "guest_portal", selector: "general")
      runtime.control_watcher.tick

      guest_key = general_room_guest_key
      expect(guest_endpoint_ids(runtime.router.topology)).to eq([guest_key])
      expect(runtime.router.topology.endpoint(guest_key)).not_to be_nil
      # And routable both ways: inbound resolves to the room, and a Telegram
      # message in that room names it as a target.
      expect(runtime.router.topology.rooms_for(guest_key).map(&:id)).to eq(["general"])
      room = runtime.router.topology.rooms_for("tg-general").first
      expect(room.targets_for("tg-general").map(&:id)).to include(guest_key)
    end

    it "reaches the DISPATCHER's topology too, which decides what is enqueued at all" do
      dashboard_enables(feature: "guest_portal", selector: "general")
      runtime.control_watcher.tick

      topology = runtime.dispatcher.instance_variable_get(:@topology)
      expect(topology.rooms_for(general_room_guest_key).map(&:id)).to eq(["general"])
    end

    it "does not reload when nothing was written" do
      expect(runtime.control_watcher.tick["snapshot"]).to be(false)
    end

    # Announcement schedules were reconciled once, at boot, so turning the
    # feature off left its recurring jobs running until the process restarted.
    it "rebuilds the announcement schedules, so a toggle no longer needs a restart" do
      expect(runtime.control_watcher.tick["announcement_settings"]).to be(false)

      dashboard_enables(feature: "scheduled_announcements", selector: "all")

      expect(runtime.control_watcher.tick["announcement_settings"]).to be(true)
    end
  end

  describe "#reload_control_plane, the entry point for the issue #224 push nudge" do
    after { runtime.control_watcher&.stop }

    it "triggers the same reload path the poll uses, without waiting for a tick" do
      start_watcher(runtime)
      dashboard_enables(feature: "guest_portal", selector: "general")

      expect(runtime.reload_control_plane(reason: "http nudge")).to be(true)

      expect(guest_endpoint_ids(runtime.router.topology)).to eq([general_room_guest_key])
    end

    it "is a harmless no-op without a control plane, so a nudge can never crash the bot" do
      plain = described_class.new(
        config: config, logger: Rubotty::Log.null,
        storage: Rubotty::Storage::Memory.new, env: ControlPlaneHelpers::CONFIG_ENV
      ).build
      expect(plain.reload_control_plane).to be(false)
    end
  end

  # Unsupervised, a dead poll thread and "nobody has changed anything" look the
  # same from outside for the rest of the process's life.
  describe "supervision, so a dead watcher can never be silent again" do
    after { runtime.control_watcher&.stop }

    it "reports the runtime unhealthy when the watcher thread is gone" do
      start_watcher(runtime)
      runtime.adapters.each_value do |adapter|
        allow(adapter).to receive(:running?).and_return(true)
      end
      expect(runtime.healthy?).to be(true)

      runtime.control_watcher.instance_variable_get(:@thread).kill
      sleep(0.05)

      expect(runtime.control_watcher.healthy?).to be(false)
      expect(runtime.healthy?).to be(false)
    end
  end
end
