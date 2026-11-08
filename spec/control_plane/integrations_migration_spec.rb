# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The storage for one deployment-wide connection to an outside service, e.g.
# libretranslate. No community_id: an integration belongs to the whole
# deployment.
RSpec.describe "integrations migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:integrations)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the table intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:integrations)).to be(true)
  end

  it "rolls fully back down, dropping the table" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:integrations)).to be(false)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:integrations)).to be(true)
  end

  it "has no community_id column: an integration is deployment-wide" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.schema(:integrations).to_h.keys).not_to include(:community_id)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    it "stores config as text so the schema is identical on sqlite and pg" do
      db_type = db.schema(:integrations).to_h[:config][:db_type].to_s.downcase
      expect(db_type).to include("text")
    end
  end

  describe "the name uniqueness" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    def integration(name:)
      now = Time.now
      db[:integrations].insert(name: name, created_at: now, updated_at: now)
    end

    it "rejects two rows with the same name" do
      integration(name: "libretranslate")
      expect { integration(name: "libretranslate") }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows two different names" do
      integration(name: "libretranslate")
      expect { integration(name: "object_storage") }.not_to raise_error
    end
  end
end
