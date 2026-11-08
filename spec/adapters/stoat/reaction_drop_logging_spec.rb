# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Stoat's Inbound accepted a logger and never called it: the same gap already
# closed on Telegram, where every drop below used to leave nothing behind, and
# the dispatch switch had no else to catch an event type the platform adds
# later.
RSpec.describe "Stoat reaction drop logging" do
  include Builders

  let(:general) { endpoint("st-general", adapter: :stoat, settings: { channel_id: "CHAN01" }) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  subject(:adapter) do
    Rubotty::Adapters::Stoat::Adapter.new(
      account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: logger, endpoints: [general]
    )
  end

  it "says which channel a reaction was dropped for when nothing is bridged to it" do
    result = adapter.handle_event(
      "type" => "MessageReact", "id" => "700", "channel_id" => "UNKNOWN",
      "user_id" => "u-ada", "emoji_id" => "👍"
    )
    expect(result).to be_nil
    expect(logs.string).to include("UNKNOWN")
    expect(logs.string).to include("no endpoint is bridged to it")
  end

  it "says a reaction was dropped for carrying no message id" do
    result = adapter.handle_event(
      "type" => "MessageReact", "channel_id" => "CHAN01", "user_id" => "u-ada", "emoji_id" => "👍"
    )
    expect(result).to be_nil
    expect(logs.string).to include("no message id")
  end

  it "says a reaction was dropped for naming no emoji" do
    result = adapter.handle_event(
      "type" => "MessageReact", "id" => "700", "channel_id" => "CHAN01", "user_id" => "u-ada"
    )
    expect(result).to be_nil
    expect(logs.string).to include("no emoji named")
  end

  it "logs an event type the dispatch switch does not recognise, instead of vanishing it" do
    result = adapter.handle_event("type" => "SomeFutureEvent", "channel_id" => "CHAN01")
    expect(result).to be_nil
    expect(logs.string).to include("unhandled Stoat event type")
    expect(logs.string).to include("SomeFutureEvent")
  end
end
