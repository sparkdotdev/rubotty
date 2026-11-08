# frozen_string_literal: true

module Rubotty
  module Polls
    # The single driver of a poll's side-effects, so every surface that can open
    # one behaves the same.
    class Lifecycle
      # @param polls [ControlPlane::Polls]
      # @param board [Polls::Board]
      # @param timekeeper [Polls::Timekeeper]
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for a deterministic test
      def initialize(polls:, board:, timekeeper:, logger: nil, clock: -> { Time.now })
        @polls = polls
        @board = board
        @timekeeper = timekeeper
        @logger = logger
        @clock = clock
      end

      def announce(poll)
        @board.announce_opened(poll)
        @timekeeper.arm(poll)
        poll
      end

      # Closing is the gate, so two workers racing the same job leave exactly
      # one results message.
      #
      # @return [Boolean] whether this call is the one that closed it
      def close(poll_id)
        poll = @polls.by_id(poll_id)
        return false if poll.nil?

        @timekeeper.cancel_for(poll)
        return false unless @polls.close(poll: poll)

        @board.announce_results(poll)
        true
      rescue StandardError => e
        @logger&.warn { "polls: could not close poll #{poll_id}: #{e.class}: #{e.message}" }
        false
      end

      def repost(poll_id)
        poll = @polls.by_id(poll_id)
        return 0 if poll.nil?

        unless poll.open?
          @timekeeper.cancel_for(poll)
          return 0
        end

        @board.repost_if_buried(poll)
      rescue StandardError => e
        @logger&.warn { "polls: could not repost poll #{poll_id}: #{e.class}: #{e.message}" }
        0
      end

      # The backstop for a poll whose close job was lost, or whose deadline fell
      # while this process was down.
      #
      # @return [Integer] how many were closed
      def sweep(now: nil)
        @polls.due(now: now || @clock.call).count { |poll| close(poll.id) }
      rescue StandardError => e
        @logger&.warn { "polls: could not sweep the closed polls: #{e.class}: #{e.message}" }
        0
      end

      # {ControlPlane::Watcher}'s per-tick seam.
      def check = sweep
    end
  end
end
