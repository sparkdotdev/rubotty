# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Every removal path (in-process timer, durable job, periodic reap, boot sweep) runs
# against real primitives on a fake clock, so each can be starved independently.
RSpec.describe "command cleanup durability" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:adapters) { Hash.new(adapter) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:topo) { topology(room("r", tg, dc)) }

  let(:base) { Time.now }
  let(:clock) { -> { @now ||= base } }
  def advance(seconds) = (@now = (@now || base) + seconds)

  let(:db) do
    database = Sequel.sqlite
    Rubotty::ControlPlane.migrate!(database)
    database
  end
  let(:ephemeral_store) { Rubotty::Core::EphemeralStore::Sequel.new(db: db) }
  let(:job_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }
  let(:durable) do
    Rubotty::Core::DurableScheduler.new(
      store: job_store, session_id: "live", logger: Rubotty::Log.null, clock: clock
    )
  end
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }

  # A real logger over a StringIO, so log assertions read what an operator would.
  let(:log_io) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: log_io) }
  def logged = log_io.string

  # The delivery ledger the ephemeral primitive notes its own posts in, so an echo is recognised.
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  def ephemeral(session_id: "live", loop_guard: self.loop_guard, logger: Rubotty::Log.null)
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: session_id, store: ephemeral_store, topology: topo,
      loop_guard: loop_guard, logger: logger, clock: clock, durable_scheduler: durable
    )
  end

  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  def moderation(ephemeral: self.ephemeral, logger: Rubotty::Log.null)
    Rubotty::Features::Moderation.new(
      topology: topo, adapters: adapters, storage: storage, logger: logger,
      commands: commands, cleanup: scheduler, cleanup_after: 15, acknowledge: true,
      ephemeral: ephemeral
    )
  end

  # The target was relayed tg -> dc, so `/delete` has something to remove on both.
  before { storage.record(source: ref("tg", "900"), destination: ref("dc", "d9"), room_id: "r") }
  after { scheduler.stop }

  def issue_delete(feature, config: {})
    feature.call(
      Rubotty::Features::Context.new(
        message: message(
          tg, text: "/delete", native_id: "1000", author: author(native_id: "55"),
              reply_to: ref("tg", "900"),
              reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "900"))
        ),
        config: config, operators: directory
      )
    )
  end

  def ack_text = adapter.delivered_to("tg").first&.body&.text
  def ack_native_id = "d1"

  # The row's native id, group and delete horizon are each asserted: those are the three
  # things every later removal path reads back.
  describe "a posted acknowledgement" do
    it "records its durable pending-deletion row, keyed by the ack's own id" do
      issue_delete(moderation)

      expect(ack_text).to start_with("Acknowledged,")
      group_id = ephemeral_store.group_id_for(endpoint_id: tg.id, native_id: ack_native_id)
      expect(group_id).not_to be_nil

      row = ephemeral_store.members(group_id).find { |m| m.native_id == ack_native_id }
      expect(row.endpoint_id).to eq(tg.id)
      expect(row.session_id).to eq("live")
      # The grace period twice over: act at 15s, remove the ack 15s after that.
      expect(row.delete_at).to be_within(1).of(base + 30)

      # The invocation is linked into the SAME group, so the pair goes together.
      expect(ephemeral_store.members(group_id).map(&:native_id)).to include("1000")
    end
  end

  # A loop guard that raises stands in for any failure in the bookkeeping after a
  # successful send. The native id is already in hand and must survive it.
  describe "an acknowledgement whose post lands" do
    let(:loop_guard) do
      Class.new do
        def note_delivery(_endpoint_id, _native_id) = raise(Rubotty::StorageError, "ledger unavailable")
      end.new
    end

    it "keeps the id the platform gave back, so the acknowledgement is still manageable" do
      issue_delete(moderation)

      expect(ack_text).to eq("Acknowledged, deleting this message on all services in 15 seconds.")
      # The handle survived, so both backstops exist: a durable row per copy and a removal job.
      expect(ephemeral_store.count).to be_positive
      expect(durable.pending).to eq(1)
    end

    it "edits the acknowledgement to its outcome and then removes it" do
      issue_delete(moderation)

      advance(15)
      scheduler.run_due
      expect(adapter.edited.last.last.body.text).to eq("Successfully removed message on 2/2 connected services.")
      expect(adapter.deleted).to include(%w[tg 900], %w[dc d9])

      advance(15)
      scheduler.run_due
      expect(adapter.deleted).to include(["tg", ack_native_id])
    end
  end

  # A post that comes back with nothing usable must not look like no acknowledgement at all.
  describe "an acknowledgement that comes back without an id" do
    it "is reported rather than passed on as a silent nil" do
      allow(adapter).to receive(:deliver).and_return(nil)
      issue_delete(moderation(ephemeral: ephemeral, logger: logger))

      expect(logged).to include("came back without an id")
    end
  end

  describe "when the in-process scheduler never runs" do
    it "still removes the acknowledgement and the command message" do
      issue_delete(moderation)
      expect(ack_text).to start_with("Acknowledged,")

      # The in-process timer is never driven, so the durable job is all that is left.
      advance(30)
      expect(durable.run_due).to eq(1)

      expect(adapter.deleted).to include(["tg", ack_native_id])
      expect(adapter.deleted).to include(%w[tg 1000])
      expect(ephemeral_store.count).to be_zero
    end
  end

  describe "a moderation command whose scope opts out of removing the invocation" do
    it "still removes the acknowledgement but leaves the command message alone" do
      issue_delete(moderation, config: { delete_command_message: false })

      advance(15)
      scheduler.run_due
      advance(15)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg", ack_native_id])
      expect(adapter.deleted).not_to include(%w[tg 1000])
    end
  end

  describe "an overdue deletion whose own job was lost" do
    it "is reaped by the periodic tick without a restart" do
      issue_delete(moderation)
      # Lose the group's own removal job: the pending row is the only evidence anything is owed.
      expect(durable.forget(kind: Rubotty::Core::EphemeralMessage::DELETE_KIND,
                            every_community: true)).to eq(1)

      ephemeral.arm_periodic_reap(interval: 60)
      expect(ephemeral_store.count).to be_positive

      # Same process, same session, no boot sweep: only the recurring job runs.
      advance(120)
      expect(durable.run_due).to be_positive

      expect(adapter.deleted).to include(["tg", ack_native_id], %w[tg 1000])
      expect(ephemeral_store.count).to be_zero
    end

    it "keeps the recurring job alive for the next pass" do
      ephemeral.arm_periodic_reap(interval: 60)
      advance(60)
      durable.run_due

      expect(durable.pending).to eq(1)
    end
  end

  describe "after a restart" do
    it "removes both the reply and the command message a dead session left" do
      issue_delete(moderation)

      # A fresh process: new session id, same store, nothing in memory.
      advance(30)
      fresh = ephemeral(session_id: "next-boot")
      expect(fresh.sweep(alive_session_ids: ["next-boot"])).to eq(2)

      expect(adapter.deleted).to include(["tg", ack_native_id], %w[tg 1000])
      expect(ephemeral_store.count).to be_zero
    end
  end

  # A swallowed command is never relayed, so its invocation must go with the bot's reply.
  describe "a public command and its reply" do
    def utility(ephemeral: self.ephemeral)
      Rubotty::Features::UtilityCommands.new(
        topology: topo, adapters: adapters, logger: Rubotty::Log.null,
        ephemeral: ephemeral, cleanup: scheduler
      )
    end

    def issue_help(feature, config: {})
      feature.call(
        Rubotty::Features::Context.new(
          message: message(tg, text: "/help", native_id: "77", author: author(native_id: "u1")),
          config: config
        )
      )
    end

    it "removes both when the TTL elapses" do
      issue_help(utility, config: { ack_ttl_seconds: 30 })
      expect(adapter.delivered_to("tg").last.body.text).to include("/help")
      expect(adapter.deleted).to be_empty

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg", ack_native_id], %w[tg 77])
    end

    it "leaves the invocation alone when the scope opts out" do
      issue_help(utility, config: { ack_ttl_seconds: 30, delete_command_message: false })

      advance(30)
      scheduler.run_due

      expect(adapter.deleted).to include(["tg", ack_native_id])
      expect(adapter.deleted).not_to include(%w[tg 77])
    end

    it "removes both from the durable path alone, with no in-process timer" do
      issue_help(utility, config: { ack_ttl_seconds: 30 })

      advance(30)
      expect(durable.run_due).to eq(1)

      expect(adapter.deleted).to include(["tg", ack_native_id], %w[tg 77])
    end

    it "removes both after a restart, from what the dead session recorded" do
      issue_help(utility, config: { ack_ttl_seconds: 30 })

      advance(30)
      expect(ephemeral(session_id: "next-boot").sweep(alive_session_ids: ["next-boot"])).to eq(2)

      expect(adapter.deleted).to include(["tg", ack_native_id], %w[tg 77])
    end
  end

  describe "a member the bot may not delete" do
    # Telegram wants delete rights and Discord wants Manage Messages to remove
    # somebody else's message. Without them the command message stays put.
    let(:adapter) do
      Class.new(Fakes::ReactingAdapter) do
        def delete(endpoint, native_id)
          raise Rubotty::AdapterError, "not enough rights to delete a message" if native_id == "1000"

          super
        end
      end.new
    end
    it "still removes the reply, says why, and keeps the row for another try" do
      issue_delete(moderation(ephemeral: ephemeral(logger: logger)))

      advance(30)
      durable.run_due

      expect(adapter.deleted).to include(["tg", ack_native_id])
      expect(logged).to include("not enough rights to delete a message")
      # The row is kept, so the periodic reap comes back for it.
      expect(ephemeral_store.count).to be_positive
    end

    # A permission the bot will never be granted must not be retried for the life of the process.
    it "gives up on it after a day rather than retrying for ever" do
      issue_delete(moderation(ephemeral: ephemeral(logger: logger)))

      advance(30)
      durable.run_due
      expect(ephemeral_store.count).to be_positive

      advance(Rubotty::Core::EphemeralMessage::ABANDON_AFTER)
      ephemeral(logger: logger).reap_overdue

      expect(logged).to include("giving up on 1000")
      expect(ephemeral_store.count).to be_zero
    end
  end
end
