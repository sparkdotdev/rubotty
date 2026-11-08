# frozen_string_literal: true

require "spec_helper"

# An RSVP reaction on an event card posted into a forum topic that shares its
# chat with other bridged topics used to resolve to the wrong endpoint. A card
# goes straight through Adapter#deliver rather than being relayed, so the
# message map never learns it, and #endpoint_holding fell to a bare-chat guess.
RSpec.describe "a Telegram reaction on an event card in a forum topic" do
  include Builders

  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:topic) do
    endpoint("tg-topic", adapter: :telegram, settings: { chat_id: "-1008000000001", thread_id: 678 })
  end
  let(:general) do
    endpoint("tg-general", adapter: :telegram, settings: { chat_id: "-1008000000001" })
  end

  # Stands in for Events::Announcer#holds_card?, whose own coverage lives in
  # spec/events/announcer_spec.rb; this exercises only the adapter's side of
  # the contract, the same seam #card_lookup is injected through.
  let(:card_lookup) { instance_double(Rubotty::Events::Announcer) }

  def build(endpoints)
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: endpoints
    ).replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http)
    ).tap do |adapter|
      adapter.storage = storage
      adapter.card_lookup = card_lookup
    end
  end

  def reaction(message_id: 900)
    {
      "update_id" => 11,
      "message_reaction" => {
        "chat" => { "id" => -1008000000001, "type" => "supergroup", "is_forum" => true },
        "message_id" => message_id,
        "date" => 1_700_000_100,
        "user" => { "id" => 55, "first_name" => "Ada", "username" => "ada" },
        "old_reaction" => [],
        "new_reaction" => [{ "type" => "emoji", "emoji" => "👍" }]
      }
    }
  end

  context "when the chat bridges more than one topic and the message map has no row" do
    subject(:adapter) { build([general, topic]) }

    it "asks the card lookup and resolves to the endpoint holding the card" do
      allow(card_lookup).to receive(:holds_card?).with("tg-general", 900).and_return(false)
      allow(card_lookup).to receive(:holds_card?).with("tg-topic", 900).and_return(true)

      adapter.handle_update(reaction)

      expect(dispatcher.last.origin.id).to eq("tg-topic")
    end

    it "still prefers the message map over the card lookup when both could answer" do
      storage.record(
        source: Rubotty::Core::MessageRef.new("tg-topic", 900),
        destination: Rubotty::Core::MessageRef.new("dc-room", "77"),
        room_id: "r1"
      )
      allow(card_lookup).to receive(:holds_card?).and_return(false)

      adapter.handle_update(reaction)

      expect(dispatcher.last.origin.id).to eq("tg-topic")
      expect(card_lookup).not_to have_received(:holds_card?)
    end

    it "drops the reaction when neither source can say, rather than guessing the bare chat id" do
      allow(card_lookup).to receive(:holds_card?).and_return(false)

      adapter.handle_update(reaction)

      expect(dispatcher.last).to be_nil
    end

    it "still drops the reaction with no card lookup wired at all" do
      bare = build([general, topic])
      bare.card_lookup = nil

      bare.handle_update(reaction)

      expect(dispatcher.last).to be_nil
    end
  end
end
