# frozen_string_literal: true

require "spec_helper"

# The RSVP ledger: the write side of event_rsvps, shared by the reaction and /rsvp
# capture surfaces, over a migrated in-memory database.
RSpec.describe Rubotty::Events::RsvpLedger, :control_plane do
  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  let(:community) do
    models.community.create(slug: "c", name: "C", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  let(:room) do
    models.room.create(community_id: community.id, room_key: "gaming", label: "Gaming",
                       display_name: "{}", created_at: now, updated_at: now)
  end

  def event(rsvp_mode:)
    row = models.event.create(
      community_id: community.id, room_id: room.id, title: "Raid Night",
      starts_at: now + 3600, kind: "gaming", rsvp_mode: rsvp_mode, status: "scheduled",
      native_refs: "{}", created_at: now, updated_at: now
    )
    Rubotty::Events::Event.new(row)
  end

  subject(:ledger) { described_class.new(models: models, logger: Rubotty::Log.null) }

  describe "#allowed_for" do
    it "is empty for a none-mode event" do
      expect(ledger.allowed_for(event(rsvp_mode: "none"))).to eq([])
    end

    it "is ['in'] for an affirm-mode event" do
      expect(ledger.allowed_for(event(rsvp_mode: "affirm"))).to eq(["in"])
    end

    it "is yes/maybe/no for a full-mode event" do
      expect(ledger.allowed_for(event(rsvp_mode: "full"))).to eq(%w[yes maybe no])
    end
  end

  describe "#record" do
    it "refuses any response for a none-mode event" do
      ev = event(rsvp_mode: "none")
      expect { ledger.record(event: ev, identity: "u1", platform: "telegram", response: "yes") }
        .to raise_error(described_class::Invalid, /not enabled/)
      expect(models.event_rsvp.count).to eq(0)
    end

    it "accepts only 'in' for an affirm-mode event" do
      ev = event(rsvp_mode: "affirm")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "in")
      expect(models.event_rsvp.first.response).to eq("in")
    end

    it "refuses yes/maybe/no for an affirm-mode event" do
      ev = event(rsvp_mode: "affirm")
      expect { ledger.record(event: ev, identity: "u1", platform: "telegram", response: "yes") }
        .to raise_error(described_class::Invalid, /response must be/)
    end

    it "accepts yes, maybe or no for a full-mode event, case-insensitively" do
      ev = event(rsvp_mode: "full")
      expect(ledger.record(event: ev, identity: "u1", platform: "telegram", response: "YES")).to eq("yes")
      expect(ledger.record(event: ev, identity: "u2", platform: "telegram", response: "Maybe")).to eq("maybe")
      expect(ledger.record(event: ev, identity: "u3", platform: "telegram", response: "no")).to eq("no")
    end

    it "refuses 'in' for a full-mode event" do
      ev = event(rsvp_mode: "full")
      expect { ledger.record(event: ev, identity: "u1", platform: "telegram", response: "in") }
        .to raise_error(described_class::Invalid)
    end

    it "moves an identity's response on a second call rather than adding a second row" do
      ev = event(rsvp_mode: "full")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "maybe")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "yes")

      expect(models.event_rsvp.where(event_id: ev.id, identity: "u1").count).to eq(1)
      expect(models.event_rsvp.first.response).to eq("yes")
    end

    it "keeps two different identities' responses independent" do
      ev = event(rsvp_mode: "full")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "yes")
      ledger.record(event: ev, identity: "u2", platform: "discord", response: "no")

      expect(ledger.response_for(event: ev, identity: "u1")).to eq("yes")
      expect(ledger.response_for(event: ev, identity: "u2")).to eq("no")
    end
  end

  describe "#clear" do
    it "removes the row when no expected_response is given" do
      ev = event(rsvp_mode: "full")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "yes")

      expect(ledger.clear(event: ev, identity: "u1")).to be(true)
      expect(models.event_rsvp.count).to eq(0)
    end

    it "removes the row when it matches expected_response" do
      ev = event(rsvp_mode: "full")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "maybe")

      expect(ledger.clear(event: ev, identity: "u1", expected_response: "maybe")).to be(true)
      expect(models.event_rsvp.count).to eq(0)
    end

    it "is a no-op when the row no longer matches expected_response (a stale reaction being removed)" do
      ev = event(rsvp_mode: "full")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "maybe")
      ledger.record(event: ev, identity: "u1", platform: "telegram", response: "yes") # moved

      expect(ledger.clear(event: ev, identity: "u1", expected_response: "maybe")).to be(false)
      expect(ledger.response_for(event: ev, identity: "u1")).to eq("yes")
    end

    it "is a no-op, returning false, when there is no row at all" do
      ev = event(rsvp_mode: "full")
      expect(ledger.clear(event: ev, identity: "nobody")).to be(false)
    end
  end

  describe "#response_for" do
    it "is nil for an identity with no response" do
      ev = event(rsvp_mode: "full")
      expect(ledger.response_for(event: ev, identity: "nobody")).to be_nil
    end
  end
end
