# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # Writes cross-platform channel mappings into +rooms+ and +room_channels+:
    # the write half of the discovery-and-mapping wizard, driven by both the
    # in-chat wizard and the dashboard. A room is "the set of channels that
    # mirror each other", so mapping a Telegram channel to a Discord channel is
    # exactly creating a room and linking both into it. Every write rebuilds
    # and swaps the {Snapshot} through the {Registry}, so a mapping is live and
    # {ChangeDetector} picks it up from another process too. This only maps
    # channels already known as rows; discovery creates those.
    class ChannelMapper
      # Raised for a request that cannot be carried out: an unknown selector, or a
      # mapping that names no channel at all. Carries a human-readable message.
      class Invalid < Rubotty::Error; end

      Result = Struct.new(:status, :room, :channels, keyword_init: true) do
        def mapped? = status == :mapped
        def unlinked? = status == :unlinked
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param registry [Registry, nil] reloaded after a write when present
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
      end

      # The community's channels grouped by platform (adapter), each decorated with
      # whether it is already in a room, in a stable order.
      #
      # @return [Hash{String=>Array<Hash>}] adapter => [{ endpoint_key:, label:,
      #   route_key:, mapped:, rooms: }]
      def channels_by_platform(community)
        roomed = channel_ids_in_a_room(community)
        @models.channel.where(community_id: community.id).order(:id).all
               .group_by(&:adapter)
               .transform_values do |rows|
                 rows.map { |row| describe_channel(row, roomed) }
               end
      end

      # The channels not yet in any room: the natural candidates a discovery sweep
      # offers to map. Same shape as {#channels_by_platform}, filtered to unmapped.
      def unmapped_by_platform(community)
        channels_by_platform(community).transform_values { |list| list.reject { |c| c[:mapped] } }
                                       .reject { |_adapter, list| list.empty? }
      end

      # Links a set of channels into one room so they mirror each other, named by
      # selector (an endpoint_key or a route_key); idempotent, a channel already
      # in the target room is left as is. Mapping another platform's channel into
      # the SAME room_key later grows a bridged room with no migration.
      #
      # @param room_key [String, nil] stable room id; derived from the label or the
      #   channels when omitted
      # @return [Result] :mapped
      def map(community:, selectors:, room_key: nil, label: nil)
        channels = Array(selectors).map { |selector| resolve_channel(community, selector) }
        raise Invalid, "a mapping needs at least one channel; got none." if channels.empty?

        # Resolved outside the linking transaction: a UniqueConstraintViolation
        # from the create below leaves that transaction unusable for a plain
        # rescue-and-retry, so the room has to be settled first, on its own.
        room = upsert_room(community, room_key: room_key, label: label, channels: channels)
        @models.db.transaction do
          channels.each { |channel| link(room, channel) }
        end
        reload
        log_map(room, channels)
        Result.new(status: :mapped, room: room, channels: channels)
      end

      # The channel a selector names in a community: an endpoint_key first
      # (globally unique), then a route_key, preferring the receiving row when a
      # hub group shares one. Raises {Invalid} on a miss.
      def resolve_channel(community, selector)
        selector = selector.to_s
        scope = @models.channel.where(community_id: community.id)
        channel = scope.where(endpoint_key: selector).first
        channel ||= scope.where(route_key: selector, receives: true).first
        channel ||= scope.where(route_key: selector).first
        return channel if channel

        raise Invalid, "no channel in community #{community.slug.inspect} matches #{selector.inspect}. " \
                       "Use an endpoint key or a route key."
      end

      # Resolve an operator's mapping choice for one channel: a given
      # +room_key+ maps into that room, folding in one existing member so it
      # reconciles; no room_key with +solo+ maps the channel alone into a
      # fresh room; no room_key, not solo, with a different +partner+ maps the
      # two together into a fresh room; anything else raises {Invalid}.
      #
      # @param channel [String, #endpoint_key] a selector or an already-resolved row
      # @return [Result] :mapped, from {#map}
      def resolve_selection(community:, channel:, room_key: nil, partner: nil, solo: false, label: nil)
        primary = channel.respond_to?(:endpoint_key) ? channel : resolve_channel(community, channel)
        room_key = presence(room_key)
        partner = presence(partner)
        solo = flag?(solo)

        choices = [room_key, partner, solo ? true : nil].compact
        if choices.length != 1
          raise Invalid, "pick exactly one destination: a room, another unroomed channel, or this channel on its own."
        end

        if room_key
          anchor = anchor_channel_in_room(community, room_key)
          others = anchor.nil? ? [] : [anchor.endpoint_key]
          return map(community: community, selectors: [primary.endpoint_key] + others,
                     room_key: room_key, label: label)
        end

        return map(community: community, selectors: [primary.endpoint_key], label: label) if solo

        if partner == primary.endpoint_key
          raise Invalid, "choose another unroomed channel to start a room with."
        end

        partner_channel = resolve_channel(community, partner)
        if channel_mapped?(community, partner_channel)
          raise Invalid, "choose another unroomed channel to start a room with."
        end

        map(community: community, selectors: [primary.endpoint_key, partner_channel.endpoint_key], label: label)
      end

      # Adds another room onto a channel already mapped, without moving it: what
      # IRC hub mode needs, where several rooms mirror one physical channel and
      # only one may ever receive inbound. Clones +anchor+ with receives: false
      # so the anchor's own receiving row stays unique, then maps the clone
      # into +room_key+. Idempotent: the clone's key derives from anchor and
      # room, so calling this again reconciles the same row.
      #
      # @return [Result] :mapped, from {#map}, whose one channel is the clone
      def add_hub_room(community:, anchor:, room_key:, room_label: nil, short_code: nil, label: nil)
        source = anchor.respond_to?(:endpoint_key) ? anchor : resolve_channel(community, anchor)
        clone = upsert_hub_clone(community, source, room_key: room_key, room_label: room_label, short_code: short_code)
        map(community: community, selectors: [clone.endpoint_key], room_key: room_key, label: label)
      end

      # Remove one channel from a room, without touching the room itself: a
      # room's id is cascade-referenced by feature_settings, events and the
      # guest tables, so destroying an empty room here would silently take
      # its configuration and event history down with it. An empty room left
      # behind is no leak, since a fresh channel mapped into the SAME
      # room_key later hands that configuration back.
      #
      # @return [Result] :unlinked
      def unlink(room:, channel:)
        row = @models.room_channel.where(room_id: room.id, channel_id: channel.id).first
        raise Invalid, "#{channel.endpoint_key} is not in room #{room.room_key}." if row.nil?

        row.delete
        reload
        log_unlink(room, channel)
        Result.new(status: :unlinked, room: room, channels: [channel])
      end

      private

      def channel_ids_in_a_room(community)
        room_ids = @models.room.where(community_id: community.id).select_map(:id)
        return [] if room_ids.empty?

        @models.room_channel.where(room_id: room_ids).select_map(:channel_id).uniq
      end

      def channel_mapped?(community, channel)
        room_ids = @models.room.where(community_id: community.id).select_map(:id)
        return false if room_ids.empty?

        @models.room_channel.where(room_id: room_ids, channel_id: channel.id).count.positive?
      end

      def describe_channel(row, roomed)
        room_keys = rooms_of(row.id)
        {
          endpoint_key: row.endpoint_key,
          label: presence(row.label) || row.endpoint_key,
          route_key: row.route_key,
          mapped: roomed.include?(row.id),
          rooms: room_keys
        }
      end

      def rooms_of(channel_id)
        room_ids = @models.room_channel.where(channel_id: channel_id).select_map(:room_id)
        return [] if room_ids.empty?

        @models.room.where(id: room_ids).select_map(:room_key)
      end

      # Find or create the room this mapping writes into. An existing room_key is
      # reconciled, so an operator can extend a room by mapping another channel
      # into it; otherwise a fresh room gets a derived, collision-free key.
      def upsert_room(community, room_key:, label:, channels:)
        key = presence(room_key) || derive_room_key(community, label, channels)
        existing = @models.room.where(community_id: community.id, room_key: key).first
        now = @clock.call
        if existing
          existing.update(label: presence(label) || existing.label, updated_at: now)
          return existing
        end

        @models.room.create(
          community_id: community.id, room_key: key,
          label: presence(label) || key, display_name: "{}",
          created_at: now, updated_at: now
        )
      rescue Sequel::UniqueConstraintViolation
        # Another writer created the same room_key between our SELECT and our
        # INSERT; fall back to the row it just committed, so a race reads as
        # an ordinary reconcile rather than a crash.
        @models.room.where(community_id: community.id, room_key: key).first
      end

      # A stable, unique room_key: a slug of the label, else of the channels'
      # shared label. Suffixed with a number until it is free.
      def derive_room_key(community, label, channels)
        base = slugify(presence(label) || common_label(channels) || "room")
        candidate = base
        counter = 2
        while @models.room.where(community_id: community.id, room_key: candidate).first
          candidate = "#{base}-#{counter}"
          counter += 1
        end
        candidate
      end

      def common_label(channels)
        labels = channels.map { |channel| presence(channel.label) }.compact
        labels.first
      end

      def link(room, channel)
        return if @models.room_channel.where(room_id: room.id, channel_id: channel.id).first

        @models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: @clock.call)
      end

      # The room-scoped channel row {#add_hub_room} maps: same physical
      # address as +source+, its own endpoint_key so it addresses
      # independently, and always receives: false, since +source+ (or
      # whichever row in the group already claims it) stays the one row that
      # answers inbound for this route_key.
      def upsert_hub_clone(community, source, room_key:, room_label:, short_code:)
        endpoint_key = "#{source.endpoint_key}:hub:#{room_key}"
        settings = source.json_value(:settings)
        settings["room_label"] = room_label if presence(room_label)
        settings["short_code"] = short_code if presence(short_code)
        attributes = {
          community_id: community.id, platform_connection_id: source.platform_connection_id,
          adapter: source.adapter, account: source.account, route_key: source.route_key,
          label: presence(room_label) || source.label, receives: false, sends: source.sends,
          relay: source.relay, display_name: source.display_name, settings: Models.dump_json(settings),
          updated_at: @clock.call
        }
        existing = @models.channel.where(endpoint_key: endpoint_key).first
        if existing
          existing.update(attributes)
          existing
        else
          @models.channel.create(attributes.merge(endpoint_key: endpoint_key, created_at: @clock.call))
        end
      end

      # Any one channel already linked into a community's room, by room_key, or nil
      # when the room does not exist or has no channels yet. Used only by
      # #resolve_selection, to name an existing member alongside the new channel.
      def anchor_channel_in_room(community, room_key)
        room = @models.room.where(community_id: community.id, room_key: room_key).first
        return nil if room.nil?

        channel_id = @models.room_channel.where(room_id: room.id).select_map(:channel_id).first
        return nil if channel_id.nil?

        @models.channel[channel_id]
      end

      # True for a Boolean true, or a present (non-blank) form-style value. Plain
      # #presence cannot be reused here: `presence(false)` reads as present, i.e.
      # true, which is backwards for a flag holding Ruby's own `false`.
      def flag?(value)
        value == true || (value.is_a?(String) && !presence(value).nil?)
      end

      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "channel mapper: snapshot reload after a write failed: #{e.message}" }
      end

      def log_map(room, channels)
        @logger&.info do
          "mapped #{channels.map(&:endpoint_key).join(", ")} into room #{room.room_key}"
        end
      end

      def log_unlink(room, channel)
        @logger&.info { "unlinked #{channel.endpoint_key} from room #{room.room_key}" }
      end

      def slugify(text)
        slug = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        slug.empty? ? "room" : slug[0, 64]
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
