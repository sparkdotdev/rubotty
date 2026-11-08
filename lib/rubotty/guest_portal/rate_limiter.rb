# frozen_string_literal: true

module Rubotty
  module GuestPortal
    # A per-session send limit for the guest portal: a fixed-window limiter over the
    # DURABLE feed, counting the invite's own sends in the trailing window. Counting
    # persisted rows means the limit survives a restart and holds across instances.
    class RateLimiter
      # Default budget: plenty for a person typing, and it caps a script hammering
      # the send endpoint.
      DEFAULT_MAX = 5
      DEFAULT_WINDOW_SECONDS = 15

      # @param feed [ControlPlane::GuestFeed] the durable send store to count over
      # @param max [Integer] sends permitted per window
      # @param window_seconds [Integer] the trailing window width
      # @param clock [#call] injectable time source
      def initialize(feed:, max: DEFAULT_MAX, window_seconds: DEFAULT_WINDOW_SECONDS, clock: -> { Time.now })
        @feed = feed
        @max = max.to_i
        @window_seconds = window_seconds.to_i
        @clock = clock
      end

      attr_reader :max, :window_seconds

      # True when this invite has made fewer than +max+ sends in the trailing window.
      #
      # @param invite [Models::GuestInvite]
      # @return [Boolean]
      def allow?(invite)
        since = @clock.call - @window_seconds
        @feed.out_count_since(invite: invite, since: since) < @max
      end

      # Seconds for the Retry-After header: the whole window, a safe upper bound.
      def retry_after = @window_seconds
    end
  end
end
