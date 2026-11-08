# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The forget path the scheduled announcements reconcile through: clear a
# community's pending jobs of a kind, then re-enqueue from config.
RSpec.describe "durable scheduler forget", :control_plane do
  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

  before { Rubotty::ControlPlane::Migrator.run(db) }

  describe Rubotty::Core::DurableSchedulerStore::Sequel do
    it "deletes only pending jobs of the kind, scoped to a community" do
      store.enqueue(kind: "announcement", run_at: Time.now, community: "a")
      store.enqueue(kind: "announcement", run_at: Time.now, community: "b")
      store.enqueue(kind: "other", run_at: Time.now, community: "a")

      expect(store.delete_pending(kind: "announcement", community: "a")).to eq(1)
      expect(store.count).to eq(2)
    end

    # Inverted from "when no community is given": the store still deletes
    # every tenant's rows for a nil, but nil now has to be written out, so a
    # caller that simply forgot the keyword gets an ArgumentError instead.
    it "deletes every community's pending jobs of the kind for an explicit nil community" do
      store.enqueue(kind: "announcement", run_at: Time.now, community: "a")
      store.enqueue(kind: "announcement", run_at: Time.now, community: "b")
      expect(store.delete_pending(kind: "announcement", community: nil)).to eq(2)
    end

    it "refuses to guess when the community keyword is omitted altogether" do
      expect { store.delete_pending(kind: "announcement") }.to raise_error(ArgumentError)
    end

    it "never removes a claimed job, only pending ones" do
      id = store.enqueue(kind: "announcement", run_at: Time.now - 1, community: "a")
      store.claim_next(now: Time.now, session_id: "s")
      expect(store.delete_pending(kind: "announcement", community: nil)).to eq(0)
      expect(store.find(id).status).to eq("claimed")
    end
  end

  describe Rubotty::Core::DurableSchedulerStore::Null do
    it "no-ops" do
      expect(described_class.new.delete_pending(kind: "announcement", community: "a")).to eq(0)
    end
  end

  describe Rubotty::Core::DurableScheduler do
    subject(:scheduler) { described_class.new(store: store, session_id: "s", logger: Rubotty::Log.null) }

    it "forgets pending jobs through the store and returns the count" do
      scheduler.schedule(kind: "announcement", run_at: Time.now + 100, community: "a")
      scheduler.schedule(kind: "announcement", run_at: Time.now + 100, community: "a")
      expect(scheduler.forget(kind: "announcement", community: "a")).to eq(2)
      expect(scheduler.pending).to eq(0)
    end

    # Issue #1792. Omitting the keyword used to widen the delete to every
    # tenant, which made the dangerous call the shorter one to write.
    it "refuses a forget that names no community at all" do
      expect { scheduler.forget(kind: "announcement") }
        .to raise_error(ArgumentError, /needs a community/)
    end

    it "sweeps every community only when asked for by name" do
      scheduler.schedule(kind: "announcement", run_at: Time.now + 100, community: "a")
      scheduler.schedule(kind: "announcement", run_at: Time.now + 100, community: "b")
      expect(scheduler.forget(kind: "announcement", every_community: true)).to eq(2)
    end

    it "refuses a community and a deployment-wide sweep together, which cannot both be meant" do
      expect { scheduler.forget(kind: "announcement", community: "a", every_community: true) }
        .to raise_error(ArgumentError, /never both/)
    end
  end
end
