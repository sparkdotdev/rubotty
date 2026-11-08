# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Issue #1800, a live functional bug as well as a scoping one. The selection
# keyed on endpoint.settings[:guild_id], which ChannelDiscovery never stamps,
# so guild member events routed nowhere at all; and it ran across every
# community on the account, so once it did match it would match both.
RSpec.describe Rubotty::Adapters::Discord::Adapter, "guild member fan-out across tenants" do
  let(:client) { DiscordFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }
  let(:ada) { DiscordFakes.user(id: "55", username: "ada", global_name: "Ada L") }
  let(:alpha) { CollidingCommunities::ALPHA }
  let(:beta) { CollidingCommunities::BETA }

  def discord_endpoints_of(spec)
    colliding_endpoints(spec[:slug], spec[:id], adapters: [:discord])
  end

  # Neither channel row carries a guild_id, which is the live shape: the guild
  # is only ever resolvable off the gateway.
  def place(slug, guild_id)
    client.channel("#{slug}-discord-chan").server = DiscordFakes::Server.new(id: guild_id, name: guild_id)
  end

  def member_adapter
    described_class.new(
      account: "shared", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: dispatcher, logger: logger,
      endpoints: discord_endpoints_of(alpha) + discord_endpoints_of(beta)
    ).replace_client(client).tap(&:start)
  end

  def member_event(guild_id)
    DiscordFakes::MemberEvent.new(user: ada, server: DiscordFakes::Server.new(id: guild_id, name: guild_id))
  end

  context "with each community in its own guild" do
    before do
      place("alpha", "guild-alpha")
      place("beta", "guild-beta")
    end

    it "routes a join at all, which selecting on the unstamped guild_id setting never did" do
      member_adapter
      client.fire(:member_join, member_event("guild-beta"))

      expect(dispatcher.messages.map { |m| m.origin.id }).to eq(["beta-discord"])
    end

    it "leaves the other community's channels out of it" do
      member_adapter
      client.fire(:member_leave, member_event("guild-beta"))

      expect(dispatcher.messages.map { |m| m.origin.id }).not_to include("alpha-discord")
    end

    it "still does nothing for a guild no endpoint bridges, rather than guessing one" do
      member_adapter
      client.fire(:member_join, member_event("guild-nobody"))

      expect(dispatcher.messages).to be_empty
    end
  end

  context "with both communities bridging channels in one guild" do
    before do
      place("alpha", "guild-shared")
      place("beta", "guild-shared")
    end

    it "refuses the fan-out rather than announcing one tenant's arrivals in the other's channels" do
      member_adapter
      client.fire(:member_join, member_event("guild-shared"))

      expect(dispatcher.messages).to be_empty
    end

    it "names both communities it could not choose between, at error level" do
      member_adapter
      client.fire(:member_join, member_event("guild-shared"))

      expect(logs.string).to include("REFUSED", alpha[:id].to_s, beta[:id].to_s)
    end
  end

  # A seeded channel does carry a guild_id, which is the only shape the old
  # selection ever matched, so it is where the cross-tenant fan-out was
  # reachable rather than merely latent.
  context "with both communities' channels carrying the same guild_id setting" do
    def stamped(spec, guild_id)
      discord_endpoints_of(spec).map do |ep|
        Rubotty::Core::Endpoint.owned_by(
          ep.community_id, id: ep.id, adapter_name: :discord, account: ep.account,
          settings: ep.settings.merge(guild_id: guild_id)
        )
      end
    end

    subject(:adapter) do
      described_class.new(
        account: "shared", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: logger,
        endpoints: stamped(alpha, "guild-shared") + stamped(beta, "guild-shared")
      ).replace_client(client).tap(&:start)
    end

    it "refuses rather than delivering the join into both tenants" do
      adapter
      client.fire(:member_join, member_event("guild-shared"))

      expect(dispatcher.messages).to be_empty
    end

    it "still delivers where only one community carries the guild" do
      described_class.new(
        account: "shared", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
        dispatcher: dispatcher, logger: logger,
        endpoints: stamped(beta, "guild-shared")
      ).replace_client(client).start
      client.fire(:member_join, member_event("guild-shared"))

      expect(dispatcher.messages.map { |m| m.origin.id }).to eq(["beta-discord"])
    end
  end
end
