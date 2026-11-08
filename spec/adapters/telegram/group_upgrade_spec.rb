# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Turning on topics upgrades a basic group to a supergroup under a new chat id.
# Telegram announces it with a service message in each chat and refuses every
# later send to the old id, naming the new one; the mapped channel has to follow.
RSpec.describe Rubotty::Adapters::Telegram::Adapter, "following a group upgraded to a supergroup" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:logs) { StringIO.new }
  let(:old_chat) { -5_223_379_096 }
  let(:new_chat) { -1_004_429_957_423 }
  let(:migration) { instance_spy(Rubotty::ControlPlane::SpaceMigration) }
  let(:discovery) { instance_spy(Rubotty::ControlPlane::ChannelDiscovery) }
  let(:general) { endpoint("tg-general", adapter: :telegram, settings: { chat_id: old_chat.to_s }) }

  def adapter_with(space_migration:, endpoint_resolver: nil, endpoints: [general])
    described_class.new(
      account: "telegram",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.build(level: "debug", io: logs),
      endpoints: endpoints, endpoint_resolver: endpoint_resolver, discovery: discovery
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http)).tap do |adapter|
      adapter.space_migration = space_migration
    end
  end

  def service_message(chat_id, type, extra)
    { "update_id" => 7, "message" => {
      "message_id" => 1, "date" => 1_759_000_000, "chat" => { "id" => chat_id, "type" => type, "title" => "SECOND" },
      "from" => { "id" => 55, "first_name" => "Ada", "is_bot" => false }
    }.merge(extra) }
  end

  def upgraded_in_old_chat = service_message(old_chat, "group", "migrate_to_chat_id" => new_chat)

  def upgraded_in_new_chat = service_message(new_chat, "supergroup", "migrate_from_chat_id" => old_chat)

  def refuse_as_upgraded
    http.error_on("sendMessage", code: 400, description: "Bad Request: group chat was upgraded to a supergroup chat",
                                 parameters: { "migrate_to_chat_id" => new_chat })
  end

  it "follows the service message the old chat receives" do
    adapter_with(space_migration: migration).handle_update(upgraded_in_old_chat)

    expect(migration).to have_received(:call)
      .with(adapter: :telegram, account: "telegram", from: old_chat.to_s, to: new_chat.to_s)
  end

  it "follows the service message the new chat receives" do
    adapter_with(space_migration: migration).handle_update(upgraded_in_new_chat)

    expect(migration).to have_received(:call)
      .with(adapter: :telegram, account: "telegram", from: old_chat.to_s, to: new_chat.to_s)
  end

  it "neither relays nor discovers either service message" do
    adapter = adapter_with(space_migration: migration)
    adapter.handle_update(upgraded_in_old_chat)
    adapter.handle_update(upgraded_in_new_chat)

    expect(dispatcher.messages).to be_empty
    expect(discovery).not_to have_received(:saw)
  end

  it "follows the refusal a send to the old chat gets back" do
    refuse_as_upgraded

    expect { adapter_with(space_migration: migration).deliver(message(general, text: "hi"), general) }
      .to raise_error(Rubotty::Adapters::Telegram::ChatMigratedError)
    expect(migration).to have_received(:call)
      .with(adapter: :telegram, account: "telegram", from: old_chat.to_s, to: new_chat.to_s)
  end

  it "names the new chat id for the configuration when there is no control plane to rewrite" do
    refuse_as_upgraded

    expect { adapter_with(space_migration: nil).deliver(message(general, text: "hi"), general) }
      .to raise_error(Rubotty::AdapterError)
    expect(logs.string).to include("chat #{old_chat} was upgraded to supergroup #{new_chat}")
  end

  describe "against a real control plane", :control_plane do
    let(:db) { migrated_db }
    let(:models) { build_models(db) }
    let(:registry) { Rubotty::ControlPlane::Registry.build(models: models) }
    let(:resolver) { Rubotty::ControlPlane::ChannelResolver.new(registry) }
    let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }
    let(:service) do
      Rubotty::ControlPlane::SpaceMigration.new(models: models, registry: registry, logger: Rubotty::Log.null)
    end
    let(:adapter) { adapter_with(space_migration: service, endpoint_resolver: resolver, endpoints: []) }

    def stamp = { created_at: now, updated_at: now }

    before do
      community = models.community.create(slug: "second", name: "SECOND", status: "active", **stamp)
      room = models.room.create(community_id: community.id, room_key: "general", label: "general", **stamp)
      [["telegram", old_chat.to_s, { "chat_id" => old_chat.to_s }],
       ["discord", "1427709346040512650", { "channel_id" => "1427709346040512650" }]].each do |adapter, id, settings|
        space = models.platform_connection.create(community_id: community.id, adapter: adapter, account: adapter,
                                                  external_id: id, **stamp)
        channel = models.channel.create(
          community_id: community.id, platform_connection_id: space.id, adapter: adapter, account: adapter,
          route_key: id, endpoint_key: "discovered:#{adapter}:#{adapter}:#{id}", settings: JSON.generate(settings),
          **stamp
        )
        models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: now)
      end
    end

    def bridged = registry.current.resolve(:telegram, "telegram", new_chat.to_s)&.endpoint

    def chat_in_new_chat
      service_message(new_chat, "supergroup", "message_id" => 2, "text" => "hello from the supergroup")
    end

    it "bridges the new chat into the old channel's room once the upgrade is announced" do
      adapter.handle_update(upgraded_in_old_chat)

      expect(registry.current.topology.rooms_for(bridged.id).map(&:id)).to eq(["general"])
      adapter.handle_update(chat_in_new_chat)
      expect(dispatcher.messages.map { |message| message.origin.id }).to eq([bridged.id])
    end

    it "sends to the new chat after the first send to the old one was refused" do
      stale = registry.current.resolve(:telegram, "telegram", old_chat.to_s).endpoint
      refuse_as_upgraded
      expect { adapter.deliver(message(stale, text: "lost"), stale) }.to raise_error(Rubotty::AdapterError)

      adapter.deliver(message(bridged, text: "found"), bridged)
      expect(http.last("sendMessage").params["chat_id"]).to eq(new_chat.to_s)
    end
  end
end
