# frozen_string_literal: true

require "spec_helper"

# The Event domain object, a thin read wrapper over one events row: kind, rsvp
# mode, status predicates, UTC normalisation and JSON parsing.
RSpec.describe Rubotty::Events::Event do
  # A plain Hash stands in for an Event row, since the domain object only ever reads
  # columns by symbol key. A real Sequel row is used further down.
  def row(overrides = {})
    {
      id: 1, community_id: 10, room_id: 20, title: "Raid night",
      description: nil, timezone: "Europe/Lisbon", kind: "gaming",
      game_title: "Baldur's Gate 3", server_address: nil, url: nil,
      rsvp_mode: "full", status: "scheduled",
      reminder_intervals: nil, native_refs: "{}", created_by: "sample_owner",
      starts_at: Time.utc(2026, 8, 1, 20, 0, 0), ends_at: nil
    }.merge(overrides)
  end

  subject(:event) { described_class.new(row) }

  describe "plain readers" do
    it "reads the row's own columns" do
      expect(event.id).to eq(1)
      expect(event.community_id).to eq(10)
      expect(event.room_id).to eq(20)
      expect(event.title).to eq("Raid night")
      expect(event.timezone).to eq("Europe/Lisbon")
      expect(event.game_title).to eq("Baldur's Gate 3")
      expect(event.created_by).to eq("sample_owner")
    end
  end

  describe "kind predicates" do
    it "is gaming when kind is gaming" do
      expect(described_class.new(row(kind: "gaming")).gaming?).to be(true)
      expect(described_class.new(row(kind: "gaming")).general?).to be(false)
    end

    it "is general when kind is general" do
      expect(described_class.new(row(kind: "general")).general?).to be(true)
      expect(described_class.new(row(kind: "general")).gaming?).to be(false)
    end
  end

  describe "status predicates" do
    it "reports scheduled, cancelled and completed" do
      expect(described_class.new(row(status: "scheduled")).scheduled?).to be(true)
      expect(described_class.new(row(status: "cancelled")).cancelled?).to be(true)
      expect(described_class.new(row(status: "completed")).completed?).to be(true)
    end

    it "a status only reports its own predicate true" do
      scheduled = described_class.new(row(status: "scheduled"))
      expect(scheduled.cancelled?).to be(false)
      expect(scheduled.completed?).to be(false)
    end
  end

  describe "rsvp_mode predicates" do
    it "reports none, affirm and full" do
      expect(described_class.new(row(rsvp_mode: "none")).rsvp_none?).to be(true)
      expect(described_class.new(row(rsvp_mode: "affirm")).rsvp_affirm?).to be(true)
      expect(described_class.new(row(rsvp_mode: "full")).rsvp_full?).to be(true)
    end
  end

  describe "#starts_at" do
    it "is always UTC, regardless of the zone the underlying Time carries" do
      local = Time.new(2026, 8, 1, 21, 0, 0, "+01:00")
      wrapped = described_class.new(row(starts_at: local))
      expect(wrapped.starts_at).to eq(local)
      expect(wrapped.starts_at.utc?).to be(true)
    end

    it "parses a String timestamp, the shape SQLite hands some Sequel paths back" do
      wrapped = described_class.new(row(starts_at: "2026-08-01 20:00:00 UTC"))
      expect(wrapped.starts_at).to eq(Time.utc(2026, 8, 1, 20, 0, 0))
    end

    it "reads a String timestamp with no zone as UTC, not the process's local zone" do
      original_tz = ENV.fetch("TZ", nil)
      ENV["TZ"] = "Europe/Lisbon"

      # August is DST there (+01:00), so a naive parse that fell back to the
      # local zone would land an hour off from the UTC the column holds.
      wrapped = described_class.new(row(starts_at: "2026-08-01 20:00:00"))
      expect(wrapped.starts_at).to eq(Time.utc(2026, 8, 1, 20, 0, 0))
    ensure
      ENV["TZ"] = original_tz
    end
  end

  describe "#ends_at" do
    it "is nil when the row has no end time" do
      expect(described_class.new(row(ends_at: nil)).ends_at).to be_nil
    end

    it "is UTC when present" do
      local = Time.new(2026, 8, 1, 23, 0, 0, "+01:00")
      wrapped = described_class.new(row(ends_at: local))
      expect(wrapped.ends_at.utc?).to be(true)
      expect(wrapped.ends_at).to eq(local)
    end
  end

  describe "#reminder_intervals" do
    it "is nil when the row holds no override, meaning \"use the feature default\"" do
      expect(described_class.new(row(reminder_intervals: nil)).reminder_intervals).to be_nil
    end

    it "parses a JSON array override" do
      wrapped = described_class.new(row(reminder_intervals: "[3600,900]"))
      expect(wrapped.reminder_intervals).to eq([3600, 900])
    end

    it "is nil, not a raise, for an unparsable blob" do
      wrapped = described_class.new(row(reminder_intervals: "not json"))
      expect(wrapped.reminder_intervals).to be_nil
    end
  end

  describe "#native_refs and #native_ref" do
    it "is an empty hash for a row with no native mirror" do
      expect(described_class.new(row(native_refs: "{}")).native_refs).to eq({})
      expect(described_class.new(row(native_refs: nil)).native_refs).to eq({})
    end

    it "parses the platform => native id map" do
      wrapped = described_class.new(row(native_refs: '{"discord":"123456789012345678"}'))
      expect(wrapped.native_refs).to eq("discord" => "123456789012345678")
      expect(wrapped.native_ref("discord")).to eq("123456789012345678")
      expect(wrapped.native_ref(:discord)).to eq("123456789012345678")
    end

    it "is nil for a platform with no ref, an empty hash rather than a raise for garbage JSON" do
      wrapped = described_class.new(row(native_refs: "not json"))
      expect(wrapped.native_refs).to eq({})
      expect(wrapped.native_ref("discord")).to be_nil
    end
  end

  describe "#to_s and #inspect" do
    it "summarises title, kind and status" do
      expect(event.to_s).to eq("Raid night (gaming, scheduled)")
      expect(event.inspect).to include("Raid night (gaming, scheduled)")
    end
  end

  describe "wrapping a real control-plane row", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community) { models.community.where(slug: "sample").first }
    let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }
    let(:now) { Time.now }

    let(:stored) do
      models.event.create(
        community_id: community.id, room_id: room.id, title: "Raid night",
        starts_at: now + 3600, kind: "gaming", rsvp_mode: "full", status: "scheduled",
        native_refs: Rubotty::ControlPlane::Models.dump_json("discord" => "42"),
        created_at: now, updated_at: now
      )
    end

    it "wraps a Sequel::Model row exactly as it wraps a Hash" do
      wrapped = described_class.new(stored)
      expect(wrapped.title).to eq("Raid night")
      expect(wrapped.gaming?).to be(true)
      expect(wrapped.native_ref("discord")).to eq("42")
      expect(wrapped.starts_at.utc?).to be(true)
    end
  end
end
