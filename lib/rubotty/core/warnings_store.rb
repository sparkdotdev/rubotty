# frozen_string_literal: true

require "sequel"
require "json"

module Rubotty
  module Core
    # Durable backing for the warnings ladder: the strike history (`warnings`) and
    # the live temp-mutes / temp-bans (`active_sanctions`).
    #
    # Two implementations, chosen by whether the storage backend exposes a Sequel
    # connection. The {Sequel} store persists to migration 007's tables; {Null} is
    # a no-op for the memory and pstore backends, where the ladder never fires.
    module WarningsStore
      # One persisted strike, as the service reads it back.
      Warning = Struct.new(:id, :community, :adapter, :subject_native_id, :subject_username,
                           :subject_display, :reason, :issued_by, :account, :active, :issued_at,
                           keyword_init: true)

      # One applied, still-live sanction and the moment it lifts.
      Sanction = Struct.new(:id, :community, :adapter, :subject_native_id, :subject_username,
                            :action, :endpoints, :until_at, :job_id, :active, keyword_init: true)

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

        def record_warning(**) = nil

        def active_warnings(**) = []

        def active_count(**) = 0

        def deactivate_warnings(**) = 0

        def deactivate_warning(**) = false

        def record_sanction(**) = nil

        def attach_job(*) = nil

        def find_sanction(**) = nil

        def lift_sanction(**) = false

        def active_sanctions(**) = []

        def community_sanctions(**) = []

        # No database, so no second caller to lock against; this backend's own
        # single-process contract already makes it safe.
        def with_advisory_lock(_name, timeout: nil)
          yield
        end
      end

      # Persistent store over the `warnings` and `active_sanctions` tables.
      class Sequel
        WARNINGS = :warnings
        SANCTIONS = :active_sanctions

        def initialize(db:, logger: nil)
          @db = db
          @logger = logger
        end

        def durable? = true

        # Record a strike and return it as a {Warning}; `issued_at` is stamped
        # here so the caller works in plain values. `account` is the adapter
        # account it was issued from, so a decay job can DM back through it.
        def record_warning(community:, adapter:, subject_native_id:, subject_username: nil,
                           subject_display: nil, reason: nil, issued_by: nil, account: nil, now: Time.now)
          id = warnings.insert(
            community: community.to_s, adapter: adapter.to_s,
            subject_native_id: subject_native_id.to_s,
            subject_username: subject_username, subject_display: subject_display,
            reason: reason, issued_by: issued_by, account: account&.to_s, active: true, issued_at: now
          )
          Warning.new(
            id: id, community: community.to_s, adapter: adapter.to_s,
            subject_native_id: subject_native_id.to_s, subject_username: subject_username,
            subject_display: subject_display, reason: reason, issued_by: issued_by,
            account: account&.to_s, active: true, issued_at: now
          )
        rescue ::Sequel::Error => e
          raise StorageError, "could not record warning: #{e.message}"
        end

        # A subject's active strikes, most recent last.
        def active_warnings(community:, adapter:, subject_native_id:)
          subject_scope(warnings, community, adapter, subject_native_id)
            .where(active: true).order(:issued_at, :id).map { |row| to_warning(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not read warnings: #{e.message}"
        end

        # How many active strikes a subject has, which is what the ladder reads.
        def active_count(community:, adapter:, subject_native_id:)
          subject_scope(warnings, community, adapter, subject_native_id).where(active: true).count
        rescue ::Sequel::Error => e
          raise StorageError, "could not count warnings: #{e.message}"
        end

        # Deactivates a subject's active strikes: `scope: :all` clears every active
        # warning, `scope: :latest` clears only the most recent. Returns how many
        # were deactivated, and leaves the history in place.
        def deactivate_warnings(community:, adapter:, subject_native_id:, scope: :all, now: Time.now)
          base = subject_scope(warnings, community, adapter, subject_native_id).where(active: true)
          if scope == :latest
            latest = base.order(::Sequel.desc(:issued_at), ::Sequel.desc(:id)).select(:id).first
            return 0 if latest.nil?

            base = warnings.where(id: latest[:id])
          end
          base.update(active: false, deactivated_at: now)
        rescue ::Sequel::Error => e
          raise StorageError, "could not clear warnings: #{e.message}"
        end

        # Deactivate exactly one of +community+'s warnings by id, the durable
        # decay job's target. False when it was already inactive, so an
        # at-least-once retry never double-fires the decay DM, and false as well
        # for a warning belonging to another community.
        def deactivate_warning(community:, id:, now: Time.now)
          cleared = warnings.where(id: id, community: community.to_s, active: true)
                            .update(active: false, deactivated_at: now).positive?
          refuse_foreign(warnings, "deactivating warning", id, community) unless cleared
          cleared
        rescue ::Sequel::Error => e
          raise StorageError, "could not deactivate warning #{id}: #{e.message}"
        end

        # Record an applied sanction and return it as a {Sanction}. `endpoints` is
        # the list of endpoint ids it was carried out on, JSON-encoded here.
        def record_sanction(community:, adapter:, subject_native_id:, action:, until_at:,
                            endpoints: [], subject_username: nil, job_id: nil, now: Time.now)
          id = sanctions.insert(
            community: community.to_s, adapter: adapter.to_s,
            subject_native_id: subject_native_id.to_s, subject_username: subject_username,
            action: action.to_s, endpoints: JSON.generate(Array(endpoints).map(&:to_s)),
            until_at: until_at, job_id: job_id&.to_s, active: true, created_at: now
          )
          Sanction.new(
            id: id, community: community.to_s, adapter: adapter.to_s,
            subject_native_id: subject_native_id.to_s, subject_username: subject_username,
            action: action.to_s, endpoints: Array(endpoints).map(&:to_s),
            until_at: until_at, job_id: job_id&.to_s, active: true
          )
        rescue ::Sequel::Error => e
          raise StorageError, "could not record sanction: #{e.message}"
        end

        # Attach the durable-scheduler job id that drives a sanction's expiry, once
        # it has been scheduled. Separate from the insert so a store that could not
        # schedule still records the sanction.
        def attach_job(id, job_id)
          sanctions.where(id: id).update(job_id: job_id&.to_s)
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not attach the expiry job: #{e.message}"
        end

        # One of +community+'s sanctions by id, or nil. A row belonging to
        # another community reads as nil, the same answer a bad id gives.
        def find_sanction(community:, id:)
          row = sanctions.where(id: id, community: community.to_s).first
          refuse_foreign(sanctions, "reading sanction", id, community) if row.nil?
          row && to_sanction(row)
        rescue ::Sequel::Error => e
          raise StorageError, "could not read sanction: #{e.message}"
        end

        # Mark one of +community+'s sanctions lifted once its reversal has run,
        # leaving the row in place so the history survives.
        #
        # @return [Boolean] whether a sanction of this community was lifted
        def lift_sanction(community:, id:, now: Time.now)
          lifted = sanctions.where(id: id, community: community.to_s)
                            .update(active: false, lifted_at: now).positive?
          refuse_foreign(sanctions, "lifting sanction", id, community) unless lifted
          lifted
        rescue ::Sequel::Error => e
          raise StorageError, "could not lift sanction: #{e.message}"
        end

        # A subject's live sanctions. Diagnostics and tests.
        def active_sanctions(community:, adapter:, subject_native_id:)
          subject_scope(sanctions, community, adapter, subject_native_id)
            .where(active: true).order(:id).map { |row| to_sanction(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not read sanctions: #{e.message}"
        end

        # Every sanction in a community, across every subject and platform, most
        # recently issued first. `active: true` (the default) returns only live
        # sanctions; pass `false` for a full history including lifted ones.
        def community_sanctions(community:, active: true)
          scope = sanctions.where(community: community.to_s)
          scope = scope.where(active: active) unless active.nil?
          scope.order(::Sequel.desc(:id)).map { |row| to_sanction(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not read community sanctions: #{e.message}"
        end

        # Delegates to {Storage::Dialect}'s app lock: only one caller should be
        # mid-warn for the same subject at once, so a warning and a concurrent
        # word-filter strike serialize instead of both reading the count before
        # either's insert lands.
        def with_advisory_lock(name, timeout: ::Rubotty::Storage::Dialect::APP_LOCK_TIMEOUT, &block)
          dialect.with_advisory_lock(name, timeout: timeout, &block)
        end

        private

        def dialect = @dialect ||= ::Rubotty::Storage::Dialect.for(@db)

        def warnings = @db[WARNINGS]

        def sanctions = @db[SANCTIONS]

# A scoped write that changed nothing looks exactly like a retry that
# was already served, so a row another community owns says so loudly.
# Only ever reached on the miss, so nothing else pays for the query.
def refuse_foreign(dataset, doing, id, community)
  owner = dataset.where(id: id).get(:community)
  return if owner.nil? || owner == community.to_s

  @logger&.error do
    "warnings store: refusing #{doing} #{id}, which belongs to #{owner.inspect} " \
      "and was addressed as #{community.to_s.inspect}"
  end
end

def subject_scope(dataset, community, adapter, native_id)
          dataset.where(
            community: community.to_s, adapter: adapter.to_s,
            subject_native_id: native_id.to_s
          )
        end

        def to_warning(row)
          Warning.new(
            id: row[:id], community: row[:community], adapter: row[:adapter],
            subject_native_id: row[:subject_native_id], subject_username: row[:subject_username],
            subject_display: row[:subject_display], reason: row[:reason],
            issued_by: row[:issued_by], account: row[:account], active: row[:active], issued_at: row[:issued_at]
          )
        end

        def to_sanction(row)
          Sanction.new(
            id: row[:id], community: row[:community], adapter: row[:adapter],
            subject_native_id: row[:subject_native_id], subject_username: row[:subject_username],
            action: row[:action], endpoints: decode(row[:endpoints]), until_at: row[:until_at],
            job_id: row[:job_id], active: row[:active]
          )
        end

        def decode(raw)
          return [] if raw.nil? || raw == ""

          value = JSON.parse(raw)
          value.is_a?(Array) ? value : []
        rescue JSON::ParserError
          []
        end
      end
    end
  end
end
