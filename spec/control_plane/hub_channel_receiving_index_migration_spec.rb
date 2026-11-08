# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 061: channels_route_idx drops its uniqueness so a hub group's
# several rows can share (adapter, account, route_key), and
# channels_route_receiving_idx picks up the narrower invariant that actually
# matters: at most one receives: true row per triple.
RSpec.describe "hub_channel_receiving_index migration", :control_plane do
  let(:db) { Sequel.sqlite }

  before { Rubotty::ControlPlane::Migrator.run(db) }

  let(:now) { Time.now }

  let(:community_id) do
    db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}", created_at: now, updated_at: now)
  end

  let(:connection_id) do
    db[:platform_connections].insert(
      community_id: community_id, adapter: "irc", account: "irc-hub", external_id: "irc-hub",
      created_at: now, updated_at: now
    )
  end

  def insert_channel(endpoint_key:, receives:)
    db[:channels].insert(
      community_id: community_id, platform_connection_id: connection_id,
      adapter: "irc", account: "irc-hub", route_key: "#sample", endpoint_key: endpoint_key,
      receives: receives, sends: true, relay: "{}", display_name: "{}", settings: "{}",
      created_at: now, updated_at: now
    )
  end

  it "allows two rows sharing a route_key as long as at most one receives" do
    insert_channel(endpoint_key: "irc-hub-gaming", receives: false)
    expect { insert_channel(endpoint_key: "irc-hub-travel", receives: true) }.not_to raise_error

    expect(db[:channels].where(adapter: "irc", account: "irc-hub", route_key: "#sample").count).to eq(2)
  end

  it "allows several non-receiving rows to share a route_key (a read-only hub)" do
    insert_channel(endpoint_key: "irc-hub-gaming", receives: false)
    insert_channel(endpoint_key: "irc-hub-travel", receives: false)
    expect { insert_channel(endpoint_key: "irc-hub-third", receives: false) }.not_to raise_error

    expect(db[:channels].where(adapter: "irc", account: "irc-hub", route_key: "#sample").count).to eq(3)
  end

  it "still rejects a second receives: true row on the same route_key" do
    insert_channel(endpoint_key: "irc-hub-gaming", receives: true)

    expect do
      insert_channel(endpoint_key: "irc-hub-travel", receives: true)
    end.to raise_error(Sequel::UniqueConstraintViolation)
  end

  # Every non-hub adapter never writes two rows sharing a route_key at all, so
  # the ordinary single-channel case is unconditionally the same guarantee the
  # old plain unique index gave.
  it "still rejects an ordinary duplicate route_key with no hub grouping involved" do
    insert_channel(endpoint_key: "irc-general", receives: true)

    expect do
      db[:channels].insert(
        community_id: community_id, platform_connection_id: connection_id,
        adapter: "irc", account: "irc-hub", route_key: "#sample", endpoint_key: "irc-general-2",
        receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
        created_at: now, updated_at: now
      )
    end.to raise_error(Sequel::UniqueConstraintViolation)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:channels)).to be(true)
  end

  it "rolls back to 60, restoring the plain global uniqueness on the triple" do
    Rubotty::ControlPlane::Migrator.rollback(db, target: 60)
    insert_channel(endpoint_key: "irc-hub-gaming", receives: false)

    expect do
      insert_channel(endpoint_key: "irc-hub-travel", receives: true)
    end.to raise_error(Sequel::UniqueConstraintViolation)
  end

  it "migrates cleanly again after rolling back to 60, restoring the hub-group allowance" do
    Rubotty::ControlPlane::Migrator.rollback(db, target: 60)
    Rubotty::ControlPlane::Migrator.run(db)

    insert_channel(endpoint_key: "irc-hub-gaming", receives: false)
    expect { insert_channel(endpoint_key: "irc-hub-travel", receives: true) }.not_to raise_error
  end
end
