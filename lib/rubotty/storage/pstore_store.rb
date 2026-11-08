# frozen_string_literal: true

require "pstore"

module Rubotty
  module Storage
    # Message map and reaction state in a stdlib PStore file: the zero
    # dependency embedded option, for trying the bridge or running a small
    # private one without standing up PostgreSQL. Commits by serialising and
    # rewriting the whole file, so cost per write is O(total size) rather
    # than O(1) and keeps growing with a busy bridge's TTL window; it is
    # also single-process only, since PStore takes a file lock. Move to
    # `driver: pg` early, before this becomes a problem: the storage
    # interface makes it a one line configuration change.
    class PStoreStore < Base
      ROOT = :state

      Entry = Struct.new(:source_endpoint, :source_native_id,
                         :destination_endpoint, :destination_native_id,
                         :room_id, :expires_at)

      ReactionRow = Struct.new(:endpoint_id, :native_id, :key, :emoji,
                               :custom_id, :custom_name, :actor_id, :expires_at, :sequence)

      def initialize(path:, logger: nil)
        super()
        @path = path
        @logger = logger
        # thread_safe gives PStore an internal mutex, which the bridge needs
        # because room workers write concurrently.
        @store = ::PStore.new(path, true)
        # Guards @advisory_locks itself (see #with_advisory_lock), separate
        # from the per-name mutexes it hands out.
        @locks_mutex = Mutex.new
      end

      attr_reader :path

      def migrate!
        FileUtils.mkdir_p(File.dirname(@path))
        @store.transaction do
          @store[ROOT] ||= { entries: [], reactions: [], kv: {}, claims: {}, multiposts: {}, sequence: 0 }
        end
        self
      rescue StandardError => e
        raise StorageError, "could not open the PStore file at #{@path}: #{e.message}"
      end

      def record(source:, destination:, room_id:, expires_at: nil)
        write do |state|
          existing = state[:entries].find do |entry|
            entry.source_endpoint == source.endpoint_id &&
              entry.source_native_id == source.native_id &&
              entry.destination_endpoint == destination.endpoint_id &&
              entry.destination_native_id == destination.native_id
          end
          if existing
            existing.expires_at = expires_at
          else
            state[:entries] << Entry.new(
              source.endpoint_id, source.native_id,
              destination.endpoint_id, destination.native_id,
              room_id.to_s, expires_at
            )
          end
        end
        nil
      end

      def counterparts(source, endpoint_id: nil)
        read do |state|
          live(state[:entries])
            .select { |e| e.source_endpoint == source.endpoint_id && e.source_native_id == source.native_id }
            .select { |e| endpoint_id.nil? || e.destination_endpoint == endpoint_id.to_s }
            .map { |e| Core::MessageRef.new(e.destination_endpoint, e.destination_native_id) }
        end
      end

      def origins(destination)
        read do |state|
          live(state[:entries])
            .select do |e|
              e.destination_endpoint == destination.endpoint_id &&
                e.destination_native_id == destination.native_id
            end
            .map { |e| Core::MessageRef.new(e.source_endpoint, e.source_native_id) }
        end
      end

      def destination?(ref)
        read do |state|
          live(state[:entries]).any? do |e|
            e.destination_endpoint == ref.endpoint_id && e.destination_native_id == ref.native_id
          end
        end
      end

      def map_expiry(ref)
        read do |state|
          expiries = live(state[:entries]).select { |e| mentions?(e, ref) }.map(&:expires_at)
          expiries.empty? || expiries.any?(&:nil?) ? nil : expiries.max
        end
      end

      def forget(ref)
        write do |state|
          state[:entries].reject! { |e| mentions?(e, ref) }
          state[:reactions].reject! do |r|
            r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id
          end
        end
        nil
      end

      def add_reaction(ref, reaction:, actor_id:, expires_at: nil)
        write do |state|
          existing = find_reaction(state, ref, reaction, actor_id)
          if existing
            existing.expires_at = expires_at
          else
            state[:sequence] += 1
            state[:reactions] << ReactionRow.new(
              ref.endpoint_id, ref.native_id, reaction.key, reaction.emoji,
              reaction.custom_id, reaction.custom_name, actor_id.to_s,
              expires_at, state[:sequence]
            )
          end
          count_actors(state, ref, reaction)
        end
      end

      def remove_reaction(ref, reaction:, actor_id:)
        write do |state|
          state[:reactions].reject! do |r|
            r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id &&
              r.key == reaction.key && r.actor_id == actor_id.to_s
          end
          count_actors(state, ref, reaction)
        end
      end

      def reactions_on(ref)
        read do |state|
          live(state[:reactions])
            .select { |r| r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id }
            .group_by(&:key)
            .map { |_, rows| rows.min_by(&:sequence) }
            .sort_by(&:sequence)
            .map { |r| Core::Reaction.new(emoji: r.emoji, custom_id: r.custom_id, custom_name: r.custom_name) }
        end
      end

      def reactions_by(ref, actor_id:)
        read do |state|
          live(state[:reactions])
            .select do |r|
              r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id &&
                r.actor_id == actor_id.to_s
            end
            .sort_by(&:sequence)
            .map { |r| Core::Reaction.new(emoji: r.emoji, custom_id: r.custom_id, custom_name: r.custom_name) }
        end
      end

      def clear_reactions(ref, reaction: nil)
        write do |state|
          state[:reactions].reject! do |r|
            r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id &&
              (reaction.nil? || r.key == reaction.key)
          end
        end
        nil
      end

      # Persisted in the store, so the claim survives the restart that PStore
      # exists to survive, but single process only, like everything else here:
      # PStore takes a file lock, so there is never a second instance to race.
      def claim_relay(source:, operation:, community: nil, expires_at: nil)
        write do |state|
          state[:claims] ||= {}
          key = claim_key(community, source, operation)
          next false if state[:claims].key?(key)

          state[:claims][key] = expires_at
          true
        end
      end

      # Whether a claim is already held for this key, without taking one.
      def relay_claimed?(source:, operation:, community: nil)
        read { |state| (state[:claims] || {}).key?(claim_key(community, source, operation)) }
      end

      def release_relay(source:, operation:, community: nil)
        write do |state|
          state[:claims] ||= {}
          state[:claims].delete(claim_key(community, source, operation))
        end
        nil
      end

      # Persisted in the store like the relay claims, but single process only:
      # PStore takes a file lock, so there is never a second instance to race.
      # One key per (community, author, fingerprint, channel) carrying its window
      # expiry; the distinct-channel count is the number of live keys sharing the
      # (community, author, fingerprint) prefix.
      def record_multipost(community:, author:, fingerprint:, channel:, now:, window_seconds:)
        prefix = [community.to_s, author.to_s, fingerprint.to_s]
        expires_at = now + window_seconds
        write do |state|
          state[:multiposts] ||= {}
          state[:multiposts][prefix + [channel.to_s]] = expires_at
          state[:multiposts].count { |key, expiry| key.first(3) == prefix && expiry > now }
        end
      end

      # PStore is single process by construction, like Memory (it takes a
      # file lock, so there is never a second process to race). See
      # {Memory#with_advisory_lock} for why this is a real per-name mutex
      # rather than a no-op: it is what makes two THREADS in this one process
      # genuinely mutually exclusive, and lets a spec prove it.
      def with_advisory_lock(name, timeout: 5)
        mutex = @locks_mutex.synchronize { (@advisory_locks ||= {})[name.to_s] ||= Mutex.new }
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
        read do |state|
          row = (state[:kv] || {})[key.to_s]
          next nil if row.nil?
          next nil if row[:expires_at] && row[:expires_at] <= Time.now

          row[:value]
        end
      end

      def put_state(key, value, expires_at: nil)
        write do |state|
          state[:kv] ||= {}
          state[:kv][key.to_s] = { value: value.to_s, expires_at: expires_at }
        end
        nil
      end

      def purge(now: Time.now)
        write do |state|
          state[:kv] ||= {}
          state[:claims] ||= {}
          state[:multiposts] ||= {}
          before = state[:entries].size + state[:reactions].size + state[:kv].size +
                   state[:claims].size + state[:multiposts].size
          state[:entries].reject! { |e| e.expires_at && e.expires_at <= now }
          state[:reactions].reject! { |r| r.expires_at && r.expires_at <= now }
          state[:kv].delete_if { |_, row| row[:expires_at] && row[:expires_at] <= now }
          state[:claims].delete_if { |_, expires_at| expires_at && expires_at <= now }
          state[:multiposts].delete_if { |_, expires_at| expires_at && expires_at <= now }
          before - (state[:entries].size + state[:reactions].size + state[:kv].size +
                    state[:claims].size + state[:multiposts].size)
        end
      end

      def size
        read { |state| live(state[:entries]).size }
      end

      def close = nil

      def describe
        "pstore message map at #{@path} (single process, rewrites the whole file on every write)"
      end

      private

      def read
        @store.transaction(true) { yield(state_in(@store)) }
      rescue StandardError => e
        raise StorageError, "pstore read failed: #{e.message}"
      end

      def write
        @store.transaction do
          state = state_in(@store)
          result = yield(state)
          @store[ROOT] = state
          result
        end
      rescue StandardError => e
        raise StorageError, "pstore write failed: #{e.message}"
      end

      def state_in(store)
        (store[ROOT] || {}).tap do |state|
          state[:entries] ||= []
          state[:reactions] ||= []
          state[:kv] ||= {}
          state[:claims] ||= {}
          state[:multiposts] ||= {}
          state[:sequence] ||= 0
        end
      end

      def claim_key(community, source, operation)
        [community.to_s, source.endpoint_id, source.native_id, operation.to_s]
      end

      def live(rows)
        now = Time.now
        rows.reject { |row| row.expires_at && row.expires_at <= now }
      end

      # Whether an entry names +ref+ on either side, the map being directional
      # while an action arrives on whichever copy the person was looking at.
      def mentions?(entry, ref)
        (entry.source_endpoint == ref.endpoint_id && entry.source_native_id == ref.native_id) ||
          (entry.destination_endpoint == ref.endpoint_id && entry.destination_native_id == ref.native_id)
      end

      def find_reaction(state, ref, reaction, actor_id)
        state[:reactions].find do |r|
          r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id &&
            r.key == reaction.key && r.actor_id == actor_id.to_s
        end
      end

      def count_actors(state, ref, reaction)
        live(state[:reactions]).count do |r|
          r.endpoint_id == ref.endpoint_id && r.native_id == ref.native_id && r.key == reaction.key
        end
      end
    end
  end
end
