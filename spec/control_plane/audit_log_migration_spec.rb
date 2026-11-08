# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The moderation audit log, migration 009, so the rollback targets below are
# relative to that.
RSpec.describe "audit_events migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:audit_events)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:audit_events)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:audit_events)).to be(false)
  end

  it "rolls back one step, dropping only this table and leaving the warnings tables" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 8)
    expect(db.table_exists?(:audit_events)).to be(false)
    expect(db.table_exists?(:warnings)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:audit_events)).to be(true)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    it "stores the metadata as TEXT, like the other control-plane JSON columns" do
      db_type = db.schema(:audit_events).to_h[:metadata][:db_type].to_s.downcase
      expect(db_type).to include("text")
    end

    it "uses a plain DateTime for created_at, not a backend-only type" do
      db_type = db.schema(:audit_events).to_h[:created_at][:db_type].to_s.downcase
      expect(db_type).to match(/timestamp|datetime/)
    end
  end
end
