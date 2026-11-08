# frozen_string_literal: true

require "spec_helper"
require "sequel"

# These specs drive #run_due and #recover synchronously with a fake clock rather
# than sleeping on wall time. A "restart" is a second service instance with a new
# session id over the same store.
RSpec.describe Rubotty::Core::DurableScheduler do
  # Every wait on a background thread is bounded by this, so a regression in
  # the code under test fails the example instead of hanging the run.
  WAIT = 5

  let(:db) do
    database = Sequel.sqlite
    Rubotty::ControlPlane.migrate!(database)
    database
  end
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:base) { Time.now }

  # Distinct session ids stand in for distinct processes.
  def service(session_id: "live", clock: -> { base }, **rest)
    described_class.new(
      store: store, session_id: session_id, logger: Rubotty::Log.null, clock: clock, **rest
    )
  end

  # Poll until a background thread has done something, rather than sleeping a
  # guessed interval and hoping. Raises rather than carrying on quietly, so a
  # thing that never happens fails the example that waited for it.
  def wait_for(what, timeout: WAIT)
    deadline = Time.now + timeout
    sleep(0.01) until yield || Time.now > deadline
    raise "waited #{timeout}s for #{what} and it never happened" unless yield
  end

  describe "scheduling and running" do
    it "runs a registered job once its time has arrived" do
      ran = []
      sched = service
      sched.register("greet") { |job| ran << job.payload["who"] }
      sched.schedule(kind: "greet", run_at: base + 30, payload: { "who" => "ada" })

      expect(sched.run_due(now: base)).to eq(0)
      expect(ran).to be_empty

      expect(sched.run_due(now: base + 30)).to eq(1)
      expect(ran).to eq(["ada"])
    end

    it "marks a one-shot job done after it runs" do
      sched = service
      sched.register("greet") { nil }
      id = sched.schedule(kind: "greet", run_at: base, payload: {})

      sched.run_due(now: base)
      expect(store.find(id).status).to eq("done")
    end

    it "scrubs a marked payload after a one-shot job succeeds" do
      sched = service
      sched.register("greet") { nil }
      id = sched.schedule(kind: "greet", run_at: base, payload: { "text" => "private" }, discard_payload: true)

      sched.run_due(now: base)

      expect(store.find(id).payload).to eq({})
    end

    it "runs due jobs oldest first" do
      order = []
      sched = service
      sched.register("mark") { |job| order << job.payload["n"] }
      sched.schedule(kind: "mark", run_at: base + 20, payload: { "n" => "later" })
      sched.schedule(kind: "mark", run_at: base + 10, payload: { "n" => "sooner" })

      sched.run_due(now: base + 30)
      expect(order).to eq(%w[sooner later])
    end

    it "records a global job with a nil community" do
      sched = service
      sched.register("noop") { nil }
      id = sched.schedule(kind: "noop", run_at: base)
      expect(store.find(id).community).to be_nil
    end

    it "carries the community through to the handler's job" do
      seen = []
      sched = service
      sched.register("noop") { |job| seen << job.community }
      sched.schedule(kind: "noop", run_at: base, community: "sample")
      sched.run_due(now: base)
      expect(seen).to eq(["sample"])
    end

    it "has a built-in noop handler so the loop works before any feature registers one" do
      sched = service
      id = sched.schedule(kind: described_class::NOOP_KIND, run_at: base)
      sched.run_due(now: base)
      expect(store.find(id).status).to eq("done")
    end

    it "requires a handler to register" do
      expect { service.register("x") }.to raise_error(ArgumentError)
    end
  end

  describe "recovery after a restart" do
    it "runs a job a dead prior session left pending and now due" do
      service(session_id: "dead").schedule(kind: "greet", run_at: base + 10, payload: { "who" => "ada" })

      ran = []
      fresh = service(session_id: "live")
      fresh.register("greet") { |job| ran << job.payload["who"] }
      fresh.recover(alive_session_ids: ["live"], now: base + 10)

      expect(ran).to eq(["ada"])
    end

    it "reclaims and runs a job a dead prior session had claimed but not finished" do
      dead = service(session_id: "dead")
      dead.register("greet") { nil }
      dead.schedule(kind: "greet", run_at: base, payload: { "who" => "ada" })
      # The dead session claims it but never settles it.
      store.claim_next(now: base, session_id: "dead")
      expect(store.count(status: "claimed")).to eq(1)

      ran = []
      fresh = service(session_id: "live")
      fresh.register("greet") { |job| ran << job.payload["who"] }
      fresh.recover(alive_session_ids: ["live"], now: base)

      expect(ran).to eq(["ada"])
      expect(store.count(status: "claimed")).to eq(0)
    end

    it "is idempotent: a second recovery finds nothing left to do" do
      service(session_id: "dead").schedule(kind: "noop", run_at: base)
      fresh = service(session_id: "live")

      expect(fresh.recover(alive_session_ids: ["live"], now: base)).to eq(1)
      expect(fresh.recover(alive_session_ids: ["live"], now: base)).to eq(0)
    end

    it "leaves a not-yet-due job for later rather than running it early" do
      service(session_id: "dead").schedule(kind: "noop", run_at: base + 60)
      fresh = service(session_id: "live")
      expect(fresh.recover(alive_session_ids: ["live"], now: base)).to eq(0)
      expect(store.count(status: "pending")).to eq(1)
    end
  end

  describe "at-least-once claiming" do
    it "runs a due job exactly once within a session" do
      count = 0
      sched = service
      sched.register("once") { count += 1 }
      sched.schedule(kind: "once", run_at: base)

      sched.run_due(now: base)
      sched.run_due(now: base)

      expect(count).to eq(1)
    end

    it "does not run a job another live session is already holding" do
      sched = service(session_id: "s1")
      sched.register("noop") { nil }
      sched.schedule(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "other-live")

      # "other-live" is alive, so run_due finds nothing to claim.
      expect(sched.run_due(now: base)).to eq(0)
    end
  end

  # A handler's side effect (a DM, a post, a deletion) already happened by
  # the time settle_success runs, so a completion write that keeps failing
  # must never leave the row looking like an abandoned claim: that is
  # exactly what a lease reclaim cannot tell from a worker that crashed.
  describe "a completion write that keeps failing" do
    it "does not replay the handler once the lease expires and a real tick reclaims and drains" do
      allow(store).to receive(:complete).and_raise(Rubotty::StorageError, "MySQL server has gone away")
      ran = []
      now = base
      sched = service(clock: -> { now }, lease: 300)
      sched.register("greet") { |job| ran << job.id }
      id = sched.schedule(kind: "greet", run_at: base)

      sched.run_due(now: base)
      expect(ran.size).to eq(1)
      expect(store.find(id).status).to eq("failed")

      # Well past the lease, so a naive reclaim would treat this exactly like
      # an abandoned claim. tick_once is exercised directly (not run_due)
      # so both halves of a real tick, reclaim then drain, run for real.
      now = base + 1000
      sched.send(:tick_once)

      expect(ran.size).to eq(1)
    end

    it "leaves the row claimed rather than raising when the mark_failed fallback fails too" do
      allow(store).to receive(:complete).and_raise(Rubotty::StorageError, "boom")
      allow(store).to receive(:mark_failed).and_raise(Rubotty::StorageError, "boom too")
      ran = []
      sched = service
      sched.register("greet") { |job| ran << job.id }
      id = sched.schedule(kind: "greet", run_at: base)

      expect { sched.run_due(now: base) }.not_to raise_error

      expect(ran.size).to eq(1)
      expect(store.find(id).status).to eq("claimed")
    end

    # A recurring job's next occurrence is still ahead of it; marking it
    # failed on a settle blip would stop it forever, a worse outcome than
    # leaving this one occurrence claimed for a later reclaim to retry.
    it "does not mark a recurring job failed when its reschedule write fails" do
      allow(store).to receive(:reschedule).and_raise(Rubotty::StorageError, "boom")
      runs = []
      sched = service
      sched.register("beat") { |job| runs << job.id }
      id = sched.schedule(kind: "beat", run_at: base, recurrence: 60)

      sched.run_due(now: base)

      expect(runs.size).to eq(1)
      expect(store.find(id).status).to eq("claimed")
    end
  end

  describe "recurrence" do
    it "reschedules a recurring job to its next occurrence instead of finishing" do
      runs = []
      sched = service
      sched.register("beat") { |job| runs << job.run_at }
      id = sched.schedule(kind: "beat", run_at: base, payload: {}, recurrence: 60)

      sched.run_due(now: base)

      row = store.find(id)
      expect(row.status).to eq("pending")
      expect(row.run_at.to_i).to be_within(1).of((base + 60).to_i)
      expect(runs.size).to eq(1)
    end

    it "fires again on the next occurrence" do
      count = 0
      sched = service
      sched.register("beat") { count += 1 }
      sched.schedule(kind: "beat", run_at: base, recurrence: 60)

      sched.run_due(now: base)          # first occurrence, reschedules to base+60
      sched.run_due(now: base + 60)     # next occurrence
      expect(count).to eq(2)
    end

    it "rolls a recurring job forward past occurrences missed during downtime" do
      count = 0
      sched = service
      sched.register("beat") { count += 1 }
      id = sched.schedule(kind: "beat", run_at: base, recurrence: 60)

      # 10 intervals have elapsed, so it runs once and moves to the next slot.
      sched.run_due(now: base + 605)
      expect(count).to eq(1)
      row = store.find(id)
      expect(row.run_at.to_i).to be_within(1).of((base + 660).to_i)
    end
  end

  describe "failure handling" do
    it "retries a failing job with a backoff, then marks it failed at the bound" do
      attempts = 0
      sched = service(clock: -> { base }, max_attempts: 3, retry_backoff: 1)
      sched.register("boom") { attempts += 1; raise "nope" }
      id = sched.schedule(kind: "boom", run_at: base)

      # Each drain past the backoff makes one attempt.
      sched.run_due(now: base)
      expect(store.find(id).status).to eq("pending")
      expect(store.find(id).attempts).to eq(1)

      sched.run_due(now: base + 100)
      expect(store.find(id).attempts).to eq(2)

      sched.run_due(now: base + 200)
      expect(store.find(id).status).to eq("failed")
      expect(store.find(id).attempts).to eq(3)
      expect(attempts).to eq(3)
    end

    it "does not retry a failed attempt within the same drain (the backoff is in the future)" do
      attempts = 0
      sched = service(max_attempts: 5, retry_backoff: 10)
      sched.register("boom") { attempts += 1; raise "nope" }
      sched.schedule(kind: "boom", run_at: base)

      sched.run_due(now: base)
      expect(attempts).to eq(1)
    end

    it "scrubs a marked payload once a failing job is permanently failed" do
      sched = service(max_attempts: 1, retry_backoff: 1)
      sched.register("boom") { raise "nope" }
      id = sched.schedule(kind: "boom", run_at: base, payload: { "text" => "private" }, discard_payload: true)

      sched.run_due(now: base)

      expect(store.find(id).status).to eq("failed")
      expect(store.find(id).payload).to eq({})
    end

    # The ladder is for a fault that may clear. A request the far end refused
    # on its merits gets the same refusal back every time, so five attempts
    # with backoff are five wasted round trips at that end's expense.
    it "settles a job at once when its handler calls the failure permanent" do
      attempts = 0
      refused = Class.new(StandardError) { def permanent? = true }
      sched = service(max_attempts: 5, retry_backoff: 1)
      sched.register("boom") { attempts += 1; raise refused, "refused on its merits" }
      id = sched.schedule(kind: "boom", run_at: base)

      sched.run_due(now: base)
      sched.run_due(now: base + 100)

      expect(store.find(id).status).to eq("failed")
      expect(store.find(id).attempts).to eq(1)
      expect(attempts).to eq(1)
    end

    # Nothing else in the codebase answers the predicate, so the default has
    # to stay "climb the ladder" for every error that says nothing about it.
    it "still climbs the ladder for a handler error that says nothing about being permanent" do
      sched = service(max_attempts: 5, retry_backoff: 1)
      sched.register("boom") { raise "nope" }
      id = sched.schedule(kind: "boom", run_at: base)

      sched.run_due(now: base)

      expect(store.find(id).status).to eq("pending")
    end

    it "fails a job whose kind has no registered handler after the retry bound" do
      sched = service(max_attempts: 2, retry_backoff: 1)
      id = sched.schedule(kind: "unregistered", run_at: base)

      sched.run_due(now: base)
      sched.run_due(now: base + 100)
      expect(store.find(id).status).to eq("failed")
    end
  end

  # max_age is opt-in per kind: a kind that never sets it keeps running no
  # matter how overdue, exactly as every kind behaved before this option
  # existed.
  describe "a kind registered with max_age" do
    it "runs the handler normally for a job still within the max_age window" do
      ran = []
      sched = service
      sched.register("expiring", max_age: 100) { |job| ran << job.id }
      id = sched.schedule(kind: "expiring", run_at: base)

      sched.run_due(now: base + 50)

      expect(ran).to eq([id])
      expect(store.find(id).status).to eq("done")
    end

    it "discards a job past its max_age without ever calling the handler, settling it as done" do
      ran = []
      sched = service
      sched.register("expiring", max_age: 100) { |job| ran << job.id }
      id = sched.schedule(kind: "expiring", run_at: base)

      sched.run_due(now: base + 1000)

      expect(ran).to be_empty
      expect(store.find(id).status).to eq("done")
    end

    it "runs a job no matter how far past due when its kind has no max_age registered" do
      ran = []
      sched = service
      sched.register("unbounded") { |job| ran << job.id }
      id = sched.schedule(kind: "unbounded", run_at: base)

      sched.run_due(now: base + 1_000_000)

      expect(ran).to eq([id])
      expect(store.find(id).status).to eq("done")
    end

    # A discard settles as a success, so without this hook the one outcome a
    # reader most wants to know about leaves nothing behind but a log line.
    it "tells a listener which job it dropped" do
      dropped = []
      sched = service(on_discard: ->(job) { dropped << [job.kind, job.community] })
      sched.register("expiring", max_age: 100) { raise "should never run" }
      sched.schedule(kind: "expiring", run_at: base, community: "sample")

      sched.run_due(now: base + 1000)

      expect(dropped).to eq([["expiring", "sample"]])
    end

    it "tells no listener about a job that ran normally" do
      dropped = []
      sched = service(on_discard: ->(job) { dropped << job.id })
      sched.register("expiring", max_age: 100) { nil }
      sched.schedule(kind: "expiring", run_at: base)

      sched.run_due(now: base + 50)

      expect(dropped).to be_empty
    end

    it "settles the job anyway when the listener raises" do
      sched = service(on_discard: ->(_job) { raise "the rollup is down" })
      sched.register("expiring", max_age: 100) { raise "should never run" }
      id = sched.schedule(kind: "expiring", run_at: base)

      sched.run_due(now: base + 1000)

      expect(store.find(id).status).to eq("done")
    end

    it "logs how overdue a discarded job was, instead of running it" do
      logs = StringIO.new
      sched = described_class.new(
        store: store, session_id: "live", logger: Rubotty::Log.build(level: "info", io: logs), clock: -> { base }
      )
      sched.register("expiring", max_age: 100) { raise "should never run" }
      sched.schedule(kind: "expiring", run_at: base)

      sched.run_due(now: base + 1000)

      expect(logs.string).to include("expiring")
      expect(logs.string).to include("discarding without running")
    end
  end

  # #claim_next is already a compare-and-swap, so no two sessions run the same
  # row even unlocked. The advisory lock adds only that two live processes do
  # not hammer the same due window at once, and it is taken around the claim
  # rather than around the handler that follows it.
  describe "cross-process mutual exclusion via the advisory lock" do
    it "takes the run lock, by name, to claim each job" do
      names = []
      allow(store).to receive(:with_advisory_lock).and_wrap_original do |original, name, **kwargs, &block|
        names << name
        original.call(name, **kwargs, &block)
      end
      sched = service
      sched.register("noop") { nil }
      sched.schedule(kind: "noop", run_at: base)

      sched.run_due(now: base)

      expect(names.uniq).to eq([described_class::RUN_LOCK_NAME])
    end

    # The point of the whole arrangement: the lock is released before the
    # handler runs, so one slow handler cannot hold up any other job.
    it "has released the run lock by the time a handler runs" do
      held = false
      held_during_handler = nil
      allow(store).to receive(:with_advisory_lock).and_wrap_original do |original, name, **kwargs, &block|
        original.call(name, **kwargs) do
          held = true
          begin
            block.call
          ensure
            held = false
          end
        end
      end
      sched = service
      sched.register("noop") { held_during_handler = held }
      sched.schedule(kind: "noop", run_at: base)

      sched.run_due(now: base)

      expect(held_during_handler).to be(false)
    end

    # Two distinct names, so a recovery pass and the drain it calls internally
    # never take the same lock from one call stack.
    it "takes a distinct recovery lock, then the run lock, during recovery" do
      names = []
      allow(store).to receive(:with_advisory_lock).and_wrap_original do |original, name, **kwargs, &block|
        names << name
        original.call(name, **kwargs, &block)
      end

      service.recover(alive_session_ids: ["live"], now: base)

      expect(names).to eq([described_class::RECOVER_LOCK_NAME, described_class::RUN_LOCK_NAME])
    end

    # A session that loses the lock race treats LockUnavailable as nothing to
    # do this pass, leaving the job for the lock holder or its own next tick.
    it "skips this pass, without running anything or raising, when the run lock is already held" do
      allow(store).to receive(:with_advisory_lock).and_raise(Rubotty::LockUnavailable, "busy")
      ran = []
      sched = service
      sched.register("noop") { |job| ran << job.id }
      id = sched.schedule(kind: "noop", run_at: base)

      expect(sched.run_due(now: base)).to eq(0)

      expect(ran).to be_empty
      expect(store.find(id).status).to eq("pending")
    end

    it "does the same for a recovery pass that cannot get its lock" do
      allow(store).to receive(:with_advisory_lock).and_raise(Rubotty::LockUnavailable, "busy")
      expect(service.recover(alive_session_ids: ["live"], now: base)).to eq(0)
    end

    # The bug this file exists to keep fixed: a content policy handler waiting
    # on the model endpoint used to hold the run lock, so every other kind of
    # job in the deployment queued behind it.
    it "lets another session claim and run a second due job while a slow handler is still going" do
      entered = Queue.new
      release = Queue.new
      executed = []

      a = service(session_id: "a")
      b = service(session_id: "b")
      a.register("slow") { entered << :in; release.pop(timeout: WAIT) }
      b.register("quick") { |job| executed << job.id }
      a.schedule(kind: "slow", run_at: base)
      quick_id = a.schedule(kind: "quick", run_at: base)

      thread = Thread.new { a.run_due(now: base) }
      entered.pop(timeout: WAIT) # a is inside the slow handler, holding no lock while it waits

      expect(b.run_due(now: base)).to eq(1)
      expect(executed).to eq([quick_id])

      release << :go
      thread.join(WAIT)
    end

    # Two sessions draining the same backlog at once. The compare-and-swap in
    # claim_next, not the lock, is what makes each job run exactly once.
    it "runs each due job exactly once when two sessions drain the same backlog" do
      guard = Mutex.new
      executed = []
      ids = []

      a = service(session_id: "a")
      b = service(session_id: "b")
      [a, b].each do |sched|
        sched.register("shared") { |job| guard.synchronize { executed << job.id } }
      end
      20.times { ids << a.schedule(kind: "shared", run_at: base) }

      threads = [a, b].map { |sched| Thread.new { sched.run_due(now: base) } }
      threads.each { |t| t.join(WAIT) }

      expect(executed.sort).to eq(ids.sort)
    end
  end

  # A handler no longer runs under the drain lock, so a reclaim sweep in
  # another process can reach a row whose handler is still working. The claim
  # is refreshed underneath a running handler so that sweep leaves it alone.
  describe "keeping a running handler's claim fresh" do
    it "does not touch the claim for a handler that finishes inside one refresh interval" do
      allow(store).to receive(:touch_claim).and_call_original
      sched = service(lease: 300)
      sched.register("quick") { nil }
      sched.schedule(kind: "quick", run_at: base)

      sched.run_due(now: base)

      expect(store).not_to have_received(:touch_claim)
    end

    it "refreshes a slow handler's claim, so a lease sweep does not reclaim it mid-flight" do
      now = base
      entered = Queue.new
      release = Queue.new
      runs = []
      sched = service(session_id: "a", clock: -> { now }, lease: 0.3)
      sched.register("slow") { |job| runs << job.id; entered << :in; release.pop(timeout: WAIT) }
      id = sched.schedule(kind: "slow", run_at: base)

      thread = Thread.new { sched.run_due(now: base) }
      entered.pop(timeout: WAIT)
      # The handler is now a minute in, far past a 0.3s lease.
      now = base + 60
      wait_for("the claim to be refreshed") { store.find(id).claimed_at.to_i >= (base + 60).to_i }

      # What a second process's tick would do while this handler still runs.
      expect(store.reclaim_stale(now: now, lease: 0.3)).to eq(0)

      release << :go
      thread.join(WAIT)
      expect(runs.size).to eq(1)
      expect(store.find(id).status).to eq("done")
    end

    it "says so and stops refreshing when the claim has gone to someone else" do
      logs = StringIO.new
      now = base
      touched = Queue.new
      release = Queue.new
      allow(store).to receive(:touch_claim) { touched << :lost; 0 }
      sched = described_class.new(
        store: store, session_id: "a", logger: Rubotty::Log.build(level: "warn", io: logs),
        clock: -> { now }, lease: 0.3
      )
      sched.register("slow") { release.pop(timeout: WAIT) }
      sched.schedule(kind: "slow", run_at: base)

      thread = Thread.new { sched.run_due(now: base) }
      touched.pop(timeout: WAIT)
      release << :go
      thread.join(WAIT)

      expect(logs.string).to include("lost its claim while its handler was still running")
      expect(store).to have_received(:touch_claim).once
    end
  end

  describe "the worker loop" do
    it "reports whether it is running and stops cleanly, tolerating a double call" do
      sched = service
      sched.start
      expect(sched.running?).to be(true)
      sched.start
      sched.stop
      expect(sched.running?).to be(false)
      expect { sched.stop }.not_to raise_error
    end

    it "is safe to stop when never started" do
      expect { service.stop }.not_to raise_error
    end
  end

  describe "with the Null store" do
    subject(:sched) do
      described_class.new(
        store: Rubotty::Core::DurableSchedulerStore::Null.new,
        session_id: "live", logger: Rubotty::Log.null, clock: -> { base }
      )
    end

    it "schedules to nothing and runs nothing" do
      sched.register("noop") { raise "should never run" }
      expect(sched.schedule(kind: "noop", run_at: base)).to be_nil
      expect(sched.run_due(now: base)).to eq(0)
      expect(sched.recover(alive_session_ids: ["live"], now: base)).to eq(0)
    end

    it "starts no worker thread on a non-durable store" do
      sched.start
      expect(sched.running?).to be(false)
    end
  end

  # A kind declares what it is worth where it declares its max age, and the
  # scheduler stamps that on every row it enqueues for that kind.
  describe "priority" do
    it "stamps a registered kind's priority onto the row it enqueues" do
      sched = service
      sched.register("policy", priority: described_class::PRIORITY_HIGH) { nil }
      id = sched.schedule(kind: "policy", run_at: base)

      expect(store.find(id).priority).to eq(described_class::PRIORITY_HIGH)
    end

    it "gives a kind that never named one the default" do
      sched = service
      sched.register("housekeeping") { nil }

      expect(sched.priority_for("housekeeping")).to eq(described_class::PRIORITY_DEFAULT)
      expect(store.find(sched.schedule(kind: "housekeeping", run_at: base)).priority).to eq(0)
    end

    it "answers the default for a kind nobody registered" do
      expect(service.priority_for("nothing-here")).to eq(described_class::PRIORITY_DEFAULT)
    end

    # The ordering that makes a moderation check jump a topic routing backlog.
    it "runs the higher priority kind first even where the other is older" do
      ran = []
      sched = service
      sched.register("topic") { |job| ran << job.kind }
      sched.register("policy", priority: described_class::PRIORITY_HIGH) { |job| ran << job.kind }
      sched.schedule(kind: "topic", run_at: base - 600)
      sched.schedule(kind: "policy", run_at: base - 1)

      sched.run_due(now: base)

      expect(ran).to eq(%w[policy topic])
    end

    # Priority ordering alone still leaves one thread, so the reserved worker
    # takes high priority work and nothing else.
    it "drains only high priority work under the reserved floor" do
      ran = []
      sched = service
      sched.register("topic") { |job| ran << job.kind }
      sched.register("policy", priority: described_class::PRIORITY_HIGH) { |job| ran << job.kind }
      sched.schedule(kind: "topic", run_at: base - 600)
      sched.schedule(kind: "policy", run_at: base - 1)

      sched.send(:reserved_tick_once)

      expect(ran).to eq(%w[policy])
    end
  end
end
