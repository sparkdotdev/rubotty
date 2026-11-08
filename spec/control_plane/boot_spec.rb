# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::Boot, :control_plane do
  # One in-memory database, which the control plane then reuses.
  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  let(:config) { sample_model }

  describe ".available?" do
    it "is true for a Sequel-backed store (the connection to reuse)" do
      expect(described_class.available?(sequel_store)).to be(true)
    end

    it "is false for the memory store, which has no Sequel connection" do
      expect(described_class.available?(Rubotty::Storage::Memory.new)).to be(false)
    end
  end

  describe ".slug_for" do
    it "prefers an explicit override" do
      expect(described_class.slug_for(config, env: {}, override: "sample")).to eq("sample")
    end

    it "reads RUBOTTY_COMMUNITY_SLUG from the environment" do
      expect(described_class.slug_for(config, env: { "RUBOTTY_COMMUNITY_SLUG" => "My Group" }))
        .to eq("my-group")
    end

    it "slugs the config name when nothing overrides it, stably across calls" do
      slug = described_class.slug_for(config, env: {})
      expect(slug).to eq("sample")
      expect(described_class.slug_for(config, env: {})).to eq(slug)
    end
  end

  describe ".prepare migrates then seeds when empty" do
    it "builds a Registry whose snapshot carries the seeded community" do
      store = sequel_store
      registry = described_class.prepare(storage: store, config: config, slug: "sample")
      expect(registry).to be_a(Rubotty::ControlPlane::Registry)
      expect(registry.current.community("sample")).not_to be_nil
    end

    it "returns nil for a store that cannot host the control plane" do
      expect(described_class.prepare(storage: Rubotty::Storage::Memory.new, config: config, slug: "sample"))
        .to be_nil
    end
  end

  describe "idempotency across two boots on the same database" do
    it "seeds once and does not duplicate on the second boot" do
      store = sequel_store

      described_class.prepare(storage: store, config: config, slug: "sample")
      models = Rubotty::ControlPlane.models(store.db)
      first = models.community.count
      channels_first = models.channel.count

      # The seed is skipped this time, because the plane is no longer empty.
      described_class.prepare(storage: store, config: config, slug: "sample")
      expect(models.community.count).to eq(first)
      expect(models.channel.count).to eq(channels_first)
      expect(first).to eq(1)
    end

    it "runs migrations idempotently (up to date after the first prepare)" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample")
      expect(Rubotty::ControlPlane::Migrator.current?(store.db)).to be(true)
    end
  end

  # The NAME is reconciled even on a non-seeding boot, so a rename in
  # bridge.config.yaml reaches the row without a manual UPDATE.
  describe "reconciling identity on a later boot" do
    def renamed_config(new_name)
      yaml = File.read(ControlPlaneHelpers::CONFIG_PATH).sub(/^name: .*$/, "name: #{new_name}")
      Rubotty::Config::Loader.load_string(yaml, env: ControlPlaneHelpers::CONFIG_ENV)
    end

    it "picks up a name changed in config on the next boot, without reseeding" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample")
      models = Rubotty::ControlPlane.models(store.db)
      channels_before = models.channel.count

      described_class.prepare(storage: store, config: renamed_config("SAMPLE Renamed"), slug: "sample")

      expect(models.community.where(slug: "sample").first.name).to eq("SAMPLE Renamed")
      expect(models.community.count).to eq(1)
      expect(models.channel.count).to eq(channels_before)
    end

    it "leaves an unrelated, dynamically-onboarded community's name untouched" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample")
      models = Rubotty::ControlPlane.models(store.db)
      other = models.community.create(
        slug: "other-space", name: "Other Space", status: "active",
        created_at: Time.now, updated_at: Time.now
      )

      described_class.prepare(storage: store, config: renamed_config("SAMPLE Renamed"), slug: "sample")

      expect(models.community[other.id].name).to eq("Other Space")
    end

    # A database-only deployment boots on an all-defaults config, where
    # `name` is the schema's own "rubotty" rather than anything an operator
    # wrote. Reconciling from that would rename the community on every
    # restart, undoing whatever the dashboard set.
    it "leaves the name alone for a configuration that never declared one" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample")
      models = Rubotty::ControlPlane.models(store.db)
      models.community.where(slug: "sample").first.update(name: "Renamed In The Dashboard")

      bare = Rubotty::Config::Loader.load_string("", source: "(no configuration given)", env: {})
      expect(bare.name).to eq("rubotty")
      expect(bare.name_declared?).to be(false)

      described_class.prepare(storage: store, config: bare, slug: "sample")

      expect(models.community.where(slug: "sample").first.name).to eq("Renamed In The Dashboard")
    end
  end

  # Boot no longer imports accounts from the config at all: the accounts
  # table is the deployment's one account source, whether an operator
  # populated it through the dashboard or through an explicit `rubotty seed`.
  describe ".prepare leaves the accounts table alone" do
    def accounts_in(store)
      Rubotty::ControlPlane.models(store.db).account.order(:adapter, :name).all
    end

    it "imports nothing on the first boot, even though the config declares accounts" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample")
      expect(accounts_in(store)).to be_empty
    end

    it "imports nothing on a later boot of an already-seeded community either" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample")
      described_class.prepare(storage: store, config: config, slug: "sample")
      expect(accounts_in(store)).to be_empty
    end

    # The actual proof a control-plane deployment with no YAML accounts at all
    # works exactly as before: an account the dashboard created reaches the
    # live snapshot the bot routes with, straight off the table, with the
    # config's own accounts (still declared here) never in the picture.
    it "carries a dashboard-created account into the live snapshot" do
      store = sequel_store
      env = ControlPlaneHelpers::CONFIG_ENV
      described_class.prepare(storage: store, config: config, slug: "sample", env: env)
      models = Rubotty::ControlPlane.models(store.db)
      Rubotty::ControlPlane::Accounts.new(models: models).create(
        adapter: "telegram", name: "telegram",
        settings: { "token_env" => "TELEGRAM_BOT_TOKEN", "poll_timeout" => 99 }
      )

      registry = described_class.prepare(storage: store, config: config, slug: "sample", env: env)
      expect(registry.current.accounts["telegram"].settings[:poll_timeout]).to eq(99)
    end

    it "imports nothing when the caller asked for no seeding at all" do
      store = sequel_store
      described_class.prepare(storage: store, config: config, slug: "sample", seed: false)
      expect(accounts_in(store)).to be_empty
    end
  end

  describe ".migrate and .seed for the CLI" do
    it "migrate raises a clear StorageError on a non-Sequel store" do
      expect { described_class.migrate(storage: Rubotty::Storage::Memory.new) }
        .to raise_error(Rubotty::StorageError, /Sequel-backed store/)
    end

    it "seed projects the config and is idempotent when re-run" do
      store = sequel_store
      described_class.seed(storage: store, config: config, slug: "sample")
      described_class.seed(storage: store, config: config, slug: "sample")
      models = Rubotty::ControlPlane.models(store.db)
      expect(models.community.count).to eq(1)
      expect(models.channel.count).to eq(16)
    end

    # The one place YAML accounts still reach the table: an operator running
    # `rubotty seed` explicitly, unlike a boot, which never touches accounts
    # at all. This only proves the CLI wiring still reaches the import.
    it "seed imports the config's accounts too" do
      store = sequel_store
      described_class.seed(storage: store, config: config, slug: "sample")
      described_class.seed(storage: store, config: config, slug: "sample")
      models = Rubotty::ControlPlane.models(store.db)
      expect(models.account.order(:adapter, :name).all.map(&:name))
        .to contain_exactly("telegram", "discord", "stoat", "fluxer")
    end
  end
end
