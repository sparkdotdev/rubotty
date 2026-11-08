# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The hot-path bridge between an inbound {Core::Message} and the
    # {IdentityDirectory}. The runtime calls {#record} for every inbound message
    # that resolves to a community, BEFORE and independent of the feature chain,
    # so the directory is populated whatever features are on. A small bounded
    # per-process cache throttles the writes: an unchanged sighting writes at
    # most once per {#throttle} seconds, a CHANGE always writes. Recording is
    # best-effort; any error is swallowed to a debug line, since a directory
    # write must never be the reason a message fails to relay.
    class IdentityRecorder
      # How long an unchanged sighting is suppressed before it is written through
      # again (to advance last_seen_at, which retention reads).
      DEFAULT_THROTTLE = 60
      # Cap on distinct authors tracked in the throttle cache. Beyond this the
      # oldest-inserted entry is evicted and writes through on its next message.
      MAX_TRACKED = 5_000

      # @param directory [IdentityDirectory] the query/write API to record into
      # @param logger [#debug, nil]
      # @param throttle [Integer] seconds an unchanged sighting is suppressed
      # @param clock [#call] monotonic seconds source, injectable for tests
      # @param adapters [Hash, nil] adapter instances by [name, account], asked
      #   how durable their ids are. Nil reads every id as durable, which is
      #   useful for test doubles; production always supplies the adapter map.
      def initialize(directory:, logger: nil, throttle: DEFAULT_THROTTLE,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     adapters: nil)
        @directory = directory
        @logger = logger
        @throttle = throttle
        @clock = clock
        @adapters = adapters
        @seen = {}
        @mutex = Mutex.new
      end

      attr_reader :throttle

      # Records the author of one inbound message as an observed identity in its
      # resolved community; a no-op with no community, a non-user or bot author,
      # or an author carrying no native id to dedupe on. Best-effort: never raises.
      #
      # @param message [Core::Message]
      # @param community [ControlPlane::Snapshot::Community, nil]
      def record(message, community)
        return if community.nil? || message.nil?

        author = message.author
        return unless author && author.kind == :user
        return if author.bot?

        native_id = author.native_id
        return if native_id.nil?

        adapter = message.origin&.adapter_name
        return if adapter.nil?
        return unless durable_identity?(message.origin)

        record_sighting(
          community_id: community.id, adapter: adapter, native_id: native_id,
          username: author.username, display: author.profile_name
        )
      rescue StandardError => e
        @logger&.debug { "identity recorder: skipped a sighting: #{e.class}: #{e.message}" }
      end

      # Whether an id from this connection names one person for long enough to
      # anchor an identity on. A session slot or a display name does not: the
      # directory would merge two strangers across a restart and split one
      # person across two, with nothing to say it had. Unknown reads as durable for compatibility; production supplies
      # every configured adapter so session-scoped identities are excluded.
      def durable_identity?(origin)
        return true if @adapters.nil? || origin.nil?

        adapter = @adapters[[origin.adapter_name, origin.account]]
        return true if adapter.nil? || !adapter.respond_to?(:identity_durability)

        durable = adapter.identity_durability.to_sym == :account
        unless durable
          @logger&.debug do
            "identity recorder: #{origin.adapter_name} ids are per session, so nothing is anchored on them"
          end
        end
        durable
      end

      # The same throttled write, for a caller holding a bare identity tuple
      # rather than a Core::Message: a native RSVP list today, and any future
      # adapter that can enumerate members without seeing them speak.
      # Best-effort, same contract as {#record}: never raises.
      def record_sighting(community_id:, adapter:, native_id:, username: nil, display: nil)
        return if community_id.nil? || native_id.nil? || adapter.nil?
        return unless due?(community_id, adapter, native_id, username, display)

        @directory.record(
          community_id: community_id, adapter: adapter,
          native_id: native_id, username: username, display: display
        )
      rescue StandardError => e
        @logger&.debug { "identity recorder: skipped a sighting: #{e.class}: #{e.message}" }
      end

      private

      # Whether this sighting should reach the directory now: yes when the author is
      # new to the cache, when their handle or display changed, or when the throttle
      # window has elapsed. Thread-safe: several adapters may drive it at once.
      def due?(community_id, adapter, native_id, username, display)
        key = [community_id, adapter.to_s, native_id.to_s]
        now = @clock.call
        @mutex.synchronize do
          last = @seen[key]
          if last && last[:username] == username && last[:display] == display &&
             (now - last[:at]) < @throttle
            return false
          end

          evict_oldest if @seen.size >= MAX_TRACKED && !@seen.key?(key)
          @seen[key] = { username: username, display: display, at: now }
        end
        true
      end

      # Ruby hashes preserve insertion order, so the first key is the oldest
      # inserted. An updated key is not re-inserted, so a chatty author can be
      # evicted, which only costs one extra write later.
      def evict_oldest
        oldest = @seen.keys.first
        @seen.delete(oldest) if oldest
      end
    end
  end
end
