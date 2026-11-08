# frozen_string_literal: true

require "spec_helper"

# A refused command used to be silent: relayed as chat, or before that, vanished without a
# word. It now does neither: it is consumed here, so the other platform never sees what
# somebody tried, and the refusal is said in the room it was typed in.
RSpec.describe Rubotty::Features::Moderation, "a refused command" do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Alex", identities: { fake: ["55"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end
  let(:feature) do
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands
    )
  end

  def ctx(msg) = Rubotty::Features::Context.new(message: msg, operators: directory)

  # A /ban from a non-operator, replying to somebody else's message: refused,
  # since only an operator may ban and there is no self-delete exception for it.
  def refused_ban(native_id: "1000", author_id: "999")
    message(
      tg, text: "/ban", native_id: native_id, author: author(native_id: author_id),
      reply_to: ref("tg", "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "777", username: "target"))
    )
  end

  it "halts rather than relaying, and answers in the room" do
    outcome = feature.call(ctx(refused_ban))

    expect(outcome).to be_halt
    expect(outcome).not_to be_continue
    expect(adapter.moderations).to be_empty
    expect(adapter.delivered_to("tg").last.body.text).to include("You need to be an operator")
  end

  # A silent refusal only tells the room what happened; it does not say to
  # whom, and in a busy channel that leaves the sender guessing.
  it "replies to the message that asked, rather than posting unattached" do
    feature.call(ctx(refused_ban(native_id: "1000")))

    expect(adapter.delivered_to("tg").last.reply_to).to eq(ref("tg", "1000"))
  end

  # The usual ephemeral flow pairs an accepted command's ack with the
  # command message, so cleaning up the one takes the other with it. A
  # refusal never becomes a real Command (no source_ref for
  # {#command_pairing}), but the refused message is still right there to pair against.
  it "pairs the refused command itself with its own ack, the same as an accepted command" do
    ephemeral = Rubotty::Core::EphemeralMessage.new(
      adapters: Hash.new(adapter), topology: topology(room("r", tg)), session_id: "s", logger: Rubotty::Log.null
    )
    feature = described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, ephemeral: ephemeral
    )

    group = nil
    allow(ephemeral).to receive(:post).and_wrap_original do |original, **kwargs|
      group = original.call(**kwargs)
    end

    feature.call(ctx(refused_ban(native_id: "cmd3", author_id: "999")))
    group.delete_now

    expect(adapter.deleted).to include(["tg", "cmd3"])
  end

  it "still remembers the message, so a later /delete by text can target it" do
    feature.call(ctx(refused_ban(native_id: "cmd1", author_id: "999")))

    operator_delete = message(
      tg, text: "/delete /ban", native_id: "cmd2", author: author(native_id: "55")
    )
    feature.call(ctx(operator_delete))

    expect(adapter.deleted).to include(%w[tg cmd1])
  end

  it "still halts and executes an accepted command from a real operator" do
    ban = message(
      tg, text: "/ban", native_id: "1000", author: author(native_id: "55"),
      reply_to: ref("tg", "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "777", username: "target"))
    )

    outcome = feature.call(ctx(ban))

    expect(outcome).to be_halt
    expect(adapter.moderations.map { |m| m[:action] }).to eq([:ban])
  end

  it "replies to the command message with the executed acknowledgement too" do
    acking_feature = described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands, acknowledge: true
    )
    ban = message(
      tg, text: "/ban", native_id: "1000", author: author(native_id: "55"),
      reply_to: ref("tg", "900"),
      reply_preview: Rubotty::Core::ReplyPreview.new(author: author(native_id: "777", username: "target"))
    )

    acking_feature.call(ctx(ban))

    expect(adapter.delivered_to("tg").last.reply_to).to eq(ref("tg", "1000"))
  end
end

# No commands service at all: the deployment never built one (e.g. no operators
# configured anywhere). Without a word recognised as a moderation verb, this used
# to relay the raw text; it now still recognises the verb and refuses.
RSpec.describe Rubotty::Features::Moderation, "with no commands service" do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:feature) do
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: nil
    )
  end

  def ctx(msg) = Rubotty::Features::Context.new(message: msg)

  it "refuses a recognised verb rather than relaying it" do
    msg = message(tg, text: "/ban", native_id: "1", author: author(native_id: "999"),
                      reply_to: ref("tg", "900"))
    outcome = feature.call(ctx(msg))

    expect(outcome).to be_halt
    expect(adapter.moderations).to be_empty
    expect(adapter.delivered_to("tg").last.body.text).to include("/ban")
    expect(adapter.delivered_to("tg").last.reply_to).to eq(ref("tg", "1"))
  end

  it "leaves an ordinary message alone so it still relays" do
    msg = message(tg, text: "just chatting about the game", native_id: "2", author: author(native_id: "999"))
    outcome = feature.call(ctx(msg))

    expect(outcome).to be_continue
    expect(adapter.delivered).to be_empty
  end
end
