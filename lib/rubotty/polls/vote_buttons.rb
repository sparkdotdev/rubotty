# frozen_string_literal: true

module Rubotty
  module Polls
    # The token a vote button carries, written by {Board} and read back by
    # {Features::PollSurface} when somebody presses one. Prefixed so a button
    # some other card puts on the same platform can never be counted as a vote.
    module VoteButtons
      PREFIX = "poll-option"

      module_function

      # @param position [Integer] 1-based
      # @return [String]
      def token_for(position) = "#{PREFIX}:#{position}"

      # @param token [String, nil] what a press reported back
      # @return [Integer, nil] the 1-based position, or nil for anybody else's
      def position_for(token)
        match = /\A#{PREFIX}:([1-9]\d*)\z/.match(token.to_s)
        match && match[1].to_i
      end
    end
  end
end
