# frozen_string_literal: true

require "spec_helper"

# The room-scoped event and its responses, shaped like community.channels and
# community.rooms.
RSpec.describe Rubotty::ControlPlane::Models, "events and event_rsvps", :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "sample", name: "SAMPLE", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  let(:room) do
    models.room.create(community_id: community.id, room_key: "gaming", label: "Gaming",
                       display_name: "{}", created_at: now, updated_at: now)
  end

  describe "events" do
    let!(:event) do
      models.event.create(
        community_id: community.id, room_id: room.id, title: "Raid night",
        starts_at: now + 3600, kind: "gaming", rsvp_mode: "full", status: "scheduled",
        native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "123"),
        created_at: now, updated_at: now
      )
    end

    it "is reachable from its community, mirroring community.channels" do
      expect(community.events.map(&:title)).to eq(["Raid night"])
    end

    it "is reachable from its room, mirroring room.channels" do
      expect(room.events.map(&:title)).to eq(["Raid night"])
    end

    it "points back to its community and room" do
      expect(event.community.slug).to eq("sample")
      expect(event.room.room_key).to eq("gaming")
    end

    it "reads the native_refs blob back as a Ruby hash" do
      expect(event.json_value(:native_refs)).to eq("discord" => "123")
    end

    it "is removed when its community is destroyed" do
      community.destroy
      expect(models.event.count).to eq(0)
    end

    it "is removed when its room is destroyed, independent of the community" do
      room.destroy
      expect(models.event.count).to eq(0)
    end
  end

  describe "event_rsvps" do
    let!(:event) do
      models.event.create(
        community_id: community.id, room_id: room.id, title: "Raid night",
        starts_at: now + 3600, kind: "gaming", rsvp_mode: "full", status: "scheduled",
        native_refs: "{}", created_at: now, updated_at: now
      )
    end

    let!(:rsvp) do
      models.event_rsvp.create(
        event_id: event.id, identity: "80000012", platform: "telegram",
        response: "yes", responded_at: now
      )
    end

    it "is reachable from its event, mirroring guest_invite.guest_messages" do
      expect(event.rsvps.map(&:identity)).to eq(["80000012"])
    end

    it "points back to its event" do
      expect(rsvp.event.title).to eq("Raid night")
    end

    it "is removed when its event is destroyed" do
      event.destroy
      expect(models.event_rsvp.count).to eq(0)
    end
  end

  describe "event_cards (issue #184, wave 3b)" do
    let!(:event) do
      models.event.create(
        community_id: community.id, room_id: room.id, title: "Raid night",
        starts_at: now + 3600, kind: "gaming", rsvp_mode: "full", status: "scheduled",
        native_refs: "{}", created_at: now, updated_at: now
      )
    end

    let!(:card) do
      models.event_card.create(event_id: event.id, endpoint_id: "tg-gaming", native_id: "123", created_at: now)
    end

    it "is reachable from its event, mirroring event.rsvps" do
      expect(event.cards.map(&:native_id)).to eq(["123"])
    end

    it "points back to its event" do
      expect(card.event.title).to eq("Raid night")
    end

    it "is removed when its event is destroyed" do
      event.destroy
      expect(models.event_card.count).to eq(0)
    end
  end

  it "binds to the supplied database without global state, like the other models" do
    models.event.create(
      community_id: community.id, room_id: room.id, title: "Raid night",
      starts_at: now + 3600, kind: "gaming", native_refs: "{}", created_at: now, updated_at: now
    )
    other = build_models(migrated_db)
    expect(models.event.count).to eq(1)
    expect(other.event.count).to eq(0)
  end
end
