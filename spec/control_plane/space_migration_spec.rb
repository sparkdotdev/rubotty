# frozen_string_literal: true

require "spec_helper"

# Turning on topics upgrades a Telegram basic group to a supergroup under a new
# chat id. SECOND's general room kept relaying to the dead id until the new chat
# was mapped by hand as a second channel.
RSpec.describe Rubotty::ControlPlane::SpaceMigration, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.utc(2026, 10, 4, 12, 0, 0) }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models) }
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }
  let(:old_chat) { "-5223379096" }
  let(:new_chat) { "-1008000000004" }
  let(:new_key) { "discovered:telegram:telegram:#{new_chat}" }

  subject(:migration) do
    described_class.new(models: models, registry: registry, audit: audit, logger: Rubotty::Log.null,
                        clock: -> { now })
  end

  def community(slug)
    models.community.create(slug: slug, name: slug.upcase, status: "active", created_at: now, updated_at: now)
  end

  def space(community, external_id, adapter: "telegram")
    models.platform_connection.create(community_id: community.id, adapter: adapter, account: adapter,
                                      external_id: external_id, created_at: now, updated_at: now)
  end

  def channel(space, route_key, settings: { "chat_id" => route_key })
    key = Rubotty::ControlPlane::ChannelDiscovery.endpoint_key_for(space.adapter, space.account, route_key)
    models.channel.create(
      community_id: space.community_id, platform_connection_id: space.id, adapter: space.adapter,
      account: space.account, route_key: route_key, endpoint_key: key, label: "SECOND",
      settings: JSON.generate(settings), created_at: now, updated_at: now
    )
  end

  def room(community, key, *channels)
    row = models.room.create(community_id: community.id, room_key: key, label: key, created_at: now, updated_at: now)
    channels.each { |member| models.room_channel.create(room_id: row.id, channel_id: member.id, created_at: now) }
    row
  end

  def members(room) = models.room_channel.where(room_id: room.id).select_map(:channel_id)

  def migrate = migration.call(adapter: :telegram, account: "telegram", from: old_chat, to: new_chat)

  let!(:second) { community("second") }
  let!(:old_space) { space(second, old_chat) }
  let!(:old_channel) { channel(old_space, old_chat, settings: { "chat_id" => old_chat, "sender_prefix" => false }) }
  let!(:discord) do
    channel(space(second, "8000000000000000010", adapter: "discord"), "1427709346040512650",
            settings: { "channel_id" => "1427709346040512650" })
  end

  describe "when nothing holds the new chat yet" do
    let!(:general) { room(second, "general", old_channel, discord) }

    it "readdresses the mapped channel to the supergroup, still in its room" do
      expect(migrate.status).to eq(:migrated)

      resolved = registry.current.resolve(:telegram, "telegram", new_chat)
      expect(resolved.endpoint.settings[:chat_id]).to eq(new_chat)
      expect(registry.current.topology.rooms_for(resolved.endpoint.id).map(&:id)).to eq(["general"])
      expect(registry.current.resolve(:telegram, "telegram", old_chat)).to be_nil
    end

    # A message id remembered from the old chat would name an unrelated message
    # in the new one, so nothing keyed by the old endpoint may reach it.
    it "keeps the row and its settings under a key naming the new chat" do
      migrate

      row = models.channel[old_channel.id]
      expect(row.endpoint_key).to eq(new_key)
      expect(row.json_value(:settings)).to eq("chat_id" => new_chat, "sender_prefix" => false)
      expect(members(general)).to contain_exactly(row.id, discord.id)
    end

    it "moves the community's connection onto the new chat id" do
      migrate

      expect(old_space.reload.external_id).to eq(new_chat)
      expect(old_space.community_id).to eq(second.id)
    end

    it "settles a pending review the new chat's own traffic opened" do
      pending = models.pending_space.create(adapter: "telegram", account: "telegram", external_id: new_chat,
                                            state: "pending", expires_at: now + 1800, created_at: now,
                                            updated_at: now)
      migrate

      expect(pending.reload.state).to eq("approved")
      expect(pending.community_id).to eq(second.id)
    end

    it "records the move in the community's audit trail" do
      migrate

      event = audit.query(community: "second", action: "space_migrated").first
      expect(event.metadata).to include("from" => old_chat, "to" => new_chat,
                                        "renamed" => { old_channel.endpoint_key => new_key })
    end

    it "finds nothing left to move when the second service message arrives" do
      migrate

      expect(migrate.status).to eq(:unknown)
      expect(models.channel[old_channel.id].route_key).to eq(new_chat)
    end
  end

  describe "when the community already maps the new chat, as SECOND did by hand" do
    let!(:new_space) { space(second, new_chat) }
    let!(:new_channel) { channel(new_space, new_chat) }
    let!(:general) { room(second, "general", old_channel, new_channel, discord) }

    it "retires the old channel into the mapped one instead of making a duplicate" do
      expect(migrate.retired).to eq(old_channel.endpoint_key => new_key)

      expect(models.channel[old_channel.id]).to be_nil
      expect(models.channel.where(adapter: "telegram", route_key: new_chat).select_map(:id)).to eq([new_channel.id])
    end

    it "leaves the room bridging the supergroup exactly once" do
      migrate

      expect(members(general)).to contain_exactly(new_channel.id, discord.id)
      expect(registry.current.topology.rooms_for(new_key).map(&:id)).to eq(["general"])
    end

    it "carries the supergroup into a room only the old channel was in" do
      announcements = room(second, "announcements", old_channel)
      migrate

      expect(members(announcements)).to eq([new_channel.id])
    end

    it "keeps a guest invite that named the old channel" do
      invite = models.guest_invite.create(
        community_id: second.id, channel_id: old_channel.id, room_id: general.id, nickname: "visitor",
        token_hash: "a" * 64, expires_at: now + 3600, created_at: now, updated_at: now
      )
      migrate

      expect(invite.reload.channel_id).to eq(new_channel.id)
    end

    it "drops the connection to the dead chat once nothing is left on it" do
      migrate

      expect(models.platform_connection.where(adapter: "telegram", external_id: old_chat).count).to eq(0)
      expect(new_space.reload.community_id).to eq(second.id)
    end
  end

  describe "when another community holds the new chat" do
    let!(:general) { room(second, "general", old_channel, discord) }
    let!(:elsewhere) { community("elsewhere") }
    let!(:their_space) { space(elsewhere, new_chat) }
    let!(:their_channel) { channel(their_space, new_chat) }

    it "refuses, leaving both communities exactly as they were" do
      expect(migrate.status).to eq(:refused)

      expect(models.channel[old_channel.id].route_key).to eq(old_chat)
      expect(old_space.reload.external_id).to eq(old_chat)
      expect(members(general)).to contain_exactly(old_channel.id, discord.id)
      expect(models.channel[their_channel.id].community_id).to eq(elsewhere.id)
      expect(models.room_channel.where(channel_id: their_channel.id).count).to eq(0)
    end

    it "notes the refusal for the community that asked, without naming the other" do
      migrate

      event = audit.query(community: "second", action: "space_migration_refused").first
      expect(event.metadata).to eq("from" => old_chat, "to" => new_chat)
      expect(audit.query(community: "elsewhere")).to be_empty
    end
  end

  it "does nothing for a chat no community holds" do
    result = migration.call(adapter: :telegram, account: "telegram", from: "-4000000001", to: "-1004000000001")

    expect(result.status).to eq(:unknown)
    expect(models.platform_connection.where(external_id: "-1004000000001").count).to eq(0)
  end
end
