# frozen_string_literal: true

module Rubotty
  module Features
    # The result a feature hands back to the pipeline. The status (:continue or
    # :halt) decides whether later features still see the message; the value is
    # diagnostic only, since side effects happen through the feature's own machinery.
    class Outcome
      attr_reader :status, :value, :reason

      # Proceed to the next feature. The driver returns +value+ only if no later
      # feature supersedes it.
      def self.continue(value = []) = new(:continue, value: value)

      # Stop the pipeline here. Nothing after this feature sees the message.
      def self.halt(value = [], reason: nil) = new(:halt, value: value, reason: reason)

      def initialize(status, value: [], reason: nil)
        @status = status
        @value = value
        @reason = reason
        freeze
      end

      def halt? = @status == :halt

      def continue? = @status == :continue
    end
  end
end
