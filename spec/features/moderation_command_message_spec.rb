# frozen_string_literal: true

require "spec_helper"

# `delete_command_message` governs the invocation on BOTH command paths. The
# act-at-once path never removed it at all, so a `/delete` left a bare command
# sitting in the channel, and the grace-period path removed it whatever the
# scope had asked for.
RSpec.describe Rubotty::Features::Moderation, "the invocation message" do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end
  let(:clock) { -> { @now ||= Time.now } }
  let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(adapter), session_id: "s", topology: topology(room("r", tg)),
      logger: Rubotty::Log.null
    )
  end

  def feature(cleanup_after: 0, acknowledge: true)
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, cleanup: scheduler,
      cleanup_after: cleanup_after, acknowledge: acknowledge, ephemeral: ephemeral
    )
  end

  def issue_delete(subject, config)
    subject.call(
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

  after { scheduler.stop }

  describe "acting at once" do
    it "removes the invocation, since no acknowledgement group will carry it away later" do
      issue_delete(feature, {})

      expect(adapter.deleted).to include(%w[tg 900], %w[tg 1000])
    end

    it "leaves it alone when the scope opts out" do
      issue_delete(feature, { delete_command_message: false })

      expect(adapter.deleted).to include(%w[tg 900])
      expect(adapter.deleted).not_to include(%w[tg 1000])
    end

    it "posts the summary before removing the invocation it hangs off" do
      issue_delete(feature, {})

      expect(adapter.delivered_to("tg").last.body.text)
        .to eq("Successfully removed message on 1/1 connected services.")
      expect(adapter.delivered_to("tg").last.reply_to).to eq(ref("tg", "1000"))
    end
  end

  describe "after a grace period" do
    it "removes the invocation once the verb lands" do
      issue_delete(feature, { ack_ttl_seconds: 20 })
      expect(adapter.deleted).to be_empty

      @now += 20
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg 900], %w[tg 1000])
    end

    it "leaves it alone when the scope opts out" do
      issue_delete(feature, { ack_ttl_seconds: 20, delete_command_message: false })

      @now += 20
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg 900])
      expect(adapter.deleted).not_to include(%w[tg 1000])
    end
  end
end
