# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Driven with fake adapters and an in-memory sqlite durable store, with a fake
# clock standing in for wall time.
RSpec.describe Rubotty::Core::EphemeralMessage do
  # Two endpoints on two distinct adapters, so "deleted on every platform" is a
  # claim about two independent records.
  let(:tg) { endpoint("tg", account: "a") }
  let(:dc) { endpoint("dc", account: "b") }
  let(:tg_adapter) { Fakes::ReactingAdapter.new }
  let(:dc_adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { { [:fake, "a"] => tg_adapter, [:fake, "b"] => dc_adapter } }
  let(:topo) { topology(room("r", tg, dc)) }

  let(:db) do
    database = Sequel.sqlite
    Rubotty::ControlPlane.migrate!(database)
    database
  end
  let(:store) { Rubotty::Core::EphemeralStore::Sequel.new(db: db) }

  let(:base) { Time.now }

  def service(session_id: "live", store: self.store, clock: -> { base })
    described_class.new(
      adapters: adapters, session_id: session_id, store: store, topology: topo,
      logger: Rubotty::Log.null, clock: clock
    )
  end

  subject(:ephemeral) { service }

  describe "the ack-act-edit-delete primitive" do
    it "posts one copy per endpoint, as the bot, under one group" do
      group = ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      expect(group.copies.size).to eq(2)
      expect(tg_adapter.delivered_to("tg").first.body.text).to eq("up")
      expect(dc_adapter.delivered_to("dc").first.body.text).to eq("up")
      expect(tg_adapter.delivered_to("tg").first.system_notice?).to be(true)
    end

    it "edits every copy to the result in place" do
      group = ephemeral.post(endpoints: [tg, dc], body: "working", name: "rubotty", delete_after: 30)
      group.edit("done")

      expect(tg_adapter.edited.last.last.body.text).to eq("done")
      expect(dc_adapter.edited.last.last.body.text).to eq("done")
    end

    it "self-deletes every copy when asked" do
      group = ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)
      group.delete_now

      expect(tg_adapter.deleted).to include(%w[tg d1])
      expect(dc_adapter.deleted).to include(%w[dc d1])
    end

    # The delay is the scheduler's job. This mirrors how the banner is wired:
    # schedule delete_now, advance the clock, and the group goes at once.
    it "removes the whole group on a single scheduled fire (the timed self-delete)" do
      now = base
      clock = -> { now }
      scheduler = Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock)
      group = ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      scheduler.after(30) { group.delete_now }
      expect(scheduler.pending).to eq(1)

      now += 30
      scheduler.run_due
      expect(tg_adapter.deleted).to include(%w[tg d1])
      expect(dc_adapter.deleted).to include(%w[dc d1])
    ensure
      scheduler&.stop
    end
  end

  describe "durable recording" do
    it "records one pending-deletion row per copy, all sharing a group id" do
      ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      expect(store.count).to eq(2)
      group_id = store.group_id_for(endpoint_id: "tg", native_id: "d1")
      expect(store.group_id_for(endpoint_id: "dc", native_id: "d1")).to eq(group_id)
    end

    it "records nothing when the message is meant to persist (delay 0)" do
      ephemeral.post(endpoints: [tg, dc], body: "summary", name: "rubotty", delete_after: 0)
      expect(store.count).to eq(0)
    end

    it "forgets the durable rows once the group self-deletes" do
      group = ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)
      group.delete_now
      expect(store.count).to eq(0)
    end

    # The seam moderation uses so a /delete on one copy reaches the others.
    # The message map has no banner row.
    it "resolves a copy's sibling id on another platform" do
      ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      sibling = ephemeral.sibling_native_id(ref: ref("tg", "d1"), endpoint_id: "dc")
      expect(sibling).to eq("d1")
    end

    it "returns nil for a message that is part of no group" do
      expect(ephemeral.sibling_native_id(ref: ref("tg", "nope"), endpoint_id: "dc")).to be_nil
    end
  end

  describe "when one endpoint refuses the post" do
    it "still posts, records and links the copies that landed" do
      tg_adapter.fail_next(Rubotty::AdapterError.new("kicked", adapter: :fake))
      group = ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      expect(group.copies.map { |c| c.endpoint.id }).to eq(["dc"])
      expect(store.count).to eq(1)
    end
  end

  describe "#sweep" do
    it "deletes every copy left by a session that is no longer alive" do
      service(session_id: "dead").post(endpoints: [tg, dc], body: "old", name: "rubotty", delete_after: 300)

      removed = service(session_id: "live").sweep(alive_session_ids: ["live"], now: base)

      expect(removed).to eq(2)
      expect(tg_adapter.deleted).to include(%w[tg d1])
      expect(dc_adapter.deleted).to include(%w[dc d1])
      expect(store.count).to eq(0)
    end

    it "leaves a live session's still-pending copies untouched" do
      live = service(session_id: "live")
      live.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 300)

      removed = live.sweep(alive_session_ids: ["live"], now: base)

      expect(removed).to eq(0)
      expect(tg_adapter.deleted).to be_empty
      expect(store.count).to eq(2)
    end

    # Time is the other orphan signal: a row past its delete_at is due even
    # when its session is still alive.
    it "deletes a copy whose delete_at has already passed" do
      live = service(session_id: "live")
      live.post(endpoints: [tg], body: "up", name: "rubotty", delete_after: 60)

      removed = live.sweep(alive_session_ids: ["live"], now: base + 120)

      expect(removed).to eq(1)
      expect(tg_adapter.deleted).to include(%w[tg d1])
    end

    it "is idempotent: a second sweep finds nothing left to do" do
      service(session_id: "dead").post(endpoints: [tg, dc], body: "old", name: "rubotty", delete_after: 300)
      live = service(session_id: "live")

      live.sweep(alive_session_ids: ["live"], now: base)
      expect(live.sweep(alive_session_ids: ["live"], now: base)).to eq(0)
    end

    # The Telegram /identify-topic fallback answers a chat belonging to no
    # room, so it addresses a synthetic endpoint the topology never heard of.
    # A sweep that cannot resolve the id has to rebuild it from the row.
    it "deletes a copy on an endpoint the topology does not carry, by rebuilding it from the row" do
      roomless = endpoint("identify-topic:-100123/456", account: "a", settings: { chat_id: "-100123" })
      service(session_id: "dead").post(endpoints: [roomless], body: "named it", name: "rubotty", delete_after: 300)

      removed = service(session_id: "live").sweep(alive_session_ids: ["live"], now: base)

      expect(removed).to eq(1)
      expect(tg_adapter.deleted).to include(["identify-topic:-100123/456", "d1"])
      expect(store.count).to eq(0)
    end

    # A row written before the blob carried the adapter and account cannot be
    # rebuilt, so it is simply dropped.
    it "still drops a row whose stored addressing predates the adapter and account" do
      store.add(
        group_id: "g1", endpoint_id: "gone", channel: JSON.generate({ chat_id: "-1" }),
        native_id: "m1", delete_at: base - 60, session_id: "dead"
      )

      expect(service(session_id: "live").sweep(alive_session_ids: ["live"], now: base)).to eq(0)
      expect(store.count).to eq(0)
    end

    it "is a harmless no-op with the null store" do
      null = service(store: Rubotty::Core::EphemeralStore::Null.new)
      null.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)
      expect(null.sweep(alive_session_ids: ["live"], now: base)).to eq(0)
    end

    # A mixed-endpoint group where one copy deletes and the other fails on the
    # same pass: the copy that already succeeded must not be retried on the
    # next pass, since re-deleting it is at best pointless and at worst an
    # adapter error that keeps the whole group from ever being forgotten.
    it "does not retry an endpoint copy that already deleted, when its group-mate fails on the same pass" do
      ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)
      dc_adapter.fail_next(Rubotty::AdapterError.new("rate limited", adapter: :fake))

      first_pass = ephemeral.sweep(alive_session_ids: ["live"], now: base + 31)

      expect(first_pass).to eq(1)
      expect(tg_adapter.deleted).to eq([%w[tg d1]])
      expect(dc_adapter.deleted).to be_empty
      expect(store.count).to eq(1)

      second_pass = ephemeral.sweep(alive_session_ids: ["live"], now: base + 31)

      expect(second_pass).to eq(1)
      # tg was already gone after the first pass, so it must not be deleted twice.
      expect(tg_adapter.deleted).to eq([%w[tg d1]])
      expect(dc_adapter.deleted).to eq([%w[dc d1]])
      expect(store.count).to eq(0)
    end
  end

  # #post addresses an endpoint; #post_dm addresses a DmTarget instead, the
  # operator startup DM's own primitive.
  describe "#post_dm" do
    let(:tg_adapter) { Fakes::ReactingAdapter.new(admin_dm: true) }
    let(:dc_adapter) { Fakes::ReactingAdapter.new(admin_dm: true) }
    let(:dm_target) { described_class::DmTarget.new(adapter_name: :fake, account: "a", native_id: "op1") }
    let(:other_target) { described_class::DmTarget.new(adapter_name: :fake, account: "b", native_id: "op2") }

    it "DMs every target, as one linked group" do
      group = ephemeral.post_dm(targets: [dm_target, other_target], body: "up", name: "rubotty", delete_after: 90)

      expect(group.copies.size).to eq(2)
      expect(tg_adapter.dms_sent).to eq([{ native_id: "op1", text: "up" }])
      expect(dc_adapter.dms_sent).to eq([{ native_id: "op2", text: "up" }])
    end

    it "self-deletes every DM when asked" do
      group = ephemeral.post_dm(targets: [dm_target, other_target], body: "up", name: "rubotty", delete_after: 90)
      group.delete_now

      expect(tg_adapter.dms_deleted).to eq(["dm1"])
      expect(dc_adapter.dms_deleted).to eq(["dm1"])
    end

    it "refuses a target whose adapter cannot delete a DM it sent, rather than sending one that lingers" do
      undeletable_tg = Fakes::ReactingAdapter.new(admin_dm: true, admin_dm_delete: false)
      solo = described_class.new(
        adapters: { [:fake, "a"] => undeletable_tg }, session_id: "live", store: store, topology: topo,
        logger: Rubotty::Log.null, clock: -> { base }
      )

      group = solo.post_dm(targets: [dm_target], body: "up", name: "rubotty", delete_after: 90)

      expect(group.copies).to be_empty
      expect(undeletable_tg.dms_sent).to be_empty
    end

    it "refuses a target whose adapter cannot DM at all" do
      mute = Fakes::ReactingAdapter.new
      solo = described_class.new(
        adapters: { [:fake, "a"] => mute }, session_id: "live", store: store, topology: topo,
        logger: Rubotty::Log.null, clock: -> { base }
      )

      group = solo.post_dm(targets: [dm_target], body: "up", name: "rubotty", delete_after: 90)

      expect(group.copies).to be_empty
      expect(mute.dms_sent).to be_empty
    end

    it "still links the targets that landed when one target's send fails" do
      tg_adapter.fail_next(Rubotty::AdapterError.new("blocked", adapter: :fake))

      group = ephemeral.post_dm(targets: [dm_target, other_target], body: "up", name: "rubotty", delete_after: 90)

      expect(group.copies.size).to eq(1)
      expect(dc_adapter.dms_sent.size).to eq(1)
    end

    it "records nothing when the message is meant to persist (delay 0)" do
      ephemeral.post_dm(targets: [dm_target], body: "up", name: "rubotty", delete_after: 0)
      expect(store.count).to eq(0)
    end

    it "is never edited: a DM group is only ever removed" do
      group = ephemeral.post_dm(targets: [dm_target], body: "up", name: "rubotty", delete_after: 90)
      expect { group.edit("done") }.not_to raise_error
    end

    describe "durable recording and sweep" do
      it "records one pending-deletion row per DM, all sharing a group id" do
        ephemeral.post_dm(targets: [dm_target, other_target], body: "up", name: "rubotty", delete_after: 90)
        expect(store.count).to eq(2)
      end

      it "forgets the durable rows once the group self-deletes" do
        group = ephemeral.post_dm(targets: [dm_target, other_target], body: "up", name: "rubotty", delete_after: 90)
        group.delete_now
        expect(store.count).to eq(0)
      end

      it "keeps the durable row when the platform refuses the delete, rather than forgetting a DM still there" do
        refusing = Fakes::ReactingAdapter.new(admin_dm: true, admin_dm_delete_succeeds: false)
        solo = described_class.new(
          adapters: { [:fake, "a"] => refusing }, session_id: "live", store: store, topology: topo,
          logger: Rubotty::Log.null, clock: -> { base }
        )

        group = solo.post_dm(targets: [dm_target], body: "up", name: "rubotty", delete_after: 90)
        group.delete_now

        expect(store.count).to eq(1)
      end

      it "reaps a DM left by a session that is no longer alive, on a fresh session's boot sweep" do
        service(session_id: "dead").post_dm(
          targets: [dm_target, other_target], body: "old", name: "rubotty", delete_after: 300
        )

        removed = service(session_id: "live").sweep(alive_session_ids: ["live"], now: base)

        expect(removed).to eq(2)
        expect(tg_adapter.dms_deleted).to eq(["dm1"])
        expect(dc_adapter.dms_deleted).to eq(["dm1"])
        expect(store.count).to eq(0)
      end

      it "leaves a live session's still-pending DM untouched" do
        live = service(session_id: "live")
        live.post_dm(targets: [dm_target], body: "up", name: "rubotty", delete_after: 300)

        removed = live.sweep(alive_session_ids: ["live"], now: base)

        expect(removed).to eq(0)
        expect(tg_adapter.dms_deleted).to be_empty
        expect(store.count).to eq(1)
      end
    end
  end

  # The in-process Core::Scheduler keeps its queue in memory, so a timer lost
  # to a redeploy mid window never fires and the banner lingers. #sweep only
  # helps at the next boot, and reaps immediately rather than honouring
  # delete_after.
  describe "durable-scheduler-backed delete" do
    let(:durable_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

    # A "restart" is a fresh scheduler and a fresh EphemeralMessage over the
    # same two tables, with a new session id. Constructing the EphemeralMessage
    # registers its delete handler, as Runtime#build does before recovery.
    def durable(session_id:, clock: -> { base })
      Rubotty::Core::DurableScheduler.new(store: durable_store, session_id: session_id,
                                          logger: Rubotty::Log.null, clock: clock)
    end

    def service_with_durable(session_id:, durable_scheduler:, clock: -> { base })
      described_class.new(
        adapters: adapters, session_id: session_id, store: store, topology: topo,
        logger: Rubotty::Log.null, clock: clock, durable_scheduler: durable_scheduler
      )
    end

    it "schedules a durable delete job alongside the durable row" do
      sched = durable(session_id: "live")
      svc = service_with_durable(session_id: "live", durable_scheduler: sched)

      svc.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      expect(sched.pending).to eq(1)
    end

    it "schedules nothing durable when delete_after is 0, the message is meant to persist" do
      sched = durable(session_id: "live")
      svc = service_with_durable(session_id: "live", durable_scheduler: sched)

      svc.post(endpoints: [tg, dc], body: "summary", name: "rubotty", delete_after: 0)

      expect(sched.pending).to eq(0)
    end

    it "schedules nothing durable when no durable_scheduler was given" do
      ephemeral.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)
      expect(durable_store.count(status: "pending")).to eq(0)
    end

    # The fresh session never had the group id or its endpoints in memory; it
    # reads them back from the durable ephemeral store by group id.
    it "a fresh scheduler instance over the same store completes a deletion the dead session's timer never fired" do
      dead_sched = durable(session_id: "dead")
      dead = service_with_durable(session_id: "dead", durable_scheduler: dead_sched)
      dead.post(endpoints: [tg, dc], body: "Started rubotty version: 1.1.1", name: "rubotty", delete_after: 30)

      # The dead session never calls run_due or recover: both its timers die
      # with the process here, like a redeploy mid delete_after window.
      expect(tg_adapter.deleted).to be_empty
      expect(dc_adapter.deleted).to be_empty

      later = -> { base + 31 }
      fresh_sched = durable(session_id: "live", clock: later)
      service_with_durable(session_id: "live", durable_scheduler: fresh_sched, clock: later)

      ran = fresh_sched.recover(alive_session_ids: ["live"], now: base + 31)

      expect(ran).to eq(1)
      expect(tg_adapter.deleted).to include(%w[tg d1])
      expect(dc_adapter.deleted).to include(%w[dc d1])
      expect(store.count).to eq(0)
    end

    # The two paths race on purpose, and whichever wins leaves the other a
    # no-op rather than a double delete or an error.
    it "is a harmless no-op when the fast in-process path already reaped the group" do
      sched = durable(session_id: "live")
      svc = service_with_durable(session_id: "live", durable_scheduler: sched)
      group = svc.post(endpoints: [tg, dc], body: "up", name: "rubotty", delete_after: 30)

      # The fast path fires first, as Runtime#announce_startup wires it.
      group.delete_now
      expect(tg_adapter.deleted).to include(%w[tg d1])

      # The durable job comes due later and finds nothing left to reap.
      ran = sched.run_due(now: base + 30)
      expect(ran).to eq(1)
      expect(tg_adapter.deleted.size).to eq(1)
      expect(dc_adapter.deleted.size).to eq(1)
    end
  end
end
