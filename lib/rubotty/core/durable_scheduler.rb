# frozen_string_literal: true

require "monitor"
require "json"

module Rubotty
  module Core
    # The durable, cross-restart deferred-action primitive: an action persists
    # past a restart or crash, with the in-process {Core::Scheduler} as the
    # fast path and this the backstop. A feature registers a handler per
    # `kind`; a due job is claimed atomically so two workers never run it
    # twice, but an abandoned claim is later reclaimed, giving at-least-once
    # delivery (see {#recover} for boot catch-up). Nothing here raises: a
    # failing handler retries a bounded number of times then is marked
    # failed; a briefly unavailable store is logged and retried next tick.
    class DurableScheduler
      DEFAULT_TICK = 1.0
      # A claim held longer than this without completing is assumed abandoned and
      # is reclaimed. A handler still working keeps its own claim fresh, so this
      # stays a statement about a worker that is gone rather than a slow one.
      DEFAULT_LEASE = 300.0
      # A running handler refreshes its claim every lease divided by this, so the
      # claim never ages into a reclaim while the work is live and a handler that
      # finishes inside one interval writes nothing at all.
      CLAIM_REFRESH_DIVISOR = 3.0
      # How long a drain waits for a finished handler's refresher to notice. The
      # thread is idle in a timed wait almost always, and nothing after this
      # depends on it having exited.
      CLAIM_REFRESH_STOP_WAIT = 1.0
      DEFAULT_MAX_ATTEMPTS = 5
      # Base of the exponential backoff between retries, in seconds.
      DEFAULT_RETRY_BACKOFF = 10.0
      # Cap so a job with a high attempt count does not back off for hours.
      MAX_RETRY_BACKOFF = 3600.0
      # A run_due drain claims each due job at most this many times, a safety net
      # against a handler that keeps returning a job to the due window.
      DRAIN_LIMIT = 1000

      # The per-row claim is already a compare-and-swap, so these advisory locks
      # only stop every live process hammering the same due window. Held across
      # a claim, never across a handler. One name each, so {#recover}, the
      # {#run_due} it calls, and the reserved worker never take the same one.
      RUN_LOCK_NAME = "rubotty:durable_scheduler:run"
      RECOVER_LOCK_NAME = "rubotty:durable_scheduler:recover"
      RESERVED_RUN_LOCK_NAME = "rubotty:durable_scheduler:run_reserved"

      # What a kind is worth relative to the others, highest first. A default
      # kind is housekeeping or a convenience; a high one is a judgement about
      # a person that somebody is waiting on, and waiting behind a backlog of
      # the former is what this exists to prevent.
      PRIORITY_DEFAULT = 0
      PRIORITY_HIGH = 10

      # The floor the reserved worker claims at. Priority ordering alone still
      # leaves one thread, so a high priority job falling due while a slow low
      # priority one is mid-call would wait for that call regardless; a second
      # worker that will only ever take high priority work removes that without
      # letting the low priority backlog occupy both.
      RESERVED_PRIORITY_FLOOR = PRIORITY_HIGH

      # How long #run_due/#recover wait for their lock before giving up on this
      # pass. Short, because both are called from a tight tick loop and the
      # winner's own next tick picks up whatever is still due.
      LOCK_TIMEOUT = 2

      # The built-in handler kind, registered by default, so the worker can be
      # proven end to end before any feature registers a real handler.
      NOOP_KIND = "noop"
      DISCARD_PAYLOAD_KEY = "_rubotty_discard_payload_on_settle"

      # @param store [DurableSchedulerStore::Sequel, DurableSchedulerStore::Null]
      # @param session_id [String] this process's boot id, stamped on every claim
      # @param clock [#call] returns the current Time. Injected in tests.
      # @param tick [Float] seconds the worker sleeps between polls
      # @param lease [Float] seconds after which a held claim is reclaimable
      # @param max_attempts [Integer] handler failures before a job is marked failed
      # @param retry_backoff [Float] base seconds for the exponential retry backoff
      # @param on_discard [#call, nil] receives a job dropped past its max_age
      def initialize(store:, session_id:, logger: nil, clock: -> { Time.now },
                     tick: DEFAULT_TICK, lease: DEFAULT_LEASE,
                     max_attempts: DEFAULT_MAX_ATTEMPTS, retry_backoff: DEFAULT_RETRY_BACKOFF,
                     on_discard: nil)
        @store = store
        @session_id = session_id.to_s
        @logger = logger
        @clock = clock
        @tick = tick
        @lease = lease
        @max_attempts = max_attempts
        @retry_backoff = retry_backoff
        @on_discard = on_discard
        @handlers = {}
        @max_ages = {}
        @priorities = {}
        @monitor = Monitor.new
        @threads = []
        @running = false
        register(NOOP_KIND) { |job| @logger&.debug { "durable noop job #{job.id} ran" } }
      end

      # +max_attempts+ is read by a handler that would rather do something other
      # than raise on its last go: a redirection skips the one message it cannot
      # relay instead of letting the whole move die with it.
      attr_reader :session_id, :store, :max_attempts

      # Register the handler for a job +kind+: a callable taking the
      # {DurableSchedulerStore::Row} for the due job. Raising from it marks the run
      # a failure; re-registering a kind replaces its handler. +max_age+, in
      # seconds, discards a job outright once it is that far past its run_at
      # rather than running the handler; nil (the default) never discards.
      def register(kind, handler = nil, max_age: nil, priority: PRIORITY_DEFAULT, &block)
        callable = handler || block
        raise ArgumentError, "a handler is required" if callable.nil?

        @monitor.synchronize do
          @handlers[kind.to_s] = callable
          @max_ages[kind.to_s] = max_age
          @priorities[kind.to_s] = priority.to_i
        end
        self
      end

      # What a kind is worth, as registered. A kind nobody registered is worth
      # the default, which is also what a row enqueued before its handler
      # existed already carries.
      def priority_for(kind) = @monitor.synchronize { @priorities[kind.to_s] } || PRIORITY_DEFAULT

      # Whether a handler is registered for +kind+.
      def handler?(kind) = @monitor.synchronize { @handlers.key?(kind.to_s) }

      # Persist a job to run at +run_at+. Returns the new job's id, or nil on a
      # store that is not durable, where the primitive degrades to a no-op.
      #
      # @param recurrence [Integer, String, nil] interval in seconds for a recurring
      #   job that reschedules itself, or nil for a one-shot
      # @param discard_payload [Boolean] clear the persisted payload when a terminal
      #   job succeeds or exhausts its retries
      def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil, discard_payload: false)
        stored_payload = payload.dup
        stored_payload[DISCARD_PAYLOAD_KEY] = true if discard_payload
        @store.enqueue(
          kind: kind.to_s, run_at: run_at, payload: stored_payload,
          community: community, recurrence: normalized_recurrence(recurrence),
          priority: priority_for(kind)
        )
      rescue StorageError => e
        @logger&.warn { "could not schedule durable job #{kind}: #{e.message}" }
        nil
      end

      # Forget every PENDING job of a kind within +community+, returning how many
      # were removed (0 on a non-durable store). Never touches a claimed or done
      # job, so nothing in flight or already run is disturbed. The
      # deployment-wide sweep is +every_community: true+; see {#scope_of}.
      def forget(kind:, community: nil, every_community: false)
        @store.delete_pending(kind: kind.to_s, community: scope_of(community, every_community, "forget"))
      rescue StorageError => e
        @logger&.warn { "could not forget scheduled jobs of kind #{kind}: #{e.message}" }
        0
      end

      # The filtered sibling of {#forget}: cancel every PENDING job of +kind+
      # whose decoded payload the block accepts, for a caller whose kind covers
      # many independent things. Scoped exactly as {#forget} is. Returns how
      # many were cancelled.
      def cancel(kind:, community: nil, every_community: false, &predicate)
        scope = scope_of(community, every_community, "cancel")
        @store.delete_pending_matching(kind: kind.to_s, community: scope, &predicate)
      rescue StorageError => e
        @logger&.warn { "could not cancel scheduled jobs of kind #{kind}: #{e.message}" }
        0
      end

      # Claim and run every job whose time has arrived, oldest first, returning how
      # many ran. Each job is claimed before it runs (at-least-once) and, on
      # return, is done, rescheduled, requeued for a bounded retry, or failed.
      # The lock covers picking the next job rather than running it: a handler
      # that held it would stall every other kind behind its own I/O.
      def run_due(now: @clock.call, min_priority: nil, lock: RUN_LOCK_NAME)
        ran = 0
        while ran < DRAIN_LIMIT
          job = claim_one(now, min_priority: min_priority, lock: lock)
          break if job.nil?

          dispatch(job, now)
          ran += 1
        end
        ran
      rescue LockUnavailable
        # Another process is claiming from the same due window; whatever is left
        # there is picked up by its drain or by the next tick here.
        @logger&.debug { "durable scheduler drain skipped, another instance already has the lock" }
        ran
      rescue StorageError => e
        @logger&.warn { "durable scheduler drain failed: #{e.message}" }
        ran
      end

      # Boot may overlap another live process. Reclaim only expired leases unless
      # the caller supplies an authoritative set of live sessions.
      # Idempotent and safe to call more than once.
      #
      # @return [Integer] jobs run during recovery
      def recover(alive_session_ids: nil, now: @clock.call)
        with_lock(RECOVER_LOCK_NAME) do
          reclaimed = @store.reclaim_stale(now: now, lease: @lease, alive_session_ids: alive_session_ids)
          if reclaimed.positive?
            @logger&.info { "reclaimed #{reclaimed} scheduled job(s) left claimed by a previous session" }
          end
          run_due(now: now)
        end
      rescue LockUnavailable
        # Another process is already recovering; let it finish.
        @logger&.debug { "durable scheduler recovery skipped, another instance already has the lock" }
        0
      rescue StorageError => e
        @logger&.warn { "durable scheduler recovery failed: #{e.message}" }
        0
      end

      # Start the worker thread. A no-op on a non-durable store, so the memory and
      # pstore backends run no extra thread; safe to call twice.
      def start
        return self unless @store.durable?

        @monitor.synchronize do
          return self if @running

          @running = true
          @threads = [worker("durable-scheduler") { tick_once },
                      worker("durable-scheduler-reserved") { reserved_tick_once }]
        end
        self
      end

      # One polling thread. Both workers poll on the same tick; they differ only
      # in what each is allowed to claim.
      def worker(name, &pass)
        Thread.new do
          Thread.current.name = name
          loop do
            sleep(@tick)
            pass.call
          end
        end
      end
      private :worker

      # A job left claimed by this session is reclaimed by the next one. Safe to
      # call when never started and safe to call twice.
      def stop
        threads = @monitor.synchronize do
          @running = false
          current = @threads
          @threads = []
          current
        end
        threads.each(&:kill)
        self
      end

      def running? = @monitor.synchronize { @running }

      # How many jobs are pending in the store. +kind+ narrows it; the runtime
      # schedules its own recurring housekeeping, so a bare total covers more than
      # whatever the caller put there.
      def pending(kind: nil) = @store.count(status: "pending", kind: kind)

      # The jobs that gave up, most recent first, so an operator surface can
      # show that a feature has stopped rather than leaving it to a log line a
      # restart wipes. Never raises: a reading surface must not take a page down.
      def recent_failures(since: nil, limit: 100)
        @store.recent_failures(since: since, limit: limit)
      rescue StorageError => e
        @logger&.warn { "durable scheduler could not read its failures: #{e.message}" }
        []
      end

      private

      # The community predicate a delete runs under. Omitting both keywords used
      # to mean every tenant, which made the dangerous call the shorter one, so
      # the deployment-wide sweep now has to be asked for by name and a caller
      # that simply forgot gets an error instead of the whole deployment.
      #
      # @raise [ArgumentError]
      # @return [String, nil] nil ONLY for an explicit every_community sweep
      def scope_of(community, every_community, doing)
        return nil if every_community && community.nil?

        if every_community
          raise ArgumentError, "#{doing} takes a community or every_community: true, never both"
        end
        raise ArgumentError, "#{doing} needs a community, or every_community: true to sweep them all" if community.nil?

        community
      end

      # The claim half of a drain, and the only half the lock covers: one job
      # taken off the due window, or nil when nothing is left there.
      # +min_priority+ narrows that window to what the reserved worker may take.
      def claim_one(now, min_priority: nil, lock: RUN_LOCK_NAME)
        with_lock(lock) do
          @store.claim_next(now: now, session_id: @session_id, min_priority: min_priority)
        end
      end

      # Run +block+ under the named advisory lock when the store supports one, or
      # straight through on a store that does not (the Null store).
      def with_lock(name, &block)
        return yield unless @store.respond_to?(:with_advisory_lock)

        @store.with_advisory_lock(name, timeout: LOCK_TIMEOUT, &block)
      end

      # One worker pass: reclaim any lease-expired claim, then drain what is due.
      # Never raises.
      def tick_once
        @store.reclaim_stale(now: @clock.call, lease: @lease)
        run_due
      rescue StandardError => e
        @logger&.warn { "durable scheduler tick failed: #{e.class}: #{e.message}" }
      end

      # The reserved worker's pass: high priority work only, under a lock of its
      # own so it never waits on the general worker's claim. It reclaims nothing,
      # since the general pass already does and doing it twice per tick would be
      # two writes for one answer. Never raises.
      def reserved_tick_once
        run_due(min_priority: RESERVED_PRIORITY_FLOOR, lock: RESERVED_RUN_LOCK_NAME)
      rescue StandardError => e
        @logger&.warn { "durable scheduler reserved tick failed: #{e.class}: #{e.message}" }
      end

      # Run one claimed job and settle its row by the outcome. A kind
      # registered with max_age skips the handler and settles as a discard,
      # not a failure, once the job is that far past its run_at: see
      # {#stale_beyond_max_age?}.
      def dispatch(job, now)
        handler, max_age = @monitor.synchronize { [@handlers[job.kind.to_s], @max_ages[job.kind.to_s]] }
        if handler.nil?
          # No handler for this kind. Treated as a failure so a job whose feature
          # is not present does not sit claimed forever.
          fail_or_retry(job, now, "no handler registered for kind #{job.kind.inspect}")
          return
        end

        return discard_stale(job, now) if stale_beyond_max_age?(job, now, max_age)

        call_handler(handler, job)
        settle_success(job, now, discard_payload: discard_payload?(job))
      rescue StandardError => e
        fail_or_retry(job, now, "#{e.class}: #{e.message}", permanent: permanent?(e))
      end

      # Whether the handler's own error says a second attempt would send the
      # same refused request again. Duck-typed rather than tied to any one
      # error class, so a feature says it without this knowing the feature.
      def permanent?(error) = error.respond_to?(:permanent?) && !!error.permanent?

      # Call the handler with the job's claim kept fresh underneath it. Handlers
      # run outside the drain lock, so without this a handler slower than the
      # lease would have its row reclaimed and handed to another worker while it
      # was still going, replaying a side effect it had already done.
      def call_handler(handler, job)
        refresher = start_claim_refresh(job)
        handler.call(job)
      ensure
        stop_claim_refresh(refresher)
      end

      # The refresher for +job+ as a [queue, thread] pair, or nil on a store with
      # no claim to refresh or a lease too small to divide.
      def start_claim_refresh(job)
        interval = @lease.to_f / CLAIM_REFRESH_DIVISOR
        return nil unless interval.positive? && @store.respond_to?(:touch_claim)

        stop = Queue.new
        thread = Thread.new do
          Thread.current.name = "durable-claim-refresh"
          refresh_until_stopped(job, stop, interval)
        end
        [stop, thread]
      end

      # A pop that times out, and so comes back nil, is the handler saying it is
      # still going; anything popped is the drain saying it has finished.
      def refresh_until_stopped(job, stop, interval)
        while stop.pop(timeout: interval).nil?
          break unless refresh_claim(job)
        end
      end

      def stop_claim_refresh(refresher)
        return if refresher.nil?

        stop, thread = refresher
        stop << :done
        thread.join(CLAIM_REFRESH_STOP_WAIT)
      end

      # One refresh, true while there is any point doing another. A store error
      # is nothing to stop for, since the next interval tries again; a refresh
      # that matches no row means the claim is not ours any more, which nothing
      # from here can undo, so it is said out loud and the refreshing stops.
      def refresh_claim(job)
        return true if @store.touch_claim(job.id, session_id: @session_id, now: @clock.call,
                                                  claim_token: job.claim_token).to_i == 1

        @logger&.warn do
          "durable job #{job.id} (#{job.kind}) lost its claim while its handler was still running"
        end
        false
      rescue StorageError => e
        @logger&.warn { "durable job #{job.id} could not refresh its claim: #{e.message}" }
        true
      end

      # Whether +job+ is more than its kind's +max_age+ past due; nil (no
      # limit registered) is never stale.
      def stale_beyond_max_age?(job, now, max_age)
        max_age && (now - job.run_at) > max_age
      end

      # Settled exactly like a normal success, just without ever calling the
      # handler: a job this overdue is stale backlog, not a live failure
      # worth retrying.
      def discard_stale(job, now)
        overdue = (now - job.run_at).round
        @logger&.info do
          "durable job #{job.id} (#{job.kind}) is #{overdue}s past its max_age, discarding without running"
        end
        announce_discard(job)
        settle_success(job, now, discard_payload: discard_payload?(job))
      end

      # Tell whoever asked to hear about a discard. A listener that raises is
      # not worth losing the settle over.
      def announce_discard(job)
        @on_discard&.call(job)
      rescue StandardError => e
        @logger&.warn { "durable scheduler could not report a discarded job: #{e.class}: #{e.message}" }
      end

      # A recurring job goes back to pending at its next future occurrence; a
      # one-shot goes through {#complete_one_shot}, which never lets a settle
      # failure leave the row claimed (see there for why that matters).
      def settle_success(job, now, discard_payload:)
        interval = recurrence_seconds(job.recurrence)
        if interval&.positive?
          @store.reschedule(job.id, run_at: next_occurrence(job.run_at, interval, now), claim_token: job.claim_token)
        else
          complete_one_shot(job, discard_payload)
        end
      rescue StorageError => e
        @logger&.error { "durable scheduler could not reschedule recurring job #{job.id}: #{e.message}" }
      end

      # The handler above already ran, so from here the job must never come back
      # looking like an abandoned claim: reclaim_stale cannot tell "the completion
      # write failed" from "the worker died before the handler ran at all," and
      # would hand this row to the next claimant to run the handler a second time.
      # @store.complete already retries a transient database error itself; if it
      # still raises, this falls back to marking the job failed outright, a
      # terminal status reclaim_stale never touches, rather than leave it claimed.
      def complete_one_shot(job, discard_payload)
        @store.complete(job.id, discard_payload: discard_payload, claim_token: job.claim_token)
      rescue StorageError => e
        @logger&.error do
          "durable job #{job.id} (#{job.kind}) ran but its completion write kept failing " \
            "(#{e.message}); marking it failed instead of leaving it claimed for a lease " \
            "reclaim to run the handler again"
        end
        mark_failed_after_settle_failure(job, discard_payload)
      end

      # The last resort when even the fallback write above fails: nothing more to
      # do from here but say so loudly. The row stays claimed; only a genuine
      # store outage gets this far, and reclaim_stale is failing the same way
      # against the same store in the meantime, so no replay happens until it
      # recovers, and this line is what tells an operator to check by hand then.
      def mark_failed_after_settle_failure(job, discard_payload)
        @store.mark_failed(job.id, attempts: job.attempts.to_i, discard_payload: discard_payload,
                                   claim_token: job.claim_token)
      rescue StorageError => e
        @logger&.error do
          "durable job #{job.id} (#{job.kind}) could not even be marked failed after a settle failure: #{e.message}"
        end
      end

      # Bump the failure count and either requeue with a backoff or, once the bound
      # is reached, mark the job failed for good. A failure the handler reports as
      # permanent settles at once: the ladder exists for a fault that may clear,
      # and spending it on a request already refused on its merits only repeats
      # the refusal at the far end's expense.
      def fail_or_retry(job, now, reason, permanent: false)
        attempts = job.attempts.to_i + 1
        if permanent || attempts >= @max_attempts
          @logger&.warn { "durable job #{job.id} (#{job.kind}) failed permanently after #{attempts} attempt(s): #{reason}" }
          @store.mark_failed(job.id, attempts: attempts, discard_payload: discard_payload?(job),
                                     reason: reason, now: now, claim_token: job.claim_token)
        else
          @logger&.debug { "durable job #{job.id} (#{job.kind}) failed (attempt #{attempts}), will retry: #{reason}" }
          @store.retry_later(job.id, run_at: now + backoff(attempts), attempts: attempts,
                                    claim_token: job.claim_token)
        end
      rescue StorageError => e
        @logger&.warn { "durable scheduler could not record the failure of job #{job.id}: #{e.message}" }
      end

      # The next occurrence at or after +now+, rolling past occurrences missed
      # during downtime so a long outage does not fire a backlog all at once.
      def next_occurrence(run_at, interval, now)
        nxt = run_at + interval
        nxt += interval while nxt <= now
        nxt
      end

      def discard_payload?(job)
        job.payload.is_a?(Hash) && job.payload[DISCARD_PAYLOAD_KEY]
      end

      def backoff(attempts)
        [@retry_backoff * (2**(attempts - 1)), MAX_RETRY_BACKOFF].min
      end

      # A recurrence is a whole number of seconds stored as text. Anything not a
      # positive integer is treated as no recurrence.
      def recurrence_seconds(recurrence)
        return nil if recurrence.nil? || recurrence.to_s.empty?

        value = Integer(recurrence, exception: false)
        value&.positive? ? value : nil
      end

      # The text recurrence to persist: the seconds as a string when positive, nil
      # otherwise, so the row never stores a "0" that would read as recurring.
      def normalized_recurrence(recurrence)
        seconds = recurrence_seconds(recurrence)
        seconds&.to_s
      end
    end
  end
end
