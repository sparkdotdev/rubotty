# frozen_string_literal: true

require "sequel"
require "json"

module Rubotty
  module Core
    # The moderation audit log: a structured, queryable, per-community record
    # of who did what, to whom, why, and when. {Sequel} persists to the
    # `audit_events` table when the storage backend exposes one; {Null} is a
    # no-op otherwise. A lost audit line is always non-fatal: containment
    # must never hinge on the trail being written.
    module AuditLog
      # One recorded action, as a query reads it back. `metadata` is decoded from
      # its stored JSON into a Hash.
      Event = Struct.new(
        :id, :community, :source, :action, :adapter, :channel,
        :actor, :actor_native_id, :subject, :subject_native_id,
        :target_ref, :reason, :outcome, :metadata, :created_at,
        keyword_init: true
      )

      module_function

      # The right store for a storage backend: {Sequel} when it exposes a
      # Sequel::Database, {Null} otherwise.
      def for(storage, logger: nil)
        db = storage.respond_to?(:db) ? storage.db : nil
        db.is_a?(::Sequel::Database) ? Sequel.new(db: db, logger: logger) : Null.new
      end

      # No-op store for backends without a database.
      class Null
        def durable? = false

        def record(**) = nil

        def query(**) = []

        def count(**) = 0
      end

      # Persistent store over the `audit_events` table.
      class Sequel
        TABLE = :audit_events

        def initialize(db:, logger: nil)
          @db = db
          @logger = logger
        end

        def durable? = true

        # Record one action and return it as an {Event}; every field but the
        # community, source and action is optional, so a message-only action
        # and a person action use the one call. `created_at` is stamped here.
        #
        # +excerpt+ is what the message said, accepted so a caller can hand it to
        # every sink alike and deliberately dropped here: an alert quotes it, the
        # trail holds no message text. See PRIVACY.md.
        def record(community:, source:, action:, adapter: nil, channel: nil,
                   actor: nil, actor_native_id: nil, subject: nil, subject_native_id: nil,
                   target_ref: nil, reason: nil, outcome: nil, metadata: nil, excerpt: nil,
                   now: Time.now)
          row = {
            community: community.to_s, source: source.to_s, action: action.to_s,
            adapter: adapter&.to_s, channel: channel&.to_s,
            actor: actor&.to_s, actor_native_id: actor_native_id&.to_s,
            subject: subject&.to_s, subject_native_id: subject_native_id&.to_s,
            target_ref: target_ref&.to_s, reason: reason&.to_s, outcome: outcome&.to_s,
            metadata: encode(metadata), created_at: now
          }
          id = events.insert(row)
          to_event(row.merge(id: id))
        rescue ::Sequel::Error => e
          raise StorageError, "could not record audit event: #{e.message}"
        end

        # Recent events, most recent first, filtered to one community or a supplied set.
        #
        # @param since [Time, nil] only events at or after this moment
        # @param limit [Integer] page size (most recent first)
        # @return [Array<Event>]
        def query(community: nil, communities: nil, source: nil, action: nil, actor_native_id: nil,
                  subject_native_id: nil, since: nil, limit: 100)
          scope = filtered(
            community: community, communities: communities, source: source, action: action,
            actor_native_id: actor_native_id, subject_native_id: subject_native_id, since: since
          )
          scope.order(::Sequel.desc(:created_at), ::Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 1000))
               .map { |row| to_event(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not read audit events: #{e.message}"
        end

        # How many events match the same filters. Diagnostics and paging.
        def count(community: nil, communities: nil, source: nil, action: nil, actor_native_id: nil,
                  subject_native_id: nil, since: nil)
          filtered(
            community: community, communities: communities, source: source, action: action,
            actor_native_id: actor_native_id, subject_native_id: subject_native_id, since: since
          ).count
        rescue ::Sequel::Error => e
          raise StorageError, "could not count audit events: #{e.message}"
        end

        private

        def events = @db[TABLE]

        def filtered(community:, communities:, source:, action:, actor_native_id:, subject_native_id:, since:)
          scope = events
          scope = scope.where(community: Array(communities).map(&:to_s)) unless communities.nil?
          scope = scope.where(community: community.to_s) unless community.nil?
          scope = scope.where(source: source.to_s) if source
          scope = scope.where(action: action.to_s) if action
          scope = scope.where(actor_native_id: actor_native_id.to_s) if actor_native_id
          scope = scope.where(subject_native_id: subject_native_id.to_s) if subject_native_id
          scope = scope.where { created_at >= since } if since
          scope
        end

        def to_event(row)
          Event.new(
            id: row[:id], community: row[:community], source: row[:source], action: row[:action],
            adapter: row[:adapter], channel: row[:channel], actor: row[:actor],
            actor_native_id: row[:actor_native_id], subject: row[:subject],
            subject_native_id: row[:subject_native_id], target_ref: row[:target_ref],
            reason: row[:reason], outcome: row[:outcome], metadata: decode(row[:metadata]),
            created_at: row[:created_at]
          )
        end

        def encode(metadata)
          return nil if metadata.nil? || (metadata.respond_to?(:empty?) && metadata.empty?)

          JSON.generate(metadata)
        rescue StandardError
          nil
        end

        def decode(raw)
          return {} if raw.nil? || raw == ""

          value = JSON.parse(raw)
          value.is_a?(Hash) ? value : {}
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
