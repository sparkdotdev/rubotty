# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A threaded reply in a non-forum supergroup (a discussion group linked to
# a channel) overloads message_thread_id; #from_message used to read it
# with no is_forum guard. The route key built from that id names an
# endpoint discovery never creates, dropping the message with no log line.
RSpec.describe Rubotty::Adapters::Telegram::Inbound do
  include Builders

  let(:lobby) { endpoint("tg-lobby", adapter: :telegram, settings: { chat_id: "-100111" }) }
  let(:topic) { endpoint("tg-topic", adapter: :telegram, settings: { chat_id: "-100111", thread_id: 142_483 }) }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }
  let(:known) do
    lambda do |chat, thread|
      next nil unless chat.to_s == "-100111"

      thread.nil? ? lobby : (topic if thread.to_s == "142483")
    end
  end

  subject(:inbound) { described_class.new(endpoint_for: known, logger: logger) }

  def call(chat_overrides)
    inbound.call(
      "update_id" => 1,
      "message" => {
        "message_id" => 900,
        "date" => 1_700_000_000,
        "chat" => { "id" => -100_111, "type" => "supergroup" }.merge(chat_overrides),
        "message_thread_id" => 142_483,
        "from" => { "id" => 55, "first_name" => "Ada" },
        "text" => "hello"
      }
    )
  end

  it "routes to the topic when chat.is_forum vouches for the thread id" do
    result = call("is_forum" => true)
    expect(result.origin.id).to eq("tg-topic")
  end

  it "routes to the bare chat endpoint when is_forum is absent, instead of dropping the message" do
    result = call({})
    expect(result.origin.id).to eq("tg-lobby")
  end

  it "routes to the bare chat endpoint when is_forum is explicitly false" do
    result = call("is_forum" => false)
    expect(result.origin.id).to eq("tg-lobby")
  end

  it "logs a debug line naming the chat when nothing resolves at all, rather than staying silent" do
    result = inbound.call(
      "update_id" => 2,
      "message" => {
        "message_id" => 901, "date" => 1_700_000_000, "chat" => { "id" => -1, "type" => "group" },
        "message_thread_id" => 142_483, "from" => { "id" => 55, "first_name" => "Ada" }, "text" => "hello"
      }
    )
    expect(result).to be_nil
    expect(logs.string).to include("DEBUG")
    # No is_forum on the chat, so the overloaded thread id is dropped before the
    # log line is built: the miss reads as the bare chat, not "-1/142483".
    expect(logs.string).to include("dropped a Telegram message in chat -1, no endpoint is bridged to it")
  end
end
