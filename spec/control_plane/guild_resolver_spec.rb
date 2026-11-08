# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::GuildResolver, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }

  # Stands in for a live Discord adapter that has learned the guild from the gateway.
  def discord_adapter(guild_id:)
    adapter = double("discord adapter")
    allow(adapter).to receive(:guild_id_for_channel).and_return(guild_id)
    adapter
  end

  def discord_connection
    models.platform_connection.where(adapter: "discord").first
  end

  it "starts with the seed's unresolved sentinel" do
    expect(discord_connection.external_id).to eq("unresolved:sample")
  end

  it "resolves the sentinel to the real guild id the adapter reports" do
    adapters = { [:discord, "discord"] => discord_adapter(guild_id: "998877665544332211") }
    resolved = described_class.resolve(models: models, adapters: adapters)

    expect(resolved).to eq(1)
    expect(discord_connection.reload.external_id).to eq("998877665544332211")
  end

  it "is idempotent: a resolved connection is skipped on the next pass" do
    adapters = { [:discord, "discord"] => discord_adapter(guild_id: "998877665544332211") }
    described_class.resolve(models: models, adapters: adapters)

    second = double("discord adapter after resolution")
    expect(second).not_to receive(:guild_id_for_channel)
    expect(described_class.resolve(models: models, adapters: { [:discord, "discord"] => second })).to eq(0)
  end

  it "leaves the sentinel in place when the adapter cannot see the guild yet" do
    adapters = { [:discord, "discord"] => discord_adapter(guild_id: nil) }
    expect(described_class.resolve(models: models, adapters: adapters)).to eq(0)
    expect(discord_connection.reload.external_id).to eq("unresolved:sample")
  end

  it "does nothing when no Discord adapter is present (Discord did not start)" do
    expect(described_class.resolve(models: models, adapters: {})).to eq(0)
    expect(discord_connection.reload.external_id).to eq("unresolved:sample")
  end

  # GUILD_CREATE carries the guild's id and channel ids, so a sentinel resolves with
  # no per-channel API call and the auto-leave guard recognises a seeded guild before
  # it can leave one.
  describe ".resolve_from_guild" do
    let(:seeded_channel) { models.channel.where(adapter: "discord").order(:id).first }

    it "resolves the sentinel from the guild's own channels and returns the connection" do
      result = described_class.resolve_from_guild(
        models: models, account: "discord", guild_id: "424242",
        channel_ids: ["999", seeded_channel.route_key]
      )
      expect(result.id).to eq(discord_connection.id)
      expect(discord_connection.reload.external_id).to eq("424242")
    end

    it "returns nil for a guild that owns no seeded channel, leaving the sentinel intact" do
      result = described_class.resolve_from_guild(
        models: models, account: "discord", guild_id: "424242", channel_ids: %w[111 222]
      )
      expect(result).to be_nil
      expect(discord_connection.reload.external_id).to eq("unresolved:sample")
    end

    it "recognises a guild already resolved to this id, leaving it as is" do
      discord_connection.update(external_id: "424242", updated_at: Time.at(0))
      result = described_class.resolve_from_guild(
        models: models, account: "discord", guild_id: "424242", channel_ids: [seeded_channel.route_key]
      )
      expect(result.id).to eq(discord_connection.id)
      # The row was not rewritten, so updated_at stays where the setup put it.
      expect(discord_connection.reload.external_id).to eq("424242")
      expect(discord_connection.updated_at).to eq(Time.at(0))
    end

    it "returns nil when no channel ids are known yet (the bot cannot see the guild)" do
      expect(described_class.resolve_from_guild(
               models: models, account: "discord", guild_id: "424242", channel_ids: []
             )).to be_nil
    end

    it "does not match a channel on a different account" do
      expect(described_class.resolve_from_guild(
               models: models, account: "other-bot", guild_id: "424242",
               channel_ids: [seeded_channel.route_key]
             )).to be_nil
    end
  end

  # The doubles above would still pass if guild_id_for_channel became private, and the
  # resolver reaches it through public dispatch, so drive the real adapter here.
  describe "against the real Discord adapter" do
    let(:client) { DiscordFakes::Client.new }
    let(:adapter) do
      account = sample_model.accounts["discord"]
      account.adapter_class.new(
        account: "discord", settings: account.settings,
        dispatcher: ->(_message) {}, logger: Rubotty::Log.null, endpoints: []
      ).tap { |a| a.replace_client(client) }
    end

    it "exposes guild_id_for_channel publicly, so the resolver can call it" do
      expect(adapter.respond_to?(:guild_id_for_channel)).to be(true)
    end

    it "resolves the sentinel from the adapter's live gateway knowledge" do
      # dc-general's channel_id, which is the connection's channel route_key.
      client.channel("800000000000000011").server = DiscordFakes::Server.new(id: "70707070")

      resolved = described_class.resolve(
        models: models, adapters: { [:discord, "discord"] => adapter }
      )
      expect(resolved).to eq(1)
      expect(discord_connection.reload.external_id).to eq("70707070")
    end
  end

  # GuildResolver used to filter its whole pending query on adapter:
  # "discord", so a seeded Stoat connection kept its sentinel forever even
  # though the Stoat adapter already knows each channel's server.
  describe "a seeded Stoat connection" do
    def build_stoat_fixture
      now = Time.now
      community = models.community.create(slug: "stoatcom", name: "Stoat Community", created_at: now,
                                           updated_at: now)
      connection = models.platform_connection.create(
        community_id: community.id, adapter: "stoat", account: "stoat",
        external_id: "unresolved:stoatcom", created_at: now, updated_at: now
      )
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id, adapter: "stoat", account: "stoat",
        route_key: "CHAN1", endpoint_key: "discovered:stoat:CHAN1", created_at: now, updated_at: now
      )
      connection
    end

    def stoat_adapter(server_id:)
      adapter = double("stoat adapter")
      allow(adapter).to receive(:guild_id_for_channel).and_return(server_id)
      adapter
    end

    it "starts with the seed's unresolved sentinel" do
      connection = build_stoat_fixture
      expect(connection.external_id).to eq("unresolved:stoatcom")
    end

    it "is included in the pending sweep alongside Discord" do
      build_stoat_fixture
      expect(described_class.pending(models).map(&:adapter)).to include("stoat", "discord")
    end

    it "resolves the sentinel to the server id the Stoat adapter reports" do
      connection = build_stoat_fixture
      adapters = { [:discord, "discord"] => discord_adapter(guild_id: "112233445566778899"),
                   [:stoat, "stoat"] => stoat_adapter(server_id: "SRV1") }

      resolved = described_class.resolve(models: models, adapters: adapters)

      expect(resolved).to eq(2)
      expect(connection.reload.external_id).to eq("SRV1")
      expect(discord_connection.reload.external_id).to eq("112233445566778899")
    end

    it "leaves the sentinel in place with no Stoat adapter present" do
      connection = build_stoat_fixture
      resolved = described_class.resolve(models: models, adapters: {})
      expect(resolved).to eq(0)
      expect(connection.reload.external_id).to eq("unresolved:stoatcom")
    end
  end
end
