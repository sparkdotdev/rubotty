# frozen_string_literal: true

module Rubotty
  module Features
    # The part of {ControlPlane::TimezoneInference}'s chain that has to reach
    # into a resolved feature config, shared by /event and /schedule.
    module RoomTimezone
      module_function

      # The room's home zone: the first of its configured pairs, or of
      # {TimestampExpansion::DEFAULT_ZONES} where it set none, so a bare
      # wall-clock time reads in the zone its own cards lead with. A room that
      # stored an empty list gets nil and falls through to UTC.
      #
      # @param context [Features::Context]
      # @param logger [#warn, nil]
      # @return [String, nil]
      def room_default(context, logger: nil)
        community = context.community
        return nil unless community.respond_to?(:feature_config)

        config = community.feature_config(context.channel, Features::Bridge.feature_name)
        Features::TimestampExpansion.zones_for_config(
          config, Features::Bridge::TIMESTAMP_TIMEZONES_KEY, logger: logger
        ).first&.iana_timezone
      rescue StandardError => e
        logger&.warn { "could not read this room's default timezone: #{e.message}" }
        nil
      end

      # @return [String] a real IANA zone identifier, always
      def infer(context, explicit: nil, logger: nil)
        author = context.message.author
        ControlPlane::TimezoneInference.resolve(
          explicit: explicit,
          nickname: author&.nickname,
          display_name: author&.display_name,
          community_default: room_default(context, logger: logger)
        )
      end
    end
  end
end
