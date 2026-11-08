# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Fluxer::Webhook do
  let(:client) { FluxerFakes::Client.new }

  subject(:webhooks) do
    described_class.new(client: client, logger: Rubotty::Log.null, bridge_name: "rubotty")
  end

  # Fluxer follows Discord's username rules, so the same shortening applies.
  describe "#sanitise_username" do
    it "passes an ordinary name through" do
      expect(webhooks.sanitise_username("Alex (alex)")).to eq("Alex (alex)")
    end

    it "truncates to Fluxer's 80 character limit" do
      expect(webhooks.sanitise_username("x" * 200).length).to eq(80)
    end

    # Eats into the display name rather than cutting off the bracketed handle mid platform tag.
    it "shortens an over long structured label by eating the display name, not the bracketed handle" do
      long = "#{"A" * 100} [owner_handle@discord]"
      result = webhooks.sanitise_username(long)
      expect(result).to end_with(" [owner_handle@discord]")
      expect(result.length).to eq(80)
    end

    it "substitutes a fallback for an empty name" do
      expect(webhooks.sanitise_username("", fallback: "bridge")).to eq("bridge")
      expect(webhooks.sanitise_username("   ", fallback: "bridge")).to eq("bridge")
    end
  end

  def endpoint_with(**settings)
    endpoint("fx", adapter: :fluxer, settings: { channel_id: "123456789" }.merge(settings))
  end

  describe "#puppet_snapshot" do
    it "starts empty, before anything has been asked to resolve" do
      expect(webhooks.puppet_snapshot).to eq({})
    end

    it "reports :active once a webhook resolves" do
      endpoint = endpoint_with(webhook: :auto)
      webhooks.for(endpoint)
      expect(webhooks.puppet_snapshot).to eq(endpoint.id => :active)
    end

    it "reports :off for an endpoint turned off, without attempting anything" do
      endpoint = endpoint_with(webhook: :off)
      webhooks.for(endpoint)
      expect(webhooks.puppet_snapshot).to eq(endpoint.id => :off)
      expect(client.created_webhooks).to be_empty
    end

    it "reports :degraded when the create call comes back unusable" do
      allow(client).to receive(:create_webhook).and_return(nil)
      endpoint = endpoint_with(webhook: :auto)
      webhooks.for(endpoint)
      expect(webhooks.puppet_snapshot).to eq(endpoint.id => :degraded)
    end

    it "drops the entry on #forget, so a stale answer is not reported until re resolved" do
      endpoint = endpoint_with(webhook: :auto)
      webhooks.for(endpoint)
      webhooks.forget(endpoint)
      expect(webhooks.puppet_snapshot).to eq({})
    end
  end
end
