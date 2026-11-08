# frozen_string_literal: true

require "monitor"

module Rubotty
  module Core
    # Stops relayed messages from echoing back into the bridge with four
    # layered defences, since each alone has a failure mode: structural
    # exclusion in {Room#targets_for}, self-authorship (needs no state), an
    # in-memory recent-delivery ledger for races the durable map misses, and
    # the durable map itself as the restart-safe fallback. All four are
    # adapter or platform specific and can miss together; {#check_post_rate}
    # is the backstop, a plain per-endpoint post rate ceiling that does not
    # need to recognise anything about the message at all.
    class LoopGuard
      DEFAULT_LEDGER_TTL = 300 # seconds
      DEFAULT_LEDGER_LIMIT = 10_000

      # How many seconds of bridge-authored posts to one endpoint
      # {#check_post_rate} looks at. Short on purpose: an echo loop repeats far
      # faster than any ordinary burst of relayed traffic, so this catches a
      # loop without needing to be tuned per deployment. Hardcoded rather than
      # config, there being no reason yet for an operator to change it.
      POST_RATE_WINDOW = 10
      # Posts to one endpoint inside that window before the breaker trips.
      POST_RATE_LIMIT = 20
      POST_RATE_COOLDOWN = 30

      def initialize(storage: nil, ttl: DEFAULT_LEDGER_TTL, limit: DEFAULT_LEDGER_LIMIT, clock: -> { Time.now })
        @storage = storage
        @ttl = ttl
        @limit = limit
        @clock = clock
        @ledger = {}
        @own_ids = {}
        @posts = {}
        @tripped = {}
        @monitor = Monitor.new
      end

      # Register the native id(s) an adapter is signed in as, once per
      # (adapter, account) pair at boot and again if it reconnects under a
      # different identity. Usually one id; an adapter whose identity can
      # fork (see {Adapters::Base#own_account_ids}) passes every one it holds
      # at once, replacing whatever was registered before.
      #
      # Keyed on the pair, not just the adapter name, so a second account on
      # the same adapter cannot overwrite the first's registration.
      def register_identity(adapter_name, account, native_ids)
        ids = Array(native_ids).compact.map(&:to_s).reject(&:empty?)
        return if ids.empty?

        @monitor.synchronize { @own_ids[identity_key(adapter_name, account)] = ids }
      end

      # @return [Array<String>, nil]
      def own_identity(adapter_name, account)
        @monitor.synchronize { @own_ids[identity_key(adapter_name, account)] }
      end

      # Record that we have just written +native_id+ to +endpoint_id+.
      def note_delivery(endpoint_id, native_id)
        return if native_id.nil?

        key = [endpoint_id.to_s, native_id.to_s]
        @monitor.synchronize do
          # Delete before writing so insertion order and stamp order stay the
          # same, which is what lets the eviction below stop at the first live
          # entry instead of walking the whole ledger.
          @ledger.delete(key)
          @ledger[key] = @clock.call
          evict_locked
        end
      end

      # Record a post the bridge is about to make to +endpoint_id+ and answer
      # whether it may proceed: the backstop behind every other defence, since
      # it only counts posts to one endpoint rather than recognising the
      # message. Automated traffic pauses after a trip, then gets a fresh window
      # so a temporary burst cannot permanently silence the destination.
      # @return [Symbol, nil] :tripped the instant the ceiling is first
      #   crossed, for the caller to log loudly; :open on every call after
      #   that, already logged once; nil to proceed
      def check_post_rate(endpoint_id)
        key = endpoint_id.to_s
        @monitor.synchronize do
          now = @clock.call
          if (tripped_at = @tripped[key])
            next :open if now - tripped_at < POST_RATE_COOLDOWN

            @tripped.delete(key)
            @posts.delete(key)
          end
          times = (@posts[key] ||= [])
          times.push(now)
          times.shift while times.first && now - times.first > POST_RATE_WINDOW
          next nil if times.size <= POST_RATE_LIMIT

          @tripped[key] = now
          :tripped
        end
      end

      # Kinds where `message.ref` names a message that has just ARRIVED; for
      # every other kind the ref names a message being ACTED UPON, where our
      # own copy is the normal case. Edit stays on the list because only the
      # bridge can edit a message it posted, so an edit on our own copy IS
      # our own echo.
      REF_ECHO_KINDS = %i[chat edit].freeze

      # Should this inbound message be dropped as our own echo?
      #
      # @param message [Message]
      # @return [Symbol, nil] the reason it was dropped, or nil to proceed
      def echo?(message)
        # Authorship applies to every kind: our own bot reacting is an echo whatever
        # it is reacting to.
        return :self_authored if self_authored?(message)
        return nil unless REF_ECHO_KINDS.include?(message.kind)

        return :recently_delivered if recently_delivered?(message.ref)
        return :in_message_map if written_by_us?(message.ref)

        nil
      end

      def self_authored?(message)
        own = own_identity(message.origin.adapter_name, message.origin.account)
        return false if own.nil?

        author_id = message.author&.native_id
        return false if author_id.nil?

        own.include?(author_id)
      end

      def recently_delivered?(ref)
        key = [ref.endpoint_id, ref.native_id]
        @monitor.synchronize do
          seen_at = @ledger[key]
          next false if seen_at.nil?
          next false if @clock.call - seen_at > @ttl

          true
        end
      end

      # Consults the durable message map. Only reached when the in memory
      # ledger misses, which after a restart is every message for a while.
      def written_by_us?(ref)
        return false if @storage.nil?

        @storage.destination?(ref)
      rescue StorageError
        # A storage outage must not turn into a message loop, so we fail open
        # and rely on the structural and self-authorship defences, which need
        # no storage.
        false
      end

      def size
        @monitor.synchronize { @ledger.size }
      end

      private

      # The (adapter, account) pair as one hash key. Matches how the runtime's
      # own adapters hash is keyed, so a second Discord account never lands on
      # the same identity slot as the first.
      def identity_key(adapter_name, account) = [adapter_name.to_sym, account.to_s]

      # Bounds the ledger by age and count, called under the monitor. The
      # oldest entry is always first, so both bounds are a shift from the
      # front rather than the full-ledger scan that used to cost every
      # delivered copy the size of the ledger.
      def evict_locked
        now = @clock.call
        while (oldest = @ledger.first)
          break if now - oldest.last <= @ttl

          @ledger.shift
        end
        @ledger.shift while @ledger.size > @limit
      end
    end
  end
end
