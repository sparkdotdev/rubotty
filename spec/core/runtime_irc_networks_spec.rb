# frozen_string_literal: true

require "spec_helper"

# Before this, irc_networks.rb said it itself: writing a row records an
# operator's intent and nothing downstream reads the table. A network saved
# through the dashboard has to become a live gateway on the next boot, the
# same way a database account already does.
RSpec.describe Rubotty::Core::Runtime, "irc networks from the control plane" do
  let(:community_name) { "irc networks test" }
  let(:community_slug) { "irc-networks-test" }
  let(:env) { { "IRC_LIBERA_SASL_PASSWORD" => "s3cret" } }

  let(:yaml) do
    <<~YAML
      name: #{community_name}
      accounts: {}
      storage:
        driver: sqlite
        path: ":memory:"
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms: []
    YAML
  end

  let(:config) { Rubotty::Config::Loader.load_string(yaml, env: env) }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  let(:store) { sequel_store }
  let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env) }

  SYNTHETIC_ADAPTERS = [Rubotty::Adapters::Guest::NAME, Rubotty::Adapters::Api::NAME].freeze

  def gateways(rt)
    rt.adapters.keys.reject { |adapter_name, _| SYNTHETIC_ADAPTERS.include?(adapter_name) }
  end

  # A community the runtime's own boot would otherwise create; pre-made here,
  # under the slug the runtime derives from the config name, so the network
  # below has somewhere to attach before the first #build runs.
  def community
    Rubotty::ControlPlane.migrate!(store.db)
    models = Rubotty::ControlPlane.models(store.db)
    models.community.where(slug: community_slug).first ||
      models.community.create(slug: community_slug, name: community_name, status: "active", settings: "{}",
                              created_at: Time.now, updated_at: Time.now)
  end

  def irc_networks_service
    Rubotty::ControlPlane::IrcNetworks.new(models: Rubotty::ControlPlane.models(store.db))
  end

  after { runtime.stop }

  describe "a network saved through the dashboard" do
    before do
      # community migrates the control-plane database as a side effect, and
      # has to run before irc_networks_service builds its own model classes
      # over it.
      target_community = community
      irc_networks_service.create(
        community: target_community, name: "Libera", host: "irc.libera.chat", port: 6697, tls: true,
        nick: "rubotty", sasl_user: "rubotty", sasl_password_env: "IRC_LIBERA_SASL_PASSWORD",
        channels: ["#general"], mode: "per_room", hub_channel: nil, channel_keys: {}
      )
    end

    it "becomes a live IRC adapter, through the same construction loop a YAML account uses" do
      runtime.build
      expect(gateways(runtime)).to include([:irc, "irc_network:irc-networks-test:Libera"])
    end

    it "resolves its connection settings from the stored row" do
      runtime.build
      adapter = runtime.adapters[[:irc, "irc_network:irc-networks-test:Libera"]]
      expect(adapter.settings[:server]).to eq("irc.libera.chat")
      expect(adapter.settings[:nick]).to eq("rubotty")
    end

    it "resolves sasl_password_env against the environment, never storing the raw password" do
      runtime.build
      adapter = runtime.adapters[[:irc, "irc_network:irc-networks-test:Libera"]]
      expect(adapter.settings[:sasl_password]).to eq("s3cret")
    end
  end

  describe "without any irc_networks row" do
    it "boots exactly as it did before the table existed" do
      community
      runtime.build
      expect(gateways(runtime)).to be_empty
    end
  end
end
