# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Remembers whether the "cannot leave" fallback notice has already been
    # posted for a space, so a bot with no self-removal permission never repeats
    # the same notice on every reconnect or restart.
    #
    # Durable on the message map's +bridge_state+ key/value table when the store
    # has one, so the marker survives a restart; in-process only otherwise.
    class InertNotices
      # @param store [#get_state, #put_state, nil]
      def initialize(store: nil)
        @store = store
        @seen = {}
      end

      # @return [Boolean] true when the notice has already been posted for
      #   this space
      def posted?(adapter:, account:, external_id:)
        key = key_for(adapter, account, external_id)
        return @store.get_state(key) ? true : false if @store

        @seen.key?(key)
      end

      # Record that the notice was just posted for this space. Idempotent.
      def mark_posted!(adapter:, account:, external_id:)
        key = key_for(adapter, account, external_id)
        return @store.put_state(key, true) if @store

        @seen[key] = true
      end

      private

      def key_for(adapter, account, external_id)
        "join_guard:inert_notice:#{adapter}:#{account}:#{external_id}"
      end
    end
  end
end
