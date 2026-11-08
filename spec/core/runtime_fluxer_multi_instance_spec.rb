# frozen_string_literal: true

require "spec_helper"

# Fluxer is self-hostable, so one community runs the flagship instance and any
# number of self-hosted ones as N accounts of the one adapter, each its own live
# connection, with no Fluxer-specific code path in the build.
RSpec.describe Rubotty::Core::Runtime, "Fluxer multi-instance gateway (issue #155)" do
  let(:yaml) do
    <<~YAML
      name: fluxer multi-instance
      accounts:
        flagship:
          adapter: fluxer
          token_env: FLUXER_FLAGSHIP_TOKEN
        selfhosted:
          adapter: fluxer
          token_env: FLUXER_SELFHOSTED_TOKEN
          api_base: https://fluxer.example.org/api
      storage:
        driver: memory
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms:
        - id: lounge
          endpoints:
            - id: flagship-lounge
              adapter: fluxer
              account: flagship
              channel_id: "111111111111111111"
            - id: selfhosted-lounge
              adapter: fluxer
              account: selfhosted
              channel_id: "222222222222222222"
    YAML
  end

  let(:config) do
    Rubotty::Config::Loader.load_string(
      yaml, env: { "FLUXER_FLAGSHIP_TOKEN" => "flagship-token", "FLUXER_SELFHOSTED_TOKEN" => "selfhosted-token" }
    )
  end
  let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null) }

  after { runtime.stop }

  it "declares both instances as live (non-dormant) accounts of the same adapter" do
    expect(config.accounts["flagship"].dormant?).to be(false)
    expect(config.accounts["selfhosted"].dormant?).to be(false)
    expect(config.accounts.values.map(&:adapter_name).uniq).to eq([:fluxer])
  end

  it "builds two distinct adapter instances, one per configured Fluxer account" do
    runtime.build
    flagship = runtime.adapters[[:fluxer, "flagship"]]
    selfhosted = runtime.adapters[[:fluxer, "selfhosted"]]

    expect(flagship).to be_a(Rubotty::Adapters::Fluxer::Adapter)
    expect(selfhosted).to be_a(Rubotty::Adapters::Fluxer::Adapter)
    expect(flagship).not_to equal(selfhosted)
  end

  it "gives the flagship instance the adapter's built-in default API base" do
    runtime.build
    flagship = runtime.adapters[[:fluxer, "flagship"]]
    expect(flagship.client.api_base).to eq(Rubotty::Adapters::Fluxer::Client::DEFAULT_API_BASE)
  end

  it "gives the self-hosted instance its own configured API base" do
    runtime.build
    selfhosted = runtime.adapters[[:fluxer, "selfhosted"]]
    expect(selfhosted.client.api_base).to eq("https://fluxer.example.org/api")
  end

  it "resolves each instance's own token independently, never sharing one client" do
    runtime.build
    flagship = runtime.adapters[[:fluxer, "flagship"]]
    selfhosted = runtime.adapters[[:fluxer, "selfhosted"]]
    expect(flagship.client.token).to eq("flagship-token")
    expect(selfhosted.client.token).to eq("selfhosted-token")
  end

  it "gives each instance its own bridged channel, not a shared endpoint index" do
    runtime.build
    flagship = runtime.adapters[[:fluxer, "flagship"]]
    selfhosted = runtime.adapters[[:fluxer, "selfhosted"]]
    expect(flagship.describe_endpoint(config.endpoints.find { |e| e.id == "flagship-lounge" }))
      .to include("111111111111111111")
    expect(selfhosted.describe_endpoint(config.endpoints.find { |e| e.id == "selfhosted-lounge" }))
      .to include("222222222222222222")
  end
end
