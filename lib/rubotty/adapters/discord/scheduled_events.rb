# frozen_string_literal: true

module Rubotty
  module Adapters
    module Discord
      # Mirrors a Rubotty event (Rubotty::Events::Event) into Discord's native Guild Scheduled Events.
      #
      # Kept separate from Adapter for the same reason Webhook is: the payload
      # mapping (.payload_for / .rsvps_from) is a pure function a spec can drive
      # with no gateway, and the instance methods pass through to Client.
      #
      # A Rubotty event describes a game server address or an external URL, never a Discord voice or stage channel,
      # so entity_type is always EXTERNAL and entity_metadata.location carries where the event happens.
      class ScheduledEvents
        # https://discord.com/developers/docs/resources/guild-scheduled-event
        ENTITY_TYPE_EXTERNAL = 3
        PRIVACY_LEVEL_GUILD_ONLY = 2

        # Discord requires scheduled_end_time on an EXTERNAL event. A Rubotty
        # event with no announced end gets one manufactured this far after its
        # start.
        DEFAULT_DURATION_SECONDS = 3 * 60 * 60

        # Discord's entity_metadata.location caps at 100 characters.
        LOCATION_LIMIT = 100
        # Discord's guild scheduled event description caps at 1000 characters.
        DESCRIPTION_LIMIT = 1_000

        # Shown when neither Events::Event#server_address nor #url is set, since
        # entity_metadata.location is required for an EXTERNAL event.
        NO_LOCATION = "Location TBD"

        def initialize(client:, logger:)
          @client = client
          @logger = logger
        end

        attr_reader :logger

        # @param event [Rubotty::Events::Event]
        # @param guild_id [String, nil]
        # @return [String, nil] the native event id, or nil when no guild is known
        def create(event, guild_id:)
          return skip("create", guild_id) if guild_id.nil?

          response = @client.create_scheduled_event(guild_id, self.class.payload_for(event))
          response && response["id"]&.to_s
        end

        # @return [void]
        def update(native_id, event, guild_id:)
          return skip("update", guild_id, native_id) if guild_id.nil? || native_id.nil?

          @client.update_scheduled_event(guild_id, native_id, self.class.payload_for(event))
          nil
        end

        # @return [void]
        def delete(native_id, guild_id:)
          return skip("delete", guild_id, native_id) if guild_id.nil? || native_id.nil?

          @client.delete_scheduled_event(guild_id, native_id)
          nil
        end

        # @return [Array<Hash>] each a {identity:, response:} pair
        def rsvps(native_id, guild_id:)
          return Array(skip("RSVP read", guild_id, native_id)) if guild_id.nil? || native_id.nil?

          self.class.rsvps_from(@client.scheduled_event_users(guild_id, native_id))
        end

        private

        # No guild known for this account, or no native id to target: a logged
        # no-op rather than a raise.
        def skip(operation, guild_id, native_id = nil)
          reason = guild_id.nil? ? "no known Discord guild for this account" : "no native event id"
          target = native_id ? ": #{native_id}" : ""
          logger.info { "skipping a Discord scheduled-event #{operation} (#{reason}#{target})" }
          nil
        end

        public

        # The Discord create/modify request body for +event+. A pure function:
        # no client, no network.
        #
        # @param event [Rubotty::Events::Event]
        # @return [Hash]
        def self.payload_for(event)
          starts_at = event.starts_at
          {
            name: event.title.to_s,
            description: clamp(event.description.to_s, DESCRIPTION_LIMIT),
            scheduled_start_time: starts_at.iso8601,
            scheduled_end_time: (event.ends_at || starts_at + DEFAULT_DURATION_SECONDS).iso8601,
            privacy_level: PRIVACY_LEVEL_GUILD_ONLY,
            entity_type: ENTITY_TYPE_EXTERNAL,
            entity_metadata: { location: location_for(event) }
          }
        end

        # Discord's interested/going list, shaped to the adapter capability's
        # neutral pairs. Everybody it returns is "interested", and the handle
        # and global name ride along as this list is often the only sighting.
        #
        # @param users [Array<Hash>] Discord's GET .../scheduled-events/{id}/users body
        # @return [Array<Hash>] each a {identity:, response:, username:, display:} pair
        def self.rsvps_from(users)
          Array(users).filter_map do |entry|
            user = entry.is_a?(Hash) ? entry["user"] : nil
            id = user.is_a?(Hash) ? user["id"] : nil
            next nil if id.nil?

            { identity: id.to_s, response: "interested",
              username: presence(user["username"]),
              display: presence(user["global_name"]) }
          end
        end

        def self.location_for(event)
          candidate = [event.server_address, event.url].find { |value| !value.to_s.strip.empty? }
          clamp((candidate || NO_LOCATION).to_s, LOCATION_LIMIT)
        end
        private_class_method :location_for

        def self.presence(value)
          string = value.to_s.strip
          string.empty? ? nil : string
        end
        private_class_method :presence

        def self.clamp(text, limit)
          return text if text.length <= limit

          "#{text[0, limit - 1]}…"
        end
        private_class_method :clamp
      end
    end
  end
end
