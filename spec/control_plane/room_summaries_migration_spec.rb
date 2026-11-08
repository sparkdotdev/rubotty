# frozen_string_literal: true

require "spec_helper"
require "sequel"

RSpec.describe "room summaries migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates both tables when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)

    expect(db.table_exists?(:room_summary_messages)).to be(true)
    expect(db.table_exists?(:room_summary_watermarks)).to be(true)
  end

  it "is idempotent after both tables exist" do
    Rubotty::ControlPlane::Migrator.run(db)

    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
  end

  it "drops both tables when rolled back before this migration" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 71)

    expect(db.table_exists?(:room_summary_messages)).to be(false)
    expect(db.table_exists?(:room_summary_watermarks)).to be(false)
    expect(db.table_exists?(:dashboard_appearances)).to be(true)
  end

  it "runs cleanly again after a rollback before this migration" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 71)

    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:room_summary_messages)).to be(true)
    expect(db.table_exists?(:room_summary_watermarks)).to be(true)
  end

  it "accepts tables created by the earlier version before applying 072" do
    Sequel::Migrator.run(db, migration_directory, target: 71)
    db.create_table(:room_summary_messages) { primary_key :id }
    db.create_table(:room_summary_watermarks) { primary_key :id }

    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:room_summary_messages)).to be(true)
    expect(db.table_exists?(:room_summary_watermarks)).to be(true)
  end

  it "adds posted_message_id to the watermark table, defaulted for existing rows" do
    Sequel::Migrator.run(db, migration_directory, target: 82)
    db[:communities].insert(slug: "first", name: "First", status: "active", settings: "{}", created_at: Time.now, updated_at: Time.now)
    db[:room_summary_watermarks].insert(
      community_id: 1, room_key: "general", last_message_id: 4, completed_at: Time.now
    )

    Rubotty::ControlPlane::Migrator.run(db)

    expect(db[:room_summary_watermarks].columns).to include(:posted_message_id)
    expect(db[:room_summary_watermarks].first[:posted_message_id]).to eq(0)
  end

  def migration_directory = Rubotty::ControlPlane::Migrator::MIGRATIONS_DIR
end
