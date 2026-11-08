# frozen_string_literal: true

module Rubotty
  module Events
    # The claim covering the gap between asking a platform to create a native
    # scheduled event and recording the id it answered with. Discord pushes its
    # gateway create while that REST call is still returning, so
    # {Events::Announcer} opens a claim before the call and drops it after the
    # write, and {Events::NativeMirror} waits for the claim to clear before
    # deciding a native id names no event of ours. Keyed by adapter and
    # account, the pair both halves can name.
    class NativeCreateClaims
      # How long an inbound echo waits for a create in flight, in seconds. A
      # create that outlives this is treated as abandoned, so a hung platform
      # call cannot stall the gateway thread for good.
      DEFAULT_TIMEOUT = 20.0

      @shared_lock = Mutex.new

      class << self
        # The registry both halves use unless a caller injects one. It is
        # process wide deliberately: the announcer and the mirror are built
        # apart from each other, and a registry per object would leave the
        # guard silently inert rather than obviously unwired.
        def shared = @shared_lock.synchronize { @shared ||= new }
      end

      # @param timeout [Float] the wait budget {#settle} spends before giving up
      def initialize(timeout: DEFAULT_TIMEOUT)
        @timeout = timeout.to_f
        @mutex = Mutex.new
        @cleared = ConditionVariable.new
        @claims = {}
      end

      # Hold a claim on (+adapter+, +account+) for the duration of the block,
      # which has to cover the platform call AND the write recording its id:
      # the echo can arrive between the two, and that is the whole race.
      #
      # @return [Object] whatever the block returned
      def holding(adapter, account)
        key = key_for(adapter, account)
        token = Object.new
        @mutex.synchronize { (@claims[key] ||= {})[token] = Thread.current }
        yield
      ensure
        release(key, token)
      end

      # Block until no OTHER thread is creating on (+adapter+, +account+).
      #
      # @return [Boolean] true once settled, false if the budget ran out first
      def settle(adapter, account)
        key = key_for(adapter, account)
        deadline = now + @timeout
        @mutex.synchronize do
          while pending?(key)
            remaining = deadline - now
            return false if remaining <= 0

            @cleared.wait(@mutex, remaining)
          end
        end
        true
      end

      # @return [Boolean] whether another thread is mid-create on this pair
      def in_flight?(adapter, account)
        @mutex.synchronize { pending?(key_for(adapter, account)) }
      end

      private

      # A claim the calling thread holds itself never counts. An outbound
      # create and the echo of it can land on one thread, and waiting there
      # would deadlock until the budget expired rather than settling.
      def pending?(key)
        holders = @claims[key]
        return false if holders.nil?

        holders.any? { |_token, thread| thread != Thread.current }
      end

      def release(key, token)
        @mutex.synchronize do
          holders = @claims[key]
          unless holders.nil?
            holders.delete(token)
            @claims.delete(key) if holders.empty?
          end
          @cleared.broadcast
        end
      end

      def key_for(adapter, account) = [adapter.to_s, account.to_s]

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
