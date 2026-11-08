# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Driven against a real in-memory SQLite control plane, so the SQL is exercised
# rather than mocked.
RSpec.describe Rubotty::Core::DurableSchedulerStore do
  let(:db) do
    database = Sequel.sqlite
    Rubotty::ControlPlane.migrate!(database)
    database
  end
  let(:store) { described_class::Sequel.new(db: db) }
  let(:base) { Time.now }

  describe ".for" do
    it "chooses the Sequel store for a backend that exposes a database" do
      storage = instance_double("storage", db: db)
      expect(described_class.for(storage)).to be_a(described_class::Sequel)
    end

    it "chooses the Null store for a backend with no database" do
      storage = Object.new
      expect(described_class.for(storage)).to be_a(described_class::Null)
    end
  end

  describe "#enqueue" do
    it "persists a pending job and returns its id" do
      id = store.enqueue(kind: "greet", run_at: base + 60, payload: { "who" => "ada" }, community: "sample")
      row = store.find(id)

      expect(row.kind).to eq("greet")
      expect(row.status).to eq("pending")
      expect(row.attempts).to eq(0)
      expect(row.community).to eq("sample")
      expect(row.payload).to eq({ "who" => "ada" })
    end

    it "stores a global job with a nil community and a one-shot with no recurrence" do
      id = store.enqueue(kind: "noop", run_at: base)
      row = store.find(id)
      expect(row.community).to be_nil
      expect(row.recurrence).to be_nil
      expect(row.payload).to eq({})
    end
  end

  describe "#claim_next" do
    it "returns nil when nothing is due yet" do
      store.enqueue(kind: "noop", run_at: base + 60)
      expect(store.claim_next(now: base, session_id: "s1")).to be_nil
    end

    it "claims the soonest due job, flipping it to claimed under the session" do
      store.enqueue(kind: "late", run_at: base + 5)
      early = store.enqueue(kind: "early", run_at: base - 5)

      job = store.claim_next(now: base, session_id: "s1")

      expect(job.id).to eq(early)
      expect(job.kind).to eq("early")
      persisted = store.find(early)
      expect(persisted.status).to eq("claimed")
      expect(persisted.claimed_by).to eq("s1")
    end

    # The compare-and-swap on status is what keeps two workers, or two drains,
    # from running the same job.
    it "does not re-claim a job it already claimed" do
      store.enqueue(kind: "noop", run_at: base - 1)
      first = store.claim_next(now: base, session_id: "s1")
      second = store.claim_next(now: base, session_id: "s1")

      expect(first).not_to be_nil
      expect(second).to be_nil
    end

    it "claims due jobs oldest first across successive calls" do
      store.enqueue(kind: "a", run_at: base - 10)
      store.enqueue(kind: "b", run_at: base - 5)

      expect(store.claim_next(now: base, session_id: "s1").kind).to eq("a")
      expect(store.claim_next(now: base, session_id: "s1").kind).to eq("b")
    end

    # A moderation check queued behind a backlog of topic routing checks is
    # what run_at alone gave, and each of those blocks on a model call.
    it "takes the higher priority job first, even where a lower one is older" do
      store.enqueue(kind: "topic", run_at: base - 600)
      store.enqueue(kind: "policy", run_at: base - 1, priority: 10)

      expect(store.claim_next(now: base, session_id: "s1").kind).to eq("policy")
      expect(store.claim_next(now: base, session_id: "s1").kind).to eq("topic")
    end

    it "still orders by run_at within one priority" do
      store.enqueue(kind: "b", run_at: base - 5, priority: 10)
      store.enqueue(kind: "a", run_at: base - 10, priority: 10)

      expect(store.claim_next(now: base, session_id: "s1").kind).to eq("a")
      expect(store.claim_next(now: base, session_id: "s1").kind).to eq("b")
    end

    it "defaults a job with no priority to the bottom of the order" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      expect(store.find(id).priority).to eq(0)
    end

    # What the reserved worker leans on: it may take high priority work and
    # nothing else, so a low priority backlog can never occupy both workers.
    it "claims nothing below a min_priority floor" do
      store.enqueue(kind: "topic", run_at: base - 600)

      expect(store.claim_next(now: base, session_id: "s1", min_priority: 10)).to be_nil
    end

    it "claims at or above the floor" do
      store.enqueue(kind: "policy", run_at: base - 1, priority: 10)

      expect(store.claim_next(now: base, session_id: "s1", min_priority: 10).kind).to eq("policy")
    end
  end

  # The log ring buffer is cleared by the restart a stopped feature outlives,
  # so the reason has to live on the row for an operator to read it later.
  describe "#mark_failed and #recent_failures" do
    it "keeps the reason and the moment on the row" do
      id = store.enqueue(kind: "policy", run_at: base - 1)
      store.mark_failed(id, attempts: 5, reason: "OpenArc refused the call", now: base)

      row = store.find(id)
      expect(row.status).to eq("failed")
      expect(row.failed_reason).to eq("OpenArc refused the call")
      expect(row.failed_at).to be_within(1).of(base)
    end

    it "reads failures back newest first" do
      old_id = store.enqueue(kind: "a", run_at: base - 10)
      new_id = store.enqueue(kind: "b", run_at: base - 5)
      store.mark_failed(old_id, attempts: 5, reason: "older", now: base - 60)
      store.mark_failed(new_id, attempts: 5, reason: "newer", now: base)

      expect(store.recent_failures.map(&:kind)).to eq(%w[b a])
    end

    it "narrows to a window" do
      id = store.enqueue(kind: "a", run_at: base - 10)
      store.mark_failed(id, attempts: 5, reason: "long ago", now: base - 7200)

      expect(store.recent_failures(since: base - 3600)).to be_empty
    end

    it "leaves out a job that has not failed" do
      store.enqueue(kind: "pending-one", run_at: base - 1)

      expect(store.recent_failures).to be_empty
    end

    # A runaway message must not bloat the row it is recorded on.
    it "caps a very long reason" do
      id = store.enqueue(kind: "a", run_at: base - 1)
      store.mark_failed(id, attempts: 5, reason: "x" * 2000, now: base)

      expect(store.find(id).failed_reason.length).to eq(described_class::Sequel::MAX_FAILED_REASON)
    end
  end

  # What a handler that outlives the lease leans on: the claim's clock moves
  # forward under it, so the sweep below has nothing to reclaim.
  describe "#touch_claim" do
    it "moves the holder's own claim forward and says it touched one row" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")

      expect(store.touch_claim(id, session_id: "s1", now: base + 120)).to eq(1)
      row = store.find(id)
      expect(row.status).to eq("claimed")
      expect(row.claimed_at.to_i).to be_within(1).of((base + 120).to_i)
    end

    it "refuses a session that does not hold the claim, leaving it as it was" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")

      expect(store.touch_claim(id, session_id: "s2", now: base + 120)).to eq(0)
      expect(store.find(id).claimed_at.to_i).to be_within(1).of(base.to_i)
    end

    # MariaDB reports zero changed rows for a write of the value already there,
    # which must not read as a claim this session has lost.
    it "still reports the claim held when a refresh writes the same instant twice" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")
      store.touch_claim(id, session_id: "s1", now: base + 120)

      expect(store.touch_claim(id, session_id: "s1", now: base + 120)).to eq(1)
    end

    it "refuses a row that is no longer claimed at all" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")
      store.complete(id)

      expect(store.touch_claim(id, session_id: "s1", now: base + 120)).to eq(0)
    end

    # The pairing that matters: a refreshed claim is no longer lease-expired.
    it "saves a refreshed claim from a lease sweep that would otherwise take it" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")
      store.touch_claim(id, session_id: "s1", now: base + 500)

      expect(store.reclaim_stale(now: base + 500, lease: 300)).to eq(0)
      expect(store.find(id).status).to eq("claimed")
    end
  end

  describe "#reclaim_stale" do
    # On boot the fresh session is the only one alive, so every claim a prior
    # session left is orphaned.
    it "resets a claim held by a session that is no longer alive" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "dead")

      reclaimed = store.reclaim_stale(now: base, alive_session_ids: ["live"])

      expect(reclaimed).to eq(1)
      row = store.find(id)
      expect(row.status).to eq("pending")
      expect(row.claimed_by).to be_nil
    end

    it "leaves a claim held by an alive session alone" do
      store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "live")

      expect(store.reclaim_stale(now: base, alive_session_ids: ["live"])).to eq(0)
    end

    # The lease is the other reclaim signal, usable without knowing the alive set.
    it "resets a claim older than the lease" do
      id = store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")

      reclaimed = store.reclaim_stale(now: base + 500, lease: 300)

      expect(reclaimed).to eq(1)
      expect(store.find(id).status).to eq("pending")
    end

    it "does not reclaim a claim still within its lease" do
      store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")

      expect(store.reclaim_stale(now: base + 100, lease: 300)).to eq(0)
    end

    it "does nothing when given neither a lease nor an alive set" do
      store.enqueue(kind: "noop", run_at: base - 1)
      store.claim_next(now: base, session_id: "s1")
      expect(store.reclaim_stale(now: base)).to eq(0)
    end
  end

  describe "settling a run" do
    it "marks a job done" do
      id = store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")
      store.complete(id)
      expect(store.find(id).status).to eq("done")
    end

    it "reschedules a recurring job back to pending at a new time, resetting attempts" do
      id = store.enqueue(kind: "noop", run_at: base, recurrence: "60")
      store.claim_next(now: base, session_id: "s1")
      store.reschedule(id, run_at: base + 60)

      row = store.find(id)
      expect(row.status).to eq("pending")
      expect(row.run_at.to_i).to be_within(1).of((base + 60).to_i)
      expect(row.attempts).to eq(0)
      expect(row.claimed_by).to be_nil
    end

    it "requeues a failed attempt with a bumped attempt count and a future time" do
      id = store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")
      store.retry_later(id, run_at: base + 10, attempts: 1)

      row = store.find(id)
      expect(row.status).to eq("pending")
      expect(row.attempts).to eq(1)
    end

    it "marks a job failed for good" do
      id = store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")
      store.mark_failed(id, attempts: 5)

      row = store.find(id)
      expect(row.status).to eq("failed")
      expect(row.attempts).to eq(5)
    end
  end

  # A connection that goes stale while the handler runs used to raise
  # StorageError straight out of a single unretried UPDATE, leaving the row
  # claimed and indistinguishable from a crashed worker. A second, unstubbed
  # store reads the row back here, since the stub below intercepts that too.
  describe "retrying a transient database error before giving up" do
    let(:reader) { store.class.new(db: db) }

    it "retries a completion write and lands it once the connection error clears" do
      id = store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")
      real_dataset = store.send(:dataset)
      failures = 0
      allow(store).to receive(:dataset) do
        failures += 1
        raise Sequel::DatabaseError, "MySQL server has gone away" if failures < 3

        real_dataset
      end

      store.complete(id)

      expect(failures).to eq(3)
      expect(reader.find(id).status).to eq("done")
    end

    it "raises StorageError once every retry is exhausted, leaving the row claimed" do
      id = store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")
      allow(store).to receive(:dataset).and_raise(Sequel::DatabaseError, "MySQL server has gone away")

      expect { store.complete(id) }.to raise_error(Rubotty::StorageError)
      expect(reader.find(id).status).to eq("claimed")
    end

    it "applies the same retry to mark_failed, the fallback the scheduler uses when complete keeps failing" do
      id = store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")
      real_dataset = store.send(:dataset)
      failures = 0
      allow(store).to receive(:dataset) do
        failures += 1
        raise Sequel::DatabaseError, "Lost connection to MySQL server during query" if failures < 2

        real_dataset
      end

      store.mark_failed(id, attempts: 1)

      expect(reader.find(id).status).to eq("failed")
    end
  end

  describe "#count" do
    it "counts by status" do
      store.enqueue(kind: "noop", run_at: base)
      store.enqueue(kind: "noop", run_at: base)
      store.claim_next(now: base, session_id: "s1")

      expect(store.count).to eq(2)
      expect(store.count(status: "pending")).to eq(1)
      expect(store.count(status: "claimed")).to eq(1)
    end
  end

  # The memory and pstore backends have no database, so the Null store keeps them
  # wholly unaffected.
  describe "the Null store" do
    subject(:null) { described_class::Null.new }

    it "reports it is not durable" do
      expect(null.durable?).to be(false)
    end

    it "no-ops every operation" do
      expect(null.enqueue(kind: "noop", run_at: Time.now)).to be_nil
      expect(null.claim_next(now: Time.now, session_id: "s")).to be_nil
      expect(null.touch_claim(1, session_id: "s", now: Time.now)).to eq(0)
      expect(null.reclaim_stale(now: Time.now, alive_session_ids: ["s"])).to eq(0)
      expect(null.count).to eq(0)
      expect(null.find(1)).to be_nil
      expect { null.complete(1) }.not_to raise_error
      expect { null.reschedule(1, run_at: Time.now) }.not_to raise_error
      expect { null.retry_later(1, run_at: Time.now, attempts: 1) }.not_to raise_error
      expect { null.mark_failed(1, attempts: 1) }.not_to raise_error
    end
  end
end
