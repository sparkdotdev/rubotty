# frozen_string_literal: true

module Rubotty
  module Polls
    # A poll's two durable clocks: the deadline, and the six-hourly nudge that
    # offers the card back to the room ({Board#repost_if_buried} decides).
    class Timekeeper
      CLOSE_KIND = "poll_close"
      REPOST_KIND = "poll_repost"

      REPOST_INTERVAL = 6 * 60 * 60

      NOOP = ->(_poll_id) {}

      # @param scheduler [Core::DurableScheduler] both kinds are registered here,
      #   before boot recovery runs
      # @param on_close [#call, nil] called with a poll id at its deadline
      # @param on_repost [#call, nil] called with a poll id every {REPOST_INTERVAL}
      # @param logger [#info, #warn, nil]
      # @param clock [#call] returns the current Time; injected in tests
      def initialize(scheduler:, on_close: nil, on_repost: nil, logger: nil, clock: -> { Time.now })
        @scheduler = scheduler
        @on_close = on_close || NOOP
        @on_repost = on_repost || NOOP
        @logger = logger
        @clock = clock
        @scheduler.register(CLOSE_KIND) { |job| @on_close.call(poll_id(job)) }
        @scheduler.register(REPOST_KIND) { |job| @on_repost.call(poll_id(job)) }
      end

      # Cancels this poll's pending jobs first, so it is safe to call again.
      def arm(poll)
        cancel_for(poll)
        return 0 unless poll.open?

        now = @clock.call
        armed = 0
        if poll.closes_at > now
          @scheduler.schedule(kind: CLOSE_KIND, run_at: poll.closes_at, payload: { "poll_id" => poll.id })
          armed += 1
        end
        @scheduler.schedule(
          kind: REPOST_KIND, run_at: now + REPOST_INTERVAL,
          payload: { "poll_id" => poll.id }, recurrence: REPOST_INTERVAL
        )
        armed + 1
      end

      # @return [Integer] how many pending jobs were cancelled
      def cancel_for(poll)
        [CLOSE_KIND, REPOST_KIND].sum do |kind|
          @scheduler.cancel(kind: kind, every_community: true) { |payload| payload["poll_id"] == poll.id }
        end
      end

      private

      def poll_id(job)
        (job.payload || {})["poll_id"]
      end
    end
  end
end
