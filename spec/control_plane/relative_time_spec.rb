# frozen_string_literal: true

require "spec_helper"

# The bounded relative time vocabulary /event's start= accepts alongside an
# absolute date. Zones here mostly use the fixed, DST-free `Etc/GMT+-N`
# POSIX identifiers (the sign is inverted: `Etc/GMT+1` is UTC-1) so a case
# is exact regardless of when the suite runs.
RSpec.describe Rubotty::ControlPlane::RelativeTime do
  # A Tuesday.
  let(:now) { Time.utc(2026, 8, 11, 10, 0, 0) }

  describe ".parse" do
    it "reads a bare now as the reference instant itself" do
      expect(described_class.parse("now", now: now)).to eq(now)
    end

    it "is case-insensitive for now" do
      expect(described_class.parse("Now", now: now)).to eq(now)
      expect(described_class.parse("NOW", now: now)).to eq(now)
    end

    describe "offsets" do
      it "reads an hour offset" do
        expect(described_class.parse("1 hour", now: now)).to eq(now + 3600)
      end

      it "reads a plural hours offset" do
        expect(described_class.parse("6 hours", now: now)).to eq(now + 6 * 3600)
      end

      it "reads a minutes offset" do
        expect(described_class.parse("45 minutes", now: now)).to eq(now + 45 * 60)
      end

      it "reads a days offset" do
        expect(described_class.parse("2 days", now: now)).to eq(now + 2 * 86_400)
      end

      it "is case-insensitive and tolerates the singular word with a plural count" do
        expect(described_class.parse("3 Hour", now: now)).to eq(now + 3 * 3600)
      end
    end

    describe "today plus a clock time" do
      it "reads today at a bare pm hour, in the given zone" do
        expect(described_class.parse("today 3pm", timezone: "Etc/GMT-1", now: now))
          .to eq(Time.utc(2026, 8, 11, 14, 0, 0)) # Etc/GMT-1 is UTC+1
      end

      it "reads today with minutes" do
        expect(described_class.parse("today 3:30pm", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 11, 15, 30, 0))
      end

      it "defaults to UTC when no timezone is given" do
        expect(described_class.parse("today 3pm", now: now)).to eq(Time.utc(2026, 8, 11, 15, 0, 0))
      end

      it "is case-insensitive" do
        expect(described_class.parse("Today 3PM", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 11, 15, 0, 0))
      end

      it "can read as a moment already in the past, leaving the future check to the caller" do
        expect(described_class.parse("today 9am", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 11, 9, 0, 0))
      end
    end

    describe "a bare clock time with no day of its own" do
      it "reads it as today, the same as an explicit today prefix" do
        expect(described_class.parse("3pm", timezone: "Etc/GMT-1", now: now))
          .to eq(Time.utc(2026, 8, 11, 14, 0, 0)) # Etc/GMT-1 is UTC+1
      end

      it "reads minutes and is case-insensitive, same as the today-prefixed form" do
        expect(described_class.parse("3:30PM", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 11, 15, 30, 0))
      end
    end

    describe "tomorrow plus a clock time" do
      it "reads tomorrow at a bare pm hour, in the given zone" do
        expect(described_class.parse("tomorrow 4pm", timezone: "Etc/GMT-1", now: now))
          .to eq(Time.utc(2026, 8, 12, 15, 0, 0)) # Etc/GMT-1 is UTC+1
      end

      it "reads tomorrow with minutes" do
        expect(described_class.parse("tomorrow 4:30pm", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 12, 16, 30, 0))
      end

      it "defaults to UTC when no timezone is given" do
        expect(described_class.parse("tomorrow 4pm", now: now)).to eq(Time.utc(2026, 8, 12, 16, 0, 0))
      end

      it "reads 12am as midnight" do
        expect(described_class.parse("tomorrow 12am", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 12, 0, 0, 0))
      end

      it "reads 12pm as noon" do
        expect(described_class.parse("tomorrow 12pm", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 12, 12, 0, 0))
      end
    end

    describe "a weekday plus a clock time" do
      it "reads the NEXT occurrence, never today, even when today already is that weekday" do
        # now is a Tuesday.
        expect(described_class.parse("tuesday 11pm", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 18, 23, 0, 0))
      end

      it "reads the very next occurrence for a weekday later this week" do
        expect(described_class.parse("wednesday 9am", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 12, 9, 0, 0))
      end

      it "wraps to next week for a weekday earlier than today" do
        expect(described_class.parse("monday 9am", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 17, 9, 0, 0))
      end

      it "is case-insensitive on the weekday name" do
        expect(described_class.parse("Wednesday 9AM", timezone: "Etc/GMT", now: now))
          .to eq(Time.utc(2026, 8, 12, 9, 0, 0))
      end
    end

    describe "what it declines" do
      it "returns nil for an absolute date, leaving it to the stdlib fallback" do
        expect(described_class.parse("2026-07-25 20:00", now: now)).to be_nil
      end

      it "returns nil for unrecognised text" do
        expect(described_class.parse("whenever works", now: now)).to be_nil
      end

      it "returns nil for a blank string" do
        expect(described_class.parse("", now: now)).to be_nil
        expect(described_class.parse(nil, now: now)).to be_nil
      end

      it "returns nil for a 24-hour clock time, which is outside the bounded vocabulary" do
        expect(described_class.parse("tomorrow 16:00", now: now)).to be_nil
      end

      it "returns nil for an hour out of the 1..12 range" do
        expect(described_class.parse("tomorrow 13pm", now: now)).to be_nil
      end
    end

    describe "an unrecognised or blank timezone" do
      it "falls back to UTC rather than raising" do
        expect(described_class.parse("tomorrow 4pm", timezone: "Not/AZone", now: now))
          .to eq(Time.utc(2026, 8, 12, 16, 0, 0))
      end

      it "falls back to UTC for a blank timezone string" do
        expect(described_class.parse("tomorrow 4pm", timezone: "", now: now))
          .to eq(Time.utc(2026, 8, 12, 16, 0, 0))
      end
    end

    describe "real DST transitions (America/New_York)" do
      it "returns nil for a wall-clock time that does not exist in a spring-forward gap" do
        # 2027-03-14 is the US spring-forward date; 2:30am never happens.
        wednesday = Time.utc(2027, 3, 10, 10, 0, 0)
        expect(described_class.parse("sunday 2:30am", timezone: "America/New_York", now: wednesday)).to be_nil
      end

      it "resolves an ambiguous fall-back hour to standard time" do
        # 2026-11-01 is the US fall-back date; 1:30am happens twice (EDT then EST).
        wednesday = Time.utc(2026, 10, 28, 10, 0, 0)
        result = described_class.parse("sunday 1:30am", timezone: "America/New_York", now: wednesday)
        expect(result).to eq(Time.utc(2026, 11, 1, 6, 30, 0)) # 1:30 EST == 06:30 UTC
      end
    end
  end
end
