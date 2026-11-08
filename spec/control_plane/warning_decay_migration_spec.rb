# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 066 adds the two columns warning decay and a permanent sanction
# need: an issuing account on `warnings`, and a nullable `until_at` on
# `active_sanctions`.
RSpec.describe "warning decay migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "adds a nullable account column to warnings" do
    Rubotty::ControlPlane::Migrator.run(db)
    schema = db.schema(:warnings).to_h
    expect(schema[:account][:type]).to eq(:string)
    expect(schema[:account][:allow_null]).to be(true)
  end

  it "allows a null until_at on active_sanctions, for a permanent sanction" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.schema(:active_sanctions).to_h[:until_at][:allow_null]).to be(true)
  end

  it "rolls back cleanly, restoring until_at to not-null" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 65)
    expect(db[:warnings].columns).not_to include(:account)
    expect(db.schema(:active_sanctions).to_h[:until_at][:allow_null]).to be(false)
  end

  it "migrates cleanly again after a rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 65)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db[:warnings].columns).to include(:account)
  end
end
