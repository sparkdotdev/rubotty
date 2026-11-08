# frozen_string_literal: true

require "spec_helper"

# Decoding a country flag emoji out of a name, and the deliberate multi-zone
# skip policy (see lib/rubotty/control_plane/country_flag_timezone.rb).
RSpec.describe Rubotty::ControlPlane::CountryFlagTimezone do
  describe ".extract_country_code" do
    it "decodes a single-zone country's flag" do
      expect(described_class.extract_country_code("Alex \u{1F1F5}\u{1F1F9} gamer")).to eq("PT")
    end

    it "decodes a flag with nothing else around it" do
      expect(described_class.extract_country_code("\u{1F1E9}\u{1F1EA}")).to eq("DE")
    end

    it "returns nil for a name with no flag at all" do
      expect(described_class.extract_country_code("just a name")).to be_nil
    end

    it "returns nil for a blank or nil name" do
      expect(described_class.extract_country_code("")).to be_nil
      expect(described_class.extract_country_code(nil)).to be_nil
    end

    it "decodes the FIRST flag when more than one is present" do
      expect(described_class.extract_country_code("\u{1F1F5}\u{1F1F9}\u{1F1E9}\u{1F1EA} two flags")).to eq("PT")
    end

    it "decodes a multi-zone country's flag too: extraction does not apply the zone policy" do
      expect(described_class.extract_country_code("\u{1F1FA}\u{1F1F8} usa")).to eq("US")
    end
  end

  describe ".timezone_for" do
    it "answers the single zone a mapped code stands in for" do
      expect(described_class.timezone_for("PT")).to eq("Europe/Lisbon")
    end

    it "is case-insensitive" do
      expect(described_class.timezone_for("pt")).to eq("Europe/Lisbon")
    end

    it "answers nil for a deliberately unmapped multi-zone country" do
      described_class::MULTI_ZONE.each do |code|
        expect(described_class.timezone_for(code)).to be_nil
      end
    end

    it "answers nil for a code this module carries no mapping for at all" do
      expect(described_class.timezone_for("ZZ")).to be_nil
    end

    it "answers nil for a blank or nil code" do
      expect(described_class.timezone_for("")).to be_nil
      expect(described_class.timezone_for(nil)).to be_nil
    end

    it "every mapped single-zone entry is a real IANA identifier TZInfo recognises" do
      described_class::SINGLE_ZONE.each_key do |code|
        expect(described_class.timezone_for(code)).not_to be_nil, "#{code} did not resolve"
      end
    end

    it "keeps the well known multi-zone countries out of the single-zone map" do
      %w[US RU CA AU BR].each do |code|
        expect(described_class::SINGLE_ZONE).not_to have_key(code)
        expect(described_class::MULTI_ZONE).to include(code)
      end
    end
  end

  describe ".infer" do
    it "combines extraction and the zone lookup" do
      expect(described_class.infer("Alex \u{1F1EA}\u{1F1F8} gamer")).to eq("Europe/Madrid")
    end

    it "returns nil when the flag decodes but has no single-zone answer" do
      expect(described_class.infer("Sam \u{1F1FA}\u{1F1F8} gamer")).to be_nil
    end

    it "returns nil when there is no flag" do
      expect(described_class.infer("Sam the gamer")).to be_nil
    end
  end
end
