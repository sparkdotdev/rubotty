# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The one control-plane table with no community_id at all, so these specs pin
# that down rather than leave it to a reader's assumption.
RSpec.describe "accounts migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:accounts)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:accounts)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:accounts)).to be(false)
  end

  # accounts is migration 026, one step above keyword_watches at 025.
  it "rolls back above keyword_watches, keeping the earlier control plane" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 25)
    expect(db.table_exists?(:accounts)).to be(false)
    expect(db.table_exists?(:keyword_watches)).to be(true)
    expect(db.table_exists?(:communities)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:accounts)).to be(true)
  end

  describe "the table's shape" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:columns) { db.schema(:accounts).to_h { |name, spec| [name, spec] } }

    it "carries the columns an account entry needs" do
      expect(columns.keys).to contain_exactly(:id, :adapter, :name, :settings, :source,
                                              :created_at, :updated_at)
    end

    # One shared bot token serves every community at once, so there is
    # deliberately nothing to scope an account by.
    it "is GLOBAL: no community_id, and no foreign key to anything" do
      expect(columns).not_to have_key(:community_id)
      expect(db.foreign_key_list(:accounts)).to be_empty
    end

    it "requires an adapter, a name and a source" do
      expect(columns[:adapter][:allow_null]).to be(false)
      expect(columns[:name][:allow_null]).to be(false)
      expect(columns[:source][:allow_null]).to be(false)
    end

    it "defaults settings to an empty JSON object rather than NULL" do
      expect(columns[:settings][:allow_null]).to be(false)
      db[:accounts].insert(adapter: "telegram", name: "tg", source: "dashboard",
                           created_at: Time.now, updated_at: Time.now)
      expect(db[:accounts].first[:settings]).to eq("{}")
    end

    # The boot seed leans on the database for this, so two processes booting at
    # once cannot both import the same YAML account.
    it "enforces one row per (adapter, name)" do
      db[:accounts].insert(adapter: "telegram", name: "tg", settings: "{}", source: "yaml_seed",
                           created_at: Time.now, updated_at: Time.now)
      expect do
        db[:accounts].insert(adapter: "telegram", name: "tg", settings: "{}", source: "dashboard",
                             created_at: Time.now, updated_at: Time.now)
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows the same name under a different adapter" do
      db[:accounts].insert(adapter: "telegram", name: "main", settings: "{}", source: "dashboard",
                           created_at: Time.now, updated_at: Time.now)
      expect do
        db[:accounts].insert(adapter: "discord", name: "main", settings: "{}", source: "dashboard",
                             created_at: Time.now, updated_at: Time.now)
      end.not_to raise_error
    end

    # Plain TEXT rather than a Postgres-only jsonb, so sqlite, Postgres and
    # MariaDB all take the same schema.
    it "stores settings as portable TEXT, not a backend-specific JSON type" do
      expect(columns[:settings][:type]).to eq(:string)
    end
  end

  describe "the model" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:models) { Rubotty::ControlPlane.models(db) }

    it "is reachable as models.account and reads its JSON column back" do
      models.account.create(adapter: "telegram", name: "tg", settings: '{"token_env":"TG_TOKEN"}',
                            source: "dashboard", created_at: Time.now, updated_at: Time.now)
      expect(models.account.first.json_value(:settings)).to eq("token_env" => "TG_TOKEN")
    end
  end
end
