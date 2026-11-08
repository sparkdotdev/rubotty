# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The column an event's own recurrence lives on: nullable, so nothing about an
# ordinary one-off event changes.
RSpec.describe "event recurrence migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "adds recurrence_interval when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.schema(:events).to_h[:recurrence_interval]).not_to be_nil
  end

  it "is idempotent" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
  end

  it "leaves the column nullable, so an ordinary event needs no value" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.schema(:events).to_h[:recurrence_interval][:allow_null]).to be(true)
  end

  it "rolls back to 64, dropping the column but keeping the events table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 64)
    expect(db.table_exists?(:events)).to be(true)
    expect(db.schema(:events).to_h).not_to have_key(:recurrence_interval)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.schema(:events).to_h).to have_key(:recurrence_interval)
  end
end
