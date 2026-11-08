# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Polls::ScheduleSlots do
  # A Wednesday, mid-afternoon in Lisbon.
  let(:now) { Time.utc(2026, 8, 12, 14, 0, 0) }
  let(:zone) { "Europe/Lisbon" }

  def lisbon_evening(day) = Time.utc(2026, 8, day, 18, 0, 0)

  describe ".suggested" do
    it "reads a weekday and a clock time through the vocabulary /event already takes" do
      expect(described_class.suggested("tuesday 7pm", timezone: zone, now: now))
        .to eq(Time.utc(2026, 8, 18, 18, 0, 0))
    end

    it "reads the same day when somebody writes the word next in front of it" do
      expect(described_class.suggested("next monday 1pm", timezone: zone, now: now))
        .to eq(described_class.suggested("monday 1pm", timezone: zone, now: now))
    end

    it "reads tomorrow and an offset too" do
      expect(described_class.suggested("tomorrow 4pm", timezone: zone, now: now))
        .to eq(Time.utc(2026, 8, 13, 15, 0, 0))
      expect(described_class.suggested("6 hours", timezone: zone, now: now)).to eq(now + (6 * 3600))
    end

    it "says nothing for text outside the vocabulary" do
      expect(described_class.suggested("sometime next week maybe", timezone: zone, now: now)).to be_nil
      expect(described_class.suggested("", timezone: zone, now: now)).to be_nil
    end

    it "refuses a time already behind the clock" do
      expect(described_class.suggested("now", timezone: zone, now: now)).to be_nil
    end
  end

  describe ".label" do
    it "writes the slot out in the session's own zone" do
      slot = lisbon_evening(12)

      expect(described_class.label(slot, zone)).to eq(Rubotty::Util::EventTimestamps.full(slot, zone))
      expect(described_class.label(slot, nil)).to eq(Rubotty::Util::EventTimestamps.full(slot, "UTC"))
    end
  end
end
