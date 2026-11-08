# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"

# A run of reactions added and removed quickly on one message left Telegram
# showing an emoji nobody held any more: every change calls setMessageReaction
# even when the shown emoji does not change, so a burst trips the rate limit.
# The mirror is the one platform call no retry covers, so a refusal drops silently.
RSpec.describe "a run of reactions Telegram refuses partway through" do
  include Builders

  # A clock only the retry policy's sleeper moves, so waiting a refusal out is
  # the only thing in the run that can make time pass.
  class WedgeClock
    def initialize = @now = 0.0

    attr_reader :now

    def advance(seconds) = @now += seconds
  end

  # Telegram, reduced to the two rules this run turns on: the bot holds at most
  # one reaction on a message, and setMessageReaction is rate limited, so every
  # call inside the window after an accepted one is refused.
  class RateLimitedTelegram
    def initialize(clock:, window: 5)
      @clock = clock
      @window = window
      @open_at = 0.0
      @held = nil
      @refusals = 0
    end

    attr_reader :held, :refusals

    def call(method, params)
      return { "ok" => true, "result" => { "id" => 424_242, "username" => "bridgebot" } } if method == "getMe"
      unless method == "setMessageReaction"
        @notice_id ||= 0
        @notice_id += 1
        return { "ok" => true, "result" => { "message_id" => @notice_id } }
      end

      return refuse if @clock.now < @open_at

      @open_at = @clock.now + @window
      @held = JSON.parse(JSON.generate(params))["reaction"].to_a.first&.fetch("emoji", nil)
      { "ok" => true, "result" => true }
    end

    private

    def refuse
      @refusals += 1
      { "ok" => false, "error_code" => 429,
        "description" => "Too Many Requests: retry after #{@window}",
        "parameters" => { "retry_after" => @window } }
    end
  end

  let(:clock) { WedgeClock.new }
  let(:window) { 5 }
  let(:telegram) { RateLimitedTelegram.new(clock: clock, window: window) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:tg) { endpoint("tg-lounge", adapter: :telegram, account: "tg", settings: { chat_id: "-100111" }) }
  let(:dc) { endpoint("dc-lounge", adapter: :fake, account: "dc") }
  let(:source) { ref("dc-lounge", "d1") }

  let(:tg_adapter) do
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new,
      logger: logger,
      endpoints: [tg]
    ).replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: telegram, logger: logger)
    )
  end

  subject(:router) do
    Rubotty::Core::Router.new(
      topology: topology(room("r", dc, tg)),
      adapters: { [:telegram, "tg"] => tg_adapter, [:fake, "dc"] => Fakes::RecordingAdapter.new },
      storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: logger,
      retry_policy: Rubotty::Core::RetryPolicy.new(
        logger: logger, sleeper: ->(seconds) { clock.advance(seconds) }
      ),
      ttl: 3600
    )
  end

  before { storage.record(source: source, destination: ref("tg-lounge", "900"), room_id: "r") }

  def react(kind, emoji)
    router.handle(
      Rubotty::Core::Message.new(
        kind: kind, ref: source, origin: dc, author: author(native_id: "alice"),
        reaction: Rubotty::Core::Reaction.new(emoji: emoji)
      )
    )
  end

  # Two emoji on and then both back off again, faster than Telegram accepts.
  def burst
    react(:reaction_add, "👍")
    react(:reaction_add, "🎉")
    react(:reaction_remove, "👍")
    react(:reaction_remove, "🎉")
  end

  def stored = storage.reactions_on(source).map(&:emoji)

  it "refuses part of the run, which is what the bridge has to survive" do
    burst
    expect(telegram.refusals).to be_positive
  end

  it "leaves the message showing what the aggregate actually holds, which is nothing" do
    burst
    expect(stored).to be_empty
    expect(telegram.held).to be_nil
  end

  it "still ends up right when the run finishes on an emoji rather than on nothing" do
    react(:reaction_add, "👍")
    react(:reaction_add, "🎉")
    react(:reaction_remove, "👍")
    expect(stored).to eq(["🎉"])
    expect(telegram.held).to eq("🎉")
  end

  # Telegram reports the moment the limit lifts, and past a minute the room
  # worker is not held waiting for it. That copy is then genuinely out of date,
  # which is the case that has to be findable in a log.
  context "when the limit is longer than anything worth waiting out inline" do
    let(:window) { 600 }

    it "gives up rather than holding the room" do
      burst
      expect(telegram.held).to eq("👍")
    end

    it "says at warn that it abandoned the mirror, and on which copy" do
      burst
      warnings = logs.string.lines.grep(/WARN/)
      expect(warnings.join).to include("abandoned the reaction mirror")
      expect(warnings.join).to include("tg-lounge")
    end
  end
end
