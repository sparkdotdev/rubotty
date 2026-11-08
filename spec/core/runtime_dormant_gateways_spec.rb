# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A declared account whose secret has not arrived yet boots as a cleanly
# disabled, dormant gateway rather than crash looping the process.
RSpec.describe Rubotty::Core::Runtime, "dormant gateways (issue #154)" do
  let(:tg_http) { Fakes::TelegramHttp.new }

  before do
    tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    tg_http.on("deleteWebhook", true)
    tg_http.default_result([])
  end

  context "one gateway's key is present, its sibling's is not" do
    let(:yaml) do
      <<~YAML
        name: staged rollout
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
          dc:
            adapter: discord
            token_env: DC_TOKEN
        storage:
          driver: memory
        behaviour:
          log_level: fatal
          purge_interval: 0
        rooms:
          - id: lounge
            endpoints:
              - id: tg-lounge
                adapter: telegram
                account: tg
                chat_id: "-1008000000001"
              - id: dc-lounge
                adapter: discord
                account: dc
                channel_id: "8000000000000000003"
      YAML
    end

    # DC_TOKEN is deliberately absent: discord is the keyless gateway, telegram
    # the sibling that must still come all the way up.
    let(:config) { Rubotty::Config::Loader.load_string(yaml, env: { "TG_TOKEN" => "123:abc" }) }
    let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null) }

    after { runtime.stop }

    it "loads without raising, with the missing-key account marked dormant" do
      expect(config.accounts["dc"].dormant?).to be(true)
      expect(config.accounts["dc"].dormant_reason).to eq("waiting for key (DC_TOKEN not set)")
    end

    it "builds no adapter instance for the dormant account" do
      runtime.build
      expect(runtime.adapters[[:discord, "dc"]]).to be_nil
    end

    it "still builds and starts the sibling gateway whose key IS present" do
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      expect { runtime.start }.not_to raise_error
      expect(runtime.adapters[[:telegram, "tg"]].running?).to be(true)
    end

    it "logs the dormancy at info level instead of raising" do
      io = StringIO.new
      logger = Rubotty::Log.build(level: "info", io: io)
      runtime = described_class.new(config: config, logger: logger)

      runtime.build

      expect(io.string).to include("gateway dc: waiting for key (DC_TOKEN not set), staying dormant")
    ensure
      runtime&.stop
    end
  end

  context "every declared gateway is waiting for its key" do
    let(:yaml) do
      <<~YAML
        name: nothing keyed yet
        accounts:
          tg:
            adapter: telegram
            token_env: TG_TOKEN
          dc:
            adapter: discord
            token_env: DC_TOKEN
        storage:
          driver: memory
        behaviour:
          log_level: fatal
          purge_interval: 0
        rooms:
          - id: lounge
            endpoints:
              - id: tg-lounge
                adapter: telegram
                account: tg
                chat_id: "-1008000000001"
              - id: dc-lounge
                adapter: discord
                account: dc
                channel_id: "8000000000000000003"
      YAML
    end

    # No token anywhere: both accounts declared, neither key has arrived yet.
    let(:config) { Rubotty::Config::Loader.load_string(yaml, env: {}) }
    let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null) }

    after { runtime.stop }

    it "still does not raise ConfigError while loading" do
      expect(config.accounts.values.all?(&:dormant?)).to be(true)
    end

    # The zero-started-adapters guard must not fire here: nothing failed to
    # connect because nothing was asked to.
    it "does not refuse to run just because nothing has a key yet" do
      expect { runtime.start }.not_to raise_error
    end

    it "builds no adapters at all, and reports unhealthy rather than crashing" do
      runtime.start
      expect(runtime.adapters).to be_empty
      expect(runtime.healthy?).to be(false)
    end
  end
end
