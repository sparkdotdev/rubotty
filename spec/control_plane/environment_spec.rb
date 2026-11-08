# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::Environment do
  describe ".production?" do
    it "is true for exactly PRODUCTION" do
      expect(described_class.production?({ "ENVIRONMENT" => "PRODUCTION" })).to be(true)
    end

    it "tolerates surrounding whitespace and any case" do
      expect(described_class.production?({ "ENVIRONMENT" => "  production  " })).to be(true)
      expect(described_class.production?({ "ENVIRONMENT" => "Production" })).to be(true)
    end

    it "is false when ENVIRONMENT is absent" do
      expect(described_class.production?({})).to be(false)
    end

    %w[DEVELOPMENT development CI ci staging PROD].each do |value|
      it "is false for #{value.inspect}, not just literal absence" do
        expect(described_class.production?({ "ENVIRONMENT" => value })).to be(false)
      end
    end

    it "defaults to reading the real ENV when no hash is given" do
      original = ENV.fetch("ENVIRONMENT", nil)
      begin
        ENV["ENVIRONMENT"] = "PRODUCTION"
        expect(described_class.production?).to be(true)
        ENV.delete("ENVIRONMENT")
        expect(described_class.production?).to be(false)
      ensure
        original.nil? ? ENV.delete("ENVIRONMENT") : ENV["ENVIRONMENT"] = original
      end
    end
  end
end
