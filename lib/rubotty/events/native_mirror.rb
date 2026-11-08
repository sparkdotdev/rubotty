# frozen_string_literal: true

require "sequel"

module Rubotty
  module Events
    # The inbound half of the native mirror: a Guild Scheduled Event somebody
    # created in Discord's own UI, reflected into a Rubotty event by writing
    # through {ControlPlane::EventScheduling}. Outbound is {Events::Announcer}.
    class NativeMirror
      # Provenance stamped on a mirrored-in event's created_by.
      CREATED_BY = "discord-native"

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param event_scheduling [ControlPlane::EventScheduling] the pure write
      #   surface a mirrored-in event is created, updated and cancelled through
      # @param policy [ControlPlane::EventPolicy, nil] resolves which candidate
      #   room has events turned on; a real one over +models+ by default
      # @param clock [#call] time source, for a change with no start time
      # @param native_claims [Events::NativeCreateClaims] the outbound creates
      #   still in flight, which the loop guard waits on. Shared by default.
      def initialize(models:, event_scheduling:, policy: nil, logger: nil, clock: -> { Time.now },
                     native_claims: NativeCreateClaims.shared)
        @models = models
        @event_scheduling = event_scheduling
        @policy = policy || ControlPlane::EventPolicy.new(models: models)
        @logger = logger
        @clock = clock
        @native_claims = native_claims
      end

      # Handle one native-event change. A no-op without a write surface, or for
      # a change Rubotty already owns (the create loop guard).
      #
      # @param change [Events::NativeEventChange]
      # @return [void]
      def handle(change)
        return if change.nil? || @event_scheduling.nil?

        await_own_create(change)
        existing = event_for_native_ref(change)
        case change.action
        when :created
          create_from(change) if existing.nil?
        when :updated
          existing ? update_from(existing, change) : create_from(change)
        when :deleted
          @event_scheduling.cancel(event: existing) if existing
        end
        nil
      rescue StandardError => e
        @logger&.warn { "events native mirror: #{change} failed: #{e.class}: #{e.message}" }
        nil
      end

      private

      # The loop guard reads native_refs, and our own outbound create writes it
      # only once the platform answers, so an echo can beat the write and read
      # a row that is about to name it. Wait for any create in flight on this
      # account first. A wait that runs out of budget logs and reads anyway.
      def await_own_create(change)
        return if @native_claims.settle(change.adapter, change.account)

        @logger&.warn do
          "events native mirror: #{change} read the loop guard while a native create " \
            "on #{change.adapter} was still in flight"
        end
      end

      # The Rubotty event whose native_refs already names this change's id on
      # this platform, or nil: the loop guard. Narrowed by an escaped LIKE
      # on the JSON text (so a platform id carrying a metacharacter cannot
      # widen the scan), then verified in Ruby so a substring cannot
      # false-match.
      def event_for_native_ref(change)
        platform = change.adapter.to_s
        native_id = change.native_id.to_s
        return nil if native_id.empty?

        @models.event
               .where(Util::LikePattern.like(:native_refs, Util::LikePattern.contains(native_id)))
               .all
               .map { |row| Event.new(row) }
               .find { |event| event.native_ref(platform).to_s == native_id }
      end

      # Create a Rubotty event mirroring the native one, stamped with the
      # native id so it is never pushed back out (and never mirrored in twice).
      def create_from(change)
        community, room = resolve_room(change)
        return if room.nil?

        @event_scheduling.create(
          community: community, room: room, as: :operator,
          title: presence(change.title) || "Untitled event",
          starts_at: change.starts_at || @clock.call,
          ends_at: change.ends_at,
          kind: Event::KIND_GENERAL,
          url: location_of(change),
          description: description_of(change),
          created_by: CREATED_BY,
          native_refs: { change.adapter.to_s => change.native_id.to_s }
        )
      rescue ControlPlane::EventScheduling::Invalid => e
        @logger&.info { "events native mirror: not creating a mirror for #{change.native_id}: #{e.message}" }
      end

      # Push a native update onto the event it maps to, but only the field(s)
      # that genuinely differ, UNSET otherwise: resupplying an unchanged one
      # would still bump updated_at (a bare Discord status transition,
      # SCHEDULED to ACTIVE, resupplies every field verbatim). An empty diff
      # writes nothing, which also starves the outbound echo an unchanged
      # update pushed back to Discord would otherwise bounce forever on.
      def update_from(existing, change)
        diff = diff_from(existing, change)
        return if diff.empty?

        @event_scheduling.update(event: existing, **diff)
      rescue ControlPlane::EventScheduling::Invalid => e
        @logger&.info { "events native mirror: not updating event #{existing.id}: #{e.message}" }
      end

      # The community and first events-enabled room the change's guild maps to,
      # or [nil, nil]. Resolved through the connection carrying that guild id,
      # then a room one of its channels is bridged into.
      def resolve_room(change)
        guild_id = change.guild_id.to_s
        return [nil, nil] if guild_id.empty?

        connections_for(change.adapter, guild_id).each do |connection|
          community = @models.community[connection.community_id]
          next if community.nil?

          rooms_for(connection).each do |room|
            return [community, room] if @policy.room_policy(community: community, room: room)[:enabled]
          end
        end
        @logger&.info { "events native mirror: no events-enabled room for #{change.adapter} guild #{guild_id}" }
        [nil, nil]
      end

      def connections_for(adapter, guild_id)
        @models.platform_connection.where(adapter: adapter.to_s, external_id: guild_id).all
      end

      def rooms_for(connection)
        channel_ids = @models.channel.where(platform_connection_id: connection.id).select_map(:id)
        return [] if channel_ids.empty?

        room_ids = @models.room_channel.where(channel_id: channel_ids).select_map(:room_id).uniq
        room_ids.sort.filter_map { |id| @models.room[id] }
      end

      # The fields where +change+ differs from the event it maps to, each
      # mapped to the value it should become. Every candidate already falls
      # back to the event's own current value when the change carries
      # nothing for that field, so a payload missing a key reads as
      # "unchanged" rather than "clear it". Only a field that actually moved
      # is included; the rest is left for EventScheduling::UNSET to cover.
      def diff_from(event, change)
        candidates = {
          title: presence(change.title) || event.title,
          starts_at: change.starts_at || event.starts_at,
          ends_at: change.ends_at || event.ends_at,
          url: location_of(change) || event.url,
          description: description_of(change) || event.description
        }
        candidates.select { |field, value| moved?(field, value, event) }
      end

      # starts_at/ends_at compare as instants (the DB round-trip can change
      # the Time's own class or offset without changing what second it names);
      # everything else compares as text.
      def moved?(field, value, event)
        current = event.public_send(field)
        return value&.to_i != current&.to_i if %i[starts_at ends_at].include?(field)

        value.to_s != current.to_s
      end

      # entity_metadata.location off the change's raw payload, or nil. The
      # stand-in the outbound mirror invents reads as nothing here, so it is
      # never taken back in as though somebody had typed it.
      def location_of(change)
        raw = change.raw
        return nil unless raw.is_a?(Hash)

        value = presence(raw.dig("entity_metadata", "location") || raw.dig(:entity_metadata, :location))
        value == Adapters::Discord::ScheduledEvents::NO_LOCATION ? nil : value
      end

      def description_of(change)
        raw = change.raw
        return nil unless raw.is_a?(Hash)

        presence(raw["description"] || raw[:description])
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
