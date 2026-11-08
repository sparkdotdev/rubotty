# frozen_string_literal: true

require "spec_helper"

# Discord's gateway, refusing to connect, as discordrb does on a rejected token.
class CycleWiringDiscordClient
  def connect = raise(RuntimeError.new("401 Unauthorized"))
  def connected? = false
  def stop = nil
  def bot = nil
end

RSpec.describe Rubotty::Core::Runtime, "the nightly gateway cycle" do
  let(:tg_http) { Fakes::TelegramHttp.new }

  before do
    tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    tg_http.on("deleteWebhook", true)
    tg_http.default_result([])
  end

  def runtime_for(yaml)
    config = Rubotty::Config::Loader.load_string(
      yaml, env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" }
    )
    described_class.new(config: config, logger: Rubotty::Log.null, env: { "PORT" => "0" })
  end

  def started(runtime)
    runtime.build
    runtime.adapters[[:telegram, "tg"]].replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
    )
    discord = runtime.adapters[[:discord, "dc"]]
    discord&.replace_client(CycleWiringDiscordClient.new)
    runtime.start
    runtime
  end

  let(:polling_only_yaml) do
    <<~YAML
      name: cycle-polling
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
          poll_timeout: 0
      storage:
        driver: memory
      behaviour:
        log_level: fatal
        purge_interval: 0
      rooms:
        - id: lounge
          endpoints:
            - id: tg-a
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
            - id: tg-b
              adapter: telegram
              account: tg
              chat_id: "-1001061926370"
    YAML
  end

  let(:gateway_yaml) do
    <<~YAML
      name: cycle-gateway
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
          poll_timeout: 0
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

  context "on a bridge with a gateway" do
    let(:runtime) { started(runtime_for(gateway_yaml)) }

    after { runtime.stop }

    it "runs the cycle, aimed at midnight UTC" do
      expect(runtime.gateway_cycle).to be_a(Rubotty::Core::GatewayCycle)
      expect(runtime.gateway_cycle.at).to eq("00:00")
      expect(runtime.gateway_cycle.running?).to be(true)
    end

    it "targets the gateway adapter and leaves the poller alone" do
      expect(runtime.gateway_cycle.targets).to eq([runtime.adapters[[:discord, "dc"]]])
    end

    it "stops the cycle with the runtime" do
      cycle = runtime.gateway_cycle
      runtime.stop

      expect(cycle.running?).to be(false)
    end
  end

  context "on a bridge that only polls" do
    let(:runtime) { started(runtime_for(polling_only_yaml)) }

    after { runtime.stop }

    it "starts no cycle thread, having nothing to cycle" do
      expect(runtime.gateway_cycle.targets).to be_empty
      expect(runtime.gateway_cycle.running?).to be(false)
    end
  end

  context "when the operator turns it off" do
    let(:runtime) do
      started(runtime_for(gateway_yaml.sub("purge_interval: 0", "purge_interval: 0\n  gateway_cycle: false")))
    end

    after { runtime.stop }

    it "builds nothing at all" do
      expect(runtime.gateway_cycle).to be_nil
    end

    it "is still healthy, having opted out rather than failed" do
      expect(runtime.gateway_cycle_healthy?).to be(true)
    end
  end

  context "the health endpoint" do
    let(:runtime) { started(runtime_for(gateway_yaml)) }

    after { runtime.stop }

    it "does not 503 through the window where the cycle has a gateway down" do
      # The Discord client here never connects, so the bridge is unhealthy for
      # real; mid-cycle that same shape must read as healthy instead.
      expect(runtime.healthy?).to be(false)

      allow(runtime.gateway_cycle).to receive(:cycling?).and_return(true)

      expect(runtime.healthy?).to be(true)
    end

    it "reports unhealthy once the cycle thread is gone" do
      thread = runtime.gateway_cycle.instance_variable_get(:@thread)
      thread.kill
      thread.join

      expect(runtime.gateway_cycle_healthy?).to be(false)
      expect(runtime.healthy?).to be(false)
    end
  end

  context "the configured time" do
    it "takes an hour other than midnight" do
      runtime = started(runtime_for(gateway_yaml.sub("purge_interval: 0", "purge_interval: 0\n  gateway_cycle_at: \"04:15\"")))

      expect(runtime.gateway_cycle.at).to eq("04:15")
      runtime.stop
    end

    it "refuses a time that is not HH:MM" do
      expect do
        Rubotty::Config::Loader.load_string(
          gateway_yaml.sub("purge_interval: 0", "purge_interval: 0\n  gateway_cycle_at: midnight"),
          env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" }
        )
      end.to raise_error(Rubotty::ConfigError, /HH:MM in UTC/)
    end
  end
end
