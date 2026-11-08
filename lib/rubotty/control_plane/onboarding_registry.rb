# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Tracks which unmapped spaces have an operator onboarding in progress,
    # the signal {JoinGuard} consults so auto-leave holds off; onboarding
    # happens before the +platform_connections+ row that would authorize the
    # space exists. A thin, TTL-bounded marker over the message map's
    # key/value state, so an operator who abandons an onboarding does not pin
    # the bot in an unwanted space forever.
    class OnboardingRegistry
      PREFIX = "onboarding"

      # How long an onboarding marker lives without being renewed. Long enough for
      # an operator to work through a mapping wizard at a human pace, short enough
      # that an abandoned one clears within the hour.
      DEFAULT_TTL = 1800

      # @param store [#get_state, #put_state] the message map key/value state
      # @param ttl [Numeric] marker lifetime in seconds
      # @param clock [#call] injectable time source, for a deterministic test
      def initialize(store:, ttl: DEFAULT_TTL, clock: -> { Time.now })
        @store = store
        @ttl = ttl
        @clock = clock
      end

      # Mark an onboarding as in progress for a space, or renew an existing marker.
      def begin!(adapter:, account:, external_id:)
        @store.put_state(key(adapter, account, external_id), "1", expires_at: @clock.call + @ttl)
        self
      end

      # Clear the marker once onboarding has finished and the space is authorized
      # on its own.
      def complete!(adapter:, account:, external_id:)
        # Writing an already-expired marker is how the KV store forgets it on the
        # next purge; there is no delete on the state interface.
        @store.put_state(key(adapter, account, external_id), "0", expires_at: @clock.call - 1)
        self
      end

      # Is an onboarding currently in progress for this space? A lapsed marker
      # reads as absent (the store filters expired rows on read).
      def in_progress?(adapter:, account:, external_id:)
        @store.get_state(key(adapter, account, external_id)) == "1"
      end

      private

      def key(adapter, account, external_id)
        "#{PREFIX}:#{adapter}:#{account}:#{external_id}"
      end
    end
  end
end
