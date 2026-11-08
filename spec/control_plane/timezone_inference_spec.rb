# frozen_string_literal: true

require "spec_helper"

# The chain /event's start= reads a bare wall-clock time against when tz= is
# left blank (see lib/rubotty/control_plane/timezone_inference.rb): explicit
# tz= first, then a nickname flag, then a display-name flag, then this room's
# own configured default, then UTC.
RSpec.describe Rubotty::ControlPlane::TimezoneInference do
  describe ".resolve" do
    it "an explicit tz= always wins outright, even with a flag and a room default also present" do
      result = described_class.resolve(
        explicit: "Asia/Tokyo", nickname: "Sam \u{1F1F5}\u{1F1F9}",
        display_name: "Sam \u{1F1E9}\u{1F1EA}", community_default: "America/New_York"
      )
      expect(result).to eq("Asia/Tokyo")
    end

    it "falls through an invalid explicit tz= rather than trusting it blind" do
      result = described_class.resolve(explicit: "Not/AZone", community_default: "Europe/Paris")
      expect(result).to eq("Europe/Paris")
    end

    it "reads a nickname flag when there is no explicit tz=" do
      result = described_class.resolve(nickname: "Sam \u{1F1F5}\u{1F1F9}", display_name: "no flag here")
      expect(result).to eq("Europe/Lisbon")
    end

    it "prefers the nickname flag over a display-name flag" do
      result = described_class.resolve(nickname: "Sam \u{1F1F5}\u{1F1F9}", display_name: "Sam \u{1F1E9}\u{1F1EA}")
      expect(result).to eq("Europe/Lisbon")
    end

    it "falls back to a display-name flag when the nickname has none" do
      result = described_class.resolve(nickname: "Sam, no flag", display_name: "Sam \u{1F1E9}\u{1F1EA}")
      expect(result).to eq("Europe/Berlin")
    end

    it "falls through a multi-zone country's flag to the next source" do
      result = described_class.resolve(
        nickname: "Sam \u{1F1FA}\u{1F1F8}", community_default: "Europe/Paris"
      )
      expect(result).to eq("Europe/Paris")
    end

    it "reads the room's own configured default when nothing else answers" do
      result = described_class.resolve(community_default: "Asia/Tokyo")
      expect(result).to eq("Asia/Tokyo")
    end

    it "falls through an invalid room default rather than trusting it blind" do
      result = described_class.resolve(community_default: "Not/AZone")
      expect(result).to eq("UTC")
    end

    it "answers UTC as the absolute last resort" do
      expect(described_class.resolve).to eq("UTC")
    end

    it "treats a blank explicit tz= as absent, not an invalid override" do
      result = described_class.resolve(explicit: "   ", nickname: "Sam \u{1F1F5}\u{1F1F9}")
      expect(result).to eq("Europe/Lisbon")
    end

    it "treats nil nickname/display_name/community_default safely" do
      expect(described_class.resolve(nickname: nil, display_name: nil, community_default: nil)).to eq("UTC")
    end

    it "reads a bare city name typed casually, no Area/City form needed" do
      expect(described_class.resolve(explicit: "lisbon")).to eq("Europe/Lisbon")
    end

    it "is case and underscore insensitive on a bare city name" do
      expect(described_class.resolve(explicit: "New York")).to eq("America/New_York")
      expect(described_class.resolve(explicit: "new_york")).to eq("America/New_York")
    end

    it "resolves a city with no IANA segment of its own through the alias table" do
      expect(described_class.resolve(explicit: "miami")).to eq("America/New_York")
    end

    it "still refuses a name that matches neither a real zone nor an alias" do
      result = described_class.resolve(explicit: "nowhereville", community_default: "Europe/Paris")
      expect(result).to eq("Europe/Paris")
    end

    it "prefers the formal Area/City form over city-name matching when both would answer" do
      expect(described_class.resolve(explicit: "Asia/Tokyo")).to eq("Asia/Tokyo")
    end
  end
end
