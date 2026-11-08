# frozen_string_literal: true

require "spec_helper"

# A command resolves its acknowledgement TTL from this channel's feature config, falling back
# to the bridge-wide `commands.cleanup_after` only when the scope is silent.
RSpec.describe Rubotty::Features::Moderation do
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

  # Built with the bridge-wide grace period off, as a fresh install is, so any deferral
  # observed comes from the scope config.
  def feature(cleanup_after: 0)
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, cleanup: scheduler,
      cleanup_after: cleanup_after, acknowledge: true, ephemeral: ephemeral
    )
  end

  def delete_command
    message(tg, text: "/delete", native_id: "1000", author: author(native_id: "55"),
                reply_to: ref("tg", "900"),
                reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "900")))
  end

  def context(config)
    Rubotty::Features::Context.new(message: delete_command, config: config, operators: directory)
  end

  after { scheduler.stop }

  it "publishes a config schema so the dashboard can set the ack TTL" do
    expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
  end

  it "defers using the scope's ack_ttl_seconds even when the bridge-wide grace is 0" do
    feature.call(context({ ack_ttl_seconds: 20 }))

    expect(adapter.delivered_to("tg").first.body.text)
      .to eq("Acknowledged, deleting this message on all services in 20 seconds.")
    expect(scheduler.pending).to eq(1)
  end

  it "tolerates a string key from a control-plane snapshot" do
    feature.call(context({ "ack_ttl_seconds" => 5 }))

    expect(adapter.delivered_to("tg").first.body.text)
      .to eq("Acknowledged, deleting this message on all services in 5 seconds.")
  end

  it "falls back to the bridge-wide cleanup_after when the scope sets nothing" do
    feature(cleanup_after: 15).call(context({}))

    expect(adapter.delivered_to("tg").first.body.text)
      .to eq("Acknowledged, deleting this message on all services in 15 seconds.")
  end

  it "lets a scope disable the grace period with 0, overriding a non-zero bridge default" do
    feature(cleanup_after: 15).call(context({ ack_ttl_seconds: 0 }))

    # 0 means act at once, but the summary still self-deletes after the
    # standard ack window rather than accumulating in the room forever.
    expect(scheduler.pending).to eq(1)
    expect(adapter.delivered_to("tg").first.body.text)
      .to eq("Successfully removed message on 1/1 connected services.")
  end

  # Nothing anywhere even implements delete: 0/0 must not read as success.
  it "says unsupported rather than a bare 0/0 success when no endpoint can carry out the action" do
    plain = Fakes::RecordingAdapter.new
    plain_ephemeral = Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(plain), session_id: "s", topology: topology(room("r", tg)),
      logger: Rubotty::Log.null
    )
    unsupported_feature = described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(plain), storage: storage,
      logger: Rubotty::Log.null, commands: commands, cleanup: scheduler,
      cleanup_after: 0, acknowledge: true, ephemeral: plain_ephemeral
    )

    unsupported_feature.call(context({ ack_ttl_seconds: 0 }))

    expect(plain.delivered_to("tg").first.body.text).to eq("No connected service supports delete.")
  end

  # A mix of a real success and an unsupported endpoint used to say nothing about the
  # unsupported one at all, the same silent gap, just not the pure 0/0 case.
  it "names the endpoint an action is not supported on, alongside a real success" do
    dc = endpoint("dc", account: "acct-dc")
    plain = Fakes::RecordingAdapter.new(account: "acct-dc")
    mixed_adapters = { [:fake, "default"] => adapter, [:fake, "acct-dc"] => plain }
    mixed_ephemeral = Rubotty::Core::EphemeralMessage.new(
      adapters: mixed_adapters, session_id: "s", topology: topology(room("r", tg, dc)),
      logger: Rubotty::Log.null
    )
    mixed_feature = described_class.new(
      topology: topology(room("r", tg, dc)), adapters: mixed_adapters, storage: storage,
      logger: Rubotty::Log.null, commands: commands, cleanup: scheduler,
      cleanup_after: 0, acknowledge: true, ephemeral: mixed_ephemeral
    )

    mixed_feature.call(context({ ack_ttl_seconds: 0 }))

    expect(adapter.delivered_to("tg").first.body.text)
      .to eq("Successfully removed message on 1/1 connected services. Not supported on dc.")
  end
end
