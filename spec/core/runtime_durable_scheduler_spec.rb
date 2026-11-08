# frozen_string_literal: true

require "spec_helper"

# The wiring is exercised directly rather than through a full #start, which
# would bring up real adapters.
RSpec.describe Rubotty::Core::Runtime, "durable scheduler wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store:, env: ControlPlaneHelpers::CONFIG_ENV)
    described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env).build
  end

  describe "construction" do
    it "builds a durable scheduler with a durable store on a Sequel-backed backend" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.durable_scheduler).to be_a(Rubotty::Core::DurableScheduler)
      expect(runtime.durable_scheduler.store.durable?).to be(true)
    end

    # The memory backend has no database, so the durable half degrades to a
    # no-op store the caller need not special-case.
    it "builds a durable scheduler over a Null store on a backend with no database" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.durable_scheduler).to be_a(Rubotty::Core::DurableScheduler)
      expect(runtime.durable_scheduler.store.durable?).to be(false)
    end

    it "stamps the scheduler with the runtime's own session id" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.durable_scheduler.session_id).to eq(runtime.session_id)
    end
  end

  describe "warnings ladder wiring (issue #46)" do
    it "builds the shared warnings service on a durable backend" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.warnings).to be_a(Rubotty::Core::Warnings::Service)
    ensure
      runtime&.durable_scheduler&.stop
    end

    # Registered before boot recovery runs, so a temp-mute or temp-ban that
    # lapsed during downtime is reversed on the next start.
    it "registers the expire_sanction handler on the durable scheduler" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.durable_scheduler.handler?(Rubotty::Core::Warnings::EXPIRE_KIND)).to be(true)
    ensure
      runtime&.durable_scheduler&.stop
    end

    # Registered the same way, before boot recovery runs, so a warning's own
    # decay carries on across a restart just like a sanction's expiry does.
    it "registers the expire_warning (decay) handler on the durable scheduler" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.durable_scheduler.handler?(Rubotty::Core::Warnings::DECAY_KIND)).to be(true)
    ensure
      runtime&.durable_scheduler&.stop
    end
  end

  # The board lives in the dashboard, which holds no adapters, so the handlers
  # that need one are registered only here.
  describe "pending-space wiring (issue #584)" do
    it "registers both the auto-leave and the post-approval sweep handlers" do
      runtime = build_runtime(store: sequel_store)
      scheduler = runtime.durable_scheduler
      expect(scheduler.handler?(Rubotty::ControlPlane::PendingSpaces::EXPIRE_KIND)).to be(true)
      expect(scheduler.handler?(Rubotty::ControlPlane::PendingSpaces::ENUMERATE_KIND)).to be(true)
    ensure
      runtime&.durable_scheduler&.stop
    end
  end

  describe "ephemeral-message wiring (issue #65, #194)" do
    # Registered before boot recovery too, so a scheduled delete survives losing
    # its in-process timer to a crash or a redeploy mid delete_after window.
    it "registers the ephemeral delete handler on the durable scheduler" do
      runtime = build_runtime(store: sequel_store)
      expect(runtime.durable_scheduler.handler?(Rubotty::Core::EphemeralMessage::DELETE_KIND)).to be(true)
    ensure
      runtime&.durable_scheduler&.stop
    end

    # The ephemeral primitive still has to accept the Null store, keeping its
    # in-process and next-boot-sweep guarantees.
    it "builds the ephemeral primitive without raising on a backend with no database" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      expect(runtime.ephemeral).to be_a(Rubotty::Core::EphemeralMessage)
    end
  end

  describe "boot recovery" do
    # The built-in noop handler, so no feature has to be present to prove the loop.
    it "reclaims a dead prior session's claim and runs the due job" do
      runtime = build_runtime(store: sequel_store)
      store = runtime.durable_scheduler.store

      id = store.enqueue(kind: Rubotty::Core::DurableScheduler::NOOP_KIND,
                         run_at: Time.now - Rubotty::Core::DurableScheduler::DEFAULT_LEASE - 60)
      store.claim_next(now: Time.now - Rubotty::Core::DurableScheduler::DEFAULT_LEASE - 1,
                       session_id: "a-dead-session")
      expect(store.count(status: "claimed")).to eq(1)

      runtime.send(:recover_durable_scheduler)

      expect(store.find(id).status).to eq("done")
    ensure
      runtime&.durable_scheduler&.stop
    end

    it "starts the worker after recovery on a durable backend" do
      runtime = build_runtime(store: sequel_store)
      runtime.send(:recover_durable_scheduler)
      expect(runtime.durable_scheduler.running?).to be(true)
    ensure
      runtime&.durable_scheduler&.stop
    end

    it "starts no worker on a backend with no database" do
      runtime = build_runtime(store: Rubotty::Storage::Memory.new)
      runtime.send(:recover_durable_scheduler)
      expect(runtime.durable_scheduler.running?).to be(false)
    end
  end
end
