# frozen_string_literal: true

require "spec_helper"

# Day math and clock formatting for expanding a Discord `<t:UNIX:FORMAT>`
# token into readable, multi-timezone plain text. Zones here use the fixed,
# DST-free `Etc/GMT+-N` POSIX identifiers (note the inverted sign:
# `Etc/GMT+8` is UTC-8) so every case is exact regardless of when it runs.
RSpec.describe Rubotty::Features::TimestampExpansion do
  let(:pacific) { described_class::Zone.new(label: "Pacific", iana_timezone: "Etc/GMT+8") }
  let(:eastern) { described_class::Zone.new(label: "Eastern", iana_timezone: "Etc/GMT+5") }
  let(:india) { described_class::Zone.new(label: "India", iana_timezone: "Etc/GMT-4") }
  let(:utc) { described_class::Zone.new(label: "UTC", iana_timezone: "Etc/GMT") }

  describe ".day_label" do
    # Wednesday 12 August 2026, judged in a plain UTC reference zone.
    let(:now) { Time.utc(2026, 8, 12, 12, 0, 0) }

    it "reads the same calendar day as Today" do
      expect(described_class.day_label(now, "Etc/GMT", now)).to eq("Today")
    end

    it "reads one day out as Tomorrow" do
      expect(described_class.day_label(now + 86_400, "Etc/GMT", now)).to eq("Tomorrow")
    end

    it "reads two days out as the bare weekday name, not Tomorrow" do
      expect(described_class.day_label(now + 2 * 86_400, "Etc/GMT", now)).to eq("Friday")
    end

    it "keeps the bare weekday name through six days out" do
      expect(described_class.day_label(now + 6 * 86_400, "Etc/GMT", now)).to eq("Tuesday")
    end

    it "switches to Next <weekday> at exactly seven days out" do
      expect(described_class.day_label(now + 7 * 86_400, "Etc/GMT", now)).to eq("Next Wednesday")
    end

    it "keeps Next <weekday> through thirteen days out" do
      expect(described_class.day_label(now + 13 * 86_400, "Etc/GMT", now)).to eq("Next Tuesday")
    end

    it "switches to the absolute <weekday> <day> <month> form at exactly fourteen days out" do
      expect(described_class.day_label(now + 14 * 86_400, "Etc/GMT", now)).to eq("Wednesday 26 Aug")
    end

    it "keeps the absolute form well beyond fourteen days out" do
      expect(described_class.day_label(now + 40 * 86_400, "Etc/GMT", now)).to eq("Monday 21 Sept")
    end

    it "uses the absolute form for a date already in the past" do
      expect(described_class.day_label(now - 86_400, "Etc/GMT", now)).to eq("Tuesday 11 Aug")
    end

    # The maintainer's own "Monday 16 Sept" example uses the British four-letter
    # abbreviation for September specifically; every other month stays three letters.
    it "abbreviates September as Sept rather than Ruby's own three-letter Sep" do
      far_out = Time.utc(2026, 9, 16, 12, 0, 0)
      expect(described_class.day_label(far_out, "Etc/GMT", now)).to eq("Wednesday 16 Sept")
    end

    it "uses the plain three-letter form for a month other than September" do
      far_out = Time.utc(2026, 12, 25, 12, 0, 0)
      expect(described_class.day_label(far_out, "Etc/GMT", now)).to eq("Friday 25 Dec")
    end

    # The same instant reads as a different calendar day in Pacific and in
    # India: 30 minutes after `now`, Pacific is still mid afternoon on the
    # 12th, while India has crossed into the small hours of the 13th. The
    # label is judged ONLY against the zone passed in, not any other configured zone.
    it "judges the day only against the reference zone, not any other configured zone" do
      instant = now + 11 * 3600 + 30 * 60 # now + 11h30m: 23:30 UTC same day
      expect(described_class.day_label(instant, pacific.iana_timezone, now)).to eq("Today")
      # India (UTC+4) reads the SAME instant as 03:30 the next calendar day.
      expect(described_class.day_label(instant, india.iana_timezone, now)).to eq("Tomorrow")
    end
  end

  describe ".clock" do
    it "shows a plain hour with no minutes when the time falls exactly on the hour" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 15, 0, 0), "Etc/GMT")).to eq("3PM")
    end

    it "shows minutes when the time does not fall on the hour" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 15, 7, 0), "Etc/GMT")).to eq("3:07PM")
    end

    it "pads a single digit minute" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 15, 4, 0), "Etc/GMT")).to eq("3:04PM")
    end

    it "substitutes Midnight for exactly 12AM" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 0, 0, 0), "Etc/GMT")).to eq("Midnight")
    end

    it "substitutes Noon for exactly 12PM" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 12, 0, 0), "Etc/GMT")).to eq("Noon")
    end

    it "does not substitute Midnight when minutes are past the hour" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 0, 5, 0), "Etc/GMT")).to eq("12:05AM")
    end

    it "does not substitute Noon when minutes are past the hour" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 12, 30, 0), "Etc/GMT")).to eq("12:30PM")
    end

    it "reads the morning hours as AM" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 1, 0, 0), "Etc/GMT")).to eq("1AM")
      expect(described_class.clock(Time.utc(2026, 8, 12, 11, 0, 0), "Etc/GMT")).to eq("11AM")
    end

    it "reads the evening hours as PM" do
      expect(described_class.clock(Time.utc(2026, 8, 12, 13, 0, 0), "Etc/GMT")).to eq("1PM")
      expect(described_class.clock(Time.utc(2026, 8, 12, 23, 0, 0), "Etc/GMT")).to eq("11PM")
    end

    it "resolves against the zone offset, not UTC" do
      # Etc/GMT+8 is UTC-8: 15:00 UTC is 7AM there.
      expect(described_class.clock(Time.utc(2026, 8, 12, 15, 0, 0), "Etc/GMT+8")).to eq("7AM")
    end
  end

  describe ".render" do
    let(:now) { Time.utc(2026, 8, 12, 10, 0, 0) }
    let(:zones) { [pacific, eastern, india] }

    it "joins the day label and every zone's clock reading in configured order" do
      # 20:00 UTC = noon Pacific, 3PM Eastern, midnight the next day in India.
      time = Time.utc(2026, 8, 12, 20, 0, 0)
      expect(described_class.render(time, zones, now)).to eq("Today Noon Pacific, 3PM Eastern, Midnight India")
    end

    it "shows minutes on every zone alike when the instant does not fall on the hour" do
      time = Time.utc(2026, 8, 12, 20, 15, 0)
      expect(described_class.render(time, zones, now))
        .to eq("Today 12:15PM Pacific, 3:15PM Eastern, 12:15AM India")
    end
  end

  describe ".expand" do
    let(:zones) { [pacific, eastern, india] }
    let(:now) { Time.utc(2026, 8, 12, 10, 0, 0) }
    let(:unix) { Time.utc(2026, 8, 12, 20, 0, 0).to_i }

    it "replaces a single token in place, keeping the surrounding text" do
      text = "see you <t:#{unix}:t> then"
      expect(described_class.expand(text, zones, now: now))
        .to eq("see you Today Noon Pacific, 3PM Eastern, Midnight India then")
    end

    it "expands every one of Discord's format codes the same way" do
      %w[t T d D f F R].each do |code|
        text = described_class.expand("<t:#{unix}:#{code}>", zones, now: now)
        expect(text).to eq("Today Noon Pacific, 3PM Eastern, Midnight India")
      end
    end

    it "expands a bare token with no format code at all" do
      text = described_class.expand("<t:#{unix}>", zones, now: now)
      expect(text).to eq("Today Noon Pacific, 3PM Eastern, Midnight India")
    end

    it "expands more than one token in the same message independently" do
      later_unix = Time.utc(2026, 8, 14, 9, 0, 0).to_i
      text = "start <t:#{unix}:t>, then <t:#{later_unix}:t>"
      expect(described_class.expand(text, zones, now: now))
        .to eq("start Today Noon Pacific, 3PM Eastern, Midnight India, " \
               "then Friday 1AM Pacific, 4AM Eastern, 1PM India")
    end

    it "leaves a message with no timestamp token completely untouched" do
      text = "just an ordinary message, nothing to see"
      expect(described_class.expand(text, zones, now: now)).to equal(text)
    end

    it "is a no-op with no configured zones (nil)" do
      text = "see you <t:#{unix}:t> then"
      expect(described_class.expand(text, nil, now: now)).to equal(text)
    end

    it "is a no-op with an empty configured zone list" do
      text = "see you <t:#{unix}:t> then"
      expect(described_class.expand(text, [], now: now)).to equal(text)
    end
  end

  describe ".render_token" do
    it "returns nil rather than raising for a capture that is not a real number" do
      expect(described_class.render_token("not-a-number", [utc])).to be_nil
    end
  end

  describe ".parse_zones" do
    it "parses an ordered list of symbol-keyed entries" do
      raw = [
        { label: "Pacific", iana_timezone: "America/Los_Angeles" },
        { label: "India", iana_timezone: "Asia/Kolkata" }
      ]
      zones = described_class.parse_zones(raw)
      expect(zones.map(&:label)).to eq(%w[Pacific India])
      expect(zones.map(&:iana_timezone)).to eq(%w[America/Los_Angeles Asia/Kolkata])
    end

    it "parses string-keyed entries the same way, matching how YAML config arrives" do
      raw = [{ "label" => "Pacific", "iana_timezone" => "America/Los_Angeles" }]
      zones = described_class.parse_zones(raw)
      expect(zones.map(&:label)).to eq(["Pacific"])
    end

    it "drops an entry missing a label" do
      raw = [{ iana_timezone: "America/Los_Angeles" }]
      expect(described_class.parse_zones(raw, logger: Rubotty::Log.null)).to eq([])
    end

    it "drops an entry missing an iana_timezone" do
      raw = [{ label: "Pacific" }]
      expect(described_class.parse_zones(raw, logger: Rubotty::Log.null)).to eq([])
    end

    it "drops an entry naming a zone tzinfo does not recognise" do
      raw = [{ label: "Nowhere", iana_timezone: "Not/AZone" }]
      expect(described_class.parse_zones(raw, logger: Rubotty::Log.null)).to eq([])
    end

    it "drops an entry that is not a mapping at all" do
      raw = ["Pacific", 42, nil]
      expect(described_class.parse_zones(raw, logger: Rubotty::Log.null)).to eq([])
    end

    it "keeps the good entries in a mixed list rather than dropping all of them" do
      raw = [
        { label: "Pacific", iana_timezone: "America/Los_Angeles" },
        { label: "Bad" },
        { label: "India", iana_timezone: "Asia/Kolkata" }
      ]
      zones = described_class.parse_zones(raw, logger: Rubotty::Log.null)
      expect(zones.map(&:label)).to eq(%w[Pacific India])
    end

    it "is empty for nil input, which .zones_for_config never hands it for an unset key" do
      expect(described_class.parse_zones(nil)).to eq([])
    end
  end

  # The tri-state every reader of the config key shares: never set, set to
  # something, set to nothing on purpose.
  describe ".zones_for_config" do
    def labels(config) = described_class.zones_for_config(config, logger: Rubotty::Log.null).map(&:label)

    it "falls back to the shipped defaults when the key is absent" do
      expect(labels({})).to eq(["Pacific", "Eastern", "Western Europe", "Central Europe"])
    end

    it "falls back to the shipped defaults for a config that is not a mapping at all" do
      expect(labels(nil)).to eq(["Pacific", "Eastern", "Western Europe", "Central Europe"])
    end

    it "falls back to the shipped defaults for a key explicitly set to null" do
      expect(labels({ timestamp_timezones: nil })).to eq(["Pacific", "Eastern", "Western Europe",
                                                          "Central Europe"])
    end

    it "stays empty for a key explicitly set to an empty list" do
      expect(labels({ timestamp_timezones: [] })).to eq([])
    end

    it "returns exactly what was configured, without appending the defaults" do
      expect(labels({ timestamp_timezones: [{ label: "Lisbon", iana_timezone: "Europe/Lisbon" }] }))
        .to eq(["Lisbon"])
    end

    it "reads a string key the same way, since the control plane stores JSON" do
      expect(labels({ "timestamp_timezones" => [] })).to eq([])
    end

    it "leads with Pacific, the home zone the day label is judged against" do
      zones = described_class.zones_for_config({})
      expect(zones.first.iana_timezone).to eq("America/Los_Angeles")
    end

    it "names four real zones tzinfo recognises, so none is dropped on parse" do
      expect(described_class.zones_for_config({}).length).to eq(described_class::DEFAULT_ZONES.length)
    end
  end
end
