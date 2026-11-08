# frozen_string_literal: true

require "spec_helper"

# An account declared with its token present but mapped into ZERO rooms still
# connects and runs, so its channel-discovery seam can enumerate real channels
# before an operator maps any of them.
RSpec.describe Rubotty::Core::Runtime, "a zero-endpoint account (issue #203)" do
  let(:tg_http) { Fakes::TelegramHttp.new }

  before do
    tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    tg_http.on("deleteWebhook", true)
    tg_http.default_result([])
  end

  let(:yaml) do
    <<~YAML
      name: stoat dormant
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
        st:
          adapter: stoat
          token_env: STOAT_BOT_TOKEN
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

  let(:config) do
    Rubotty::Config::Loader.load_string(yaml, env: { "TG_TOKEN" => "123:abc", "STOAT_BOT_TOKEN" => "st-token" })
  end
  let(:runtime) { described_class.new(config: config, logger: Rubotty::Log.null) }

  after { runtime.stop }

  it "loads a declared account no endpoint references, without raising" do
    expect(config.accounts["st"]).not_to be_nil
    expect(config.accounts["st"].dormant?).to be(false)
    expect(config.endpoints_for("st")).to eq([])
  end

  it "counts the zero-endpoint account as active: it is not filtered out before build_adapters" do
    expect(config.active_accounts.map(&:name)).to include("st")
  end

  it "builds an adapter instance for it" do
    runtime.build
    expect(runtime.adapters[[:stoat, "st"]]).not_to be_nil
  end

  it "connects and runs it, alongside its mapped sibling, relaying nothing" do
    runtime.build
    runtime.adapters[[:telegram, "tg"]].replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
    )
    runtime.adapters[[:stoat, "st"]]
           .replace_client(StoatFakes::Client.new)
           .replace_gateway(StoatFakes::Gateway.new)

    expect { runtime.start }.not_to raise_error
    expect(runtime.adapters[[:stoat, "st"]]).to be_running
    expect(runtime.adapters[[:telegram, "tg"]]).to be_running
  end
end
