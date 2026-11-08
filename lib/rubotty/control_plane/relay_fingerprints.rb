# frozen_string_literal: true

require "digest"

module Rubotty
  module ControlPlane
    # Durable per-endpoint record of content already seen, written on both
    # arrival and on posting a copy, so "is this already on endpoint X" can be
    # answered directly rather than inferred from the relay-claim ledger
    # (which is keyed on native ref and misses copies the bridge itself
    # wrote). The digest is a SHA-256 over normalised text, author and a
    # coarse time bucket, never the raw text, so no column here ever holds a
    # message body. {#present?} is the read side; nothing here decides what
    # gets re-sent.
    class RelayFingerprints
      # Raised with a human-readable message a caller prints as-is.
      class Invalid < Rubotty::Error; end

      # How wide a time bucket folds into the digest. Coarse enough that the
      # ordinary gap between a message arriving and the bridge posting a copy of
      # it never splits across two buckets; tight enough that the same author
      # saying the same word again well within the hour is a different
      # fingerprint.
      TIME_BUCKET_SECONDS = 60

      # The minimum most rows keep, before pruning: the throttle below this.
      PRUNE_INTERVAL = 60

      # The digest for one message's SOURCE content: normalised text, author and
      # a coarse time bucket, folded together into one hash. Class level because
      # the arrival write and the post write both fingerprint the SAME source.
      #
      # @param text [String, nil] the message's own text, never a relayed copy's:
      #   a copy may carry a rewritten prefix or annotation that would never match
      # @return [String, nil] a 64-character hex SHA-256, or nil when there is
      #   nothing safe to fingerprint (blank text, or no author/timestamp)
      def self.digest_for(text:, author:, timestamp:)
        return nil if author.to_s.empty? || timestamp.nil?

        normalised = normalise(text)
        return nil if normalised.empty?

        bucket = timestamp.to_i / TIME_BUCKET_SECONDS
        # Length-prefixed so no boundary between fields is ambiguous: text
        # ending in digits cannot blend into the bucket, and text ending in
        # what looks like part of the author cannot blend into that either.
        Digest::SHA256.hexdigest("#{normalised.bytesize}:#{normalised}#{author.bytesize}:#{author}#{bucket}")
      end

      # A message's author as a stable identity across endpoints: the adapter it
      # arrived on plus the platform's own user id, so a copy posted under the
      # bridge's own sender label still fingerprints back to who actually wrote it.
      #
      # @return [String, nil] nil for an unattributed message (a bridge-owned
      #   system notice, for one), which {.digest_for} then also refuses
      def self.author_key(message)
        native_id = message.author&.native_id
        return nil if native_id.to_s.empty?

        "#{message.origin.adapter_name}:#{native_id}"
      end

      def self.normalise(text)
        text.to_s.strip.gsub(/\s+/, " ").downcase
      end
      private_class_method :normalise

      # @param registry [Registry, nil] accepted for the same constructor shape
      #   every control-plane service takes; unused here, since recording a
      #   fingerprint never changes anything a live Snapshot would reload for
      # @param window_seconds [Integer, nil] how far back a fingerprint is kept,
      #   and how far {#prune} reaches. Defaults to backfill's own lookback
      #   window (Core::Backfill::DEFAULTS[:lookback_seconds]), so this ledger
      #   never claims to remember further back than backfill itself looks.
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now }, window_seconds: nil)
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
        @window_seconds = window_seconds || Core::Backfill::DEFAULTS[:lookback_seconds]
        @pruned_at = nil
        @prune_mutex = Mutex.new
      end

      # Idempotent: the same (community, endpoint, digest) recorded twice is
      # one row, since a redelivered inbound copy or a retried post must not
      # grow the table. Never raises: losing a write here costs one future
      # lookup its answer, never the message itself.
      #
      # @return [Boolean] whether a row exists for this content on this
      #   endpoint now, whether just written or already there. Also false for
      #   content {.digest_for} refuses to fingerprint at all.
      def record(community_id:, endpoint_id:, text:, author:, timestamp:)
        digest = self.class.digest_for(text: text, author: author, timestamp: timestamp)
        return false if digest.nil? || community_id.nil? || endpoint_id.to_s.empty?

        write(community_id, endpoint_id.to_s, digest)
        prune_if_due(@clock.call)
        true
      rescue StandardError => e
        @logger&.warn { "relay fingerprints: could not record on #{endpoint_id}: #{e.class}: #{e.message}" }
        false
      end

      # Whether this content already has a row on +endpoint_id+, within the
      # kept window.
      #
      # Fails closed (answers false, "not present") on a storage error, so a
      # caller that guards a send with this cannot be talked into silently
      # dropping a message that never actually duplicated.
      #
      # @return [Boolean]
      def present?(community_id:, endpoint_id:, text:, author:, timestamp:)
        digest = self.class.digest_for(text: text, author: author, timestamp: timestamp)
        return false if digest.nil? || community_id.nil?

        cutoff = @clock.call - @window_seconds
        !@models.relay_fingerprint
                .where(community_id: community_id, endpoint_id: endpoint_id.to_s, digest: digest)
                .where { created_at > cutoff }
                .empty?
      rescue StandardError => e
        @logger&.warn { "relay fingerprints: lookup failed for #{endpoint_id}: #{e.class}: #{e.message}" }
        false
      end

      # Drop everything past the window, everywhere.
      #
      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - @window_seconds
        @models.relay_fingerprint.where { created_at <= cutoff }.delete.to_i
      end

      private

      def write(community_id, endpoint_id, digest)
        @models.relay_fingerprint.create(
          community_id: community_id, endpoint_id: endpoint_id, digest: digest, created_at: @clock.call
        )
      rescue Sequel::UniqueConstraintViolation
        nil
      end

      # Sweep at most once per {PRUNE_INTERVAL}, and never let a sweep failure
      # reach the caller: the row above is already written, and the next pass
      # tries again.
      def prune_if_due(now)
        due = @prune_mutex.synchronize do
          next false if @pruned_at && (now - @pruned_at) < PRUNE_INTERVAL

          @pruned_at = now
          true
        end
        prune(now: now) if due
      rescue StandardError
        nil
      end
    end
  end
end
