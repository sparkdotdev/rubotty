# frozen_string_literal: true

require "spec_helper"

# A `/delete@rubotty_telegram_bot` typed as a reply in a bridging Telegram room
# said nothing and arrived on Discord as chat. A dashboard-onboarded community
# has no operator rows, and an empty directory used to switch the whole parser
# off, so the verb fell through Features::Moderation as text and got relayed.
RSpec.describe "a recognised command in a bridged room" do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:bridged) { topology(room("r", tg, dc)) }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  # No operator rows, exactly as an onboarded community has them.
  let(:directory) { Rubotty::Core::Moderation::Directory.new([]) }

  let(:commands) do
    Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null)
  end

  let(:moderation) do
    Rubotty::Features::Moderation.new(
      topology: bridged, adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: commands
    )
  end

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: bridged, adapters: Hash.new(adapter), storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
    )
  end

  let(:pipeline) do
    Rubotty::Features::Pipeline.new(
      features: [moderation, bridge], logger: Rubotty::Log.null, operators: directory
    )
  end

  def reply_from(native_id, username)
    Rubotty::Core::ReplyPreview.new(author: author(native_id: native_id, username: username))
  end

  def typed(text, author:, native_id: "69")
    message(
      tg, text: text, native_id: native_id, author: author,
      reply_to: ref("tg", "68"), reply_preview: reply_from("777", "someone")
    )
  end

  # One of the four deployment-configured owners, with no row of their own anywhere.
  let(:owner) { author(native_id: "12345", username: "sample_owner") }
  let(:stranger) { author(native_id: "999", username: "passer_by") }

  def relayed_to_discord = adapter.delivered_to("dc")

  it "runs the owner's command and sends nothing at all to the far platform" do
    pipeline.handle(typed("/delete@rubotty_telegram_bot", author: owner))

    expect(relayed_to_discord).to be_empty
    expect(adapter.deleted).to include(%w[tg 68])
  end

  it "sends nothing to the far platform when the command is refused either" do
    pipeline.handle(typed("/ban", author: stranger))

    expect(relayed_to_discord).to be_empty
    expect(adapter.moderations).to be_empty
  end

  it "answers a refused command in the room it was typed in rather than going quiet" do
    pipeline.handle(typed("/ban", author: stranger))

    reply = adapter.delivered_to("tg").last
    expect(reply).not_to be_nil
    expect(reply.body.text).to include("You need to be an operator")
  end

  it "answers a verb this bridge does not accept, and keeps that off the far platform too" do
    limited = Rubotty::Core::Commands.new(actions: [:delete], logger: Rubotty::Log.null)
    feature = Rubotty::Features::Moderation.new(
      topology: bridged, adapters: Hash.new(adapter), storage: storage,
      logger: Rubotty::Log.null, commands: limited
    )
    chain = Rubotty::Features::Pipeline.new(
      features: [feature, bridge], logger: Rubotty::Log.null, operators: directory
    )

    chain.handle(typed("/kick", author: owner))

    expect(relayed_to_discord).to be_empty
    expect(adapter.delivered_to("tg").last.body.text).to include("/kick")
  end

  it "still relays an ordinary message that only looks a little like one" do
    pipeline.handle(typed("/notacommand at all", author: stranger))

    expect(relayed_to_discord.map { |sent| sent.body.text }.join).to include("notacommand")
  end
end
