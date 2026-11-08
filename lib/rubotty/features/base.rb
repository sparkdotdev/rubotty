# frozen_string_literal: true

module Rubotty
  module Features
    # The contract a feature implements to take part in inbound message handling:
    # the class-level declarations below plus #call(context), which returns
    # Outcome.continue or Outcome.halt; halting stops the chain.
    class Base
      # @return [String] stable key, e.g. "bridge" or "moderation"
      def self.feature_name
        raise NotImplementedError, "#{self} must define .feature_name"
      end

      # @return [Array<Symbol>] the message kinds this feature observes
      def self.observes
        %i[chat edit delete join leave system reaction_add reaction_remove]
      end

      # @return [Boolean] run when no control plane resolves enablement
      def self.default_enabled? = false

      # Policy failures stop the message unless a feature explicitly opts out.
      def self.failure_policy = :halt

      # @return [Boolean] when true, {Pipeline#enabled?} runs this feature
      #   regardless of feature_settings and of whether a (community, channel)
      #   resolved
      def self.always_enabled? = false

      # Command words this feature answers in chat that {Core::CommandRegistry}
      # does not carry, so {DisabledCommandNotice} can still answer one and keep
      # it off {Bridge} when this feature is not the one that handles it.
      #
      # @return [Array<String>]
      def self.command_words = []

      # @return [Config::Schema, nil]
      def self.config_schema = nil

      # One plain-English sentence for a human deciding whether to enable this.
      #
      # @return [String]
      def self.description = "No description yet."

      # What enabling this feature makes rubotty keep, or nil when it keeps
      # nothing.
      #
      # @return [String, nil]
      def self.retention_notice = nil

      # @param context [Context]
      # @return [Outcome]
      def call(_context)
        Outcome.continue
      end
    end
  end
end
