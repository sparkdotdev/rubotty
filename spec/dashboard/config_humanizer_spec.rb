# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard/config_humanizer"

# The config humaniser: turns a feature's raw config hash into labelled, legible
# rows rather than the JSON blob it is stored as. Called directly, with no Sinatra.
RSpec.describe Rubotty::Dashboard::ConfigHumanizer do
  describe ".duration" do
    it "renders zero as 0s" do
      expect(described_class.duration(0)).to eq("0s")
    end

    it "renders a sub-minute count in bare seconds" do
      expect(described_class.duration(15)).to eq("15s")
      expect(described_class.duration(59)).to eq("59s")
    end

    it "renders a whole number of minutes without a seconds remainder" do
      expect(described_class.duration(120)).to eq("2m")
    end

    it "renders minutes plus a seconds remainder" do
      expect(described_class.duration(90)).to eq("1m 30s")
    end

    it "renders a whole number of hours" do
      expect(described_class.duration(7200)).to eq("2h")
    end

    it "renders a whole number of days in the long form, pluralised" do
      expect(described_class.duration(172_800)).to eq("2 days")
      expect(described_class.duration(86_400)).to eq("1 day")
    end

    it "renders a whole number of weeks in the long form, pluralised" do
      expect(described_class.duration(1_209_600)).to eq("2 weeks")
    end

    it "coerces a numeric string" do
      expect(described_class.duration("15")).to eq("15s")
    end
  end

  describe ".rows" do
    it "returns nothing for an empty or non-hash config" do
      expect(described_class.rows({})).to eq([])
      expect(described_class.rows(nil)).to eq([])
    end

    it "renders a duration-shaped numeric key as a humanised duration, not a raw second count" do
      rows = described_class.rows({ "cleanup_after" => 15 })
      expect(rows).to eq([{ label: "Cleanup after", text: "15s" }])
    end

    it "renders a plain numeric key (no duration hint) as a bare number" do
      rows = described_class.rows({ "max_upload_bytes" => 5_000_000 })
      expect(rows).to eq([{ label: "Max upload bytes", text: "5000000" }])
    end

    it "does not mistake a millisecond field for a duration in seconds" do
      rows = described_class.rows({ "interval_ms" => 500 })
      expect(rows).to eq([{ label: "Interval ms", text: "500" }])
    end

    it "renders a boolean as Yes/No" do
      rows = described_class.rows({ "acknowledge" => true, "count_mass" => false })
      expect(rows).to contain_exactly(
        { label: "Acknowledge", text: "Yes" },
        { label: "Count mass", text: "No" }
      )
    end

    it "renders a list of scalars as chips" do
      rows = described_class.rows({ "prefixes" => ["/", "!"] })
      expect(rows).to eq([{ label: "Prefixes", chips: ["/", "!"] }])
    end

    it "renders a list-valued duration field as humanised durations, not raw seconds" do
      rows = described_class.rows({ "default_reminder_intervals" => [604_800, 259_200, 172_800] })
      expect(rows).to eq([{ label: "Default reminder intervals", chips: ["1 week", "3 days", "2 days"] }])
    end

    it "does not mistake a millisecond list field for a duration list" do
      rows = described_class.rows({ "cooldowns_ms" => [500, 1000] })
      expect(rows).to eq([{ label: "Cooldowns ms", chips: %w[500 1000] }])
    end

    it "renders a list of mapping entries as chips of their own recognisable label" do
      rows = described_class.rows({ "entries" => [{ "keyword" => "faq1", "response" => "see the wiki" }] })
      expect(rows).to eq([{ label: "Entries", chips: ["faq1"] }])
    end

    it "renders an empty list as none" do
      rows = described_class.rows({ "actions" => [] })
      expect(rows).to eq([{ label: "Actions", text: "none" }])
    end

    it "renders an unknown or nested key as a Key: value row" do
      rows = described_class.rows({ "posture" => "block_invites" })
      expect(rows).to eq([{ label: "Posture", text: "block_invites" }])

      nested = described_class.rows({ "who" => { "kind" => "operators", "notify" => true } })
      expect(nested).to eq([{ label: "Who", text: "Kind: operators, Notify: yes" }])
    end

    it "renders an unset (nil) value as not set" do
      rows = described_class.rows({ "posture" => nil })
      expect(rows).to eq([{ label: "Posture", text: "not set" }])
    end

    it "never emits JSON punctuation for any row it produces" do
      config = {
        "cleanup_after" => 15, "acknowledge" => true, "prefixes" => ["/", "!"],
        "actions" => %w[delete pin unpin ban kick mute unmute]
      }
      described_class.rows(config).each do |row|
        (row[:chips] || [row[:text]]).each do |value|
          expect(value).not_to match(/[{}\[\]"]/)
        end
      end
    end
  end
end
