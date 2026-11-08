# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 007 adds warnings and active_sanctions, which give moderation a memory.
RSpec.describe "warnings migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates both tables when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:warnings)).to be(true)
    expect(db.table_exists?(:active_sanctions)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the tables intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:warnings)).to be(true)
  end

  it "rolls fully back down, dropping both tables" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:warnings)).to be(false)
    expect(db.table_exists?(:active_sanctions)).to be(false)
  end

  # It is the newest migration, so one step back drops exactly these two tables.
  it "rolls back one step, dropping only these tables" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 6)
    expect(db.table_exists?(:warnings)).to be(false)
    expect(db.table_exists?(:active_sanctions)).to be(false)
    expect(db.table_exists?(:observed_identities)).to be(true)
    expect(db.table_exists?(:scheduled_jobs)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:warnings)).to be(true)
  end

  it "stores the endpoint list as portable TEXT-JSON, not a backend-only type" do
    Rubotty::ControlPlane::Migrator.run(db)
    schema = db.schema(:active_sanctions).to_h
    expect(schema[:endpoints][:type]).to eq(:string)
    expect(schema[:reason]).to be_nil # reason lives on warnings, not sanctions
    expect(db.schema(:warnings).to_h[:reason][:type]).to eq(:string)
  end
end
