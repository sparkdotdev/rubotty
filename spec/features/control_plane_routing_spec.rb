# frozen_string_literal: true

require "spec_helper"

# The bridge through the assembled pipeline over the real seeded SAMPLE snapshot, where
# toggling a room-scoped feature_settings row changes routing on the next snapshot reload.
RSpec.describe "the bridge feature over the control-plane snapshot", :control_plane do
  let(:model) { sample_model }
  let(:seeded) { seeded_sample(slug: "sample") }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new }

  # The router the runtime builds, minus the live platform adapters: one recording adapter
  # serves every endpoint and routing comes from the snapshot.
  subject(:router) do
    Rubotty::Core::Router.new(
      topology: registry.current.topology,
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      ttl: 3600,
      registry: registry
    )
  end

  def origin(endpoint_key) = registry.current.topology.endpoint(endpoint_key)

  def relay(endpoint_key, native_id: "1")
    router.handle(message(origin(endpoint_key), text: "hi", native_id: native_id))
  end

  # Writes the bridge row for the room +endpoint_key+'s channel belongs to, which turns off
  # relaying for every endpoint bridged into that room, not just the one named.
  def disable_bridge_on(endpoint_key)
    channel = models.channel.where(endpoint_key: endpoint_key).first
    room_id = models.room_channel.where(channel_id: channel.id).first.room_id
    models.feature_setting.create(
      community_id: channel.community_id, room_id: room_id,
      feature: "bridge", enabled: false, config: "{}",
      created_at: Time.now, updated_at: Time.now
    )
    registry.reload
  end

  it "fans a General message out to exactly its paired Discord channel" do
    relay("tg-general")
    expect(adapter.delivered.map(&:first)).to eq(["dc-general"])
  end

  it "bridges every seeded room, each Telegram leaf to its Discord pair" do
    %w[general gaming travel news technology shitposting media].each do |room|
      adapter.delivered.clear
      relay("tg-#{room}", native_id: "n-#{room}")
      expect(adapter.delivered.map(&:first)).to eq(["dc-#{room}"]), "room #{room} did not bridge"
    end
  end

  describe "per-room enablement from feature_settings" do
    it "stops relaying on a channel whose room's bridge row is turned off" do
      relay("tg-general", native_id: "1")
      expect(adapter.delivered.map(&:first)).to eq(["dc-general"])

      disable_bridge_on("tg-general")

      adapter.delivered.clear
      relay("tg-general", native_id: "2")
      expect(adapter.delivered).to be_empty
    end

    it "stops the room's OTHER platform endpoint too: the row is room-scoped, not endpoint-scoped" do
      disable_bridge_on("tg-general")

      relay("dc-general", native_id: "d1")
      expect(adapter.delivered).to be_empty
    end

    it "leaves other rooms relaying: enablement is per room, not per community" do
      disable_bridge_on("tg-general")

      relay("tg-gaming", native_id: "g1")
      expect(adapter.delivered.map(&:first)).to eq(["dc-gaming"])
    end
  end
end
