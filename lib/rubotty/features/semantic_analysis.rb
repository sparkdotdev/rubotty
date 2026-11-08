# frozen_string_literal: true

module Rubotty
  module Features
    # Semantic FAQ matching is a separate, opt-in room feature. It only queues
    # ordinary chat for its durable service; a connection failure never pauses
    # the bridge or changes the original message.
    class SemanticAnalysis < Base
      def self.feature_name = ::Rubotty::SemanticAnalysis::Service::FEATURE

      def self.description = "Matches a member's question to this room's FAQ answers after a short background check."

      def self.retention_notice = "Question text is kept only in its pending room job while a matching reply is prepared."

      def self.default_enabled? = false

      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field :minimum_confidence, :float, range: 0.0..1.0, step: 0.05,
                default: ::Rubotty::SemanticAnalysis::Service::DEFAULT_MINIMUM_CONFIDENCE,
                                       desc: "the confidence required before an existing FAQ answer is posted"
        end
      end

      def initialize(logger:, service: nil)
        @logger = logger
        @service = service
      end

      attr_reader :logger

      def call(context)
        @service&.enqueue(context)
        Outcome.continue([])
      rescue StandardError => e
        logger.warn { "semantic analysis: could not queue room work: #{e.class}: #{e.message}" }
        Outcome.continue([])
      end
    end
  end
end
