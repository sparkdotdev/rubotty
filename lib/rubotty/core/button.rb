# frozen_string_literal: true

module Rubotty
  module Core
    # One tappable button under a message the bridge itself posted, for a
    # platform whose clients have them. +token+ is opaque to every adapter: it
    # is chosen by whatever placed the button and comes straight back on
    # {Message#button} when somebody presses it, so the meaning of a press
    # stays with the feature that offered it.
    class Button
      attr_reader :token, :label

      # @param token [String] what a press reports back, short enough for the
      #   platform's own limit (Telegram allows 64 bytes of callback data)
      # @param label [String] what the button says
      def initialize(token:, label:)
        @token = token.to_s
        @label = label.to_s
        freeze
      end

      def ==(other) = other.is_a?(Button) && other.token == token && other.label == label
      alias eql? ==

      def hash = [token, label].hash

      def inspect = "#<Button #{token} #{label.inspect}>"
    end
  end
end
