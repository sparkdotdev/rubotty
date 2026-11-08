# frozen_string_literal: true

require "spec_helper"

# The seeded single community has to route identically whether the topology
# comes from the control-plane Snapshot or from the static config.
RSpec.describe Rubotty::Core::Runtime, "control-plane wiring", :control_plane do
  let(:config) { sample_model }

  # An isolated in-memory database on the same connection the control plane
  # reuses.
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
  def build_runtime(store: sequel_store, env: ControlPlaneHelpers::CONFIG_ENV)
    if Rubotty::ControlPlane::Boot.available?(store)
      Rubotty::ControlPlane.migrate!(store.db)
      Rubotty::ControlPlane::Accounts.new(models: Rubotty::ControlPlane.models(store.db)).seed_from_config(config)
    end
    described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env).build
  end

  # An adapter wired the OLD way: a static index from the config endpoints, with
  # no resolver, which is the path the cutover must match.
  def static_adapter(account_name)
    account = config.accounts[account_name]
    account.adapter_class.new(
      account: account_name, settings: account.settings,
      dispatcher: ->(_message) {}, logger: Rubotty::Log.null,
      endpoints: config.endpoints_for(account_name), endpoint_resolver: nil
    )
  end

  # Resolve to the origin endpoint through the adapter's own endpoint_for seam.
  def resolve(adapter, endpoint)
    case endpoint.adapter_name
    when :telegram
      adapter.send(:endpoint_for, endpoint.settings[:chat_id], endpoint.settings[:thread_id])
    when :discord
      adapter.send(:endpoint_for, endpoint.settings[:channel_id])
    end
  end

  # The outbound endpoint ids a message arriving at +origin+ fans out to.
  def fan_out(topology, origin)
    topology.rooms_for(origin.id).flat_map { |room| room.targets_for(origin) }.map(&:id).sort
  end

  describe "the control plane comes up at boot" do
    it "activates when the store is Sequel-backed and seeds the community" do
      runtime = build_runtime
      expect(runtime.control_plane?).to be(true)
      expect(runtime.registry.current.community("sample")).not_to be_nil
    end

    it "falls back to the config path on a store with no database" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.control_plane?).to be(false)
      expect(runtime.registry).to be_nil
    end
  end

  describe "the running router and dispatcher read the Snapshot" do
    let(:runtime) { build_runtime }

    # The router holds a LIVE view rather than the topology object the snapshot
    # held at boot, since a by-value capture keeps a reload off the relay path.
    it "sources the router's topology from the Snapshot, not the config" do
      expect(runtime.router.topology).to be_a(Rubotty::Core::LiveTopology)
      expect(runtime.router.topology.current).to be(runtime.registry.current.topology)
      expect(runtime.router.topology.rooms).to eq(runtime.registry.current.topology.rooms)
      expect(runtime.router.topology).not_to be(config.topology)
    end

    it "sources the router's operator directory from the LIVE Snapshot, not a boot-time copy (issue #230)" do
      expect(runtime.router.operators).to be_a(Rubotty::Core::LiveOperators)
      expect(runtime.router.operators.resolve(:telegram, "80000012")).to eq(
        runtime.registry.current.operators.resolve(:telegram, "80000012")
      )
    end

    it "wires each adapter with the live channel resolver" do
      tg = runtime.adapters[[:telegram, "telegram"]]
      dc = runtime.adapters[[:discord, "discord"]]
      expect(tg.endpoint_resolver).to be(runtime.channel_resolver)
      expect(dc.endpoint_resolver).to be(runtime.channel_resolver)
    end

    it "builds the operator flow and DM control lane over the same live registry" do
      expect(runtime.operator_flow).to be_a(Rubotty::ControlPlane::OperatorFlow)
      expect(runtime.control_lane).to be_a(Rubotty::ControlPlane::ControlLane)
    end

    it "builds the operator admin console (issue #36) over the control lane" do
      expect(runtime.operator_console).to be_a(Rubotty::ControlPlane::OperatorConsole)
    end

    it "builds the passive identity-directory recorder (issue #71)" do
      expect(runtime.identity_recorder).to be_a(Rubotty::ControlPlane::IdentityRecorder)
    end

    it "wires each adapter with the operator console (issue #36) as its DM handler" do
      tg = runtime.adapters[[:telegram, "telegram"]]
      dc = runtime.adapters[[:discord, "discord"]]
      expect(tg.control_lane).to be(runtime.operator_console)
      expect(dc.control_lane).to be(runtime.operator_console)
    end

    it "builds the auto-leave join guard (issue #35) and wires each adapter with it" do
      expect(runtime.join_guard).to be_a(Rubotty::ControlPlane::JoinGuard)
      tg = runtime.adapters[[:telegram, "telegram"]]
      dc = runtime.adapters[[:discord, "discord"]]
      expect(tg.join_guard).to be(runtime.join_guard)
      expect(dc.join_guard).to be(runtime.join_guard)
    end

    it "builds the channel-discovery seam (issues #38, #39) and wires each adapter with it" do
      expect(runtime.channel_discovery).to be_a(Rubotty::ControlPlane::ChannelDiscovery)
      tg = runtime.adapters[[:telegram, "telegram"]]
      dc = runtime.adapters[[:discord, "discord"]]
      expect(tg.discovery).to be(runtime.channel_discovery)
      expect(dc.discovery).to be(runtime.channel_discovery)
    end

    it "hands the Telegram adapter the space migration an upgraded group needs" do
      expect(runtime.adapters[[:telegram, "telegram"]].space_migration).to be_a(Rubotty::ControlPlane::SpaceMigration)
    end

    it "builds room provisioning (issue #227) with its handlers registered on the durable scheduler" do
      expect(runtime.room_provisioning).to be_a(Rubotty::ControlPlane::RoomProvisioning)
      expect(runtime.durable_scheduler.instance_variable_get(:@handlers).keys).to include(
        Rubotty::ControlPlane::RoomProvisioning::CREATE_KIND, Rubotty::ControlPlane::RoomProvisioning::DELETE_KIND
      )
    end
  end

  describe "without a control plane there is no operator flow" do
    it "leaves the operator flow and control lane nil on a store with no database" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.operator_flow).to be_nil
      expect(runtime.control_lane).to be_nil
    end

    it "leaves room provisioning nil on a store with no database" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.room_provisioning).to be_nil
    end

    it "leaves the identity recorder nil on a store with no database, so recording is a no-op" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.identity_recorder).to be_nil
    end

    it "leaves the join guard nil on a store with no database, so a membership change is ignored" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.join_guard).to be_nil
    end

    it "leaves channel discovery nil on a store with no database, so an adapter discovers nothing" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.channel_discovery).to be_nil
    end

    it "leaves the space migration nil on a store with no database, so an upgrade is only logged" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.adapters[[:telegram, "telegram"]].space_migration).to be_nil
    end
  end

  describe "behavior-identical routing for the single community" do
    let(:runtime) { build_runtime }
    let(:snapshot_topology) { runtime.router.topology }
    let(:snap_tg) { runtime.adapters[[:telegram, "telegram"]] }
    let(:snap_dc) { runtime.adapters[[:discord, "discord"]] }
    let(:static_tg) { static_adapter("telegram") }
    let(:static_dc) { static_adapter("discord") }

    it "resolves every endpoint's own address to the same origin on both paths" do
      config.topology.endpoints.each do |endpoint|
        static = endpoint.adapter_name == :telegram ? static_tg : static_dc
        snap = endpoint.adapter_name == :telegram ? snap_tg : snap_dc
        expect(resolve(snap, endpoint)&.id).to eq(resolve(static, endpoint)&.id),
                                               "origin drifted for #{endpoint.id}"
      end
    end

    it "fans every endpoint out to exactly the same outbound endpoint set" do
      config.topology.endpoints.each do |endpoint|
        static = endpoint.adapter_name == :telegram ? static_tg : static_dc
        snap = endpoint.adapter_name == :telegram ? snap_tg : snap_dc

        static_origin = resolve(static, endpoint)
        snap_origin = resolve(snap, endpoint)

        static_targets = fan_out(config.topology, static_origin)
        snap_targets = fan_out(snapshot_topology, snap_origin)

        expect(snap_targets).to eq(static_targets), "fan-out drifted for #{endpoint.id}"
        # And it is the real bridge: General crosses to Discord, topics to pairs.
        expect(snap_targets).not_to be_empty
      end
    end

    it "misses on an unknown thread in a known supergroup identically on both paths" do
      # An unmapped thread in a known supergroup misses rather than falling back
      # to General's endpoint.
      unknown_thread = ["-1008000000001", 424_242]
      expect(static_tg.send(:endpoint_for, *unknown_thread)).to be_nil
      expect(snap_tg.send(:endpoint_for, *unknown_thread)).to be_nil
    end

    it "misses on an unclaimed space, fail-closed, on the snapshot path" do
      expect(snap_tg.send(:endpoint_for, "-1009999999999", nil)).to be_nil
      expect(snap_dc.send(:endpoint_for, "000000000000")).to be_nil
    end
  end

  describe "the boot lifecycle is idempotent across two boots" do
    it "seeds once and does not duplicate on a second boot against the same DB" do
      store = sequel_store
      build_runtime(store: store)
      models = Rubotty::ControlPlane.models(store.db)
      # Every boot also reconciles the protected communities from
      # config/protected_communities.yml, so the count is more than this test
      # seeds; what is checked here is that a second boot duplicates none.
      first_boot_count = models.community.count
      expect(models.community.where(slug: "sample").count).to eq(1)

      build_runtime(store: store)
      expect(models.community.count).to eq(first_boot_count)
      expect(models.community.where(slug: "sample").count).to eq(1)
      expect(models.channel.count).to eq(16)
    end
  end

  describe "resolving the Discord guild-id sentinel on first boot" do
    let(:store) { sequel_store }
    let(:runtime) { build_runtime(store: store) }
    let(:models) { Rubotty::ControlPlane.models(store.db) }

    # Build first, so the boot has seeded store.db before the models query it.
    before { runtime }

    # Scoped to sample: the protected communities every boot reconciles bring
    # their own resolved Discord connections, so an unscoped query could hit one.
    def discord_connection
      sample = models.community.where(slug: "sample").first
      models.platform_connection.where(adapter: "discord", community_id: sample.id).first
    end

    it "persists the real guild id the connected adapter reports and reloads" do
      expect(discord_connection.external_id).to eq("unresolved:sample")

      before_snapshot = runtime.registry.current
      fake = double("connected discord adapter")
      allow(fake).to receive(:guild_id_for_channel).and_return("112233445566778899")
      runtime.adapters[[:discord, "discord"]] = fake

      runtime.send(:resolve_discord_guilds)

      expect(discord_connection.external_id).to eq("112233445566778899")
      # The snapshot was swapped, so the persisted id is live for flows keying on it.
      expect(runtime.registry.current).not_to be(before_snapshot)
    end

    it "does not swap the snapshot when there is nothing to resolve" do
      fake = double("connected discord adapter")
      allow(fake).to receive(:guild_id_for_channel).and_return("112233445566778899")
      runtime.adapters[[:discord, "discord"]] = fake
      runtime.send(:resolve_discord_guilds) # resolves it once

      snapshot = runtime.registry.current
      runtime.send(:resolve_discord_guilds) # nothing pending now
      expect(runtime.registry.current).to be(snapshot)
    end
  end
end
