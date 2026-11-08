# frozen_string_literal: true

require "spec_helper"

# Each adapter's start is isolated behind a rescue for AdapterError, and a plain
# StandardError out of a gateway connect is still caught because the adapter
# converts it rather than letting it crash loop the process.
RSpec.describe Rubotty::Core::Runtime, "start isolation" do
  let(:yaml) do
    <<~YAML
      name: isolation
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

  # Connect blows up as discordrb would on a rejected token, with a plain
  # StandardError rather than an AdapterError.
  class ExplodingDiscordClient
    def connect = raise(RuntimeError.new("401 Unauthorized"))
    def connected? = false
    def stop = nil
    def bot = nil
  end

  let(:tg_http) { Fakes::TelegramHttp.new }
  let(:config) do
    Rubotty::Config::Loader.load_string(
      yaml, env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc-token" }
    )
  end
  let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null) }
  let(:tg_adapter) { runtime.adapters[[:telegram, "tg"]] }
  let(:dc_adapter) { runtime.adapters[[:discord, "dc"]] }

  before do
    tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    tg_http.on("deleteWebhook", true)
    tg_http.default_result([])
    runtime.build
    tg_adapter.replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
    )
    dc_adapter.replace_client(ExplodingDiscordClient.new)
  end

  after { runtime.stop }

  it "does not abort runtime.start when the Discord adapter's start raises" do
    expect { runtime.start }.not_to raise_error
  end

  it "leaves the healthy adapter running while the failing one does not" do
    runtime.start
    expect(tg_adapter.running?).to be(true)
    expect(dc_adapter.running?).to be(false)
  end
end
