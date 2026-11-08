# frozen_string_literal: true

# The shared fixture for tenancy regressions: two communities that each own a
# room whose room_key is the SAME string, which is the shape production has.
# #colliding_snapshot builds a Snapshot for anything reading the live topology,
# and #colliding_control_plane migrates a database and seeds the same two
# communities for anything reading rows. Both are real objects, not doubles.
# ALPHA holds the LOWER id, so it is the one a first-match-wins bug picks.
module CollidingCommunities
  # The key both communities use. Deliberately the live one.
  SHARED_ROOM_KEY = "general"

  ALPHA = { id: 1, slug: "alpha" }.freeze
  BETA  = { id: 2, slug: "beta" }.freeze

  # The supergroup each community bridges, for adapters that address a chat
  # rather than a channel. Alpha's sorts first, so a first-match-wins bug in
  # the Telegram adapter picks it while acting for beta.
  CHAT_IDS = { "alpha" => "-1001000000001", "beta" => "-1001000000002" }.freeze

  # One community's endpoints for the shared room, tagged with its community so
  # Core::CommunityScope can tell them apart. The ids differ between the two
  # because endpoint keys ARE globally unique; only the room key collides.
  def colliding_endpoints(slug, community_id, adapters: %i[telegram discord])
    adapters.map do |adapter_name|
      endpoint(
        "#{slug}-#{adapter_name}", adapter: adapter_name, account: "shared",
        settings: colliding_settings(slug, adapter_name),
        community_id: community_id
      )
    end
  end

  # The addressing each adapter actually reads: Telegram wants a chat_id and
  # Discord resolves a guild off channel_id. Both are per community, which is
  # what makes a call landing on the wrong one visible.
  def colliding_settings(slug, adapter_name)
    settings = { room_key: SHARED_ROOM_KEY, channel_id: "#{slug}-#{adapter_name}-chan" }
    settings[:chat_id] = CHAT_IDS.fetch(slug) if adapter_name == :telegram
    settings
  end

  def colliding_community(spec, adapters: %i[telegram discord], people: [], operators: [],
                          feature_settings: [])
    endpoints = colliding_endpoints(spec[:slug], spec[:id], adapters: adapters)
    rooms = [Rubotty::Core::Room.owned_by(spec[:id], id: SHARED_ROOM_KEY,
                                          label: SHARED_ROOM_KEY, endpoints: endpoints)]
    channels = endpoints.map do |ep|
      Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: spec[:id], route_key: ep.id)
    end
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: spec[:id], slug: spec[:slug], name: spec[:slug].upcase, status: "active", settings: {},
      topology: Rubotty::Core::Topology.new(rooms), channels: channels,
      operators: Rubotty::Core::Moderation::Directory.new(operators),
      people: Rubotty::Core::Directory.new(people),
      feature_settings: feature_settings
    )
  end

  # @return [ControlPlane::Snapshot] alpha first, so a merged index built in
  #   load order hands alpha's "general" to a beta lookup that forgot to scope.
  def colliding_snapshot(adapters: %i[telegram discord])
    Rubotty::ControlPlane::Snapshot.new(
      communities: [
        colliding_community(ALPHA, adapters: adapters),
        colliding_community(BETA, adapters: adapters)
      ]
    )
  end

  def colliding_registry(snapshot = colliding_snapshot)
    FrozenRegistry.new(snapshot)
  end

  # A migrated database holding the same two communities as real rows: two
  # community rows, a room keyed "general" in each, and one channel per adapter
  # joined to it.
  #
  # @return [Array(Sequel::Database, ControlPlane::Models, Hash)] the third
  #   being { alpha: {community_id:, room_id:, endpoint_keys:}, beta: ... }
  def colliding_control_plane(adapters: %i[telegram discord])
    db = Sequel.sqlite
    Rubotty::ControlPlane.migrate!(db)
    models = Rubotty::ControlPlane.models(db)
    seeded = [ALPHA, BETA].to_h { |spec| [spec[:slug].to_sym, seed_colliding(models, spec, adapters)] }
    [db, models, seeded]
  end

  # A tiny Registry stand-in: the real one watches a database, and a spec that
  # only needs a fixed view should not have to.
  class FrozenRegistry
    def initialize(snapshot) = @snapshot = snapshot

    def current = @snapshot
  end

  private

  def seed_colliding(models, spec, adapters)
    now = Time.now
    community_id = models.community.insert(
      slug: spec[:slug], name: spec[:slug].upcase, status: "active", created_at: now, updated_at: now
    )
    room_id = models.room.insert(
      community_id: community_id, room_key: SHARED_ROOM_KEY, label: SHARED_ROOM_KEY,
      created_at: now, updated_at: now
    )
    keys = adapters.map { |adapter| seed_colliding_channel(models, spec, community_id, room_id, adapter, now) }
    { community_id: community_id, room_id: room_id, endpoint_keys: keys }
  end

  def seed_colliding_channel(models, spec, community_id, room_id, adapter, now)
    connection_id = models.platform_connection.insert(
      community_id: community_id, adapter: adapter.to_s, account: "shared",
      external_id: "#{spec[:slug]}-space", label: "#{spec[:slug]} #{adapter}",
      created_at: now, updated_at: now
    )
    endpoint_key = "#{spec[:slug]}-#{adapter}"
    channel_id = models.channel.insert(
      community_id: community_id, platform_connection_id: connection_id, adapter: adapter.to_s,
      account: "shared", route_key: endpoint_key, endpoint_key: endpoint_key,
      label: endpoint_key, created_at: now, updated_at: now
    )
    models.room_channel.insert(room_id: room_id, channel_id: channel_id, created_at: now)
    endpoint_key
  end
end

RSpec.configure do |config|
  config.include CollidingCommunities
end
