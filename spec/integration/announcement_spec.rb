# frozen_string_literal: true

require "spec_helper"

# The banner goes to every endpoint of one nominated room, posted directly as the
# bot, and never through the Discord webhook path.
RSpec.describe "startup announcement" do
  let(:yaml) do
    <<~YAML
      name: integration bridge
      accounts:
        tg: { adapter: telegram, token_env: TG_TOKEN }
        dc: { adapter: discord, token_env: DC_TOKEN }
      storage:
        driver: memory
      behaviour:
        log_level: fatal
      announce:
        room: lounge
        detail: minimal
        # This whole file is the no control plane path, which stays quiet unless
        # a deployment says otherwise.
        without_control_plane: true
      rooms:
        - id: lounge
          endpoints:
            - { id: tg-lounge, adapter: telegram, account: tg, chat_id: "-100111" }
            - { id: dc-lounge, adapter: discord, account: dc, channel_id: "8000000000000000003" }
        - id: other
          endpoints:
            - { id: tg-other, adapter: telegram, account: tg, chat_id: "-100222" }
            - { id: dc-other, adapter: discord, account: dc, channel_id: "9876543210987654" }
    YAML
  end

  let(:tg_http) { Fakes::TelegramHttp.new }
  let(:dc_client) { DiscordFakes::Client.new(own_id: "bot-dc") }
  let(:hook) { DiscordFakes::WebhookClient.new }

  def config_from(source)
    Rubotty::Config::Loader.load_string(
      source, env: { "TG_TOKEN" => "123:abc", "DC_TOKEN" => "dc" }
    )
  end

  def build_runtime(source = yaml)
    Rubotty::Core::Runtime.new(config: config_from(source), logger: Rubotty::Log.null).tap do |runtime|
      tg_http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
      tg_http.default_result([])
      runtime.build
      runtime.adapters[[:telegram, "tg"]].replace_client(
        Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: tg_http)
      )
      discord = runtime.adapters[[:discord, "dc"]]
      discord.replace_client(dc_client)
      allow(discord.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
    end
  end

  let(:runtime) { build_runtime }
  let(:lounge_channel) { dc_client.channel("8000000000000000003") }

  after { runtime.stop }

  def announce!
    runtime.send(:announce_startup)
  end

  it "posts to every endpoint of the nominated room" do
    tg_http.on("sendMessage", { "message_id" => 1 })
    announce!
    expect(tg_http.calls("sendMessage").size).to eq(1)
    expect(lounge_channel.sent.size).to eq(1)
  end

  it "posts to the nominated room only, not to every room" do
    tg_http.on("sendMessage", { "message_id" => 1 })
    announce!
    expect(tg_http.last("sendMessage").params["chat_id"]).to eq("-100111")
    expect(dc_client.channel("9876543210987654").sent).to be_empty
  end

  # A webhook message is not authored by the bot account, so loop prevention layer
  # 2 would not recognise it, and the banner never passes through the router.
  it "posts as the bot, never through the Discord webhook" do
    announce!
    expect(hook.executed).to be_empty
    expect(lounge_channel.sent.size).to eq(1)
  end

  it "records the banner in the delivery ledger as a second defence" do
    tg_http.on("sendMessage", { "message_id" => 55 })
    announce!
    ledger_hit = runtime.loop_guard.recently_delivered?(
      Rubotty::Core::MessageRef.new("tg-lounge", "55")
    )
    expect(ledger_hit).to be(true)
  end

  it "contains the identity lines" do
    tg_http.on("sendMessage", { "message_id" => 1 })
    announce!
    text = tg_http.last("sendMessage").params["text"]
    expect(text).to include("Started rubotty at")
    expect(text).to include("rubotty version:")
  end

  it "omits host detail at the default level" do
    announce!
    expect(lounge_channel.sent.first[:content]).not_to include("host:")
  end

  it "includes host detail when full is asked for" do
    full = build_runtime(yaml.sub("detail: minimal", "detail: full"))
    full.send(:announce_startup)
    expect(dc_client.channel("8000000000000000003").sent.first[:content]).to include("host:")
    full.stop
  end

  it "posts nothing when no room is nominated" do
    quiet = build_runtime(yaml.sub(/^announce:\n(?:  .*\n)+/, ""))
    quiet.send(:announce_startup)
    expect(lounge_channel.sent).to be_empty
    quiet.stop
  end

  # A crash looping bridge must not spam the channel.
  it "suppresses a second announcement inside the window" do
    announce!
    before = lounge_channel.sent.size
    announce!
    expect(lounge_channel.sent.size).to eq(before)
  end

  # A cosmetic banner must never be the reason a bridge fails to start.
  it "survives an adapter that refuses the post" do
    tg_http.error_on("sendMessage", code: 403, description: "Forbidden: bot was kicked")
    expect { announce! }.not_to raise_error
    # The other endpoint still gets it.
    expect(lounge_channel.sent.size).to eq(1)
  end

  it "rejects a configuration naming a room that does not exist" do
    expect { config_from(yaml.sub("room: lounge", "room: nonexistent")) }
      .to raise_error(Rubotty::ConfigError, /no room named "nonexistent"/)
  end
end
