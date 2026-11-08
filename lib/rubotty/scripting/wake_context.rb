# frozen_string_literal: true

module Rubotty
  module Scripting
    # What a script sees when it runs without a message behind it: a
    # rubotty.schedule wake, or an async_http answer coming back. It carries the
    # generation of the run that asked, which stops a chain of wakes.
    class WakeContext
      attr_reader :community, :channel, :config, :script_generation, :script_requests

      def initialize(community:, room_key:, generation: 0, config: {})
        @community = community
        @channel = room_key
        @config = config || {}
        @script_generation = generation
        @script_requests = []
      end

      # No message, so nothing here can answer about an author. nil rather than
      # raising keeps a host function that guards on it working.
      def message = nil

      def operators = nil

      def people = nil
    end
  end
end
