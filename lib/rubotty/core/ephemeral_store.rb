# frozen_string_literal: true

require "sequel"
require "rubotty/storage/dialect"

module Rubotty
  module Core
    # Durable backing for the ephemeral-message primitive: the in-process
    # Core::Scheduler removes a banner or an acknowledgement on time while the process
    # lives, and this table records the same pending deletion for a FRESH session.
    #
    # {Sequel} persists to the `ephemeral_messages` table; {Null} is a no-op used by
    # the memory and pstore backends, which keep only the in-process guarantees.
    module EphemeralStore
      # One persisted copy of a logical bot message on one endpoint.
      Row = Struct.new(:group_id, :endpoint_id, :channel, :native_id, :delete_at, :session_id,
                       keyword_init: true)

      module_function

      # The right store for a storage backend: {Sequel} when it exposes a
      # Sequel::Database, {Null} otherwise.
      def for(storage, logger: nil)
        db = storage.respond_to?(:db) ? storage.db : nil
        db.is_a?(::Sequel::Database) ? Sequel.new(db: db, logger: logger) : Null.new
      end

      # No-op store for backends without a database: cleanup degrades to in-process only.
      class Null
        def durable? = false

        def add(**) = nil

        def group_id_for(endpoint_id:, native_id:) = nil

        def members(_group_id) = []

        def forget(_group_id) = 0

        def forget_member(**) = 0

        def orphan_group_ids(now:, alive_session_ids:) = []

        def count = 0
      end

      # Persistent store over the `ephemeral_messages` table (migration 004).
      class Sequel
        TABLE = :ephemeral_messages

        def initialize(db:, logger: nil)
          @db = db
          @logger = logger
          # The upsert below is the one statement in this class whose SQL differs per
          # backend, so it goes through the same seam SequelStore uses.
          @dialect = ::Rubotty::Storage::Dialect.for(db)
        end

        def durable? = true

        # Records (or updates) one copy, idempotent on (endpoint_id,
        # native_id) so a redelivery after a partial failure reconciles
        # rather than duplicating. Upserted through the dialect seam:
        # calling #insert_conflict here directly raises a NoMethodError on
        # every write against a MariaDB deployment, while the SQLite suite
        # stays green.
        def add(group_id:, endpoint_id:, native_id:, delete_at:, session_id:, channel: nil)
          @dialect.upsert(
            dataset,
            target: %i[endpoint_id native_id],
            update: %i[group_id channel delete_at session_id]
          ).insert(
            group_id: group_id.to_s,
            endpoint_id: endpoint_id.to_s,
            channel: channel,
            native_id: native_id.to_s,
            delete_at: delete_at,
            session_id: session_id.to_s,
            created_at: Time.now
          )
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not record ephemeral message: #{e.message}"
        end

        # The group a given copy belongs to, or nil. Used to turn a `/delete` on
        # one copy into a whole-group removal.
        def group_id_for(endpoint_id:, native_id:)
          row = dataset.where(endpoint_id: endpoint_id.to_s, native_id: native_id.to_s)
                       .select(:group_id).first
          row && row[:group_id]
        rescue ::Sequel::Error => e
          raise StorageError, "ephemeral lookup failed: #{e.message}"
        end

        # Every copy in a group, oldest first.
        def members(group_id)
          dataset.where(group_id: group_id.to_s).order(:id).map do |row|
            Row.new(
              group_id: row[:group_id], endpoint_id: row[:endpoint_id], channel: row[:channel],
              native_id: row[:native_id], delete_at: row[:delete_at], session_id: row[:session_id]
            )
          end
        rescue ::Sequel::Error => e
          raise StorageError, "ephemeral group lookup failed: #{e.message}"
        end

        # Drop every row in a group, once its copies have been removed (or found
        # to be gone). Returns the number of rows removed.
        def forget(group_id)
          dataset.where(group_id: group_id.to_s).delete
        rescue ::Sequel::Error => e
          raise StorageError, "ephemeral forget failed: #{e.message}"
        end

        # Drop one member row once its copy has been removed (or found
        # unresolvable), so a reap pass that partly fails does not retry a
        # delete that already landed on the next pass.
        def forget_member(group_id:, endpoint_id:, native_id:)
          dataset.where(group_id: group_id.to_s, endpoint_id: endpoint_id.to_s, native_id: native_id.to_s).delete
        rescue ::Sequel::Error => e
          raise StorageError, "ephemeral forget member failed: #{e.message}"
        end

        # The distinct groups a boot sweep should reap: any group with at least one row
        # past its delete_at OR posted by a session that is no longer alive. In
        # production the only live session is the current one.
        def orphan_group_ids(now:, alive_session_ids:)
          alive = Array(alive_session_ids).map(&:to_s)
          expired = ::Sequel[:delete_at] <= now
          # An empty alive set means nothing is alive, so ~IN() correctly matches
          # every row (Sequel renders an empty NOT IN as an always-true clause).
          orphaned = expired | ::Sequel.~(session_id: alive)
          dataset.where(orphaned).distinct.select_map(:group_id)
        rescue ::Sequel::Error => e
          raise StorageError, "ephemeral sweep query failed: #{e.message}"
        end

        # Live row count. Diagnostics and tests only.
        def count = dataset.count

        private

        def dataset = @db[TABLE]
      end
    end
  end
end
