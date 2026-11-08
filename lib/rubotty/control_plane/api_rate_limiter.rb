# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # A per-key, fixed-window request limit for the REST admin API, expressed
    # over a DURABLE log (api_request_log) rather than in-memory state so the
    # limit survives a restart and holds across several `rubotty web` instances
    # sharing one datastore. Default budget: 60 requests per 60 seconds, per key.
    class ApiRateLimiter
      DEFAULT_MAX = 60
      DEFAULT_WINDOW_SECONDS = 60

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param max [Integer] requests permitted per window
      # @param window_seconds [Integer] the trailing window width
      # @param clock [#call] injectable time source
      def initialize(models:, max: DEFAULT_MAX, window_seconds: DEFAULT_WINDOW_SECONDS, clock: -> { Time.now })
        @models = models
        @max = max.to_i
        @window_seconds = window_seconds.to_i
        @clock = clock
      end

      attr_reader :max, :window_seconds

      # Whether this key may make another request right now: true when it has
      # made fewer than +max+ requests in the trailing window.
      #
      # @param api_key [Models::ApiKey]
      # @return [Boolean]
      def allow?(api_key)
        since = @clock.call - @window_seconds
        @models.api_request_log
               .where(api_key_id: api_key.id)
               .where { created_at >= since }
               .count < @max
      end

      # Seconds a caller should suggest waiting before retrying, for the
      # Retry-After header: the whole window, a safe upper bound.
      def retry_after = @window_seconds

      # Record one request against a key, for the window {#allow?} counts over.
      # Called from the api adapter in api/app.rb.
      #
      # @param api_key [Models::ApiKey]
      def record!(api_key)
        @models.api_request_log.create(api_key_id: api_key.id, created_at: @clock.call)
      end

      # Delete every logged request older than +older_than+, so the table does
      # not grow without bound. Called on every purge tick by
      # Core::Runtime#prune_api_request_log, from the loop started in
      # Core::Runtime#start_purge_thread.
      #
      # @param older_than [Time]
      # @return [Integer] rows removed
      def prune(older_than:)
        @models.api_request_log.where { created_at < older_than }.delete
      end
    end
  end
end
