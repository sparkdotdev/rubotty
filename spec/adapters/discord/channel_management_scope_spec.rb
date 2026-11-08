# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Issues #1782 and #1783. One Discord token serves both communities, and
# create_channel kept the deployment-wide fallback the native event path lost
# in #1767 on a line of its own, so a template-less provisioning request went
# into whichever guild the account knew first.
RSpec.describe Rubotty::Adapters::Discord::Adapter, "channel management on a shared token" do
  let(:client) { DiscordFakes::Client.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }
  let(:alpha) { CollidingCommunities::ALPHA }
  let(:beta) { CollidingCommunities::BETA }

  def discord_endpoints_of(spec)
    colliding_endpoints(spec[:slug], spec[:id], adapters: [:discord])
  end

  # Alpha's guild is the one the account resolves first, which is what a
  # template-less create used to pick no matter who asked for it.
  before do
    client.channel("alpha-discord-chan").server = DiscordFakes::Server.new(id: "guild-alpha", name: "ALPHA")
    client.channel("beta-discord-chan").server = DiscordFakes::Server.new(id: "guild-beta", name: "BETA")
  end

  let(:shared_token) do
    described_class.new(
      account: "shared", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: logger,
      endpoints: discord_endpoints_of(alpha) + discord_endpoints_of(beta)
    ).replace_client(client)
  end

  describe "#create_channel" do
    it "creates in the guild of the community being provisioned for" do
      shared_token.create_channel(name: "Gaming", community_id: beta[:id])

      expect(client.created_guild_channels.first[:guild_id]).to eq("guild-beta")
    end

    it "refuses a template naming a channel in the other community's guild" do
      created = shared_token.create_channel(name: "Gaming", community_id: beta[:id],
                                            template: "alpha-discord-chan")

      expect(created).to be_nil
      expect(client.created_guild_channels).to be_empty
    end

    it "refuses rather than guessing for a community that bridges no guild here" do
      expect(shared_token.create_channel(name: "Gaming", community_id: 99)).to be_nil
      expect(client.created_guild_channels).to be_empty
    end

    it "says at error level which community it could not place a channel for" do
      shared_token.create_channel(name: "Gaming", community_id: 99)

      expect(logs.string).to include("REFUSED", "99")
    end
  end

  describe "#delete_channel" do
    it "refuses a channel in the other community's guild rather than removing it" do
      expect(shared_token.delete_channel("alpha-discord-chan", community_id: beta[:id])).to be(false)
      expect(client.deleted_guild_channels).to be_empty
    end

    it "names the guild it refused to delete out of, at error level" do
      shared_token.delete_channel("alpha-discord-chan", community_id: beta[:id])

      expect(logs.string).to include("REFUSED", "guild-alpha")
    end

    it "still deletes a channel in the asking community's own guild" do
      shared_token.delete_channel("beta-discord-chan", community_id: beta[:id])

      expect(client.deleted_guild_channels).to eq(["beta-discord-chan"])
    end
  end

  # Issue #1783: the contract had no parameter for a community at all, which
  # is what forced every implementation to guess.
  describe "the shape of the calls" do
    it "has no overload of either call that takes a bare name or native id" do
      expect { shared_token.create_channel(name: "Gaming") }.to raise_error(ArgumentError)
      expect { shared_token.delete_channel("beta-discord-chan") }.to raise_error(ArgumentError)
    end

    it "refuses an explicit nil community rather than falling back to the account" do
      expect do
        shared_token.create_channel(name: "Gaming", community_id: nil)
      end.to raise_error(ArgumentError)
      expect do
        shared_token.delete_channel("beta-discord-chan", community_id: nil)
      end.to raise_error(ArgumentError)
    end
  end
end
