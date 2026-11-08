# frozen_string_literal: true

module Rubotty
  module Features
    # Room-scoped feature flag and config for /poll. Observes nothing;
    # {Features::PollCommand} carries the behaviour under this same feature_name.
    class Poll < Base
      def self.feature_name = "poll"

      def self.description = "Ask the room a question and let people vote by reacting or replying."

      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.retention_notice
        "the question, its options, and who voted for which, until the poll closes and for as long " \
          "as the room keeps its history"
      end

      def self.config_schema
        Config::Schema.define do
          field :duration, :string, default: "#{Polls::Poll::DEFAULT_DURATION_HOURS}h",
                one_of: Polls::Poll::DURATION_TOKENS,
                desc: "how long a poll stays open for votes"
          field :reply_votes, :boolean, default: true,
                desc: "let somebody reply to the poll message with an option number instead of reacting"
          field :reply_options, :boolean, default: false,
                desc: "room default: let somebody reply to a poll message with new text to add an " \
                      "option; a poll can override this for itself with /poll's own reply_options"
        end
      end
    end
  end
end
