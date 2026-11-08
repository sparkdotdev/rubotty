# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The durable backstop for the ephemeral message primitive.
RSpec.describe "ephemeral_messages migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:ephemeral_messages)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:ephemeral_messages)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:ephemeral_messages)).to be(false)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:ephemeral_messages)).to be(true)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    # TEXT-stored JSON like the other control-plane blobs, never a jsonb.
    it "stores the channel blob as TEXT" do
      db_type = db.schema(:ephemeral_messages).to_h[:channel][:db_type].to_s.downcase
      expect(db_type).to include("text")
    end

    it "uses a plain DateTime for the delete-at horizon, not a backend-only type" do
      db_type = db.schema(:ephemeral_messages).to_h[:delete_at][:db_type].to_s.downcase
      expect(db_type).to match(/timestamp|datetime/)
    end
  end

  describe "the one-row-per-copy uniqueness" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    def insert(endpoint_id:, native_id:, group_id: "g", session_id: "s")
      db[:ephemeral_messages].insert(
        group_id: group_id, endpoint_id: endpoint_id, native_id: native_id,
        channel: "{}", delete_at: Time.now, session_id: session_id, created_at: Time.now
      )
    end

    it "rejects a second row for the same (endpoint, native message)" do
      insert(endpoint_id: "tg", native_id: "1")
      expect { insert(endpoint_id: "tg", native_id: "1") }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows the same native id on a different endpoint" do
      insert(endpoint_id: "tg", native_id: "1")
      expect { insert(endpoint_id: "dc", native_id: "1") }.not_to raise_error
    end
  end
end
