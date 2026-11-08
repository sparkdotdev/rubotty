# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The marker RoomProvisioning's deletion path reads to tell a channel the bot
# created from one that was already there.
RSpec.describe "channel_provisioned_by_bot migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "adds the provisioned_by_bot column, defaulting to false" do
    Rubotty::ControlPlane::Migrator.run(db)
    columns = db.schema(:channels).to_h.keys
    expect(columns).to include(:provisioned_by_bot)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.schema(:channels).to_h.keys).to include(:provisioned_by_bot)
  end

  it "rolls back to 21, dropping the column but keeping channels and its earlier columns" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 21)
    expect(db.table_exists?(:channels)).to be(true)
    columns = db.schema(:channels).to_h.keys
    expect(columns).not_to include(:provisioned_by_bot)
    expect(columns).to include(:route_key, :endpoint_key)
  end

  it "migrates cleanly again after rolling back to 21" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 21)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.schema(:channels).to_h.keys).to include(:provisioned_by_bot)
  end

  describe "defaults" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:community_id) do
      now = Time.now
      db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end

    let(:connection_id) do
      now = Time.now
      db[:platform_connections].insert(
        community_id: community_id, adapter: "discord", account: "dc", external_id: "guild-1",
        created_at: now, updated_at: now
      )
    end

    it "defaults a channel row not otherwise given a value to false" do
      now = Time.now
      id = db[:channels].insert(
        community_id: community_id, platform_connection_id: connection_id,
        adapter: "discord", account: "dc", route_key: "111", endpoint_key: "discovered:discord:dc:111",
        created_at: now, updated_at: now
      )
      expect(db[:channels][id: id][:provisioned_by_bot]).to be(false)
    end

    it "stores true for a channel the bot created" do
      now = Time.now
      id = db[:channels].insert(
        community_id: community_id, platform_connection_id: connection_id,
        adapter: "discord", account: "dc", route_key: "222", endpoint_key: "discovered:discord:dc:222",
        provisioned_by_bot: true, created_at: now, updated_at: now
      )
      expect(db[:channels][id: id][:provisioned_by_bot]).to be(true)
    end
  end
end
