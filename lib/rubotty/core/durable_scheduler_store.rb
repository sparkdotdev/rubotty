# frozen_string_literal: true

require "sequel"
require "json"
require "securerandom"

module Rubotty
  module Core
    # Durable backing for the deferred-action primitive: the in-process
    # Core::Scheduler runs a delayed action while the process lives, and this table
    # records the same pending action so a FRESH session can run it for a dead one.
    #
    # {Sequel} persists to the `scheduled_jobs` table; {Null} is a no-op used by the
    # memory and pstore backends, which keep only the in-process guarantees.
    module DurableSchedulerStore
      # One persisted scheduled action, as the worker sees it. `payload` is the
      # decoded JSON (a Hash); everything else is the row's own columns.
      Row = Struct.new(:id, :community, :kind, :payload, :run_at, :recurrence, :status,
                       :attempts, :claimed_at, :claimed_by, :priority, :failed_reason, :failed_at,
                       :claim_token, keyword_init: true)

      module_function

      # The right store for a storage backend: {Sequel} when it exposes a
      # Sequel::Database, {Null} otherwise.
      def for(storage, logger: nil)
        db = storage.respond_to?(:db) ? storage.db : nil
        db.is_a?(::Sequel::Database) ? Sequel.new(db: db, logger: logger) : Null.new
      end

      # No-op store for backends without a database: the primitive degrades to
      # in-process-only scheduling.
      class Null
        def durable? = false

        def enqueue(**) = nil

        def claim_next(**) = nil

        def touch_claim(_id, **) = 0

        def reclaim_stale(**) = 0

        def complete(_id, discard_payload: false, claim_token: nil) = nil

        def reschedule(_id, **) = nil

        def retry_later(_id, **) = nil

        def mark_failed(_id, attempts:, discard_payload: false, reason: nil, now: nil, claim_token: nil) = nil

        def recent_failures(**) = []

        def delete_pending(**) = 0

        def delete_pending_matching(**) = 0

        def count(**) = 0

        def find(_id) = nil

        # No database, so no second process to lock against; this backend's own
        # single-process contract already makes it safe.
        def with_advisory_lock(_name, timeout: nil)
          yield
        end
      end

      # Persistent store over the `scheduled_jobs` table (migration 005).
      class Sequel
        TABLE = :scheduled_jobs

        # What a stored failure reason runs up to. Long enough for a class name
        # and a message, short enough that a runaway one cannot bloat the row.
        MAX_FAILED_REASON = 500

        # A settle write (complete/reschedule/retry_later/mark_failed) touches one
        # row by id and holds a connection that has usually just sat idle through a
        # handler's own I/O, so a database error there is most often a dropped or
        # lock-timed-out connection, not a real conflict: the pool hands the very
        # next attempt a fresh one. Bounded and short, so a genuine outage still
        # surfaces quickly rather than blocking the scheduler thread.
        SETTLE_RETRY_ATTEMPTS = 3
        SETTLE_RETRY_DELAY = 0.2

        def initialize(db:, logger: nil)
          @db = db
          @logger = logger
        end

        def durable? = true

        # Record a new pending job and return its id. The payload is JSON-encoded here
        # so callers work in plain Ruby values; recurrence is a whole number of seconds
        # as text, or nil for a one-shot.
        def enqueue(kind:, run_at:, payload: {}, community: nil, recurrence: nil, priority: 0)
          dataset.insert(
            community: community&.to_s,
            kind: kind.to_s,
            payload: JSON.generate(payload || {}),
            run_at: run_at,
            recurrence: recurrence&.to_s,
            status: "pending",
            attempts: 0,
            priority: priority.to_i,
            created_at: Time.now
          )
        rescue ::Sequel::Error => e
          raise StorageError, "could not enqueue scheduled job: #{e.message}"
        end

        # Atomically claim the single most urgent pending job for +session_id+ as
        # a {Row}, or nil when nothing is due. A compare-and-swap: reads the
        # first candidate, then UPDATEs it guarded by `status = 'pending'` so
        # exactly one worker matches; when it misses, the next is tried, bounded
        # against contention. Highest priority first and only then soonest due,
        # so a moderation check does not wait behind a backlog of lower value
        # work; +min_priority+ narrows that window to what a reserved worker may
        # take.
        def claim_next(now:, session_id:, max_probes: 8, min_priority: nil)
          probes = 0
          while probes < max_probes
            probes += 1
            due = dataset.where(status: "pending").where(::Sequel[:run_at] <= now)
            due = due.where { priority >= min_priority } unless min_priority.nil?
            candidate = due.order(::Sequel.desc(:priority), :run_at, :id).first
            return nil if candidate.nil?

            claim = { status: "claimed", claimed_by: session_id.to_s, claimed_at: now,
                      claim_token: SecureRandom.uuid }
            won = dataset.where(id: candidate[:id], status: "pending").update(claim)
            return to_row(candidate.merge(claim)) if won == 1
            # Lost the race for this candidate; look again for the next one.
          end
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not claim scheduled job: #{e.message}"
        end

        # Push a live claim's clock forward, so a handler that runs longer than
        # the lease is not mistaken for an abandoned one. Guarded by the holder,
        # so it can never revive a claim another session has since taken or a row
        # that has already settled: returns 1 while the claim is still this
        # session's, 0 once it is not.
        def touch_claim(id, session_id:, now:, claim_token: nil)
          held = dataset.where(id: id, status: "claimed", claimed_by: session_id.to_s)
          held = held.where(claim_token: claim_token) unless claim_token.nil?
          touched = held.update(claimed_at: now)
          # MariaDB counts rows it changed rather than rows it matched, so a
          # write of the value already stored reports zero. Ask before reading
          # that as a claim this session has lost.
          touched.zero? ? held.count : touched
        rescue ::Sequel::Error => e
          raise StorageError, "could not refresh a scheduled job claim: #{e.message}"
        end

        # Reset to pending any claimed job whose claim is stale (taken before
        # +now - lease+, or held by a session not in +alive_session_ids+), and return how
        # many. Attempts are untouched, since a crash never counts as a handler failure.
        def reclaim_stale(now:, lease: nil, alive_session_ids: nil)
          conditions = []
          conditions << (::Sequel[:claimed_at] <= (now - lease)) if lease
          # An empty alive set means nothing is alive, so ~IN() correctly matches
          # every claimed row (Sequel renders an empty NOT IN as always true).
          conditions << ::Sequel.~(claimed_by: Array(alive_session_ids).map(&:to_s)) if alive_session_ids
          return 0 if conditions.empty?

          stale = conditions.reduce { |acc, cond| acc | cond }
          dataset.where(status: "claimed").where(stale)
                 .update(status: "pending", claimed_by: nil, claimed_at: nil, claim_token: nil)
        rescue ::Sequel::Error => e
          raise StorageError, "could not reclaim stale scheduled jobs: #{e.message}"
        end

        # Mark a one-shot job finished. Terminal; the row stays as an audit record.
        def complete(id, discard_payload: false, claim_token: nil)
          changes = { status: "done", claimed_by: nil, claimed_at: nil, claim_token: nil }
          changes[:payload] = "{}" if discard_payload
          retrying_transient_error { settlement_scope(id, claim_token).update(changes) }
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not complete scheduled job: #{e.message}"
        end

        # Return a recurring job to pending at its next occurrence. Attempts reset,
        # because the next occurrence counts as a fresh run rather than a retry of this one.
        def reschedule(id, run_at:, claim_token: nil)
          retrying_transient_error do
            settlement_scope(id, claim_token).update(
              status: "pending", run_at: run_at, attempts: 0, claimed_by: nil, claimed_at: nil, claim_token: nil
            )
          end
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not reschedule scheduled job: #{e.message}"
        end

        # Return a failed job to pending for another attempt at +run_at+ (a backoff in
        # the future so it is not re-run within the same drain), with the bumped count.
        def retry_later(id, run_at:, attempts:, claim_token: nil)
          retrying_transient_error do
            settlement_scope(id, claim_token).update(
              status: "pending", run_at: run_at, attempts: attempts, claimed_by: nil, claimed_at: nil, claim_token: nil
            )
          end
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not requeue scheduled job: #{e.message}"
        end

        # Mark a job failed for good once it has exhausted its retries. Terminal;
        # claimed_by is kept as the audit trail of the session that last ran it.
        # +reason+ is kept on the row rather than only logged: the log ring buffer
        # is cleared by the restart that a stopped feature usually outlives, and
        # an operator reading a failed job later has nothing else to go on.
        def mark_failed(id, attempts:, discard_payload: false, reason: nil, now: Time.now, claim_token: nil)
          changes = { status: "failed", attempts: attempts, claimed_at: nil,
                      failed_reason: reason&.to_s&.slice(0, MAX_FAILED_REASON), failed_at: now }
          changes[:payload] = "{}" if discard_payload
          retrying_transient_error { settlement_scope(id, claim_token).update(changes) }
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not fail scheduled job: #{e.message}"
        end

        # The jobs that gave up, most recent first, for an operator surface to
        # read. Only failures carrying a moment are returned, so rows failed
        # before this was recorded never read as having just happened.
        def recent_failures(since: nil, limit: 100)
          scope = dataset.where(status: "failed").exclude(failed_at: nil)
          scope = scope.where { failed_at >= since } unless since.nil?
          scope.order(::Sequel.desc(:failed_at), ::Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 1000))
               .map { |row| to_row(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not read failed scheduled jobs: #{e.message}"
        end

        # Delete every PENDING job of a kind within +community+, and return how
        # many. Only pending rows are removed, so an in-flight or historical run
        # is never disturbed. +community+ has no default: a nil here deletes
        # every tenant's rows, so it has to be written rather than fallen into.
        def delete_pending(kind:, community:)
          scope = dataset.where(kind: kind.to_s, status: "pending")
          scope = scope.where(community: community&.to_s) unless community.nil?
          scope.delete
        rescue ::Sequel::Error => e
          raise StorageError, "could not delete pending scheduled jobs: #{e.message}"
        end

        # The filtered sibling of {#delete_pending}, holding +community+ to the
        # same bar: delete only the PENDING jobs of a kind whose decoded payload
        # the block accepts, e.g. one event's own reminder jobs among every
        # event's.
        def delete_pending_matching(kind:, community:)
          scope = dataset.where(kind: kind.to_s, status: "pending")
          scope = scope.where(community: community&.to_s) unless community.nil?
          ids = scope.select(:id, :payload).all.filter_map { |row| row[:id] if yield(decode(row[:payload])) }
          return 0 if ids.empty?

          dataset.where(id: ids, status: "pending").delete
        rescue ::Sequel::Error => e
          raise StorageError, "could not delete matching pending scheduled jobs: #{e.message}"
        end

        # Row count, optionally filtered by status. Diagnostics and tests only.
        def count(status: nil, kind: nil)
          scope = dataset
          scope = scope.where(status: status.to_s) if status
          scope = scope.where(kind: kind.to_s) if kind
          scope.count
        end

        # One job by id, as a {Row}, or nil. Diagnostics and tests only.
        def find(id)
          row = dataset.where(id: id).first
          row && to_row(row)
        end

        # Delegates to {Storage::Dialect}'s app lock: only one process should be
        # mid-drain or mid-recovery over the same `scheduled_jobs` table at once.
        def with_advisory_lock(name, timeout: ::Rubotty::Storage::Dialect::APP_LOCK_TIMEOUT, &block)
          dialect.with_advisory_lock(name, timeout: timeout, &block)
        end

        private

        def dialect = @dialect ||= ::Rubotty::Storage::Dialect.for(@db)

        def dataset = @db[TABLE]

        # A stale handler must never settle a later generation of the same job.
        def settlement_scope(id, token)
          scope = dataset.where(id: id)
          token.nil? ? scope : scope.where(status: "claimed", claim_token: token)
        end

        # Runs +block+, retrying up to SETTLE_RETRY_ATTEMPTS times, with a short
        # growing delay, on a database-level error (a dropped connection, a lock
        # wait timeout, a deadlock). Any other Sequel::Error propagates immediately,
        # since retrying a non-transient failure would only delay the same outcome.
        def retrying_transient_error
          tries = 0
          begin
            yield
          rescue ::Sequel::DatabaseError, ::Sequel::PoolTimeout
            tries += 1
            raise if tries >= SETTLE_RETRY_ATTEMPTS

            sleep(SETTLE_RETRY_DELAY * tries)
            retry
          end
        end

        def to_row(record)
          Row.new(
            id: record[:id], community: record[:community], kind: record[:kind],
            payload: decode(record[:payload]), run_at: record[:run_at],
            recurrence: record[:recurrence], status: record[:status],
            attempts: record[:attempts], claimed_at: record[:claimed_at],
            claimed_by: record[:claimed_by], priority: record[:priority],
            failed_reason: record[:failed_reason], failed_at: record[:failed_at], claim_token: record[:claim_token]
          )
        end

        def decode(raw)
          return {} if raw.nil? || raw == ""

          JSON.parse(raw)
        rescue JSON::ParserError
          {}
        end
      end
    end
  end
end
