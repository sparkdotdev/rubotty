# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The REST admin API's bearer credential table.
RSpec.describe "api_keys migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:api_keys)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:api_keys)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:api_keys)).to be(false)
  end

  # api_keys is migration 027, one step above accounts at 026.
  it "rolls back above accounts, keeping the earlier control plane" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 26)
    expect(db.table_exists?(:api_keys)).to be(false)
    expect(db.table_exists?(:accounts)).to be(true)
    expect(db.table_exists?(:communities)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:api_keys)).to be(true)
  end

  describe "the table's shape" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:columns) { db.schema(:api_keys).to_h { |name, spec| [name, spec] } }

    it "carries the columns an API key needs" do
      expect(columns.keys).to contain_exactly(
        :id, :public_id, :key_hash, :scope, :community_id, :label, :created_by,
        :revoked_at, :last_used_at, :created_at, :updated_at, :platform_account
      )
    end

    it "requires a public_id, a key_hash, a scope and a label" do
      expect(columns[:public_id][:allow_null]).to be(false)
      expect(columns[:key_hash][:allow_null]).to be(false)
      expect(columns[:scope][:allow_null]).to be(false)
      expect(columns[:label][:allow_null]).to be(false)
    end

    # The column only permits the null an administrator key needs. Which scope
    # goes with which community_id is enforced in {ApiKeys#issue}.
    it "lets community_id be nullable, for administrator keys" do
      expect(columns[:community_id][:allow_null]).to be(true)
    end

    it "requires created_at and updated_at but leaves revoked_at/last_used_at optional" do
      expect(columns[:created_at][:allow_null]).to be(false)
      expect(columns[:updated_at][:allow_null]).to be(false)
      expect(columns[:revoked_at][:allow_null]).to be(true)
      expect(columns[:last_used_at][:allow_null]).to be(true)
    end

    it "enforces a unique key_hash" do
      indexes = db.indexes(:api_keys)
      key_hash_index = indexes.values.find { |idx| idx[:columns] == [:key_hash] }
      expect(key_hash_index[:unique]).to be(true)
    end

    it "enforces a unique public_id" do
      indexes = db.indexes(:api_keys)
      public_id_index = indexes.values.find { |idx| idx[:columns] == [:public_id] }
      expect(public_id_index[:unique]).to be(true)
    end

    it "cascades a deleted community's developer keys" do
      fk = db.foreign_key_list(:api_keys).find { |entry| entry[:columns] == [:community_id] }
      expect(fk[:on_delete]).to eq(:cascade)
    end
  end

  describe "the model" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:models) { Rubotty::ControlPlane.models(db) }

    it "is reachable as models.api_key" do
      now = Time.now
      row = models.api_key.create(
        public_id: "11111111-1111-1111-1111-111111111111",
        key_hash: "a" * 64, scope: "administrator", label: "Test key",
        created_at: now, updated_at: now
      )
      expect(models.api_key.first.id).to eq(row.id)
    end
  end
end
