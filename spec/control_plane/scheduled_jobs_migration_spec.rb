# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 005 adds scheduled_jobs, the durable backstop behind deferred actions.
RSpec.describe "scheduled_jobs migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:scheduled_jobs)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:scheduled_jobs)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:scheduled_jobs)).to be(false)
  end

  # It is the newest migration, so one step back drops exactly this table.
  it "rolls back one step, dropping only this table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 4)
    expect(db.table_exists?(:scheduled_jobs)).to be(false)
    expect(db.table_exists?(:ephemeral_messages)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:scheduled_jobs)).to be(true)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    # TEXT-stored JSON like every other control-plane blob, with no jsonb anywhere.
    it "stores the payload as TEXT" do
      db_type = db.schema(:scheduled_jobs).to_h[:payload][:db_type].to_s.downcase
      expect(db_type).to include("text")
    end

    it "uses a plain DateTime for run_at, not a backend-only type" do
      db_type = db.schema(:scheduled_jobs).to_h[:run_at][:db_type].to_s.downcase
      expect(db_type).to match(/timestamp|datetime/)
    end

    it "defaults a fresh job to pending with zero attempts" do
      id = db[:scheduled_jobs].insert(
        kind: "noop", payload: "{}", run_at: Time.now, created_at: Time.now
      )
      row = db[:scheduled_jobs].where(id: id).first
      expect(row[:status]).to eq("pending")
      expect(row[:attempts]).to eq(0)
    end

    # community and recurrence are nullable: a global one-shot job carries neither.
    it "allows a job with no community and no recurrence" do
      expect do
        db[:scheduled_jobs].insert(
          kind: "noop", payload: "{}", run_at: Time.now, created_at: Time.now
        )
      end.not_to raise_error
    end
  end
end
