# frozen_string_literal: true

require "spec_helper"

# The operations core a Platforms page and the REST admin API drive to add, edit,
# list and remove a community's IRC networks.
RSpec.describe Rubotty::ControlPlane::IrcNetworks, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "sample", name: "SAMPLE", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end
  let(:other_community) do
    models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  subject(:networks) { described_class.new(models: models, clock: -> { now }) }

  def create_network(overrides = {})
    networks.create(**{
      community: community, name: "Libera", host: "irc.libera.chat", port: 6697, tls: true,
      nick: "rubotty", sasl_user: nil, sasl_password_env: nil, channels: [], mode: "per_room",
      hub_channel: nil, channel_keys: {}
    }.merge(overrides))
  end

  describe "#create" do
    it "creates a per_room network with its defaults" do
      row = create_network
      expect(row.name).to eq("Libera")
      expect(row.host).to eq("irc.libera.chat")
      expect(row.mode).to eq("per_room")
      expect(row.hub_channel).to be_nil
    end

    it "creates a hub network carrying its hub_channel" do
      row = create_network(mode: "hub", hub_channel: "#community")
      expect(row.mode).to eq("hub")
      expect(row.hub_channel).to eq("#community")
    end

    it "defaults port to 6697 and tls to true when blank" do
      row = networks.create(community: community, name: "Libera", host: "irc.libera.chat", port: nil, tls: nil,
                             nick: "rubotty", sasl_user: nil, sasl_password_env: nil, channels: [], mode: nil,
                             hub_channel: nil, channel_keys: {})
      expect(row.port).to eq(6697)
      expect(row.tls).to be(true)
    end

    it "defaults mode to per_room, matching the column's own default" do
      row = create_network(mode: nil)
      expect(row.mode).to eq("per_room")
    end

    it "rejects a blank name" do
      expect do
        create_network(name: "  ")
      end.to raise_error(described_class::Invalid, /name/)
    end

    it "rejects a blank host" do
      expect do
        create_network(host: "  ")
      end.to raise_error(described_class::Invalid, /host/)
    end

    it "rejects a blank nick" do
      expect do
        create_network(nick: "  ")
      end.to raise_error(described_class::Invalid, /nick/)
    end

    it "rejects an unknown mode" do
      expect do
        create_network(mode: "bogus")
      end.to raise_error(described_class::Invalid, /must be one of/)
    end

    it "rejects a hub network with no hub_channel" do
      expect do
        create_network(mode: "hub", hub_channel: nil)
      end.to raise_error(described_class::Invalid, /hub_channel/)
    end

    it "rejects a hub network whose hub_channel is blank" do
      expect do
        create_network(mode: "hub", hub_channel: "   ")
      end.to raise_error(described_class::Invalid, /hub_channel/)
    end

    it "clears a stray hub_channel submitted alongside mode per_room" do
      row = create_network(mode: "per_room", hub_channel: "#community")
      expect(row.hub_channel).to be_nil
    end

    it "accepts channels and channel_keys" do
      row = create_network(channels: ["#general", "#offtopic"],
                            channel_keys: { "#ops" => "IRC_OPS_CHANNEL_KEY" })
      expect(JSON.parse(row.channels)).to eq(%w[#general #offtopic])
      expect(JSON.parse(row.channel_keys)).to eq({ "#ops" => "IRC_OPS_CHANNEL_KEY" })
    end

    it "accepts sasl_user and sasl_password_env" do
      row = create_network(sasl_user: "rubotty", sasl_password_env: "IRC_LIBERA_SASL_PASSWORD")
      expect(row.sasl_user).to eq("rubotty")
      expect(row.sasl_password_env).to eq("IRC_LIBERA_SASL_PASSWORD")
    end

    it "rejects two networks with the same name in one community" do
      create_network(name: "Libera")
      expect do
        create_network(name: "Libera", host: "irc.libera.chat")
      end.to raise_error(described_class::Invalid, /already exists/)
    end

    it "allows the same name across two different communities" do
      create_network(name: "Libera")
      expect do
        create_network(name: "Libera", community: other_community)
      end.not_to raise_error
    end

    it "reports every problem in one pass rather than only the first" do
      expect do
        create_network(name: "  ", host: "  ", nick: "  ")
      end.to raise_error(described_class::Invalid) do |error|
        expect(error.message).to match(/name/)
        expect(error.message).to match(/host/)
        expect(error.message).to match(/nick/)
      end
    end
  end

  describe "#update" do
    let!(:row) { create_network }

    it "switches an existing network from per_room to hub" do
      updated = networks.update(network: row, name: "Libera", host: "irc.libera.chat", port: 6697, tls: true,
                                nick: "rubotty", sasl_user: nil, sasl_password_env: nil, channels: [],
                                mode: "hub", hub_channel: "#community", channel_keys: {})
      expect(updated.mode).to eq("hub")
      expect(updated.hub_channel).to eq("#community")
    end

    it "switches an existing network from hub back to per_room, dropping the hub_channel" do
      networks.update(network: row, name: "Libera", host: "irc.libera.chat", port: 6697, tls: true,
                      nick: "rubotty", sasl_user: nil, sasl_password_env: nil, channels: [], mode: "hub",
                      hub_channel: "#community", channel_keys: {})
      updated = networks.update(network: row.refresh, name: "Libera", host: "irc.libera.chat", port: 6697,
                                tls: true, nick: "rubotty", sasl_user: nil, sasl_password_env: nil,
                                channels: [], mode: "per_room", hub_channel: "#community", channel_keys: {})
      expect(updated.mode).to eq("per_room")
      expect(updated.hub_channel).to be_nil
    end

    it "rejects switching to hub with no hub_channel" do
      expect do
        networks.update(network: row, name: "Libera", host: "irc.libera.chat", port: 6697, tls: true,
                        nick: "rubotty", sasl_user: nil, sasl_password_env: nil, channels: [], mode: "hub",
                        hub_channel: nil, channel_keys: {})
      end.to raise_error(described_class::Invalid, /hub_channel/)
    end

    it "leaves the row unchanged when the edit is invalid" do
      expect do
        networks.update(network: row, name: "", host: "irc.libera.chat", port: 6697, tls: true, nick: "rubotty",
                        sasl_user: nil, sasl_password_env: nil, channels: [], mode: "per_room", hub_channel: nil,
                        channel_keys: {})
      end.to raise_error(described_class::Invalid)
      expect(row.refresh.name).to eq("Libera")
    end
  end

  describe "#list" do
    it "lists only the calling community's networks, ordered by name" do
      create_network(name: "Zeta net")
      create_network(name: "Alpha net")
      create_network(name: "Not mine", community: other_community)

      expect(networks.list(community: community).map(&:name)).to eq(["Alpha net", "Zeta net"])
    end
  end

  describe "#remove" do
    it "removes a network and returns true" do
      row = create_network
      expect(networks.remove(community: community, id: row.id)).to be(true)
      expect(models.irc_network[row.id]).to be_nil
    end

    it "returns false and removes nothing for an id from a different community" do
      row = create_network
      expect(networks.remove(community: other_community, id: row.id)).to be(false)
      expect(models.irc_network[row.id]).not_to be_nil
    end

    it "returns false for an unknown id" do
      expect(networks.remove(community: community, id: 999_999)).to be(false)
    end
  end

  # Nothing downstream read this table before: #live is what turns a saved
  # network row into a gateway Core::Runtime actually brings up.
  describe "#live" do
    let(:env) { { "IRC_LIBERA_SASL_PASSWORD" => "s3cret" } }

    it "resolves a row into a Config::Account for the irc adapter" do
      create_network(host: "irc.libera.chat", nick: "rubotty")
      account = networks.live(env: env).first
      expect(account).to be_a(Rubotty::Config::Account)
      expect(account.adapter_name).to eq(:irc)
      expect(account.adapter_class).to eq(Rubotty::Adapters::Irc::Adapter)
      expect(account.settings[:server]).to eq("irc.libera.chat")
      expect(account.settings[:nick]).to eq("rubotty")
    end

    it "resolves sasl_password_env against the environment, exactly as the loader does" do
      create_network(sasl_user: "rubotty", sasl_password_env: "IRC_LIBERA_SASL_PASSWORD")
      expect(networks.live(env: env).first.settings[:sasl_password]).to eq("s3cret")
    end

    it "carries mode and hub_channel through for a hub network" do
      create_network(mode: "hub", hub_channel: "#community")
      account = networks.live(env: env).first
      expect(account.settings[:mode]).to eq(:hub)
      expect(account.settings[:hub_channel]).to eq("#community")
    end

    # irc_networks_name_idx only scopes uniqueness to one community, so the
    # flat account namespace active_accounts needs has to disambiguate itself.
    it "namespaces the account name by community, so two communities may reuse a network name" do
      create_network(name: "Libera", community: community)
      create_network(name: "Libera", community: other_community)
      names = networks.live(env: env).map(&:name)
      expect(names.uniq).to eq(names)
    end

    # Written straight at the model, bypassing #create's own validation, the
    # way a row that predates a stricter rule could look.
    def broken_row
      models.irc_network.create(community_id: community.id, name: "broken", host: "irc.example.org", port: 6697,
                                tls: true, nick: "rubotty", channels: "[]", mode: "hub", hub_channel: nil,
                                channel_keys: "{}", created_at: now, updated_at: now)
    end

    it "skips a row whose stored settings no longer validate, keeping the good ones" do
      create_network(host: "irc.libera.chat", nick: "rubotty")
      broken_row
      expect(networks.live(env: env).size).to eq(1)
    end

    it "logs why a row was skipped, which is the only way an operator finds out" do
      logger = instance_spy(Logger)
      broken_row
      described_class.new(models: models, logger: logger, clock: -> { now }).live(env: env)
      expect(logger).to have_received(:warn)
    end

    it "is empty on a database with no networks at all" do
      expect(networks.live(env: env)).to be_empty
    end
  end
end
