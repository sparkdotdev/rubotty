# frozen_string_literal: true

module Rubotty
  # The moderation-watchdog abstraction: a watchdog inspects one inbound message
  # and returns a {Verdict}. The {Runner} owns the one removal flow and applies it
  # on the first removal verdict, so every watchdog removes a message the same way.
  module Watchdog
    # The answer a watchdog gives for one message: remove it (with a human reason
    # and optional diagnostic metadata) or let it pass. Immutable.
    class Verdict
      attr_reader :reason, :metadata

      # A verdict to leave the message alone.
      def self.pass = new(remove: false)

      # A verdict to remove the message. +reason+ is the sentence shown to the author
      # in the removal notice; +metadata+ is detail preserved in the audit event.
      def self.remove(reason, metadata: {}) = new(remove: true, reason: reason, metadata: metadata)

      def initialize(remove:, reason: nil, metadata: {})
        @remove = remove
        @reason = reason
        @metadata = metadata || {}
        freeze
      end

      def remove? = @remove

      def pass? = !@remove
    end
  end
end
