# frozen_string_literal: true

module Rubotty
  module Rendering
    # How a bridge-authored card writes an instant, since nothing rewrites one
    # on its way out: see {Features::TimestampExpansion} for the middle case.
    class CardTimestamps
      # @param registry [ControlPlane::Registry, nil] nil falls back to the fixed zone
      # @param logger [#warn, nil]
      # @param clock [#call] the instant a countdown or a Today/Tomorrow label
      #   is judged against; a caller with its own clock passes it in so the
      #   card and whatever text surrounds it describe one instant
      def initialize(registry:, logger: nil, clock: -> { Time.now })
        @registry = registry
        @logger = logger
        @clock = clock
      end

      # @param time [Time]
      # @param adapter [Adapters::Base] the adapter serving +endpoint+
      # @param endpoint [Core::Endpoint] the target this rendering is for
      # @param community_id [Integer, nil] whose configured zones to read
      # @param tz [String] the fixed zone the fallback renders in
      # @param style [Symbol] :full, :relative or :both, for the fallback and
      #   for Discord's markup
      # @return [String]
      def render(time, adapter:, endpoint:, community_id: nil, tz: "UTC", style: :full)
        now = @clock.call
        return fixed(time, adapter, tz, style, now) if adapter.adapter_name == :discord

        zones = zones_for(community_id, endpoint)
        return Features::TimestampExpansion.render(time, zones, now) if zones.any?

        fixed(time, adapter, tz, style, now)
      end

      private

      def fixed(time, adapter, tz, style, now) = adapter.render_timestamp(time, style: style, tz: tz, now: now)

      def zones_for(community_id, endpoint)
        community = @registry&.current&.community_by_id(community_id)
        return [] if community.nil?

        # A live Core::Endpoint has no #endpoint_key reader, but #id IS that key
        # by the convention the topology is built on.
        config = community.feature_config(endpoint.id, Features::Bridge.feature_name)
        Features::TimestampExpansion.zones_for_config(
          config, Features::Bridge::TIMESTAMP_TIMEZONES_KEY, logger: @logger
        )
      rescue StandardError => e
        @logger&.warn { "card timestamps: could not read the room's configured zones: #{e.message}" }
        []
      end
    end
  end
end
