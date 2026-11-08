# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A reaction in a forum topic was dropped before the bridge ever saw it: both
# reaction updates carry no message_thread_id, so the lookup used the bare
# chat id while the endpoint was bridged as "<chat_id>/<topic>", and the miss
# was silent, so a reaction in a travel topic mirrored into General instead.
RSpec.describe "a Telegram reaction in a forum topic" do
  include Builders

  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "debug", io: logs) }

  let(:topic) do
    endpoint("tg-topic", adapter: :telegram, settings: { chat_id: "-1008000000001", thread_id: 678 })
  end
  let(:general) do
    endpoint("tg-general", adapter: :telegram, settings: { chat_id: "-1008000000001" })
  end

  def build(endpoints)
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: dispatcher,
      logger: logger,
      endpoints: endpoints
    ).replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http)
    ).tap { |adapter| adapter.storage = storage }
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
        "new_reaction" => [{ "type" => "emoji", "emoji" => "🤣" }]
      }
    }
  end

  def reaction_count(message_id: 900)
    {
      "update_id" => 12,
      "message_reaction_count" => {
        "chat" => { "id" => -1008000000001, "type" => "supergroup", "is_forum" => true },
        "message_id" => message_id,
        "date" => 1_700_000_100,
        "reactions" => [{ "type" => { "type" => "emoji", "emoji" => "🤣" }, "total_count" => 2 }]
      }
    }
  end

  context "when the topic is the only endpoint bridged in the chat" do
    subject(:adapter) { build([topic]) }

    it "resolves to the topic and relays, instead of dropping the update" do
      adapter.handle_update(reaction)
      relayed = dispatcher.messages
      expect(relayed.size).to eq(1)
      expect(relayed.first.kind).to eq(:reaction_add)
      expect(relayed.first.origin.id).to eq("tg-topic")
      expect(relayed.first.ref.to_a).to eq(%w[tg-topic 900])
    end

    it "resolves a count-only update to the topic as well" do
      adapter.handle_update(reaction_count)
      expect(dispatcher.last.kind).to eq(:reaction_sync)
      expect(dispatcher.last.origin.id).to eq("tg-topic")
    end

    it "needs no message map row, so an aged out message still resolves" do
      expect(storage.size).to be_zero
      adapter.handle_update(reaction)
      expect(dispatcher.last.origin.id).to eq("tg-topic")
    end
  end

  context "when the chat bridges its General topic as well" do
    subject(:adapter) { build([general, topic]) }

    it "asks the message map which endpoint holds the message we relayed from there" do
      storage.record(
        source: Rubotty::Core::MessageRef.new("tg-topic", 900),
        destination: Rubotty::Core::MessageRef.new("dc-room", "77"),
        room_id: "r1"
      )
      adapter.handle_update(reaction)
      expect(dispatcher.last.origin.id).to eq("tg-topic")
    end

    it "reads the map the other way too, for a copy we wrote into the topic" do
      storage.record(
        source: Rubotty::Core::MessageRef.new("dc-room", "77"),
        destination: Rubotty::Core::MessageRef.new("tg-topic", 901),
        room_id: "r1"
      )
      adapter.handle_update(reaction(message_id: 901))
      expect(dispatcher.last.origin.id).to eq("tg-topic")
    end

    # General is one candidate among several, so answering with it is a guess,
    # and a wrong guess puts somebody's reaction in front of a different room.
    it "drops the reaction rather than attributing it to General" do
      expect(adapter.handle_update(reaction)).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    it "says at debug why it dropped it" do
      adapter.handle_update(reaction)
      expect(logs.string).to include("its topic could not be determined")
      expect(logs.string).to include("2 endpoints bridged in that chat")
    end

    it "drops a count-only update the map cannot place either" do
      expect(adapter.handle_update(reaction_count)).to be_nil
      expect(dispatcher.messages).to be_empty
    end

    # The map answering false because storage was unreachable is exactly the
    # case the old fallback turned into a confident wrong answer.
    it "drops it when the message map cannot be read at all" do
      allow(storage).to receive(:counterparts).and_raise(Rubotty::StorageError, "no connection")
      expect(adapter.handle_update(reaction)).to be_nil
      expect(dispatcher.messages).to be_empty
    end
  end

  # The deployment that hit this runs on the control plane, so the endpoints
  # come from the live snapshot rather than the boot-time index.
  context "when the endpoints come from a live resolver", :control_plane do
    let(:models) { seeded_sample[1] }
    let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts) }
    let(:resolver) { Rubotty::ControlPlane::ChannelResolver.new(registry) }

    subject(:adapter) do
      Rubotty::Adapters::Telegram::Adapter.new(
        account: "telegram",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TELEGRAM_BOT_TOKEN" },
        dispatcher: dispatcher,
        logger: logger,
        endpoints: [],
        endpoint_resolver: resolver
      ).replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http)
      ).tap { |built| built.storage = storage }
    end

    it "resolves to the topic the message map names, not to General" do
      storage.record(
        source: Rubotty::Core::MessageRef.new("tg-gaming", 900),
        destination: Rubotty::Core::MessageRef.new("dc-gaming", "77"),
        room_id: "gaming"
      )
      adapter.handle_update(reaction)
      expect(dispatcher.last.origin.id).to eq("tg-gaming")
    end

    it "drops a message the map does not name, rather than sending it to General" do
      expect(adapter.handle_update(reaction)).to be_nil
      expect(dispatcher.messages).to be_empty
    end
  end

  context "when nothing in the chat is bridged" do
    subject(:adapter) { build([]) }

    it "still drops the update" do
      expect(adapter.handle_update(reaction)).to be_nil
      expect(dispatcher.messages).to be_empty
    end
  end
end
