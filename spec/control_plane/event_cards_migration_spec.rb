# frozen_string_literal: true

require "spec_helper"
require "sequel"

# Which posted copies of an event's card exist, so a reaction resolves back to
# its event and the announcer can edit every copy when the tally changes.
RSpec.describe "event_cards migration", :control_plane do
  let(:db) { Sequel.sqlite }

  it "creates the table when the control-plane migrations run" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect(db.table_exists?(:event_cards)).to be(true)
  end

  it "is idempotent" do
    Rubotty::ControlPlane::Migrator.run(db)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:event_cards)).to be(true)
  end

  it "rolls back to 17, dropping event_cards but keeping events and event_rsvps" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 17)
    expect(db.table_exists?(:event_cards)).to be(false)
    expect(db.table_exists?(:events)).to be(true)
    expect(db.table_exists?(:event_rsvps)).to be(true)
  end

  it "migrates cleanly again after a full rollback" do
    Rubotty::ControlPlane::Migrator.run(db)
    Rubotty::ControlPlane::Migrator.rollback(db, target: 0)
    expect { Rubotty::ControlPlane::Migrator.run(db) }.not_to raise_error
    expect(db.table_exists?(:event_cards)).to be(true)
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

    let(:event_id) do
      db[:events].insert(community_id: community_id, room_id: room_id, title: "Raid night",
                         starts_at: now + 3600, kind: "gaming", native_refs: "{}",
                         created_at: now, updated_at: now)
    end

    it "rejects a card with no matching event" do
      expect do
        db[:event_cards].insert(event_id: 999_999, endpoint_id: "tg-gaming", native_id: "1", created_at: now)
      end.to raise_error(Sequel::DatabaseError)
    end

    it "permits at most one card row per (endpoint_id, native_id)" do
      db[:event_cards].insert(event_id: event_id, endpoint_id: "tg-gaming", native_id: "1", created_at: now)
      expect do
        db[:event_cards].insert(event_id: event_id, endpoint_id: "tg-gaming", native_id: "1", created_at: now)
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it "allows several endpoint copies of the same event's card" do
      db[:event_cards].insert(event_id: event_id, endpoint_id: "tg-gaming", native_id: "1", created_at: now)
      expect do
        db[:event_cards].insert(event_id: event_id, endpoint_id: "dc-gaming", native_id: "2", created_at: now)
      end.not_to raise_error
      expect(db[:event_cards].where(event_id: event_id).count).to eq(2)
    end

    it "removes an event's card rows when the event is destroyed" do
      db[:event_cards].insert(event_id: event_id, endpoint_id: "tg-gaming", native_id: "1", created_at: now)
      db[:events].where(id: event_id).delete
      expect(db[:event_cards].count).to eq(0)
    end
  end
end
