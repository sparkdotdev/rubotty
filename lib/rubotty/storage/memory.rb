# frozen_string_literal: true

require "monitor"

module Rubotty
  module Storage
    # In-process message map: the reference implementation of {Base}, what
    # the test suite runs against and what a new backend should be diffed
    # against for behaviour. Also a legitimate production choice for a
    # single-node deployment that does not mind losing edit and delete
    # propagation on restart, which is why it is not the default here.
    class Memory < Base
      Entry = Struct.new(:source, :destination, :room_id, :expires_at)

      # `sequence` preserves first added ordering, which is what lets
      # {#reactions_on} answer deterministically for targets that can only show
      # one reaction.
      ReactionRow = Struct.new(:ref, :key, :reaction, :actor_id, :expires_at, :sequence)

      def initialize(**)
        super()
        @entries = []
        @reactions = []
        @state = {}
        @claims = {}
        # [community, author, fingerprint, channel] => expires_at, the
        # cross-channel multipost fingerprint window.
        @multiposts = {}
        @sequence = 0
        @monitor = Monitor.new
      end

      def migrate! = self

      def record(source:, destination:, room_id:, expires_at: nil)
        @monitor.synchronize do
          existing = @entries.find { |e| e.source == source && e.destination == destination }
          if existing
            existing.expires_at = expires_at
          else
            @entries << Entry.new(source, destination, room_id, expires_at)
          end
        end
        nil
      end

      def counterparts(source, endpoint_id: nil)
        @monitor.synchronize do
          live.select { |e| e.source == source }
              .map(&:destination)
              .select { |ref| endpoint_id.nil? || ref.endpoint_id == endpoint_id.to_s }
        end
      end

      def origins(destination)
        @monitor.synchronize do
          live.select { |e| e.destination == destination }.map(&:source)
        end
      end

      def destination?(ref)
        @monitor.synchronize { live.any? { |e| e.destination == ref } }
      end

      def map_expiry(ref)
        @monitor.synchronize do
          expiries = live.select { |e| e.source == ref || e.destination == ref }.map(&:expires_at)
          expiries.empty? || expiries.any?(&:nil?) ? nil : expiries.max
        end
      end

      def forget(ref)
        @monitor.synchronize do
          @entries.reject! { |e| e.source == ref || e.destination == ref }
          @reactions.reject! { |r| r.ref == ref }
        end
        nil
      end

      def add_reaction(ref, reaction:, actor_id:, expires_at: nil)
        @monitor.synchronize do
          existing = @reactions.find do |r|
            r.ref == ref && r.key == reaction.key && r.actor_id == actor_id.to_s
          end
          if existing
            existing.expires_at = expires_at
          else
            @reactions << ReactionRow.new(ref, reaction.key, reaction, actor_id.to_s,
                                          expires_at, @sequence += 1)
          end
          live_reactions.count { |r| r.ref == ref && r.key == reaction.key }
        end
      end

      def remove_reaction(ref, reaction:, actor_id:)
        @monitor.synchronize do
          @reactions.reject! do |r|
            r.ref == ref && r.key == reaction.key && r.actor_id == actor_id.to_s
          end
          live_reactions.count { |r| r.ref == ref && r.key == reaction.key }
        end
      end

      def reactions_on(ref)
        @monitor.synchronize do
          live_reactions
            .select { |r| r.ref == ref }
            .group_by(&:key)
            .map { |_, rows| rows.min_by(&:sequence) }
            .sort_by(&:sequence)
            .map(&:reaction)
        end
      end

      def reactions_by(ref, actor_id:)
        @monitor.synchronize do
          live_reactions
            .select { |r| r.ref == ref && r.actor_id == actor_id.to_s }
            .sort_by(&:sequence)
            .map(&:reaction)
        end
      end

      def clear_reactions(ref, reaction: nil)
        @monitor.synchronize do
          @reactions.reject! { |r| r.ref == ref && (reaction.nil? || r.key == reaction.key) }
        end
        nil
      end

      # In-process only, which is all this backend can be: Memory is a single
      # process by definition, so there is no second instance to race. The claim
      # still dedupes a redelivery this one process sees, and the whole check and
      # set runs under the monitor, so even concurrent room workers get exactly
      # one winner.
      def claim_relay(source:, operation:, community: nil, expires_at: nil)
        key = claim_key(community, source, operation)
        @monitor.synchronize do
          next false if @claims.key?(key)

          @claims[key] = expires_at
          true
        end
      end

      # Whether a claim is already held for this key, without taking one.
      # Mirrors #claim_relay's own "key present" test, so a true here is exactly a
      # claim_relay that would return false.
      def relay_claimed?(source:, operation:, community: nil)
        @monitor.synchronize { @claims.key?(claim_key(community, source, operation)) }
      end

      def release_relay(source:, operation:, community: nil)
        @monitor.synchronize { @claims.delete(claim_key(community, source, operation)) }
        nil
      end

      # In-process only, which is all this backend ever is. One key per
      # (community, author, fingerprint, channel) carrying its window expiry, so
      # a repeat in a channel already seen only refreshes the expiry and the
      # distinct-channel count is the number of live keys sharing the prefix.
      def record_multipost(community:, author:, fingerprint:, channel:, now:, window_seconds:)
        prefix = [community.to_s, author.to_s, fingerprint.to_s]
        expires_at = now + window_seconds
        @monitor.synchronize do
          @multiposts[prefix + [channel.to_s]] = expires_at
          @multiposts.count { |key, expiry| key.first(3) == prefix && expiry > now }
        end
      end

      # Memory is single process by construction (see the relay claims above),
      # so there is never a second PROCESS to contend with. What a caller
      # like the durable scheduler or the control-plane watcher actually needs
      # guarded against, on this backend, is two of its own THREADS entering
      # at once, which this genuinely enforces with a real per-name mutex
      # rather than a no-op, so a spec can exercise the same mutual-exclusion
      # promise the shared-database backends give across processes.
      def with_advisory_lock(name, timeout: 5)
        mutex = @monitor.synchronize { (@advisory_locks ||= {})[name.to_s] ||= Mutex.new }
        deadline = Time.now + timeout
        loop do
          if mutex.try_lock
            begin
              return yield
            ensure
              mutex.unlock
            end
          end
          if Time.now >= deadline
            raise LockUnavailable,
                  "timed out after #{timeout}s waiting for the #{name.inspect} lock; " \
                  "another caller in this process already holds it"
          end
          sleep(0.02)
        end
      end

      def get_state(key)
        @monitor.synchronize do
          row = @state[key.to_s]
          next nil if row.nil?
          next nil if row[:expires_at] && row[:expires_at] <= Time.now

          row[:value]
        end
      end

      def put_state(key, value, expires_at: nil)
        @monitor.synchronize do
          @state[key.to_s] = { value: value.to_s, expires_at: expires_at }
        end
        nil
      end

      def purge(now: Time.now)
        @monitor.synchronize do
          before = @entries.size + @reactions.size + @state.size + @claims.size + @multiposts.size
          @entries.reject! { |e| e.expires_at && e.expires_at <= now }
          @reactions.reject! { |r| r.expires_at && r.expires_at <= now }
          @state.delete_if { |_, row| row[:expires_at] && row[:expires_at] <= now }
          @claims.delete_if { |_, expires_at| expires_at && expires_at <= now }
          @multiposts.delete_if { |_, expires_at| expires_at && expires_at <= now }
          before - (@entries.size + @reactions.size + @state.size + @claims.size + @multiposts.size)
        end
      end

      def size
        @monitor.synchronize { live.size }
      end

      def close = nil

      def describe = "in memory message map (not persisted across restarts)"

      private

      # Expiry is enforced on read as well as by {#purge}, so a stale row is
      # never returned even if the purge thread has not run.
      def live
        now = Time.now
        @entries.reject { |e| e.expires_at && e.expires_at <= now }
      end

      def live_reactions
        now = Time.now
        @reactions.reject { |r| r.expires_at && r.expires_at <= now }
      end

      def claim_key(community, source, operation)
        [community.to_s, source.endpoint_id, source.native_id, operation.to_s]
      end
    end
        end
end
