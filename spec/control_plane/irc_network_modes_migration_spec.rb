# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 019 adds the mode, hub_channel and channel_keys columns that 013 deferred.
RSpec.describe "irc_network_modes migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "adds the mode, hub_channel and channel_keys columns" do
    Rubotty::ControlPlane::Migrator.run(db)
    columns = db.schema(:irc_networks).to_h.keys
    expect(columns).to include(:mode, :hub_channel, :channel_keys)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.schema(:irc_networks).to_h.keys).to include(:mode)
  end

  it "rolls back to 18, dropping the new columns but keeping irc_networks and its earlier columns" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 18)
    expect(db.table_exists?(:irc_networks)).to be(true)
    columns = db.schema(:irc_networks).to_h.keys
    expect(columns).not_to include(:mode, :hub_channel, :channel_keys)
    expect(columns).to include(:name, :host, :sasl_password_env, :channels)
  end

  it "migrates cleanly again after rolling back to 18" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 18)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.schema(:irc_networks).to_h.keys).to include(:mode, :hub_channel, :channel_keys)
  end

  it "rolls fully back down, dropping irc_networks entirely" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:irc_networks)).to be(false)
  end

  describe "defaults and portability" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    def network(name:, extra: {})
      db[:irc_networks].insert(
        {
          community_id: community_id, name: name, host: "irc.example.org", port: 6697,
          tls: true, nick: "rubotty", channels: "[]", created_at: Time.now, updated_at: Time.now
        }.merge(extra)
      )
    end

    let(:community_id) do
      now = Time.now
      db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end

    it "defaults mode to per_room when not given" do
      id = network(name: "libera")
      expect(db[:irc_networks][id: id][:mode]).to eq("per_room")
    end

    it "leaves hub_channel nil for a per_room network" do
      id = network(name: "libera")
      expect(db[:irc_networks][id: id][:hub_channel]).to be_nil
    end

    it "defaults channel_keys to an empty JSON object" do
      id = network(name: "libera")
      expect(db[:irc_networks][id: id][:channel_keys]).to eq("{}")
    end

    it "stores a hub network's mode and hub_channel" do
      id = network(name: "sample-hub", extra: { mode: "hub", hub_channel: "#sample" })
      row = db[:irc_networks][id: id]
      expect(row[:mode]).to eq("hub")
      expect(row[:hub_channel]).to eq("#sample")
    end

    it "lets two networks in the same community carry different modes" do
      hub_id = network(name: "small-net", extra: { mode: "hub", hub_channel: "#sample" })
      per_room_id = network(name: "big-net", extra: { mode: "per_room" })
      expect(db[:irc_networks][id: hub_id][:mode]).to eq("hub")
      expect(db[:irc_networks][id: per_room_id][:mode]).to eq("per_room")
    end

    it "stores channel_keys as TEXT, not a backend-only jsonb type" do
      db_type = db.schema(:irc_networks).to_h[:channel_keys][:db_type].to_s.downcase
      expect(db_type).to include("text")
    end

    it "references a channel key by env var name, e.g. via channel_keys, never a raw key column" do
      columns = db.schema(:irc_networks).to_h.keys
      expect(columns).not_to include(:channel_key, :key, :password)
    end
  end
end
