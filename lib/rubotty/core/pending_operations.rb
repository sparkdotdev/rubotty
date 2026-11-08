# frozen_string_literal: true

module Rubotty
  module Core
    # Operations that have been started and are waiting for the operator to
    # say where they stop, closed by the shared sentinel word `/end`. A
    # feature {#register}s a handler under its own kind, {#open}s an
    # operation, and {#close} runs whichever kind is open, so two consumers
    # never disagree about which operation closes. Keyed by (community,
    # endpoint, operator): a window opened in one community can never be
    # closed from another. In memory, per process, TTL-bound: a restart or a
    # forgotten window just costs the operator a `/redirect` retry.
    class PendingOperations
      # The word every multi-message operation closes with.
      SENTINEL = "end"

      # How long an unclosed operation stays open: long enough to scroll back through a
      # busy room and find the end of a run, short enough that a forgotten window is
      # gone by the time the operator is doing something else.
      DEFAULT_TTL = 15 * 60

      # Total open operations held at once, across every community: nothing here is
      # ever swept by anything other than its own expiry.
      MAX_OPEN = 500

      # One open operation. +payload+ is whatever the opening command needs to
      # remember; nothing here reads it.
      Operation = Struct.new(:kind, :community_id, :endpoint_id, :actor_id, :payload,
                             :opened_at, keyword_init: true)

      def initialize(ttl: DEFAULT_TTL, clock: -> { Time.now }, logger: nil)
        @ttl = ttl
        @clock = clock
        @logger = logger
        @handlers = {}
        @open = {}
        @mutex = Mutex.new
      end

      attr_reader :ttl

      # Register the closer for a +kind+, called with the {Operation} and whatever
      # {#close} was passed as +context+; its return value is {#close}'s.
      # Re-registering a kind replaces it.
      def register(kind, handler = nil, &block)
        callable = handler || block
        raise ArgumentError, "a handler is required" if callable.nil?

        @mutex.synchronize { @handlers[kind.to_s] = callable }
        self
      end

      def handler?(kind) = @mutex.synchronize { @handlers.key?(kind.to_s) }

      # Start an operation waiting for its closing reply. An operator who opens a
      # second one in the same room replaces the first.
      def open(kind:, community_id:, endpoint_id:, actor_id:, payload: {})
        operation = Operation.new(
          kind: kind.to_s, community_id: community_id.to_s, endpoint_id: endpoint_id.to_s,
          actor_id: actor_id.to_s, payload: payload, opened_at: @clock.call
        )
        @mutex.synchronize do
          expire_locked
          key = key_for(operation.community_id, operation.endpoint_id, operation.actor_id)
          # Delete before reinserting: a reopen of an already-open key would
          # otherwise keep its original hash position, so the freshest
          # operation could be the one the shift below evicts as "oldest".
          @open.delete(key)
          @open[key] = operation
          # Oldest first, so the ceiling drops the most stale window.
          @open.shift while @open.size > MAX_OPEN
        end
        operation
      end

      # The open operation for this operator in this room, or nil.
      def peek(community_id:, endpoint_id:, actor_id:)
        @mutex.synchronize do
          expire_locked
          @open[key_for(community_id, endpoint_id, actor_id)]
        end
      end

      # Withdraw an open operation without closing it.
      def forget(community_id:, endpoint_id:, actor_id:)
        @mutex.synchronize { @open.delete(key_for(community_id, endpoint_id, actor_id)) }
      end

      # Close whatever this operator has open here, by running the handler its kind
      # registered. The operation is taken out of the map BEFORE the handler runs, so a
      # handler that raises cannot leave a window `/end` would try to close again.
      #
      # @return [:none] when nothing was open here
      # @return [:unhandled] when something was open but its kind has no handler
      #   registered (the feature that opened it is no longer in the chain)
      # @return [Object] whatever the handler returned
      def close(community_id:, endpoint_id:, actor_id:, context: nil)
        operation, handler = @mutex.synchronize do
          expire_locked
          found = @open.delete(key_for(community_id, endpoint_id, actor_id))
          [found, found && @handlers[found.kind]]
        end
        return :none if operation.nil?
        return :unhandled if handler.nil?

        handler.call(operation, context)
      end

      # How many operations are open. Diagnostics and tests.
      def size
        @mutex.synchronize do
          expire_locked
          @open.size
        end
      end

      private

      def key_for(community_id, endpoint_id, actor_id)
        [community_id.to_s, endpoint_id.to_s, actor_id.to_s]
      end

      # Drop everything past its TTL. Called under the mutex by every public
      # method, so an expired window is never visible to any of them.
      def expire_locked
        cutoff = @clock.call - @ttl
        @open.delete_if { |_key, operation| operation.opened_at < cutoff }
      end
    end
  end
end
