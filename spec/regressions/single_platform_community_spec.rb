# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rubotty/storage/schema"

# #1422: went looking for the shape that would actually break a single-platform
# community (one account, one endpoint per room, nothing to relay to) and found
# the pipeline already treats it as an ordinary room. This is the standing
# regression the issue asked for, so a later two-platform assumption fails here first.
RSpec.describe "a genuinely single-platform community", :control_plane do
  let(:seeded) { seeded_sample(slug: "sample") }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:model) { sample_model }
  let(:adapter) { Fakes::RecordingAdapter.new }
  let(:storage) { Rubotty::Storage::SequelStore.new(db: db, logger: Rubotty::Log.null).migrate! }
  let(:analytics) { Rubotty::ControlPlane::Analytics.new(db: db, models: models) }

  # A room with exactly one real channel. SnapshotBuilder still adds the
  # synthetic, non-sending API endpoint every room gets (#build_rooms in
  # snapshot_builder.rb), so this is the most single-platform a control-plane
  # room can be: one endpoint that sends, and one that only receives.
  def make_solo_room!
    connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
    now = Time.now
    room = models.room.create(community_id: community.id, room_key: "solo-room", label: "Solo",
                              display_name: "{}", created_at: now, updated_at: now)
    channel = models.channel.create(
      community_id: community.id, platform_connection_id: connection&.id,
      adapter: "telegram", account: connection&.account || "tg1", route_key: "solo-route",
      endpoint_key: "tg-solo-only", label: "Solo channel", created_at: now, updated_at: now
    )
    models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: now)
    channel
  end

  # Created before the registry reads the database, so the snapshot it builds
  # already knows about this room rather than one taken a beat too early.
  let!(:solo_channel) { make_solo_room! }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: model.accounts) }
  let(:origin) { registry.current.topology.endpoint(solo_channel.endpoint_key) }
  let(:solo_room) { registry.current.topology.rooms_for(solo_channel.endpoint_key).first }

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: registry.current.topology, adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
      ttl: 3600, registry: registry
    )
  end

  it "has no real endpoint to fan out to, which is the shape a bridged room does not have" do
    real_targets = solo_room.targets_for(origin).reject { |e| e.adapter_name == :api }

    expect(real_targets).to be_empty
    expect(solo_room.endpoints.map(&:adapter_name)).to include(:telegram)
  end

  it "still relays nothing, delivers nothing, and raises nothing" do
    expect { router.handle(message(origin, text: "hello from a solo room", native_id: "solo-1")) }
      .not_to raise_error
    expect(adapter.delivered).to be_empty
  end

  it "still counts in the analytics message volume panel, the one gap #1420 described" do
    router.handle(message(origin, text: "hello from a solo room", native_id: "solo-1"))

    messages = analytics.overview(community: community)[:messages]
    expect(messages).to include(available: true, total: 1)
  end
end
