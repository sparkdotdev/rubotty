# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The durable-row rate-limit log for the REST admin API.
RSpec.describe "api_request_log migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:api_request_log)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:api_request_log)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:api_request_log)).to be(false)
  end

  # api_request_log is migration 028, one step above api_keys at 027.
  it "rolls back above api_keys, keeping the earlier control plane" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 27)
    expect(db.table_exists?(:api_request_log)).to be(false)
    expect(db.table_exists?(:api_keys)).to be(true)
    expect(db.table_exists?(:communities)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:api_request_log)).to be(true)
  end

  describe "the table's shape" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:columns) { db.schema(:api_request_log).to_h { |name, spec| [name, spec] } }

    it "carries exactly id, api_key_id and created_at, deliberately thin" do
      expect(columns.keys).to contain_exactly(:id, :api_key_id, :created_at)
    end

    it "requires api_key_id and created_at" do
      expect(columns[:api_key_id][:allow_null]).to be(false)
      expect(columns[:created_at][:allow_null]).to be(false)
    end

    it "cascades a deleted API key's logged requests" do
      fk = db.foreign_key_list(:api_request_log).find { |entry| entry[:columns] == [:api_key_id] }
      expect(fk[:table]).to eq(:api_keys)
      expect(fk[:on_delete]).to eq(:cascade)
    end

    it "serves the rate limiter's read pattern with a composite index" do
      indexes = db.indexes(:api_request_log)
      composite = indexes.values.find { |idx| idx[:columns] == %i[api_key_id created_at] }
      expect(composite).not_to be_nil
    end
  end

  describe "the model" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:models) { Rubotty::ControlPlane.models(db) }

    it "is reachable as models.api_request_log and points back to its key" do
      now = Time.now
      key = models.api_key.create(
        public_id: "11111111-1111-1111-1111-111111111111",
        key_hash: "a" * 64, scope: "administrator", label: "Test key",
        created_at: now, updated_at: now
      )
      row = models.api_request_log.create(api_key_id: key.id, created_at: now)
      expect(row.api_key.id).to eq(key.id)
    end
  end

  # The retention purge deletes by age alone, and the key-leftmost index does not
  # serve that, so the table this writes a row to on every request full-scanned.
  describe "the retention purge's index" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    it "carries a bare created_at index" do
      expect(db.indexes(:api_request_log)).to include(
        api_request_log_age_idx: hash_including(columns: [:created_at])
      )
    end

    it "plans the purge as a search rather than a scan" do
      plan = db["EXPLAIN QUERY PLAN DELETE FROM api_request_log WHERE created_at < ?", Time.now].all
      expect(plan.map { |step| step[:detail].to_s }.join(" ")).to include("api_request_log_age_idx")
    end
  end
end
