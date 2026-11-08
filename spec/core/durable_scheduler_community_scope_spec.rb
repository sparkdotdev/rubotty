# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Issue #1792. #forget and #cancel both defaulted community to nil and the
# store turned that into no community predicate at all, so a per-tenant caller
# that forgot the keyword wiped every community's pending jobs of that kind
# with no error and no log.
RSpec.describe Rubotty::Core::DurableScheduler, "scoping a delete to one tenant" do
  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:alpha) { CollidingCommunities::ALPHA[:slug] }
  let(:beta) { CollidingCommunities::BETA[:slug] }

  subject(:scheduler) { described_class.new(store: store, session_id: "s", logger: Rubotty::Log.null) }

  before do
    Rubotty::ControlPlane::Migrator.run(db)
    [alpha, beta].each do |slug|
      scheduler.schedule(kind: "watch_expiry", run_at: Time.now + 100, community: slug,
                         payload: { "watch_id" => 1 })
    end
  end

  def pending_communities
    db[:scheduled_jobs].where(kind: "watch_expiry").select_map(:community).sort
  end

  it "forgets one community's jobs and leaves the other tenant's standing" do
    expect(scheduler.forget(kind: "watch_expiry", community: alpha)).to eq(1)

    expect(pending_communities).to eq([beta])
  end

  it "cancels one community's matching jobs and leaves the other tenant's standing" do
    cancelled = scheduler.cancel(kind: "watch_expiry", community: alpha) { |payload| payload["watch_id"] == 1 }

    expect(cancelled).to eq(1)
    expect(pending_communities).to eq([beta])
  end

  # The dangerous default the issue is about: a caller meaning one tenant and
  # forgetting the keyword used to take both. Now it takes neither.
  it "takes nothing from either tenant when a forget names no community" do
    expect { scheduler.forget(kind: "watch_expiry") }.to raise_error(ArgumentError)

    expect(pending_communities).to eq([alpha, beta])
  end

  it "takes nothing from either tenant when a cancel names no community" do
    expect { scheduler.cancel(kind: "watch_expiry") { true } }.to raise_error(ArgumentError)

    expect(pending_communities).to eq([alpha, beta])
  end

  it "still sweeps the whole deployment when that is asked for by name" do
    expect(scheduler.forget(kind: "watch_expiry", every_community: true)).to eq(2)

    expect(pending_communities).to be_empty
  end

  it "sweeps the whole deployment on a cancel asked for the same way" do
    cancelled = scheduler.cancel(kind: "watch_expiry", every_community: true) { true }

    expect(cancelled).to eq(2)
    expect(pending_communities).to be_empty
  end

  # A slug naming no tenant deletes nothing rather than falling back to all.
  it "takes nothing for a community that owns none of these jobs" do
    expect(scheduler.forget(kind: "watch_expiry", community: "ghost")).to be_zero

    expect(pending_communities).to eq([alpha, beta])
  end
end
