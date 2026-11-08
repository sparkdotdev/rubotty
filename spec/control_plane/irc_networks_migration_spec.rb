# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Migration 013 builds the data and config layer for a multi-connection IRC gateway.
# No adapter reads the table yet.
RSpec.describe "irc_networks migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:irc_networks)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:irc_networks)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:irc_networks)).to be(false)
  end

  # irc_networks is migration 013, so target 13 rolls off everything above it and
  # drops nothing earlier.
  it "rolling back to 13 keeps irc_networks and the earlier control plane" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 13)
    expect(db.table_exists?(:irc_networks)).to be(true)
    expect(db.table_exists?(:communities)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:irc_networks)).to be(true)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    it "stores the channels list as TEXT, not a backend-only jsonb type" do
      db_type = db.schema(:irc_networks).to_h[:channels][:db_type].to_s.downcase
      expect(db_type).to include("text")
    end

    it "never has a column for the raw SASL password, only its env var name" do
      columns = db.schema(:irc_networks).to_h.keys
      expect(columns).to include(:sasl_password_env)
      expect(columns).not_to include(:sasl_password)
    end
  end

  describe "the per-community network name uniqueness" do
    before do
      Rubotty::ControlPlane::Migrator.run(db)
      now = Time.now
      db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end

    let(:community_id) { db[:communities].first[:id] }

    def network(name:, community: community_id)
      db[:irc_networks].insert(
        community_id: community, name: name, host: "irc.example.org", port: 6697,
        tls: true, nick: "rubotty", channels: "[]", created_at: Time.now, updated_at: Time.now
      )
    end

    it "rejects two networks with the same name in one community" do
      network(name: "libera")
      expect { network(name: "libera") }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows the same network name in a different community" do
      other_id = db[:communities].insert(slug: "c2", name: "C2", status: "active", settings: "{}",
                                         created_at: Time.now, updated_at: Time.now)
      network(name: "libera")
      expect { network(name: "libera", community: other_id) }.not_to raise_error
    end
  end

  describe "cascade delete" do
    it "removes a community's networks when the community is deleted" do
      Rubotty::ControlPlane::Migrator.run(db)
      now = Time.now
      community_id = db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                                             created_at: now, updated_at: now)
      db[:irc_networks].insert(community_id: community_id, name: "libera", host: "irc.libera.chat",
                               port: 6697, tls: true, nick: "rubotty", channels: "[]",
                               created_at: now, updated_at: now)
      db[:communities].where(id: community_id).delete
      expect(db[:irc_networks].count).to eq(0)
    end
  end
end
