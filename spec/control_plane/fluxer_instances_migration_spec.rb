# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The data and config layer for a 1-N Fluxer gateway: one flagship plus any
# number of self-hosted instances.
RSpec.describe "fluxer_instances migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:fluxer_instances)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:fluxer_instances)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:fluxer_instances)).to be(false)
  end

  # fluxer_instances is migration 014, one step above irc_networks at 013.
  it "rolls back above irc_networks, dropping this table but keeping irc_networks" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 13)
    expect(db.table_exists?(:fluxer_instances)).to be(false)
    expect(db.table_exists?(:irc_networks)).to be(true)
    expect(db.table_exists?(:communities)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:fluxer_instances)).to be(true)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    it "never has a column for the raw API key, only its env var name" do
      columns = db.schema(:fluxer_instances).to_h.keys
      expect(columns).to include(:api_key_env)
      expect(columns).not_to include(:api_key)
    end

    it "allows endpoint_url to be NULL, for a flagship instance" do
      schema = db.schema(:fluxer_instances).to_h
      expect(schema[:endpoint_url][:allow_null]).to be(true)
    end
  end

  describe "the per-community label uniqueness" do
    before do
      Rubotty::ControlPlane::Migrator.run(db)
      now = Time.now
      db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end

    let(:community_id) { db[:communities].first[:id] }

    def instance(label:, kind: "self_hosted", community: community_id)
      db[:fluxer_instances].insert(
        community_id: community, label: label, kind: kind, api_key_env: "FLUXER_API_KEY",
        created_at: Time.now, updated_at: Time.now
      )
    end

    it "rejects two instances with the same label in one community" do
      instance(label: "Flagship", kind: "flagship")
      expect { instance(label: "Flagship", kind: "flagship") }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows a flagship and a self-hosted instance with different labels" do
      instance(label: "Flagship", kind: "flagship")
      expect { instance(label: "Our self-hosted server") }.not_to raise_error
    end

    it "allows the same label in a different community" do
      other_id = db[:communities].insert(slug: "c2", name: "C2", status: "active", settings: "{}",
                                         created_at: Time.now, updated_at: Time.now)
      instance(label: "Flagship", kind: "flagship")
      expect { instance(label: "Flagship", kind: "flagship", community: other_id) }.not_to raise_error
    end
  end

  describe "cascade delete" do
    it "removes a community's instances when the community is deleted" do
      Rubotty::ControlPlane::Migrator.run(db)
      now = Time.now
      community_id = db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                                             created_at: now, updated_at: now)
      db[:fluxer_instances].insert(community_id: community_id, label: "Flagship", kind: "flagship",
                                   api_key_env: "FLUXER_API_KEY", created_at: now, updated_at: now)
      db[:communities].where(id: community_id).delete
      expect(db[:fluxer_instances].count).to eq(0)
    end
  end
end
