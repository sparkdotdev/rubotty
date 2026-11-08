# frozen_string_literal: true

require "spec_helper"
require "sequel"

# #cancel narrows to the subset a block identifies from each job's own payload,
# so cancelling one event's reminders never disturbs a sibling event's.
RSpec.describe "durable scheduler cancel", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

  before { Rubotty::ControlPlane::Migrator.run(db) }

  describe Rubotty::Core::DurableSchedulerStore::Sequel do
    it "deletes only the pending jobs of the kind whose payload the block accepts" do
      store.enqueue(kind: "event_reminder", run_at: Time.now, payload: { "event_id" => 1 })
      store.enqueue(kind: "event_reminder", run_at: Time.now, payload: { "event_id" => 1 })
      store.enqueue(kind: "event_reminder", run_at: Time.now, payload: { "event_id" => 2 })

      deleted = store.delete_pending_matching(kind: "event_reminder",
                                              community: nil) { |payload| payload["event_id"] == 1 }
      expect(deleted).to eq(2)
      remaining = db[:scheduled_jobs].where(kind: "event_reminder").all
      expect(remaining.size).to eq(1)
      expect(JSON.parse(remaining.first[:payload])["event_id"]).to eq(2)
    end

    it "scopes to a community when one is given" do
      store.enqueue(kind: "event_reminder", run_at: Time.now, community: "a", payload: { "event_id" => 1 })
      store.enqueue(kind: "event_reminder", run_at: Time.now, community: "b", payload: { "event_id" => 1 })

      deleted = store.delete_pending_matching(kind: "event_reminder", community: "a") { |payload| payload["event_id"] == 1 }
      expect(deleted).to eq(1)
      expect(db[:scheduled_jobs].count).to eq(1)
    end

    it "never removes a claimed job, only pending ones" do
      id = store.enqueue(kind: "event_reminder", run_at: Time.now - 1, payload: { "event_id" => 1 })
      store.claim_next(now: Time.now, session_id: "s")
      deleted = store.delete_pending_matching(kind: "event_reminder",
                                              community: nil) { |payload| payload["event_id"] == 1 }
      expect(deleted).to eq(0)
      expect(store.find(id).status).to eq("claimed")
    end

    it "matches nothing when the block accepts nothing" do
      store.enqueue(kind: "event_reminder", run_at: Time.now, payload: { "event_id" => 1 })
      expect(store.delete_pending_matching(kind: "event_reminder", community: nil) { |_payload| false }).to eq(0)
    end

    # Inverted from an omitted keyword meaning every tenant: nil still does,
    # but it has to be written, so a caller that forgot gets an error.
    it "refuses to guess when the community keyword is omitted altogether" do
      expect { store.delete_pending_matching(kind: "event_reminder") { true } }.to raise_error(ArgumentError)
    end
  end

  describe Rubotty::Core::DurableSchedulerStore::Null do
    it "no-ops" do
      expect(described_class.new.delete_pending_matching(kind: "event_reminder", community: nil) { true }).to eq(0)
    end
  end

  describe Rubotty::Core::DurableScheduler do
    subject(:scheduler) { described_class.new(store: store, session_id: "s", logger: Rubotty::Log.null) }

    it "cancels through the store and returns the count, leaving another id's jobs alone" do
      scheduler.schedule(kind: "event_reminder", run_at: Time.now + 100, payload: { "event_id" => 1 })
      scheduler.schedule(kind: "event_reminder", run_at: Time.now + 200, payload: { "event_id" => 1 })
      scheduler.schedule(kind: "event_reminder", run_at: Time.now + 100, payload: { "event_id" => 2 })

      cancelled = scheduler.cancel(kind: "event_reminder",
                                   every_community: true) { |payload| payload["event_id"] == 1 }
      expect(cancelled).to eq(2)
      expect(scheduler.pending).to eq(1)
    end

    # Issue #1792, the sibling of the forget spec's own inversion.
    it "refuses a cancel that names no community at all" do
      expect { scheduler.cancel(kind: "event_reminder") { true } }
        .to raise_error(ArgumentError, /needs a community/)
    end

    it "refuses a community and a deployment-wide sweep together" do
      expect { scheduler.cancel(kind: "event_reminder", community: "a", every_community: true) { true } }
        .to raise_error(ArgumentError, /never both/)
    end
  end
end
