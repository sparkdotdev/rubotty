# frozen_string_literal: true

require "spec_helper"

# The shared fallback timestamp renderer behind Adapters::Base#render_timestamp: every
# adapter except Discord ends up here, since only Discord's own client can localise a bare
# token per viewer.
RSpec.describe Rubotty::Util::EventTimestamps do
  let(:time) { Time.utc(2026, 8, 1, 20, 0, 0) }

  describe ".full" do
    it "renders a calendar rendering in UTC by default" do
      expect(described_class.full(time, "UTC")).to eq("Sat, 01 Aug 2026 20:00 +0000")
    end

    it "renders exactly in a fixed offset Ruby can resolve" do
      expect(described_class.full(time, "+01:00")).to eq("Sat, 01 Aug 2026 21:00 +0100")
    end

    it "renders a named IANA zone with its DST offset" do
      expect(described_class.full(time, "Europe/Lisbon")).to eq("Sat, 01 Aug 2026 21:00 +0100")
    end

    it "labels an unrecognised timezone beside an honest UTC fallback" do
      expect(described_class.full(time, "Mars/Olympus")).to eq("Sat, 01 Aug 2026 20:00 +0000 (Mars/Olympus)")
    end

    it "treats a blank or nil tz as UTC" do
      expect(described_class.full(time, "")).to eq("Sat, 01 Aug 2026 20:00 +0000")
      expect(described_class.full(time, nil)).to eq("Sat, 01 Aug 2026 20:00 +0000")
    end
  end

  describe ".relative" do
    it "reports a future instant as a countdown" do
      expect(described_class.relative(time, now: time - 3 * 86_400)).to eq("in 3 days")
    end

    it "reports a past instant as a countup" do
      expect(described_class.relative(time, now: time + 2 * 3_600)).to eq("2 hours ago")
    end

    it "reports the largest whole unit, not a fractional one" do
      expect(described_class.relative(time, now: time - 90 * 60)).to eq("in 1 hour")
    end

    it "uses the singular for exactly one unit" do
      expect(described_class.relative(time, now: time - 3_600)).to eq("in 1 hour")
      expect(described_class.relative(time, now: time + 86_400)).to eq("1 day ago")
    end

    it "is just now for anything under 30 seconds either way" do
      expect(described_class.relative(time, now: time - 10)).to eq("just now")
      expect(described_class.relative(time, now: time + 10)).to eq("just now")
    end
  end

  describe ".format" do
    it "defaults to :full" do
      expect(described_class.format(time, tz: "UTC")).to eq(described_class.full(time, "UTC"))
    end

    # The caller's own instant, so a countdown here agrees with whatever text
    # that caller wrapped around it.
    it ":relative delegates to the countdown/countup renderer" do
      expect(described_class.format(time, style: :relative, tz: "UTC", now: time - (3 * 86_400)))
        .to eq("in 3 days")
    end

    it ":both combines the calendar rendering and the relative one" do
      expect(described_class.format(time, style: :both, tz: "UTC", now: time - 3_600))
        .to eq("#{described_class.full(time, "UTC")} (in 1 hour)")
    end
  end
end
