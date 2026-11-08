# frozen_string_literal: true

require "spec_helper"

# The whole adapter contract, run against every adapter there is, so a
# property broken on one adapter cannot ship unnoticed on the rest. Rules
# live in lib/rubotty/adapters/base.rb; per adapter answers live in
# spec/support/adapter_contract.rb.
RSpec.describe "the platform adapter contract", :control_plane do
  # Not registered, on purpose: registering it would make `adapter: api` legal
  # in a configuration file and put "api" in the dashboard's platform picker,
  # and an API endpoint is synthesised per room instead. It is run through the
  # contract by class here, which is the whole reason the api adapter kept
  # answering a bare nil from #deliver while three registry walks looked
  # straight past it.
  UNREGISTERED = { api: Rubotty::Adapters::Api::Adapter }.freeze

  describe "who is covered" do
    it "has a profile for every registered adapter, so a new one cannot skip the contract" do
      expect(AdapterContract::PROFILES.keys - UNREGISTERED.keys)
        .to match_array(Rubotty::Adapters::Registry.names)
    end

    it "covers the adapters that ship without being registered" do
      UNREGISTERED.each do |name, klass|
        expect(Rubotty::Adapters::Registry.known?(name)).to be(false),
                                                            "#{name} is registered now, so it belongs in the " \
                                                            "registry walk rather than in UNREGISTERED"
        expect(AdapterContract::PROFILES).to include(name)
        expect(AdapterContract.profile(name).adapter_class).to eq(klass)
      end
    end

    it "registers each adapter under the name it answers to" do
      Rubotty::Adapters::Registry.all.each do |name, klass|
        expect(klass.adapter_name).to eq(name)
      end
    end

    it "has an addressing sample for every adapter that feeds channel discovery" do
      discovering = AdapterContract::PROFILES.select { |_, p| p.adapter_class.discovers_channels? }
      expect(discovering).not_to be_empty, "the round trip below would guard nothing"
      discovering.each do |name, profile|
        expect(profile.sample).to include(:route_key, :external_id), "#{name} has no sample to round trip"
      end
    end

    it "leaves persistent_connection? false for a platform that never says" do
      anonymous = Class.new(Rubotty::Adapters::Base)

      expect(anonymous.allocate.persistent_connection?).to be(false)
    end

    it "excuses an adapter only from a property that exists" do
      AdapterContract::PROFILES.each_value do |profile|
        expect(profile.unknown_exemptions).to be_empty,
                                              "#{profile.name} excuses itself from " \
                                              "#{profile.unknown_exemptions.join(", ")}, which no rule is " \
                                              "named after"
      end
    end
  end

  # The one thing an adapter is allowed to swallow after a refusal must never be
  # swallowed again, so its definition is load bearing and belongs in one place.
  describe "the shared already-gone definition" do
    it "answers each platform's own wording, and neither refusal" do
      AdapterContract::GONE_CASES.each do |message, expected|
        error = Rubotty::AdapterError.new(message, adapter: :contract)
        expect(Rubotty::Adapters::AlreadyGone.call(error)).to be(expected), message
      end
    end

    it "refuses a rate limit however it is worded, since a wait is never an absence" do
      limited = Rubotty::RateLimitedError.new("404 while backing off", adapter: :contract)
      expect(Rubotty::Adapters::AlreadyGone.call(limited)).to be(false)
    end

    it "is what the Telegram client tolerates a gone target by" do
      client = Rubotty::Adapters::Telegram::ApiClient.new(token: "t", http: Fakes::TelegramHttp.new)
      AdapterContract::GONE_CASES.each do |message, expected|
        error = Rubotty::AdapterError.new(message, adapter: :telegram)
        expect(client.gone?(error)).to be(expected), message
      end
    end
  end

  AdapterContract::PROFILES.each_key do |name|
    describe(name) do
      include_examples "the platform adapter contract", name
    end
  end
end
