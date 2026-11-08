# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The schema behind event scheduling: apply, rollback, re-apply, portable
# columns, and the constraints the rest of the feature relies on.
RSpec.describe "events migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates both tables when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:events)).to be(true)
    expect(db.table_exists?(:event_rsvps)).to be(true)
  end

  it "is idempotent: re-running when up to date leaves the tables intact" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:events)).to be(true)
    expect(db.table_exists?(:event_rsvps)).to be(true)
  end

  it "rolls fully back down, dropping both tables" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect(db.table_exists?(:events)).to be(false)
    expect(db.table_exists?(:event_rsvps)).to be(false)
  end

  # events and event_rsvps are both migration 017.
  it "rolling back to 16 drops the events tables and keeps the earlier control plane" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 16)
    expect(db.table_exists?(:events)).to be(false)
    expect(db.table_exists?(:event_rsvps)).to be(false)
    expect(db.table_exists?(:communities)).to be(true)
    expect(db.table_exists?(:rooms)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:events)).to be(true)
    expect(db.table_exists?(:event_rsvps)).to be(true)
  end

  describe "portable columns" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    it "stores description, reminder_intervals and native_refs as TEXT, not a backend-only jsonb type" do
      types = db.schema(:events).to_h
      %i[description reminder_intervals native_refs].each do |column|
        db_type = types[column][:db_type].to_s.downcase
        expect(db_type).to include("text"), "#{column} should be TEXT, got #{db_type.inspect}"
      end
    end

    it "defaults native_refs to an empty JSON object and leaves reminder_intervals null" do
      columns = db.schema(:events).to_h
      expect(columns[:native_refs][:default]).to include("{}")
      expect(columns[:reminder_intervals][:allow_null]).to be(true)
    end
  end

  describe "rows" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:now) { Time.now }

    let(:community_id) do
      db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end

    let(:room_id) do
      db[:rooms].insert(community_id: community_id, room_key: "gaming", label: "Gaming",
                        display_name: "{}", created_at: now, updated_at: now)
    end

    def event(overrides = {})
      db[:events].insert({
        community_id: community_id, room_id: room_id, title: "Raid night",
        starts_at: now + 3600, kind: "gaming", rsvp_mode: "full", status: "scheduled",
        native_refs: "{}", created_at: now, updated_at: now
      }.merge(overrides))
    end

    it "defaults rsvp_mode and status when not supplied" do
      id = db[:events].insert(community_id: community_id, room_id: room_id, title: "Raid night",
                              starts_at: now + 3600, kind: "gaming", native_refs: "{}",
                              created_at: now, updated_at: now)
      row = db[:events][id: id]
      expect(row[:rsvp_mode]).to eq("none")
      expect(row[:status]).to eq("scheduled")
    end

    it "rejects an rsvp with no matching event" do
      expect do
        db[:event_rsvps].insert(event_id: 999_999, identity: "u1", platform: "discord",
                                response: "yes", responded_at: now)
      end.to raise_error(Sequel::DatabaseError)
    end

    it "permits at most one rsvp row per (event, identity)" do
      event_id = event
      db[:event_rsvps].insert(event_id: event_id, identity: "u1", platform: "discord",
                              response: "yes", responded_at: now)
      expect do
        db[:event_rsvps].insert(event_id: event_id, identity: "u1", platform: "discord",
                                response: "no", responded_at: now)
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows the same identity to rsvp to two different events" do
      first = event
      second = event(title: "Second raid")
      db[:event_rsvps].insert(event_id: first, identity: "u1", platform: "discord",
                              response: "yes", responded_at: now)
      expect do
        db[:event_rsvps].insert(event_id: second, identity: "u1", platform: "discord",
                                response: "maybe", responded_at: now)
      end.not_to raise_error
    end
  end

  describe "cascade delete" do
    before { Rubotty::ControlPlane::Migrator.run(db) }

    let(:now) { Time.now }

    it "removes a community's events and their rsvps when the community is deleted" do
      community_id = db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                                             created_at: now, updated_at: now)
      room_id = db[:rooms].insert(community_id: community_id, room_key: "gaming", label: "Gaming",
                                  display_name: "{}", created_at: now, updated_at: now)
      event_id = db[:events].insert(community_id: community_id, room_id: room_id, title: "Raid night",
                                    starts_at: now + 3600, kind: "gaming", native_refs: "{}",
                                    created_at: now, updated_at: now)
      db[:event_rsvps].insert(event_id: event_id, identity: "u1", platform: "discord",
                              response: "yes", responded_at: now)

      db[:communities].where(id: community_id).delete

      expect(db[:events].count).to eq(0)
      expect(db[:event_rsvps].count).to eq(0)
    end

    it "removes a room's events (and their rsvps) when the room is deleted, independent of the community" do
      community_id = db[:communities].insert(slug: "c", name: "C", status: "active", settings: "{}",
                                             created_at: now, updated_at: now)
      room_id = db[:rooms].insert(community_id: community_id, room_key: "gaming", label: "Gaming",
                                  display_name: "{}", created_at: now, updated_at: now)
      event_id = db[:events].insert(community_id: community_id, room_id: room_id, title: "Raid night",
                                    starts_at: now + 3600, kind: "gaming", native_refs: "{}",
                                    created_at: now, updated_at: now)
      db[:event_rsvps].insert(event_id: event_id, identity: "u1", platform: "discord",
                              response: "yes", responded_at: now)

      db[:rooms].where(id: room_id).delete

      expect(db[:events].count).to eq(0)
      expect(db[:event_rsvps].count).to eq(0)
    end
  end
end
