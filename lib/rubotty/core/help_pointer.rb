# frozen_string_literal: true

module Rubotty
  module Core
    # Remembers which endpoints have already been told where the command list
    # lives, so the pointer is posted once per channel rather than on every
    # message. Telegram and Discord surface {CommandRegistry} through a native
    # picker; Fluxer has no such API, so this is the only way a member there
    # discovers the bridge's commands. Durable when the store supports it, so
    # the marker survives a restart; in-process only otherwise.
    class HelpPointer
      KEY_PREFIX = "help_pointer"

      # @param store [#get_state, #put_state, nil]
      def initialize(store: nil)
        @store = store if store.respond_to?(:get_state) && store.respond_to?(:put_state)
        @seen = {}
      end

      # @param endpoint_id [String] the endpoint the pointer would be posted to
      # @return [Boolean] true when it has already been posted there
      def pointed?(endpoint_id)
        key = key_for(endpoint_id)
        return true if @seen[key]
        return false if @store.nil?

        found = @store.get_state(key) ? true : false
        @seen[key] = true if found
        found
      rescue StandardError
        # A storage hiccup must never cost the message the pointer rides on.
        # Claiming it was posted is the quiet outcome of the two.
        true
      end

      # Record that the pointer was just posted to +endpoint_id+. Idempotent.
      def mark_pointed!(endpoint_id)
        key = key_for(endpoint_id)
        @seen[key] = true
        @store&.put_state(key, true)
        nil
      rescue StandardError
        nil
      end

      private

      def key_for(endpoint_id) = "#{KEY_PREFIX}:#{endpoint_id}"
    end
  end
end
