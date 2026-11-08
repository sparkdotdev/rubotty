# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Telegram allows no keycap reaction and lets a bot hold only one reaction on a
# message, so a poll card offers an inline keyboard there and a vote arrives as
# a callback query. Nothing else in the bridge produces this update.
RSpec.describe "a Telegram button press" do
  include Builders

  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  describe Rubotty::Adapters::Telegram::Inbound do
    let(:lobby) { endpoint("tg-lobby", adapter: :telegram, settings: { chat_id: "-100111" }) }
    let(:topic) do
      endpoint("tg-gaming", adapter: :telegram, settings: { chat_id: "-100111", thread_id: 77 })
    end
    let(:known) do
      lambda do |chat, thread|
        next nil unless chat.to_s == "-100111"

        thread.to_s == "77" ? topic : lobby
      end
    end

    subject(:inbound) { described_class.new(endpoint_for: known, logger: logger) }

    def press(overrides = {}, carrier: {})
      inbound.call(
        "update_id" => 9,
        "callback_query" => {
          "id" => "cb-1",
          "from" => { "id" => 55, "username" => "ada", "first_name" => "Ada", "is_bot" => false },
          "chat_instance" => "ci",
          "data" => "poll-option:2",
          "message" => {
            "message_id" => 700,
            "date" => 1_700_000_000,
            "chat" => { "id" => -100_111, "type" => "supergroup" }
          }.merge(carrier)
        }.merge(overrides)
      )
    end

    it "produces a press naming the card, the presser and the token that came back" do
      message = press

      expect(message.kind).to eq(:button_press)
      expect(message.ref.to_a).to eq(%w[tg-lobby 700])
      expect(message.author.username).to eq("ada")
      expect(message.button).to eq("poll-option:2")
    end

    # The card is in the forum topic the keyboard was tapped in, and unlike a
    # reaction update the query carries that topic itself.
    it "places a press in a forum topic from the message it came on" do
      message = press(carrier: { "message_thread_id" => 77,
                                 "chat" => { "id" => -100_111, "type" => "supergroup", "is_forum" => true } })

      expect(message.ref.endpoint_id).to eq("tg-gaming")
    end

    it "ignores a press carrying no data at all" do
      expect(press({ "data" => "" })).to be_nil
    end

    it "ignores a press naming nobody, there being no vote to attribute" do
      expect(press({ "from" => nil })).to be_nil
    end

    it "says which chat it dropped a press for when no endpoint answers" do
      expect(press(carrier: { "chat" => { "id" => -100_999, "type" => "supergroup" } })).to be_nil
      expect(logs.string).to include("dropped a Telegram button press on -100999:700")
    end
  end

  describe Rubotty::Adapters::Telegram::Adapter do
    let(:http) { Fakes::TelegramHttp.new }
    let(:dispatcher) { Fakes::RecordingDispatcher.new }
    let(:lobby) { endpoint("tg-lobby", adapter: :telegram, settings: { chat_id: "-1008000000001" }) }

    subject(:adapter) do
      described_class.new(
        account: "tg",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
        dispatcher: dispatcher,
        logger: logger,
        endpoints: [lobby]
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    def update(chat_id: -1008000000001)
      {
        "update_id" => 4,
        "callback_query" => {
          "id" => "cb-9",
          "from" => { "id" => 55, "username" => "ada", "is_bot" => false },
          "data" => "poll-option:1",
          "message" => {
            "message_id" => 700, "date" => 1_700_000_000,
            "chat" => { "id" => chat_id, "type" => "supergroup" }
          }
        }
      }
    end

    it "declares buttons, which is what a card reads before offering any" do
      expect(adapter.capabilities_for(lobby).buttons?).to be(true)
    end

    # Telegram keeps a spinner on the presser's client until the query is
    # answered, and the vote lands on another thread well after this returns.
    it "answers the query so the presser's client stops waiting" do
      adapter.handle_update(update)

      expect(http.last("answerCallbackQuery").params["callback_query_id"]).to eq("cb-9")
    end

    it "hands the press to the pipeline" do
      adapter.handle_update(update)

      expect(dispatcher.last.kind).to eq(:button_press)
      expect(dispatcher.last.button).to eq("poll-option:1")
    end

    it "still answers a press it can place nowhere, rather than leaving it spinning" do
      adapter.handle_update(update(chat_id: -1))

      expect(http.called?("answerCallbackQuery")).to be(true)
      expect(dispatcher.messages).to be_empty
    end

    it "carries on when Telegram refuses the answer, a query being answerable only once" do
      http.error_on("answerCallbackQuery", code: 400, description: "Bad Request: query is too old")

      expect { adapter.handle_update(update) }.not_to raise_error
      expect(dispatcher.last.kind).to eq(:button_press)
    end
  end
end
