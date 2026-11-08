# frozen_string_literal: true

require "digest"

module Rubotty
  module ContentPolicy
    # Only the latest observed body digest, never a message archive. Ingestion
    # writes this before any feature can consume an edit; background jobs only
    # compare it. A delete is retained as a tombstone until every old check ages
    # out, and a redelivered original cannot replace an observed edit.
    class Revisions
      SCOPE = %i[community_id endpoint_id native_id].freeze
      PRUNE_INTERVAL = 60
      PRUNE_LIMIT = 1000

      def self.digest(text) = Digest::SHA256.hexdigest(text.to_s)

      def initialize(db:, retention:, clock: -> { Time.now })
        @db = db
        @rows = db[:content_policy_revisions]
        @retention = retention
        @clock = clock
        @pruned_at = nil
        @prune_mutex = Mutex.new
      end

      def observe(community_id:, message:, enabled: true)
        key = scope_key(community_id, message.origin.id, message.ref.native_id)
        return nil if key.nil?
        return nil if !enabled && @rows.where(key).empty?

        kind = message.kind.to_s
        digest = kind == "delete" ? nil : self.class.digest(message.body.text)
        now = @clock.call
        transaction do
          scope = @rows.where(key)
          row = scope.for_update.first
          if row && row[:expires_at] <= now
            scope.delete
            row = nil
          end
          if row.nil?
            @rows.insert(key.merge(digest: digest, kind: kind, expires_at: now + @retention)) if enabled
          elsif row[:kind] != "delete" && (kind != "chat" || row[:kind] == "chat" && row[:digest] == digest)
            scope.update(digest: digest, kind: kind, expires_at: now + @retention)
          end
        end
        prune_if_due(now)
        digest
      rescue Sequel::UniqueConstraintViolation
        # Two sessions may see the first event simultaneously. Re-read the
        # winning row under its lock before applying the later observation.
        retry
      end

      def current?(community_id:, endpoint_id:, native_id:, digest:)
        return false if digest.to_s.empty?

        key = scope_key(community_id, endpoint_id, native_id)
        return false if key.nil?

        row = @rows.where(key).first
        !row.nil? && row[:kind] != "delete" && row[:digest] == digest && row[:expires_at] > @clock.call
      end

      # Reads expire immediately; disk cleanup uses the indexed expiry and a
      # bounded batch so a quiet or disabled feature can also release its rows.
      def prune(now: @clock.call)
        ids = @rows.where { expires_at <= now }.order(:expires_at).limit(PRUNE_LIMIT).select_map(:id)
        ids.empty? ? 0 : @rows.where(id: ids).where { expires_at <= now }.delete
      end

      private

      def scope_key(community_id, endpoint_id, native_id)
        return nil if community_id.nil? || endpoint_id.to_s.empty? || native_id.to_s.empty?

        { community_id: community_id, endpoint_id: endpoint_id.to_s, native_id: native_id.to_s }
      end

      def transaction(&block)
        options = @db.database_type == :sqlite ? { mode: :immediate } : {}
        @db.transaction(**options, &block)
      end

      def prune_if_due(now)
        @prune_mutex.synchronize do
          return if @pruned_at && now - @pruned_at < PRUNE_INTERVAL

          removed = prune(now: now)
          @pruned_at = removed >= PRUNE_LIMIT ? nil : now
        end
      end
    end
  end
end
