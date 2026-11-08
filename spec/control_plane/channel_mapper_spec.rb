# frozen_string_literal: true

require "spec_helper"

# The write half of the mapping wizard, driven against the live Registry. Both
# the in-chat wizard and the dashboard land on these same rooms/room_channels.
RSpec.describe Rubotty::ControlPlane::ChannelMapper, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:community) { models.community.where(slug: "sample").first }

  let(:now) { Time.new(2026, 7, 23, 12, 0, 0) }

  subject(:mapper) do
    described_class.new(models: models, registry: registry, logger: Rubotty::Log.null, clock: -> { now })
  end

  # A channel in no room, on an existing connection, for mapping to link.
  def unmapped_channel(adapter:, endpoint_key:, route_key:, chat_key:)
    connection = models.platform_connection.where(community_id: community.id, adapter: adapter).first
    settings = adapter == "telegram" ? { chat_id: chat_key } : { channel_id: chat_key }
    models.channel.create(
      community_id: community.id, platform_connection_id: connection.id,
      adapter: adapter, account: connection.account, route_key: route_key,
      endpoint_key: endpoint_key, label: endpoint_key, receives: true, sends: true,
      relay: "{}", display_name: "{}", settings: JSON.generate(settings),
      created_at: now, updated_at: now
    )
  end

  describe "#channels_by_platform" do
    it "groups the community's channels by platform and marks the mapped ones" do
      grouped = mapper.channels_by_platform(community)
      expect(grouped.keys).to include("telegram", "discord")
      # Seeded channels are all in a room already.
      expect(grouped["telegram"]).to all(include(mapped: true))
    end
  end

  describe "#unmapped_by_platform" do
    it "lists only the channels not yet in any room" do
      unmapped_channel(adapter: "telegram", endpoint_key: "tg-new", route_key: "-100777", chat_key: "-100777")
      unmapped = mapper.unmapped_by_platform(community)
      expect(unmapped["telegram"].map { |c| c[:endpoint_key] }).to contain_exactly("tg-new")
      expect(unmapped).not_to have_key("discord") # all discord channels are seeded/mapped
    end
  end

  describe "#map" do
    before do
      unmapped_channel(adapter: "telegram", endpoint_key: "tg-new", route_key: "-100777", chat_key: "-100777")
      unmapped_channel(adapter: "discord", endpoint_key: "dc-new", route_key: "555000", chat_key: "555000")
    end

    it "links the named channels into one room so they mirror each other" do
      result = mapper.map(community: community, selectors: %w[tg-new dc-new], label: "New Room")

      expect(result.mapped?).to be(true)
      room = models.room.where(community_id: community.id, room_key: "new-room").first
      expect(room).not_to be_nil
      channel_ids = models.room_channel.where(room_id: room.id).select_map(:channel_id)
      expect(channel_ids.size).to eq(2)
    end

    it "makes the new room bridge live: the two channels fan out to each other" do
      mapper.map(community: community, selectors: %w[tg-new dc-new], label: "New Room")

      origin = registry.current.resolve(:telegram, "telegram", "-100777")&.endpoint
      targets = registry.current.topology.rooms_for(origin.id)
                        .flat_map { |room| room.targets_for(origin) }.map(&:id)
      expect(targets).to include("dc-new")
    end

    it "is idempotent: re-mapping the same channels adds no duplicate links" do
      mapper.map(community: community, selectors: %w[tg-new dc-new], label: "New Room")
      mapper.map(community: community, selectors: %w[tg-new dc-new], label: "New Room")

      room = models.room.where(community_id: community.id, room_key: "new-room").first
      expect(models.room_channel.where(room_id: room.id).count).to eq(2)
      expect(models.room.where(community_id: community.id, room_key: "new-room").count).to eq(1)
    end

    it "derives a unique room key when the label collides with an existing room" do
      mapper.map(community: community, selectors: %w[tg-new dc-new], room_key: "general")
      # "general" already exists from the seed, so a fresh key is derived.
      expect(models.room.where(community_id: community.id, room_key: "general").count).to eq(1)
    end

    # Two near-simultaneous mappings deriving the same room_key both see no
    # existing row on their SELECT; the second one's INSERT then races the
    # first's. The existence check that upsert_room runs after deriving the
    # key is made to miss a row that is, in fact, already there.
    it "falls back to the room a concurrent writer already committed for the same room_key" do
      mapper # built (and the registry snapshot it holds) before #where gets stubbed below
      calls = 0
      allow(models.room).to receive(:where).and_wrap_original do |original, *args|
        calls += 1
        if calls == 2
          # A concurrent transaction commits the same room_key right in the gap
          # between our SELECT and our INSERT. Sequel datasets are frozen, so
          # a bare stand-in with a #first that misses stands in for one.
          models.room.create(community_id: community.id, room_key: "new-room", label: "New Room",
                             display_name: "{}", created_at: now, updated_at: now)
          next Struct.new(:first).new(nil)
        end
        original.call(*args)
      end

      result = mapper.map(community: community, selectors: %w[tg-new dc-new], label: "New Room")

      expect(result.mapped?).to be(true)
      expect(models.room.where(community_id: community.id, room_key: "new-room").count).to eq(1)
      channel_ids = models.room_channel.where(room_id: result.room.id).select_map(:channel_id)
      expect(channel_ids.size).to eq(2)
    end

    it "resolves a channel by endpoint key or route key" do
      expect(mapper.resolve_channel(community, "tg-new").endpoint_key).to eq("tg-new")
      expect(mapper.resolve_channel(community, "-100777").endpoint_key).to eq("tg-new")
    end

    it "raises Invalid for an unknown selector" do
      expect { mapper.map(community: community, selectors: %w[tg-new nope]) }
        .to raise_error(described_class::Invalid, /no channel .* matches "nope"/)
    end

    it "raises Invalid when no channel is named at all" do
      expect { mapper.map(community: community, selectors: []) }
        .to raise_error(described_class::Invalid, /at least one channel/)
    end
  end

  # A community on one platform has a single channel, and room-scoped features
  # still need a room, so a one-member room is a first-class mapping.
  describe "#map with a single selector" do
    before do
      unmapped_channel(adapter: "telegram", endpoint_key: "tg-solo", route_key: "-100999", chat_key: "-100999")
    end

    it "creates a room holding just that channel" do
      result = mapper.map(community: community, selectors: %w[tg-solo], label: "Main Group")

      expect(result.mapped?).to be(true)
      room = models.room.where(community_id: community.id, room_key: "main-group").first
      expect(room).not_to be_nil
      expect(models.room_channel.where(room_id: room.id).select_map(:channel_id)).to eq([result.channels[0].id])
    end

    it "leaves the channel out of the unmapped list, so it reads as mapped everywhere" do
      mapper.map(community: community, selectors: %w[tg-solo], label: "Main Group")

      expect(mapper.unmapped_by_platform(community)).not_to have_key("telegram")
    end

    it "relays nothing extra: the room's single endpoint has no fan-out target" do
      mapper.map(community: community, selectors: %w[tg-solo], label: "Main Group")

      origin = registry.current.resolve(:telegram, "telegram", "-100999")&.endpoint
      targets = registry.current.topology.rooms_for(origin.id)
                        .flat_map { |room| room.targets_for(origin) }.map(&:id)
      expect(targets).to be_empty
    end

    it "grows into a bridged room when a second platform's channel is mapped into the SAME room later" do
      first = mapper.map(community: community, selectors: %w[tg-solo], label: "Main Group")
      unmapped_channel(adapter: "discord", endpoint_key: "dc-later", route_key: "555111", chat_key: "555111")

      mapper.map(community: community, selectors: %w[dc-later], room_key: first.room.room_key)

      expect(models.room.where(community_id: community.id, room_key: "main-group").count).to eq(1)
      expect(models.room_channel.where(room_id: first.room.id).count).to eq(2)
      origin = registry.current.resolve(:telegram, "telegram", "-100999")&.endpoint
      targets = registry.current.topology.rooms_for(origin.id)
                        .flat_map { |room| room.targets_for(origin) }.map(&:id)
      expect(targets).to include("dc-later")
    end

    it "is idempotent: re-mapping the same lone channel adds no duplicate room or link" do
      mapper.map(community: community, selectors: %w[tg-solo], label: "Main Group")
      mapper.map(community: community, selectors: %w[tg-solo], room_key: "main-group")

      expect(models.room.where(community_id: community.id, room_key: "main-group").count).to eq(1)
      expect(models.room_channel.where(room_id: room_id_for("main-group")).count).to eq(1)
    end
  end

  def room_id_for(room_key)
    models.room.where(community_id: community.id, room_key: room_key).first.id
  end

  # The one place an operator's mapping choice is interpreted, shared by the
  # dashboard's map form and the DM console's wizard.
  describe "#resolve_selection" do
    before do
      unmapped_channel(adapter: "telegram", endpoint_key: "tg-new", route_key: "-100777", chat_key: "-100777")
      unmapped_channel(adapter: "discord", endpoint_key: "dc-new", route_key: "555000", chat_key: "555000")
    end

    it "maps into an existing room, folding in a channel already there as the anchor" do
      result = mapper.resolve_selection(community: community, channel: "tg-new", room_key: "general")

      expect(result.mapped?).to be(true)
      expect(result.room.room_key).to eq("general")
      general = models.room.where(community_id: community.id, room_key: "general").first
      new_channel = models.channel.where(community_id: community.id, endpoint_key: "tg-new").first
      expect(models.room_channel.where(room_id: general.id, channel_id: new_channel.id).first).not_to be_nil
      # The room's pre-existing members (tg-general, dc-general) are untouched.
      expect(models.room_channel.where(room_id: general.id).count).to eq(3)
    end

    it "accepts an already-resolved channel row, not just a selector string" do
      channel_row = models.channel.where(community_id: community.id, endpoint_key: "tg-new").first
      result = mapper.resolve_selection(community: community, channel: channel_row, room_key: "general")

      expect(result.room.room_key).to eq("general")
    end

    it "maps into an existing room that has no channel in it yet" do
      empty_room = models.room.create(
        community_id: community.id, room_key: "empty-room", label: "Empty Room",
        display_name: "{}", created_at: now, updated_at: now
      )

      result = mapper.resolve_selection(community: community, channel: "tg-new", room_key: "empty-room")

      expect(result.room.id).to eq(empty_room.id)
      expect(models.room_channel.where(room_id: empty_room.id).count).to eq(1)
    end

    it "maps into a room_key that does not exist yet, creating it" do
      result = mapper.resolve_selection(community: community, channel: "tg-new", room_key: "brand-new")

      expect(result.room.room_key).to eq("brand-new")
      new_channel = models.channel.where(community_id: community.id, endpoint_key: "tg-new").first
      expect(models.room_channel.where(room_id: result.room.id).select_map(:channel_id))
        .to contain_exactly(new_channel.id)
    end

    it "maps the channel alone into a fresh room when solo is truthy" do
      result = mapper.resolve_selection(community: community, channel: "tg-new", solo: true)

      expect(models.room_channel.where(room_id: result.room.id).count).to eq(1)
      expect(mapper.unmapped_by_platform(community)).not_to have_key("telegram")
    end

    it "pairs the channel with a partner into a fresh room" do
      result = mapper.resolve_selection(community: community, channel: "tg-new", partner: "dc-new")

      channel_ids = models.room_channel.where(room_id: result.room.id).select_map(:channel_id)
      expect(channel_ids.size).to eq(2)
    end

    it "raises Invalid when the partner is the channel's own selector" do
      expect { mapper.resolve_selection(community: community, channel: "tg-new", partner: "tg-new") }
        .to raise_error(described_class::Invalid, /choose another unroomed channel/)
    end

    it "raises Invalid when the partner is already in a room" do
      expect { mapper.resolve_selection(community: community, channel: "tg-new", partner: "tg-general") }
        .to raise_error(described_class::Invalid, /choose another unroomed channel/)
    end

    it "raises Invalid when neither a room, a partner, nor solo is given" do
      expect { mapper.resolve_selection(community: community, channel: "tg-new") }
        .to raise_error(
          described_class::Invalid,
          "pick exactly one destination: a room, another unroomed channel, or this channel on its own."
        )
    end

    it "raises Invalid rather than silently preferring one of two destinations" do
      expect do
        mapper.resolve_selection(community: community, channel: "tg-new", room_key: "general", solo: true)
      end.to raise_error(
        described_class::Invalid,
        "pick exactly one destination: a room, another unroomed channel, or this channel on its own."
      )
    end
  end

  # Never deletes the room, even when its last member goes: a room id cascades
  # into feature_settings, events and the guest tables, and the real delete path
  # is gated behind a typed-name confirmation.
  describe "#unlink" do
    it "removes the channel from the room, leaving its other members linked" do
      unmapped_channel(adapter: "telegram", endpoint_key: "tg-new", route_key: "-100777", chat_key: "-100777")
      mapper.map(community: community, selectors: %w[tg-new], room_key: "general")
      room = models.room.where(community_id: community.id, room_key: "general").first
      channel = models.channel.where(community_id: community.id, endpoint_key: "tg-new").first
      before_count = models.room_channel.where(room_id: room.id).count

      result = mapper.unlink(room: room, channel: channel)

      expect(result.unlinked?).to be(true)
      expect(models.room_channel.where(room_id: room.id, channel_id: channel.id).first).to be_nil
      expect(models.room_channel.where(room_id: room.id).count).to eq(before_count - 1)
    end

    it "raises Invalid for a channel that is not in that room" do
      gaming_room = models.room.where(community_id: community.id, room_key: "gaming").first
      channel = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first

      expect { mapper.unlink(room: gaming_room, channel: channel) }
        .to raise_error(described_class::Invalid, "tg-general is not in room gaming.")
    end

    it "leaves the room row in place when its last channel is unlinked" do
      unmapped_channel(adapter: "telegram", endpoint_key: "tg-solo", route_key: "-100999", chat_key: "-100999")
      mapper.map(community: community, selectors: %w[tg-solo], label: "Solo Room")
      room = models.room.where(community_id: community.id, room_key: "solo-room").first
      channel = models.channel.where(community_id: community.id, endpoint_key: "tg-solo").first
      expect(models.room_channel.where(room_id: room.id).count).to eq(1)

      mapper.unlink(room: room, channel: channel)

      expect(models.room_channel.where(room_id: room.id).count).to eq(0)
      expect(models.room.where(id: room.id).first).not_to be_nil
    end
  end

  # 270d4c6 (#794) made route_key non-unique on purpose so an IRC hub group can
  # hold several room-scoped rows sharing one, with at most one receives: true.
  # Seed and Snapshot both prefer that row; resolve_channel has to too, or a
  # selector naming the shared route_key can grab whichever row loads first.
  describe "#resolve_channel with a hub group sharing one route_key" do
    def hub_pair(route_key:, receiving_endpoint_key:)
      connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
      %w[irc-hub-gaming irc-hub-travel].map do |endpoint_key|
        models.channel.create(
          community_id: community.id, platform_connection_id: connection.id,
          adapter: "irc", account: "irc-hub", route_key: route_key,
          endpoint_key: endpoint_key, label: endpoint_key, receives: endpoint_key == receiving_endpoint_key,
          sends: true, relay: "{}", display_name: "{}", settings: "{}", created_at: now, updated_at: now
        )
      end
    end

    it "picks the receiving row when it is the second one created" do
      hub_pair(route_key: "#sample", receiving_endpoint_key: "irc-hub-travel")

      expect(mapper.resolve_channel(community, "#sample").endpoint_key).to eq("irc-hub-travel")
    end

    it "picks the receiving row when it is the first one created" do
      hub_pair(route_key: "#sample-2", receiving_endpoint_key: "irc-hub-gaming")

      expect(mapper.resolve_channel(community, "#sample-2").endpoint_key).to eq("irc-hub-gaming")
    end
  end

  # The write half of the section above: what actually grows an existing IRC
  # channel into a hub group live, the way #map builds an ordinary
  # cross-platform room, so an operator on a database-only deployment can do
  # this from the dashboard with no YAML hub config involved anywhere.
  describe "#add_hub_room" do
    def irc_channel(endpoint_key:, route_key:, room_label:)
      connection = models.platform_connection.create(
        community_id: community.id, adapter: "irc", account: "irc-hub",
        external_id: endpoint_key, created_at: now, updated_at: now
      )
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "irc", account: "irc-hub", route_key: route_key, endpoint_key: endpoint_key,
        label: endpoint_key, receives: true, sends: true, relay: "{}", display_name: "{}",
        settings: JSON.generate(channel: route_key, room_label: room_label),
        created_at: now, updated_at: now
      )
    end

    def clone_channel
      models.channel.where(adapter: "irc", account: "irc-hub", route_key: "#sample")
            .exclude(endpoint_key: "irc-hub-gaming").first
    end

    before do
      gaming = irc_channel(endpoint_key: "irc-hub-gaming", route_key: "#sample", room_label: "gaming")
      mapper.map(community: community, selectors: [gaming.endpoint_key], room_key: "irc-gaming-room", label: "Gaming")
    end

    it "creates a new channel row sharing the anchor's route_key, mapped into the new room" do
      result = mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                                   room_label: "travel", label: "Travel")

      expect(result.mapped?).to be(true)
      clone = result.channels.first
      expect(clone.route_key).to eq("#sample")
      expect(clone.endpoint_key).not_to eq("irc-hub-gaming")
      room = models.room.where(community_id: community.id, room_key: "irc-travel-room").first
      expect(models.room_channel.where(room_id: room.id, channel_id: clone.id).first).not_to be_nil
    end

    it "always writes the clone as receives: false, leaving the anchor the one receiver" do
      mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                          room_label: "travel")

      expect(models.channel.where(endpoint_key: "irc-hub-gaming").first.receives).to be(true)
      expect(clone_channel.receives).to be(false)
    end

    it "stores the room_label and short_code on the clone's own settings, not the anchor's" do
      mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                          room_label: "travel", short_code: "tv")

      settings = clone_channel.json_value(:settings)
      expect(settings["room_label"]).to eq("travel")
      expect(settings["short_code"]).to eq("tv")
      anchor_settings = models.channel.where(endpoint_key: "irc-hub-gaming").first.json_value(:settings)
      expect(anchor_settings["short_code"]).to be_nil
    end

    it "leaves the anchor's own room untouched" do
      mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                          room_label: "travel")

      gaming_room = models.room.where(community_id: community.id, room_key: "irc-gaming-room").first
      expect(models.room_channel.where(room_id: gaming_room.id).count).to eq(1)
    end

    it "is idempotent: calling it again for the same anchor and room reconciles the same clone" do
      first = mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                                  room_label: "travel")
      second = mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                                   room_label: "travel")

      expect(second.channels.first.id).to eq(first.channels.first.id)
      room = models.room.where(community_id: community.id, room_key: "irc-travel-room").first
      expect(models.room_channel.where(room_id: room.id).count).to eq(1)
    end

    it "accepts an already-resolved channel row as the anchor, not just a selector" do
      anchor_row = models.channel.where(endpoint_key: "irc-hub-gaming").first
      result = mapper.add_hub_room(community: community, anchor: anchor_row, room_key: "irc-travel-room",
                                   room_label: "travel")

      expect(result.mapped?).to be(true)
    end

    it "makes both rows in the new group resolvable live through the registry" do
      mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "irc-travel-room",
                          room_label: "travel")

      expect(registry.current.channel_by_endpoint_key("irc-hub-gaming")).not_to be_nil
      expect(registry.current.channel_by_endpoint_key(clone_channel.endpoint_key)).not_to be_nil
    end
  end
end
