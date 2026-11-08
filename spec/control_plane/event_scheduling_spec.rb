# frozen_string_literal: true

require "spec_helper"

# Both the /event chat command and the dashboard's events page drive this, so
# neither can disagree about what a valid event is or who may create one.
RSpec.describe Rubotty::ControlPlane::EventScheduling, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }
  let(:disabled_room) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:now) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }
  let(:clock) { -> { @now } }

  before { @now = now }

  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  subject(:scheduling) { described_class.new(models: models, clock: clock) }

  def turn_on!(who: "operators", selector: room.room_key)
    controls.enable(community: community, selector: selector, feature: "events")
    controls.set(community: community, selector: selector, feature: "events",
                 key: "who_can_create", value: who)
  end

  def create!(as: :operator, **overrides)
    scheduling.create(
      **{
        community: community, room: room, as: as, title: "Friday Raid Night",
        starts_at: "2026-07-25 20:00", timezone: "Europe/Lisbon", kind: "gaming",
        game_title: "Counter-Strike 2", server_address: "1.2.3.4:7777"
      }.merge(overrides)
    )
  end

  describe "#create" do
    before { turn_on! }

    it "creates a scheduled event with the given fields" do
      event = create!
      expect(event.community_id).to eq(community.id)
      expect(event.room_id).to eq(room.id)
      expect(event.title).to eq("Friday Raid Night")
      expect(event.kind).to eq("gaming")
      expect(event.scheduled?).to be(true)
      expect(event.status).to eq("scheduled")
    end

    it "reads a plain start time in its selected timezone, including DST" do
      event = create!(starts_at: "2026-07-25 20:00")
      expect(event.starts_at).to eq(Time.utc(2026, 7, 25, 19, 0, 0))
    end

    it "converts an explicit offset to UTC rather than trusting the server zone" do
      event = create!(starts_at: "2026-07-25T20:00:00-04:00")
      expect(event.starts_at).to eq(Time.utc(2026, 7, 26, 0, 0, 0))
    end

    it "reads a plain start time in its selected timezone" do
      event = create!(starts_at: "2026-07-25 20:00", timezone: "Asia/Tokyo")
      expect(event.starts_at).to eq(Time.utc(2026, 7, 25, 11, 0, 0))
      expect(event.timezone).to eq("Asia/Tokyo")
    end

    it "defaults rsvp_mode to none" do
      event = create!(rsvp_mode: nil)
      expect(event.rsvp_mode).to eq("none")
    end

    it "stamps provenance and the creation clock" do
      event = create!(created_by: "dashboard")
      expect(event.created_by).to eq("dashboard")
      expect(event.row.created_at.to_i).to eq(now.to_i)
    end

    it "carries gaming fields for a gaming event and drops them for a general one" do
      gaming = create!(kind: "gaming", game_title: "Valorant", server_address: "1.2.3.4:7777", url: "https://x")
      expect(gaming.game_title).to eq("Valorant")
      expect(gaming.server_address).to eq("1.2.3.4:7777")
      expect(gaming.url).to be_nil

      general = create!(kind: "general", game_title: "Valorant", url: "https://meet.example/room")
      expect(general.game_title).to be_nil
      expect(general.server_address).to be_nil
      expect(general.url).to eq("https://meet.example/room")
    end

    it "rejects a blank title" do
      expect { create!(title: "  ") }.to raise_error(described_class::Invalid, /title/)
    end

    it "rejects an unparsable start time" do
      expect { create!(starts_at: "whenever works") }.to raise_error(described_class::Invalid, /start time/)
    end

    it "rejects an unknown kind" do
      expect { create!(kind: "raid") }.to raise_error(described_class::Invalid, /kind/)
    end

    it "rejects an unknown rsvp_mode" do
      expect { create!(rsvp_mode: "maybe") }.to raise_error(described_class::Invalid, /rsvp_mode/)
    end

    it "rejects an end time at or before the start time" do
      expect { create!(ends_at: "2026-07-25 19:00") }.to raise_error(described_class::Invalid, /end time/)
    end

    describe "a relative start time" do
      # Overrides the outer `now`/clock with an explicit UTC instant (a
      # Friday), so the day/offset arithmetic below is exact regardless of
      # the outer let's own (locally-zoned) value or the host running this
      # suite's own timezone.
      let(:now) { Time.utc(2026, 7, 24, 12, 0, 0) }

      it "reads a bare offset against the injected clock, not the real one" do
        event = create!(starts_at: "6 hours")
        expect(event.starts_at).to eq(now + 6 * 3600)
      end

      it "reads now" do
        expect(create!(starts_at: "now").starts_at).to eq(now)
      end

      it "anchors tomorrow plus a clock time to the given timezone" do
        event = create!(starts_at: "tomorrow 4pm", timezone: "Etc/GMT-1") # Etc/GMT-1 is UTC+1
        expect(event.starts_at).to eq(Time.utc(2026, 7, 25, 15, 0, 0))
      end

      it "anchors a bare clock time to UTC when no timezone is given at all" do
        event = create!(starts_at: "tomorrow 4pm", timezone: nil)
        expect(event.starts_at).to eq(Time.utc(2026, 7, 25, 16, 0, 0))
      end

      it "reads a bare absolute start string in the selected timezone" do
        event = create!(starts_at: "2026-07-25 20:00", timezone: "Asia/Tokyo")
        expect(event.starts_at).to eq(Time.utc(2026, 7, 25, 11, 0, 0))
      end
    end

    describe "reminder_intervals" do
      it "leaves it nil (use the community/room default) when not given" do
        expect(create!.reminder_intervals).to be_nil
      end

      it "stores an explicit ladder" do
        expect(create!(reminder_intervals: [3600, 900]).reminder_intervals).to eq([3600, 900])
      end

      it "stores an explicit empty ladder as no reminders, distinct from nil" do
        event = create!(reminder_intervals: [])
        expect(event.reminder_intervals).to eq([])
        expect(event.reminder_intervals).not_to be_nil
      end

      it "rejects a non-positive entry" do
        expect { create!(reminder_intervals: [3600, 0]) }
          .to raise_error(described_class::Invalid, /reminder_intervals/)
        expect { create!(reminder_intervals: [-60]) }
          .to raise_error(described_class::Invalid, /reminder_intervals/)
      end
    end

    describe "recurrence_interval" do
      it "leaves it nil (a one-off event) when not given" do
        expect(create!.recurrence_interval).to be_nil
        expect(create!).not_to be_recurring
      end

      it "stores a positive interval" do
        event = create!(recurrence_interval: 604_800)
        expect(event.recurrence_interval).to eq(604_800)
        expect(event).to be_recurring
      end

      it "rejects a non-positive interval" do
        expect { create!(recurrence_interval: 0) }.to raise_error(described_class::Invalid, /repeat/)
        expect { create!(recurrence_interval: -60) }.to raise_error(described_class::Invalid, /repeat/)
      end
    end

    it "refuses a room that belongs to another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      settings: "{}", created_at: now, updated_at: now)
      other_room = models.room.create(community_id: other.id, room_key: "other-room", label: "Other",
                                      display_name: "{}", created_at: now, updated_at: now)
      expect { create!(room: other_room) }.to raise_error(described_class::Invalid, /does not belong/)
    end
  end

  describe "the events feature gate" do
    it "refuses a create when the room's events feature is off" do
      expect { create! }.to raise_error(described_class::Invalid, /not enabled/)
    end

    it "allows a create once the room turns events on" do
      turn_on!
      expect { create! }.not_to raise_error
    end
  end

  describe "who_can_create permission" do
    it "lets an operator create where events are on" do
      turn_on!(who: "operators")
      expect { create!(as: :operator) }.not_to raise_error
    end

    it "refuses a normal member when who_can_create is operators" do
      turn_on!(who: "operators")
      expect { create!(as: :member) }.to raise_error(described_class::Invalid, /only operators/)
    end

    it "lets a normal member create when who_can_create is everyone" do
      turn_on!(who: "everyone")
      expect { create!(as: :member) }.not_to raise_error
    end
  end

  describe "#cancel and #cancel_by_id" do
    before { turn_on! }

    it "marks a scheduled event cancelled" do
      event = create!
      cancelled = scheduling.cancel(event: event)
      expect(cancelled.cancelled?).to be(true)
    end

    it "is idempotent: cancelling an already-cancelled event is a harmless no-op" do
      event = create!
      scheduling.cancel(event: event)
      expect { scheduling.cancel(event: event) }.not_to raise_error
      expect(scheduling.find(community: community, id: event.id).cancelled?).to be(true)
    end

    it "cancels by id, scoped to the community" do
      event = create!
      cancelled = scheduling.cancel_by_id(community: community, id: event.id)
      expect(cancelled.cancelled?).to be(true)
    end

    it "returns nil for an id that does not exist in the community" do
      expect(scheduling.cancel_by_id(community: community, id: 999_999)).to be_nil
    end
  end

  # This class writes a row and stops. Announcements, reminders and the native
  # mirror are {Events::Lifecycle}'s, driven by watching the table.
  describe "creating a stamped native_refs mirror (issue #184, inbound mirror)" do
    before { turn_on! }

    it "stores the starting native_refs map a mirrored-in event carries" do
      event = create!(native_refs: { "discord" => "998877" })
      expect(scheduling.find(community: community, id: event.id).native_ref("discord")).to eq("998877")
    end

    it "leaves native_refs empty by default (every other caller)" do
      expect(create!.native_refs).to eq({})
    end
  end

  describe "#update" do
    before { turn_on! }

    it "changes only the fields it is given and bumps updated_at" do
      event = create!(title: "Old", starts_at: "2026-07-25 20:00")
      @now = now + 3600
      updated = scheduling.update(event: event, title: "New")

      expect(updated.title).to eq("New")
      expect(updated.starts_at).to eq(Time.utc(2026, 7, 25, 19, 0, 0)) # untouched
      expect(updated.row.updated_at.to_i).to eq((now + 3600).to_i)
    end

    it "moves the start time when asked" do
      event = create!(starts_at: "2026-07-25 20:00")
      updated = scheduling.update(event: event, starts_at: "2026-07-26 21:00")
      expect(updated.starts_at).to eq(Time.utc(2026, 7, 26, 20, 0, 0))
    end

    it "clears an optional field when passed nil, distinct from leaving it unset" do
      event = create!(kind: "general", url: "https://old.example")
      expect(scheduling.update(event: event, url: nil).url).to be_nil
    end

    it "writes nothing (no updated_at bump) when nothing actually changes" do
      event = create!(title: "Same")
      before_stamp = event.row.updated_at.to_i
      @now = now + 3600
      updated = scheduling.update(event: event)
      expect(updated.row.updated_at.to_i).to eq(before_stamp)
    end

    it "rejects a blank title and an unparsable start time" do
      event = create!
      expect { scheduling.update(event: event, title: "  ") }.to raise_error(described_class::Invalid, /title/)
      expect { scheduling.update(event: event, starts_at: "whenever") }
        .to raise_error(described_class::Invalid, /start time/)
    end

    it "rejects an ends_at pushed before the event's existing starts_at, leaving the row untouched" do
      event = create!(starts_at: "2026-07-25 20:00", ends_at: "2026-07-25 22:00")
      expect { scheduling.update(event: event, ends_at: "2020-01-01 00:00") }
        .to raise_error(described_class::Invalid, /end time must be after the start time/)
      expect(event.row.refresh.ends_at).not_to be_nil
    end

    it "rejects a starts_at pushed past the event's existing ends_at" do
      event = create!(starts_at: "2026-07-25 20:00", ends_at: "2026-07-25 22:00")
      expect { scheduling.update(event: event, starts_at: "2026-07-26 23:00") }
        .to raise_error(described_class::Invalid, /end time must be after the start time/)
    end

    it "allows moving both starts_at and ends_at together, staying ordered" do
      event = create!(starts_at: "2026-07-25 20:00", ends_at: "2026-07-25 22:00")
      updated = scheduling.update(event: event, starts_at: "2026-07-26 20:00", ends_at: "2026-07-26 22:00")
      expect(updated.starts_at).to eq(Time.utc(2026, 7, 26, 19, 0, 0))
      expect(updated.ends_at).to eq(Time.utc(2026, 7, 26, 21, 0, 0))
    end

    describe "a relative start time" do
      let(:now) { Time.utc(2026, 7, 24, 12, 0, 0) } # a Friday; overrides the outer clock

      it "anchors a relative starts_at to the event's OWN existing timezone when this call leaves it alone" do
        event = create!(starts_at: "2026-07-25 20:00", timezone: "Etc/GMT-1") # Etc/GMT-1 is UTC+1
        updated = scheduling.update(event: event, starts_at: "tomorrow 9am")
        expect(updated.starts_at).to eq(Time.utc(2026, 7, 25, 8, 0, 0))
      end

      it "anchors to the NEW timezone when both are changed in the same call" do
        event = create!(starts_at: "2026-07-25 20:00", timezone: "Etc/GMT")
        updated = scheduling.update(event: event, starts_at: "tomorrow 9am", timezone: "Etc/GMT-1")
        expect(updated.starts_at).to eq(Time.utc(2026, 7, 25, 8, 0, 0))
      end
    end

    describe "reminder_intervals" do
      it "leaves an unset override alone when not given" do
        event = create!(reminder_intervals: [3600])
        updated = scheduling.update(event: event, title: "New")
        expect(updated.reminder_intervals).to eq([3600])
      end

      it "replaces the override when given" do
        event = create!(reminder_intervals: [3600])
        updated = scheduling.update(event: event, reminder_intervals: [1800, 900])
        expect(updated.reminder_intervals).to eq([1800, 900])
      end

      it "clears the override back to nil (the community/room default) when passed nil explicitly" do
        event = create!(reminder_intervals: [3600])
        updated = scheduling.update(event: event, reminder_intervals: nil)
        expect(updated.reminder_intervals).to be_nil
      end

      it "rejects a non-positive entry" do
        event = create!
        expect { scheduling.update(event: event, reminder_intervals: [0]) }
          .to raise_error(described_class::Invalid, /reminder_intervals/)
      end
    end

    describe "recurrence_interval" do
      it "leaves an unset recurrence alone when not given" do
        event = create!(recurrence_interval: 86_400)
        updated = scheduling.update(event: event, title: "New")
        expect(updated.recurrence_interval).to eq(86_400)
      end

      it "replaces the recurrence when given" do
        event = create!(recurrence_interval: 86_400)
        updated = scheduling.update(event: event, recurrence_interval: 604_800)
        expect(updated.recurrence_interval).to eq(604_800)
      end

      it "clears the recurrence back to a one-off event when passed nil explicitly" do
        event = create!(recurrence_interval: 86_400)
        updated = scheduling.update(event: event, recurrence_interval: nil)
        expect(updated.recurrence_interval).to be_nil
        expect(updated).not_to be_recurring
      end
    end
  end

  describe "with no announcer or reminders (a pure writer)" do
    before { turn_on! }

    it "creates and cancels the row and nothing else" do
      event = create!
      expect(event.scheduled?).to be(true)
      expect(scheduling.cancel(event: event).cancelled?).to be(true)
    end
  end

  describe "#upcoming" do
    before { turn_on! }

    it "lists scheduled, not-yet-started events soonest first" do
      later = create!(title: "Later", starts_at: "2026-07-26 20:00")
      sooner = create!(title: "Sooner", starts_at: "2026-07-25 20:00")
      expect(scheduling.upcoming(community: community).map(&:id)).to eq([sooner.id, later.id])
    end

    it "excludes a cancelled event" do
      event = create!
      scheduling.cancel(event: event)
      expect(scheduling.upcoming(community: community)).to be_empty
    end

    it "excludes an event that has already started" do
      create!(starts_at: "2026-07-24 06:00") # before `now`
      expect(scheduling.upcoming(community: community)).to be_empty
    end

    it "does not leak another community's events" do
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      settings: "{}", created_at: now, updated_at: now)
      create!
      expect(scheduling.upcoming(community: other)).to be_empty
    end

    it "narrows to one room when given, the /events command's bare listing" do
      turn_on!(selector: disabled_room.room_key)
      in_gaming = create!(title: "In gaming")
      in_general = create!(title: "In general", room: disabled_room)

      expect(scheduling.upcoming(community: community, room: room).map(&:id)).to eq([in_gaming.id])
      expect(scheduling.upcoming(community: community, room: disabled_room).map(&:id)).to eq([in_general.id])
    end
  end

  describe "#room_for_endpoint_key" do
    it "resolves the room a channel's endpoint_key is bridged into" do
      resolved = scheduling.room_for_endpoint_key(community: community, endpoint_key: "tg-gaming")
      expect(resolved.room_key).to eq("gaming")
    end

    it "returns nil for an unknown endpoint_key" do
      expect(scheduling.room_for_endpoint_key(community: community, endpoint_key: "nope")).to be_nil
    end

    it "prefers the newest link when a channel is briefly bridged into two rooms (issue #1694)" do
      # Dashboard::App's channel-mapping route links a channel into its new
      # room before unlinking it from the old one, so room_channels briefly
      # holds a row for both. The newest row is the mapping an operator just
      # made; the older one is already on its way out.
      channel = models.channel.where(community_id: community.id, endpoint_key: "tg-gaming").first
      mapper = Rubotty::ControlPlane::ChannelMapper.new(models: models)
      mapper.map(community: community, selectors: [channel.endpoint_key], room_key: disabled_room.room_key)

      resolved = scheduling.room_for_endpoint_key(community: community, endpoint_key: "tg-gaming")
      expect(resolved.room_key).to eq("general")
    end
  end

  describe "#community_by_id" do
    it "resolves the community row for its id" do
      expect(scheduling.community_by_id(community.id).slug).to eq("sample")
    end

    it "returns nil for an unknown id" do
      expect(scheduling.community_by_id(999_999)).to be_nil
    end
  end

  describe ".parse_time" do
    it "reads a bare date-time as UTC" do
      expect(described_class.parse_time("2026-07-25 20:00")).to eq(Time.utc(2026, 7, 25, 20, 0, 0))
    end

    it "honours an explicit Z" do
      expect(described_class.parse_time("2026-07-25T20:00:00Z")).to eq(Time.utc(2026, 7, 25, 20, 0, 0))
    end

    it "converts an explicit offset" do
      expect(described_class.parse_time("2026-07-25T20:00:00+01:00")).to eq(Time.utc(2026, 7, 25, 19, 0, 0))
    end

    it "honours a lowercase utc suffix instead of reading it as local time" do
      value = described_class.parse_time("2026-08-16 20:00 utc", timezone: "America/New_York")
      expect(value).to eq(Time.utc(2026, 8, 16, 20, 0, 0))
    end

    it "honours a lowercase gmt suffix instead of reading it as local time" do
      value = described_class.parse_time("2026-08-16 20:00 gmt", timezone: "America/New_York")
      expect(value).to eq(Time.utc(2026, 8, 16, 20, 0, 0))
    end

    it "uses the matching DST offset for a bare local date-time" do
      value = described_class.parse_time("2026-08-16 20:00", timezone: "Europe/Lisbon")
      expect(value).to eq(Time.utc(2026, 8, 16, 19, 0, 0))
    end

    it "rejects a wall-clock time skipped by the spring-forward transition" do
      value = described_class.parse_time("2026-03-29 01:30", timezone: "Europe/Lisbon")
      expect(value).to be_nil
    end

    it "uses standard time for a repeated autumn wall-clock hour" do
      value = described_class.parse_time("2026-10-25 01:30", timezone: "Europe/Lisbon")
      expect(value).to eq(Time.utc(2026, 10, 25, 1, 30, 0))
    end

    it "passes a Time through as UTC" do
      expect(described_class.parse_time(Time.utc(2026, 1, 1))).to eq(Time.utc(2026, 1, 1))
    end

    it "returns nil for blank or unparsable input" do
      expect(described_class.parse_time("")).to be_nil
      expect(described_class.parse_time(nil)).to be_nil
      expect(described_class.parse_time("not a date")).to be_nil
    end

    describe "the relative vocabulary (delegated to RelativeTime)" do
      let(:reference) { Time.utc(2026, 7, 24, 12, 0, 0) } # a Friday

      it "reads a bare offset against the injected now" do
        expect(described_class.parse_time("2 hours", now: reference)).to eq(reference + 2 * 3600)
      end

      it "reads a clock time against the given timezone" do
        expect(described_class.parse_time("tomorrow 9am", timezone: "Etc/GMT-1", now: reference))
          .to eq(Time.utc(2026, 7, 25, 8, 0, 0))
      end

      it "still falls through to the absolute stdlib path for anything outside the vocabulary" do
        expect(described_class.parse_time("2026-07-25 20:00", timezone: "Asia/Tokyo", now: reference))
          .to eq(Time.utc(2026, 7, 25, 11, 0, 0))
      end
    end
  end
end
