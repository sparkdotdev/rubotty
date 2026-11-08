# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Fluxer's Inbound accepted a logger and never called it: the same gap already
# closed on Telegram, where every drop below used to leave nothing behind, and
# the dispatch switch had no else to catch an event type the platform adds
# later.
RSpec.describe "Fluxer reaction drop logging" do
  include Builders

  let(:general) { endpoint("fx-general", adapter: :fluxer, settings: { channel_id: "111111111" }) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  subject(:adapter) do
    Rubotty::Adapters::Fluxer::Adapter.new(
      account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: logger, endpoints: [general]
    )
  end

  it "says which channel a reaction was dropped for when nothing is bridged to it" do
    result = adapter.handle_event(
      FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                           { "channel_id" => "999999999", "message_id" => "700",
                             "user_id" => "55", "emoji" => { "id" => nil, "name" => "👍" } })
    )
    expect(result).to be_nil
    expect(logs.string).to include("999999999")
    expect(logs.string).to include("no endpoint is bridged to it")
  end

  it "says a reaction was dropped for carrying no message id" do
    result = adapter.handle_event(
      FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                           { "channel_id" => "111111111",
                             "user_id" => "55", "emoji" => { "id" => nil, "name" => "👍" } })
    )
    expect(result).to be_nil
    expect(logs.string).to include("no message id")
  end

  it "says a reaction was dropped for naming no emoji" do
    result = adapter.handle_event(
      FluxerFakes.dispatch("MESSAGE_REACTION_ADD",
                           { "channel_id" => "111111111", "message_id" => "700", "user_id" => "55" })
    )
    expect(result).to be_nil
    expect(logs.string).to include("no emoji named")
  end

  it "logs an event type the dispatch switch does not recognise, instead of vanishing it" do
    result = adapter.handle_event(FluxerFakes.dispatch("SOME_FUTURE_EVENT", { "channel_id" => "111111111" }))
    expect(result).to be_nil
    expect(logs.string).to include("unhandled Fluxer event type")
    expect(logs.string).to include("SOME_FUTURE_EVENT")
  end
end
