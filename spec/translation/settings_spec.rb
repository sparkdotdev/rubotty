# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Translation::Settings do
  describe "reading from the environment by default" do
    let(:env) do
      { Rubotty::Translation::Settings::URL_VAR => "http://libretranslate.example",
        Rubotty::Translation::Settings::API_KEY_VAR => "secret-key" }
    end

    let(:settings) { described_class.new(env: env) }

    it "reads the URL and key by their env var names" do
      expect(settings.url).to eq("http://libretranslate.example")
      expect(settings.api_key).to eq("secret-key")
      expect(settings).to be_configured
    end

    it "is unconfigured with nothing set" do
      expect(described_class.new(env: {})).not_to be_configured
    end

    it "allows every pair with no allow list configured" do
      expect(settings.allowed?("en", "pt")).to be(true)
      expect(settings.allowed?("xx", "yy")).to be(true)
    end

    it "narrows to an allow list read from the environment" do
      narrowed = described_class.new(env: env.merge(
        Rubotty::Translation::Settings::ALLOWED_PAIRS_VAR => "en:pt, pt:en , en:es"
      ))

      expect(narrowed.allowed?("en", "pt")).to be(true)
      expect(narrowed.allowed?("pt", "en")).to be(true)
      expect(narrowed.allowed?("en", "de")).to be(false)
    end
  end

  describe "a stored setting, the seam the Integrations page drives" do
    let(:env) { { Rubotty::Translation::Settings::URL_VAR => "http://env.example" } }

    it "wins over the environment for the URL and key" do
      store = Struct.new(:url, :api_key, :allowed_pairs).new("http://store.example", "store-key", nil)
      settings = described_class.new(env: env, store: store)

      expect(settings.url).to eq("http://store.example")
      expect(settings.api_key).to eq("store-key")
    end

    it "falls back to the environment for whatever the store leaves blank" do
      store = Struct.new(:url, :api_key, :allowed_pairs).new("", nil, [])
      settings = described_class.new(env: env, store: store)

      expect(settings.url).to eq("http://env.example")
    end

    it "narrows to the store's own allow list when it has one" do
      store = Struct.new(:url, :api_key, :allowed_pairs).new(nil, nil, [%w[en pt]])
      settings = described_class.new(env: env, store: store)

      expect(settings.allowed?("en", "pt")).to be(true)
      expect(settings.allowed?("en", "es")).to be(false)
    end
  end

  describe ".parse_pairs" do
    it "parses comma separated source:target pairs, trimming whitespace" do
      expect(described_class.parse_pairs("en:pt, pt:en , en:es"))
        .to eq([%w[en pt], %w[pt en], %w[en es]])
    end

    it "is nil for blank input, meaning no restriction" do
      expect(described_class.parse_pairs(nil)).to be_nil
      expect(described_class.parse_pairs("")).to be_nil
      expect(described_class.parse_pairs("   ")).to be_nil
    end

    it "skips a malformed entry rather than raising" do
      expect(described_class.parse_pairs("en:pt,bogus,pt:en")).to eq([%w[en pt], %w[pt en]])
    end
  end
end
