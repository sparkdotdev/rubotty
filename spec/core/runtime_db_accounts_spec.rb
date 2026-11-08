# frozen_string_literal: true

require "spec_helper"

# The control plane's accounts table is the one account source once it is
# active: the YAML's `accounts:` entries no longer feed
# Runtime#active_accounts, and nothing imports them into the table on boot.
# A deployment with no control plane still reads the YAML accounts as before.
RSpec.describe Rubotty::Core::Runtime, "accounts from the control plane" do
  let(:env) { { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token", "TG_SECOND" => "456:def" } }

  let(:yaml) do
    <<~YAML
      name: db accounts
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
        dc:
          adapter: discord
          token_env: DC_TOKEN
      storage:
        driver: sqlite
        path: ":memory:"
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms:
        - id: lounge
          endpoints:
            - id: tg-a
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
            - id: dc-a
              adapter: discord
              account: dc
              channel_id: "123456789012345678"
    YAML
  end

  let(:config) { Rubotty::Config::Loader.load_string(yaml, env: env) }

  # An isolated in-memory database on the same connection the control plane
  # reuses.
  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  let(:store) { sequel_store }
  let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env) }

  def accounts_service
    Rubotty::ControlPlane::Accounts.new(models: Rubotty::ControlPlane.models(store.db))
  end

  # The guest-portal and REST-API adapters the control plane always adds are
  # not `accounts:` entries from either origin, so they are noise here.
  SYNTHETIC = [Rubotty::Adapters::Guest::NAME, Rubotty::Adapters::Api::NAME].freeze

  def gateways(rt)
    rt.adapters.keys.reject { |adapter_name, _| SYNTHETIC.include?(adapter_name) }
  end

  after { runtime.stop }

  describe "a fresh deploy with an empty database, a control plane active" do
    it "builds no gateways at all: the config's accounts are never read" do
      runtime.build
      expect(gateways(runtime)).to be_empty
    end

    it "imports nothing from the config into the accounts table either" do
      runtime.build
      expect(accounts_service.list).to be_empty
    end
  end

  describe "database accounts, the deployment's one account source" do
    before do
      # Written before the runtime boots, as the dashboard would have, in the
      # same database the runtime brings its control plane up on.
      Rubotty::ControlPlane.migrate!(store.db)
      accounts_service.create(adapter: "telegram", name: "tg_second", settings: { "token_env" => "TG_SECOND" })
    end

    it "becomes a live adapter object, through the same construction loop" do
      runtime.build
      expect(runtime.adapters[[:telegram, "tg_second"]]).to be_a(Rubotty::Adapters::Telegram::Adapter)
    end

    it "is the only gateway built: the config's own tg/dc accounts never enter it" do
      runtime.build
      expect(gateways(runtime)).to contain_exactly([:telegram, "tg_second"])
    end

    it "resolves its own token_env against the environment" do
      runtime.build
      expect(runtime.adapters[[:telegram, "tg_second"]].settings[:token]).to eq("456:def")
    end

    # A zero-endpoint account is legal: the adapter connects so channel
    # discovery can run.
    it "is built even with no endpoint referencing it yet" do
      runtime.build
      expect(config.endpoints_for("tg_second")).to eq([])
      expect(runtime.adapters[[:telegram, "tg_second"]]).not_to be_nil
    end
  end

  describe "a broken database row" do
    # A database row is web-form input, so one bad row costs that one gateway
    # and nothing else; a good row beside it still comes up.
    it "does not stop the boot: every other database gateway still comes up" do
      Rubotty::ControlPlane.migrate!(store.db)
      models = Rubotty::ControlPlane.models(store.db)
      models.account.create(adapter: "telegram", name: "broken", settings: '{"transport":"webhook"}',
                            source: "dashboard", created_at: Time.now, updated_at: Time.now)
      accounts_service.create(adapter: "discord", name: "dc", settings: { "token_env" => "DC_TOKEN" })
      expect { runtime.build }.not_to raise_error
      expect(gateways(runtime)).to contain_exactly([:discord, "dc"])
    end
  end

  describe "a database account whose key has not arrived yet" do
    # An operator may add an account before setting its env var, and that must
    # not take down the boot.
    it "stays dormant, building no adapter, and the process still boots" do
      Rubotty::ControlPlane.migrate!(store.db)
      accounts_service.create(adapter: "telegram", name: "tg_later", settings: { "token_env" => "NOT_SET_YET" })
      expect { runtime.build }.not_to raise_error
      expect(gateways(runtime)).to be_empty
    end
  end

  describe "without a control plane" do
    # memory and pstore have no Sequel connection, so there is no accounts
    # table to read; the YAML accounts remain the sole source there, exactly
    # as they always have been.
    let(:memory_yaml) { yaml.sub("driver: sqlite\n  path: \":memory:\"", "driver: memory") }
    let(:memory_config) { Rubotty::Config::Loader.load_string(memory_yaml, env: env) }

    it "uses the YAML accounts alone, with no attempt to read a table" do
      plain = described_class.new(config: memory_config, logger: Rubotty::Log.null, env: env)
      plain.build
      expect(plain.control_plane?).to be(false)
      expect(gateways(plain)).to contain_exactly([:telegram, "tg"], [:discord, "dc"])
      plain.stop
    end
  end
end
