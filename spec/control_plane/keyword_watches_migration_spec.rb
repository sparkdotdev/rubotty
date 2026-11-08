# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 025 adds keyword_watches, a per-person keyword subscription that runs
# for a bounded window.
RSpec.describe "keyword_watches migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the keyword_watches table with every column the store reads/writes" do
    Rubotty::ControlPlane::Migrator.run(db)
    columns = db.schema(:keyword_watches).to_h.keys
    expect(columns).to include(
      :id, :community, :subscriber_adapter, :subscriber_account, :subscriber_native_id,
      :subscriber_username, :subscriber_display, :keyword, :notify_via, :created_at,
      :expires_at, :cancelled_at, :last_notified_at, :job_id
    )
  end

  it "defaults notify_via to mention" do
    Rubotty::ControlPlane::Migrator.run(db)
    now = Time.now
    id = db[:keyword_watches].insert(
      community: "alpha", subscriber_adapter: "telegram", subscriber_account: "acc",
      subscriber_native_id: "111", keyword: "aoe3", created_at: now, expires_at: now + 3600
    )
    expect(db[:keyword_watches][id: id][:notify_via]).to eq("mention")
  end

  it "leaves cancelled_at, last_notified_at and job_id nil until set" do
    Rubotty::ControlPlane::Migrator.run(db)
    now = Time.now
    id = db[:keyword_watches].insert(
      community: "alpha", subscriber_adapter: "telegram", subscriber_account: "acc",
      subscriber_native_id: "111", keyword: "aoe3", created_at: now, expires_at: now + 3600
    )
    row = db[:keyword_watches][id: id]
    expect(row[:cancelled_at]).to be_nil
    expect(row[:last_notified_at]).to be_nil
    expect(row[:job_id]).to be_nil
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:keyword_watches)).to be(true)
  end

  it "rolls back to 24, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 24)
    expect(db.table_exists?(:keyword_watches)).to be(false)
  end

  it "migrates cleanly again after rolling back to 24" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 24)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:keyword_watches)).to be(true)
  end
end
