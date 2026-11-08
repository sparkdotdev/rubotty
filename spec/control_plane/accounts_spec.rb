# frozen_string_literal: true

require "spec_helper"

# Credential-path code, so the questions are blunt: can a row ever hold a
# resolved secret, can a second boot overwrite an operator's edit, and does a
# database account come out shaped like a YAML one.
RSpec.describe Rubotty::ControlPlane::Accounts, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }
  let(:env) { { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-secret" } }

  subject(:accounts) { described_class.new(models: models, clock: -> { now }) }

  # A small config of our own rather than SAMPLE's, so the seed specs control
  # which accounts exist and can add one mid-test.
  def config_for(yaml, config_env: env)
    Rubotty::Config::Loader.load_string(yaml, env: config_env)
  end

  let(:two_account_yaml) do
    <<~YAML
      name: seed test
      accounts:
        telegram:
          adapter: telegram
          token_env: TG_TOKEN
          transport: long_polling
        discord:
          adapter: discord
          token_env: DC_TOKEN
      storage:
        driver: memory
      rooms:
        - id: lounge
          endpoints:
            - id: tg-a
              adapter: telegram
              account: telegram
              chat_id: "-1008000000001"
            - id: dc-a
              adapter: discord
              account: discord
              channel_id: "123456789012345678"
    YAML
  end

  describe "#create" do
    it "stores an account under its adapter and name" do
      row = accounts.create(adapter: "telegram", name: "telegram_2", settings: { "token_env" => "TG_SECOND" })
      expect(row.adapter).to eq("telegram")
      expect(row.name).to eq("telegram_2")
      expect(row.json_value(:settings)).to eq("token_env" => "TG_SECOND")
    end

    it "defaults source to dashboard, so an operator-added row is distinguishable" do
      row = accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "TG_TOKEN" })
      expect(row.source).to eq(described_class::SOURCE_DASHBOARD)
    end

    it "keeps a non-default setting the operator actually chose" do
      row = accounts.create(adapter: "telegram", name: "tg",
                            settings: { "token_env" => "TG_TOKEN", "transport" => "webhook",
                                        "webhook_url" => "https://example.test/hook" })
      expect(row.json_value(:settings)).to include("transport" => "webhook")
    end

    # The row records what an operator chose, not the expanded schema, so a
    # later change to a code default still reaches the account.
    it "drops a value that merely equals the field's own schema default" do
      row = accounts.create(adapter: "telegram", name: "tg",
                            settings: { "token_env" => "TG_TOKEN", "transport" => "long_polling",
                                        "skip_backlog" => true })
      stored = row.json_value(:settings)
      expect(stored).to eq("token_env" => "TG_TOKEN")
      expect(stored).not_to have_key("transport")
      expect(stored).not_to have_key("skip_backlog")
    end

    it "refuses an adapter nothing is registered under" do
      expect do
        accounts.create(adapter: "nosuchplatform", name: "x", settings: { "token_env" => "T" })
      end.to raise_error(described_class::Invalid, /unknown adapter/)
    end

    it "refuses a blank name" do
      expect do
        accounts.create(adapter: "telegram", name: "  ", settings: { "token_env" => "T" })
      end.to raise_error(described_class::Invalid, /name: is required/)
    end

    # A name is a routing key stored verbatim in channels.account, so a space
    # in one would be invisible on the page.
    it "refuses a name containing whitespace" do
      expect do
        accounts.create(adapter: "telegram", name: "my account", settings: { "token_env" => "T" })
      end.to raise_error(described_class::Invalid, /whitespace/)
    end

    it "refuses a duplicate (adapter, name)" do
      accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "T" })
      expect do
        accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "T2" })
      end.to raise_error(described_class::Invalid, /already exists/)
    end

    it "allows the same name under a different adapter, the identity being the pair" do
      accounts.create(adapter: "telegram", name: "main", settings: { "token_env" => "TG" })
      expect do
        accounts.create(adapter: "discord", name: "main", settings: { "token_env" => "DC" })
      end.not_to raise_error
    end
  end

  describe "validation through each adapter's own account_schema" do
    it "rejects a Telegram account missing the token_env its schema requires" do
      expect do
        accounts.create(adapter: "telegram", name: "tg", settings: {})
      end.to raise_error(described_class::Invalid, /token_env: is required/)
    end

    it "rejects a Discord key on a Telegram account: the schemas are not interchangeable" do
      expect do
        accounts.create(adapter: "telegram", name: "tg",
                        settings: { "token_env" => "T", "intents" => %w[servers] })
      end.to raise_error(described_class::Invalid, /intents: unknown key/)
    end

    it "accepts that same key on a Discord account" do
      row = accounts.create(adapter: "discord", name: "dc",
                            settings: { "token_env" => "DC", "intents" => %w[servers] })
      expect(row.json_value(:settings)["intents"]).to eq(%w[servers])
    end

    it "rejects a value outside a field's one_of" do
      expect do
        accounts.create(adapter: "telegram", name: "tg",
                        settings: { "token_env" => "T", "transport" => "carrier_pigeon" })
      end.to raise_error(described_class::Invalid, /transport: must be one of/)
    end

    # The cross-field check has to run here too, or a dashboard-added account
    # could be accepted in a shape the YAML loader would refuse.
    it "runs the adapter's cross-field validate_account, not only the per-field schema" do
      expect do
        accounts.create(adapter: "telegram", name: "tg",
                        settings: { "token_env" => "T", "transport" => "webhook" })
      end.to raise_error(described_class::Invalid, /webhook_url: required when transport is webhook/)
    end

    it "reports every problem in one pass rather than only the first" do
      expect do
        accounts.create(adapter: "telegram", name: "tg",
                        settings: { "transport" => "carrier_pigeon", "poll_limit" => "lots" })
      end.to raise_error(described_class::Invalid, /token_env.*poll_limit|poll_limit.*token_env/m)
    end
  end

  describe "secrets never reach a row" do
    # The seed's input is the settings of a running account, which the loader
    # has already resolved: token_env has become an actual token.
    it "stores token_env but never the resolved token the loader put beside it" do
      config = config_for(two_account_yaml)
      loaded = config.accounts["telegram"]
      expect(loaded.settings[:token]).to eq("123:abc")

      accounts.seed_from_config(config)
      stored = models.account.where(adapter: "telegram", name: "telegram").first.json_value(:settings)
      expect(stored).to include("token_env" => "TG_TOKEN")
      expect(stored).not_to have_key("token")
      expect(stored.to_s).not_to include("123:abc")
    end

    # The second guard: no account_schema declares `token`, so the schema
    # refuses it as an unknown key even without the storable filter.
    it "refuses a raw token posted straight at the create path" do
      expect do
        accounts.create(adapter: "telegram", name: "tg",
                        settings: { "token_env" => "TG_TOKEN", "token" => "123:abc" })
      end.to raise_error(described_class::Invalid, /token: unknown key/)
    end

    it "keeps no raw secret anywhere in the table after seeding a whole config" do
      accounts.seed_from_config(config_for(two_account_yaml))
      blob = models.account.all.map(&:settings).join
      expect(blob).not_to include("123:abc")
      expect(blob).not_to include("dc-secret")
    end
  end

  describe "#update" do
    let!(:row) { accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "TG_TOKEN" }) }

    it "replaces the settings, validated by the row's own adapter schema" do
      accounts.update(account: row, settings: { "token_env" => "TG_OTHER", "poll_timeout" => 60 })
      expect(row.reload.json_value(:settings)).to eq("token_env" => "TG_OTHER", "poll_timeout" => 60)
    end

    it "refuses settings the adapter's schema rejects, leaving the row alone" do
      expect do
        accounts.update(account: row, settings: { "token_env" => "TG_OTHER", "transport" => "nope" })
      end.to raise_error(described_class::Invalid)
      expect(row.reload.json_value(:settings)).to eq("token_env" => "TG_TOKEN")
    end

    # channels.account and platform_connections.account carry this pair as a
    # string, with no cascade behind it.
    it "leaves the (adapter, name) identity untouched" do
      accounts.update(account: row, settings: { "token_env" => "TG_OTHER" })
      expect([row.reload.adapter, row.name]).to eq(["telegram", "tg"])
    end
  end

  describe "#remove" do
    it "removes a row by id and reports it" do
      row = accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "T" })
      expect(accounts.remove(id: row.id)).to be(true)
      expect(models.account.count).to eq(0)
    end

    it "reports false for an id that is not there" do
      expect(accounts.remove(id: 9999)).to be(false)
    end
  end

  describe "#list" do
    it "orders by adapter then name, so the page groups platform by platform" do
      accounts.create(adapter: "telegram", name: "tg_b", settings: { "token_env" => "A" })
      accounts.create(adapter: "discord", name: "dc", settings: { "token_env" => "B" })
      accounts.create(adapter: "telegram", name: "tg_a", settings: { "token_env" => "C" })
      expect(accounts.list.map { |row| [row.adapter, row.name] })
        .to eq([%w[discord dc], %w[telegram tg_a], %w[telegram tg_b]])
    end
  end

  # The dashboard resolves a platform connection's account and offers the
  # api_wrapper names on the API-key form. Both used to read the boot-time
  # config alone, which on a database-only deployment holds nothing at all.
  describe "#names_for and #resolved" do
    it "names every account of one adapter, in name order" do
      accounts.create(adapter: "telegram", name: "tg_b", settings: { "token_env" => "TG_TOKEN" })
      accounts.create(adapter: "telegram", name: "tg_a", settings: { "token_env" => "TG_TOKEN" })
      accounts.create(adapter: "discord", name: "dc", settings: { "token_env" => "DC_TOKEN" })

      expect(accounts.names_for(adapter: "telegram")).to eq(%w[tg_a tg_b])
      expect(accounts.names_for(adapter: :discord)).to eq(%w[dc])
      expect(accounts.names_for(adapter: "matrix")).to eq([])
    end

    it "resolves one row by its identity, the same shape #live gives" do
      accounts.create(adapter: "telegram", name: "telegram", settings: { "token_env" => "TG_TOKEN" })

      account = accounts.resolved(adapter: "telegram", name: "telegram", env: env)

      expect(account).to be_a(Rubotty::Config::Account)
      expect(account.adapter_name).to eq(:telegram)
      expect(account.adapter_class).to eq(Rubotty::Adapters::Telegram::Adapter)
      expect(account.settings[:token_env]).to eq("TG_TOKEN")
    end

    it "is nil for an identity no row carries" do
      expect(accounts.resolved(adapter: "telegram", name: "nobody", env: env)).to be_nil
    end
  end

  describe "#seed_from_config" do
    it "imports every YAML account into the table" do
      created = accounts.seed_from_config(config_for(two_account_yaml))
      expect(created.map { |row| [row.adapter, row.name] }).to contain_exactly(%w[telegram telegram],
                                                                              %w[discord discord])
      expect(models.account.count).to eq(2)
    end

    it "marks an imported row as yaml_seed, not dashboard" do
      accounts.seed_from_config(config_for(two_account_yaml))
      expect(models.account.all.map(&:source).uniq).to eq([described_class::SOURCE_YAML])
    end

    it "is idempotent: a second run creates nothing and duplicates nothing" do
      config = config_for(two_account_yaml)
      accounts.seed_from_config(config)
      expect(accounts.seed_from_config(config)).to be_empty
      expect(models.account.count).to eq(2)
    end

    it "never overwrites a row a dashboard edit has since changed" do
      config = config_for(two_account_yaml)
      accounts.seed_from_config(config)
      row = models.account.where(adapter: "telegram", name: "telegram").first
      accounts.update(account: row, settings: { "token_env" => "TG_OPERATOR_CHOSE_THIS" })

      accounts.seed_from_config(config)
      expect(row.reload.json_value(:settings)).to eq("token_env" => "TG_OPERATOR_CHOSE_THIS")
    end

    it "never resurrects an account an operator removed but the YAML still declares" do
      # It does come back, because the file still declares it. What matters is
      # that it returns as a fresh import rather than something else.
      config = config_for(two_account_yaml)
      accounts.seed_from_config(config)
      accounts.remove(id: models.account.where(name: "telegram").first.id)
      created = accounts.seed_from_config(config)
      expect(created.map(&:name)).to eq(["telegram"])
      expect(created.first.source).to eq(described_class::SOURCE_YAML)
    end

    it "imports an account added to the YAML after an earlier seed, additively" do
      accounts.seed_from_config(config_for(two_account_yaml))
      grown = two_account_yaml.sub(
        "storage:\n",
        "  telegram_2:\n    adapter: telegram\n    token_env: TG_TOKEN\nstorage:\n"
      )
      created = accounts.seed_from_config(config_for(grown))
      expect(created.map(&:name)).to eq(["telegram_2"])
      expect(models.account.count).to eq(3)
    end

    it "imports the SAMPLE fixture's accounts unchanged" do
      created = accounts.seed_from_config(sample_model)
      expect(created.map(&:name)).to contain_exactly("telegram", "discord", "stoat", "fluxer")
    end
  end

  describe "#live" do
    it "resolves a row into the same struct a YAML account produces" do
      accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "TG_TOKEN" })
      account = accounts.live(env: env).first
      expect(account).to be_a(Rubotty::Config::Account)
      expect(account.name).to eq("tg")
      expect(account.adapter_name).to eq(:telegram)
      expect(account.adapter_class).to eq(Rubotty::Adapters::Telegram::Adapter)
    end

    it "resolves token_env against the environment, exactly as the loader does" do
      accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "TG_TOKEN" })
      expect(accounts.live(env: env).first.settings[:token]).to eq("123:abc")
    end

    it "re-applies the schema defaults a stored row deliberately left out" do
      accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "TG_TOKEN" })
      expect(accounts.live(env: env).first.settings[:transport]).to eq(:long_polling)
    end

    # Dormancy has to work identically from the database, or an operator adding
    # an account before its key arrives would crash the boot.
    it "returns a dormant account when its key is not in the environment yet" do
      accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "NOT_SET_YET" })
      account = accounts.live(env: {}).first
      expect(account.dormant?).to be(true)
      expect(account.dormant_reason).to include("NOT_SET_YET")
    end

    # A database row is web-form input, so one bad row costs that one gateway
    # and nothing else.
    it "skips a row whose stored settings no longer validate, keeping the good ones" do
      accounts.create(adapter: "discord", name: "dc", settings: { "token_env" => "DC_TOKEN" })
      models.account.create(adapter: "telegram", name: "broken", settings: '{"transport":"webhook"}',
                            source: "dashboard", created_at: now, updated_at: now)
      expect(accounts.live(env: env).map(&:name)).to eq(["dc"])
    end

    it "skips a row for an adapter this process has no registration for" do
      models.account.create(adapter: "ansible", name: "future", settings: '{"token_env":"X"}',
                            source: "dashboard", created_at: now, updated_at: now)
      expect(accounts.live(env: env)).to be_empty
    end

    it "logs why a row was skipped, which is the only way an operator finds out" do
      logger = instance_double(Logger, info: nil, warn: nil)
      models.account.create(adapter: "telegram", name: "broken", settings: "{}",
                            source: "dashboard", created_at: now, updated_at: now)
      described_class.new(models: models, logger: logger, clock: -> { now }).live(env: env)
      expect(logger).to have_received(:warn)
    end

    it "is empty on a database with no accounts at all" do
      expect(accounts.live(env: env)).to be_empty
    end
  end

  describe "seed then read back" do
    it "reproduces every YAML account's effective settings from the database alone" do
      config = config_for(two_account_yaml)
      accounts.seed_from_config(config)

      from_db = accounts.live(env: env).to_h { |account| [account.name, account] }
      config.active_accounts.each do |yaml_account|
        expect(from_db[yaml_account.name].settings).to eq(yaml_account.settings)
        expect(from_db[yaml_account.name].adapter_class).to eq(yaml_account.adapter_class)
        expect(from_db[yaml_account.name].dormant?).to eq(yaml_account.dormant?)
      end
    end
  end

  describe ".adapter_names" do
    it "lists the registered adapters, so the add form needs no hardcoded list" do
      expect(described_class.adapter_names).to include(:telegram, :discord)
    end

    # The guest portal carries no credential and the runtime builds it at a
    # fixed key, so a row for it would only fight the runtime for that key.
    it "leaves out the guest portal, which is not a credentialed gateway" do
      expect(described_class.adapter_names).not_to include(:guest)
    end

    it "refuses to create a guest account even if the POST is hand-crafted" do
      expect do
        accounts.create(adapter: "guest", name: "guest", settings: {})
      end.to raise_error(described_class::Invalid, /not a credentialed gateway/)
    end
  end
end
