# frozen_string_literal: true

require "spec_helper"

# The scheduler's clock is faked so the ack, act, edit, cleanup sequence is
# driven synchronously.
RSpec.describe "moderation command cleanup" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:alex) do
    Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] })
  end
  let(:directory) { Rubotty::Core::Moderation::Directory.new([alex]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  let(:base) { Time.now }
  let(:clock) { -> { @now ||= base } }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }

  def advance(seconds) = (@now = (@now || base) + seconds)

  let(:cleanup_after) { 15 }
  let(:acknowledge) { true }

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)),
      adapters: Hash.new(adapter),
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      commands: commands,
      operators: directory,
      cleanup: scheduler,
      cleanup_after: cleanup_after,
      acknowledge: acknowledge
    )
  end

  # A message from tg was relayed to dc, so the target has an id on each side.
  before { storage.record(source: ref("tg", "900"), destination: ref("dc", "d9"), room_id: "r") }
  after { scheduler.stop }

  def issue(text, author_id: "55", reply_to: ref("tg", "900"), preview: nil)
    router.handle(
      message(tg, text: text, native_id: "1000",
                  author: author(native_id: author_id), reply_to: reply_to, reply_preview: preview)
    )
  end

  def own_reply(id)
    Rubotty::Core::ReplyPreview.new(
      author: author(native_id: id), body: Rubotty::Core::RichText.plain("a message")
    )
  end

  describe "authorisation" do
    it "lets an operator delete anyone's message" do
      issue("/delete", author_id: "55", preview: own_reply("777"))
      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, deleting this message on all services in 15 seconds.")
    end

    it "lets a non operator delete a message they authored" do
      issue("/delete", author_id: "999", preview: own_reply("999"))
      expect(adapter.delivered_to("tg").size).to eq(1)

      advance(15)
      scheduler.run_due
      expect(adapter.moderations.map { |m| m[:endpoint_id] }).to contain_exactly("tg", "dc")
    end

    it "refuses a non operator deleting someone else's message, answering rather than relaying it" do
      issue("/delete", author_id: "999", preview: own_reply("777"))
      expect(adapter.delivered_to("dc")).to be_empty
      expect(adapter.delivered_to("tg").last.body.text).to include("You need to be an operator")

      advance(15)
      scheduler.run_due
      expect(adapter.moderations).to be_empty
      # Only the refusal cleans itself up; the message it was aimed at stays put.
      expect(adapter.deleted).not_to include(%w[tg 900])
      expect(adapter.deleted).not_to include(%w[dc d9])
    end

    # There is no coherent self ban, so every verb but delete stays operator only.
    it "refuses a non operator issuing a non delete verb, answering rather than relaying it" do
      issue("/pin", author_id: "999", preview: own_reply("999"))
      expect(adapter.delivered_to("dc")).to be_empty
      expect(adapter.delivered_to("tg").last.body.text).to include("You need to be an operator")
    end
  end

  describe "the delete sequence" do
    it "acknowledges immediately and does not act yet" do
      issue("/delete")
      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, deleting this message on all services in 15 seconds.")
      expect(adapter.moderations).to be_empty
      expect(adapter.deleted).to be_empty
      expect(scheduler.pending).to eq(1)
    end

    it "acts on every endpoint, removes the command, and edits the acknowledgement at the grace point" do
      issue("/delete")
      advance(15)
      scheduler.run_due

      expect(adapter.moderations.map { |m| m[:endpoint_id] }).to contain_exactly("tg", "dc")
      expect(adapter.deleted).to include(%w[tg 900], %w[dc d9])
      expect(adapter.deleted).to include(%w[tg 1000])
      # d1 is the acknowledgement, the first delivery.
      endpoint_id, native_id, edited = adapter.edited.last
      expect(endpoint_id).to eq("tg")
      expect(native_id).to eq("d1")
      expect(edited.body.text).to eq("Successfully removed message on 2/2 connected services.")
    end

    it "removes the acknowledgement after a second grace period" do
      issue("/delete")
      advance(15)
      scheduler.run_due
      expect(adapter.deleted).not_to include(%w[tg d1])

      advance(15)
      scheduler.run_due
      expect(adapter.deleted).to include(%w[tg d1])
    end
  end

  describe "the pin sequence" do
    it "runs ack, act, edit and cleanup without deleting the target message" do
      issue("/pin")
      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Acknowledged, pinning this message on all services in 15 seconds.")

      advance(15)
      scheduler.run_due

      expect(adapter.moderations.map { |m| m[:action] }.uniq).to eq([:pin])
      expect(adapter.deleted).to include(%w[tg 1000])
      # The pinned message stays; pinning something you also deleted is absurd.
      expect(adapter.deleted).not_to include(%w[tg 900])
      expect(adapter.deleted).not_to include(%w[dc d9])
      expect(adapter.edited.last.last.body.text)
        .to eq("Successfully pinned message on 2/2 connected services.")

      advance(15)
      scheduler.run_due
      expect(adapter.deleted).to include(%w[tg d1])
    end
  end

  describe "partial success" do
    class FailingModerator < Fakes::ReactingAdapter
      def moderate(_command, endpoint, _native_id)
        Rubotty::Core::Moderation::Result.new(
          endpoint_id: endpoint.id, status: :failed, detail: "boom"
        )
      end
    end

    let(:ok_adapter) { Fakes::ReactingAdapter.new }
    let(:failing) { FailingModerator.new }
    let(:tg) { endpoint("tg", account: "a") }
    let(:dc) { endpoint("dc", account: "b") }

    subject(:router) do
      Rubotty::Core::Router.new(
        topology: topology(room("r", tg, dc)),
        adapters: { [:fake, "a"] => ok_adapter, [:fake, "b"] => failing },
        storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
        logger: Rubotty::Log.null, commands: commands, operators: directory,
        cleanup: scheduler, cleanup_after: 15, acknowledge: true
      )
    end

    # A count alone leaves the issuer unable to tell WHERE a copy survives; the
    # failing endpoint and why must be visible from inside the chat, since the
    # log line naming it is somewhere the issuer never sees.
    it "reports the successes over the attempts, names where a copy survives, and still proceeds" do
      issue("/delete")
      advance(15)
      scheduler.run_due

      expect(ok_adapter.edited.last.last.body.text)
        .to eq("Successfully removed message on 1/2 connected services. Still there on dc: failed (boom).")
      expect(ok_adapter.deleted).to include(%w[tg 1000])
    end
  end

  describe "missing copies" do
    class GoneModerator < Fakes::ReactingAdapter
      def moderate(_command, endpoint, _native_id)
        Rubotty::Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :not_found)
      end
    end

    class MapClearingModerator < Fakes::ReactingAdapter
      def initialize(storage:)
        super()
        @storage = storage
        @cleared = false
      end

      def moderate(command, endpoint, native_id)
        result = super
        return result if @cleared

        @cleared = true
        @storage.forget(Rubotty::Core::MessageRef.new("tg", "900"))
        result
      end
    end

    it "does not say an unrecorded counterpart is still there" do
      issue("/delete", reply_to: ref("tg", "901"))
      advance(15)
      scheduler.run_due

      expect(adapter.moderations.map { |moderation| moderation[:endpoint_id] }).to eq(["tg"])
      expect(adapter.edited.last.last.body.text)
        .to eq("Successfully removed message on 1 connected service. No recorded copy on dc.")
    end

    it "treats a platform's already-gone reply as a completed delete" do
      gone = GoneModerator.new
      router = Rubotty::Core::Router.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(gone), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
        commands: commands, operators: directory, cleanup: scheduler, cleanup_after: 15, acknowledge: true
      )
      router.handle(
        message(tg, text: "/delete", native_id: "1000", author: author(native_id: "55"), reply_to: ref("tg", "900"))
      )
      advance(15)
      scheduler.run_due

      expect(gone.edited.last.last.body.text).to eq("Successfully removed message on 2/2 connected services.")
    end

    it "keeps every resolved target when the first delete clears the message map" do
      clearing = MapClearingModerator.new(storage: storage)
      router = Rubotty::Core::Router.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(clearing), storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null,
        commands: commands, operators: directory, cleanup: scheduler, cleanup_after: 15, acknowledge: true
      )
      router.handle(
        message(tg, text: "/delete", native_id: "1000", author: author(native_id: "55"), reply_to: ref("tg", "900"))
      )
      advance(15)
      scheduler.run_due

      expect(clearing.moderations.map { |moderation| moderation[:endpoint_id] }).to contain_exactly("tg", "dc")
      expect(clearing.edited.last.last.body.text).to eq("Successfully removed message on 2/2 connected services.")
    end
  end

  describe "with acknowledgements disabled" do
    let(:acknowledge) { false }

    it "still defers and deletes the command, but posts no acknowledgement" do
      issue("/delete")
      expect(adapter.delivered).to be_empty

      advance(15)
      scheduler.run_due
      expect(adapter.moderations).not_to be_empty
      expect(adapter.deleted).to include(%w[tg 1000])
      # No acknowledgement means nothing to edit and nothing more to schedule.
      expect(adapter.edited).to be_empty
      expect(scheduler.pending).to eq(0)
    end
  end

  describe "with the grace period disabled" do
    let(:cleanup_after) { 0 }

    it "acts at once, leaves a self-deleting summary acknowledgement, and removes the invocation" do
      issue("/delete")

      expect(adapter.moderations.map { |m| m[:endpoint_id] }).to contain_exactly("tg", "dc")
      expect(adapter.delivered_to("tg").first.body.text)
        .to eq("Successfully removed message on 2/2 connected services.")
      expect(scheduler.pending).to eq(1)
      expect(adapter.deleted).to include(%w[tg 1000])
    end

    it "still lets a non operator delete their own message immediately" do
      issue("/delete", author_id: "999", preview: own_reply("999"))
      expect(adapter.moderations.map { |m| m[:endpoint_id] }).to contain_exactly("tg", "dc")
    end
  end

  describe "when cleanup operations fail" do
    class RaisingAdapter < Fakes::ReactingAdapter
      def delete(_endpoint, _native_id)
        raise Rubotty::AdapterError.new("already gone", adapter: :fake)
      end

      def edit(_message, _endpoint, _native_id)
        raise Rubotty::AdapterError.new("cannot edit", adapter: :fake)
      end
    end

    let(:adapter) { RaisingAdapter.new }

    it "swallows a failing edit and delete and keeps the scheduler alive" do
      issue("/delete")

      advance(15)
      expect { scheduler.run_due }.not_to raise_error

      advance(15)
      expect { scheduler.run_due }.not_to raise_error
    end
  end
end
