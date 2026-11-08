# frozen_string_literal: true

require "spec_helper"

# YAML in, canonical message through the router, platform call out: the wiring
# mistakes unit tests structurally cannot see. Two Telegram endpoints in one
# room, so a message posted in one topic is relayed into the other, which
# exercises every layer without needing a second platform.
RSpec.describe "a message crossing the bridge" do
  let(:yaml) do
    <<~YAML
      name: integration
      accounts:
        tg:
          adapter: telegram
          token_env: TG_TOKEN
          transport: long_polling
      storage:
        driver: memory
      behaviour:
        message_ttl: 1 hour
        log_level: fatal
      display_name:
        format: "{first_name} ({username})"
        fallback_format: "{first_name}"
      rooms:
        - id: lounge
          endpoints:
            - id: topic-a
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
              thread_id: 111
            - id: topic-b
              adapter: telegram
              account: tg
              chat_id: "-1008000000001"
              thread_id: 222
    YAML
  end

  let(:http) { Fakes::TelegramHttp.new }
  let(:config) { Rubotty::Config::Loader.load_string(yaml, env: { "TG_TOKEN" => "123:abc" }) }
  let(:runtime) { Rubotty::Core::Runtime.new(config: config, logger: Rubotty::Log.null) }

  let(:adapter) do
    runtime.adapters[[:telegram, "tg"]]
  end

  before do
    http.on("getMe", { "id" => 424_242, "username" => "bridgebot" })
    http.on("deleteWebhook", true)
    http.default_result([])
    runtime.build
    adapter.replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    runtime.dispatcher.start
    runtime.loop_guard.register_identity(:telegram, "tg", adapter.identify)
  end

  after { runtime.stop }

  def deliver_update(payload)
    adapter.handle_update(payload)
    runtime.dispatcher.drain
  end

  def incoming(overrides = {})
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 700,
        "date" => 1_700_000_000,
        "chat" => { "id" => -1008000000001, "type" => "supergroup", "is_forum" => true },
        "message_thread_id" => 111,
        "from" => { "id" => 55, "first_name" => "Ada", "username" => "ada", "is_bot" => false },
        "text" => "hello everyone"
      }.merge(overrides)
    }
  end

  it "relays a message from one endpoint to the other" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming)

    sent = http.last("sendMessage")
    expect(sent).not_to be_nil
    expect(sent.params["message_thread_id"]).to eq(222)
    expect(sent.params["text"]).to include("hello everyone")
  end

  it "renders the sender using the configured template" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming)
    expect(http.last("sendMessage").params["text"]).to include("Ada (ada)")
  end

  it "uses the fallback template for a sender with no username" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming("from" => { "id" => 56, "first_name" => "Grace" }))
    text = http.last("sendMessage").params["text"]
    expect(text).to include("Grace")
    expect(text).not_to include("()")
  end

  it "preserves formatting across an emoji, end to end" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming(
                     "text" => "🎉 party time",
                     "entities" => [{ "type" => "bold", "offset" => 3, "length" => 5 }]
                   ))
    expect(http.last("sendMessage").params["text"]).to include("<b>party</b>")
  end

  it "records the mapping so an edit can follow the message" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming)

    deliver_update({ "update_id" => 2,
                     "edited_message" => incoming["message"].merge("text" => "hello again") })

    edited = http.last("editMessageText")
    expect(edited).not_to be_nil
    expect(edited.params["message_id"]).to eq(900)
    expect(edited.params["text"]).to include("hello again")
  end

  it "does not relay a message the bridge itself posted" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming("from" => { "id" => 424_242, "first_name" => "bridgebot", "is_bot" => true }))
    expect(http.called?("sendMessage")).to be(false)
  end

  it "does not relay the copy it just created back to where it came from" do
    http.on("sendMessage", { "message_id" => 900 })
    deliver_update(incoming)
    before = http.calls("sendMessage").size

    # Telegram echoes our own write back as a new update, which is exactly the
    # shape of an infinite loop if nothing catches it.
    deliver_update({
                     "update_id" => 3,
                     "message" => {
                       "message_id" => 900,
                       "date" => 1_700_000_001,
                       "chat" => { "id" => -1008000000001, "type" => "supergroup", "is_forum" => true },
                       "message_thread_id" => 222,
                       "from" => { "id" => 424_242, "first_name" => "bridgebot", "is_bot" => true },
                       "text" => "Ada (ada):\nhello everyone"
                     }
                   })

    expect(http.calls("sendMessage").size).to eq(before)
  end

  it "relays a photo by URL rather than downloading it" do
    http.on("getFile", { "file_path" => "photos/x.jpg" })
    http.on("sendPhoto", { "message_id" => 901 })
    deliver_update(incoming("text" => nil, "caption" => "look",
                            "photo" => [{ "file_id" => "small" }, { "file_id" => "big" }]))
    expect(http.last("sendPhoto").params["photo"]).to include("photos/x.jpg")
  end

  it "ignores an update for a chat that is not in the topology" do
    deliver_update(incoming("chat" => { "id" => -999 }))
    expect(http.called?("sendMessage")).to be(false)
  end
end
