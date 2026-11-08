# frozen_string_literal: true

require "spec_helper"

# A message originating on Stoat was the only kind that failed to puppet
# elsewhere, falling back to posting as the bot. The cause is avatar_url,
# built from a Stoat file's unescaped, uploader-chosen filename: an unsafe
# character makes it malformed, and the target's webhook API refuses it.
RSpec.describe "a Stoat-originated message reaching a Discord webhook" do
  let(:stoat_general) do
    endpoint("stoat-general", adapter: :stoat, settings: { channel_id: "CHAN01" })
  end
  let(:discord_general) do
    endpoint("dc-general", adapter: :discord,
                           settings: { channel_id: "8000000000000000003", webhook: :auto })
  end

  let(:resolver) do
    lambda do |id|
      next nil unless id == "u-spacey"

      { "_id" => id, "username" => "owner_handle", "display_name" => "River",
        "avatar" => { "_id" => "av2", "filename" => "my photo.png" } }
    end
  end

  let(:inbound) do
    Rubotty::Adapters::Stoat::Inbound.new(
      endpoint_for: ->(channel_id) { channel_id == "CHAN01" ? stoat_general : nil },
      user_resolver: resolver,
      file_url: Rubotty::Adapters::Stoat::Client.new(token: "t").method(:file_url)
    )
  end

  # What the bridge attaches to every relayed copy just before delivery (see
  # Bridge#prepare); reproduced by hand here so the adapter is exercised on
  # its own, the same isolation spec/adapters/discord/webhook_spec.rb uses.
  def prepared(message)
    label = Rubotty::Core::SenderLabel.for(author: message.author, platform: "stoat")
    message.with(sender_label: label)
  end

  let(:dc_client) { DiscordFakes::Client.new(own_id: "bot-dc") }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  subject(:adapter) do
    Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [discord_general]
    ).replace_client(dc_client)
  end

  # A minimal double for discordrb's webhook client that enforces the one rule every real
  # HTTP-facing service holds a payload to: an avatar_url has to be a well formed URL, which
  # Discord's own webhook API documents refusing when malformed.
  class URLValidatingHook
    attr_reader :executed

    def initialize
      @executed = []
    end

    def execute(builder, _wait = false)
      URI.parse(builder.avatar_url) if builder.avatar_url
      @executed << { content: builder.content, username: builder.username, avatar_url: builder.avatar_url }
      Struct.new(:body).new(%({"id":"wh-1"}))
    rescue URI::InvalidURIError => e
      raise "Discord refused the webhook send: avatar_url is not a well formed URL (#{e.message})"
    end
  end

  let(:hook) { URLValidatingHook.new }
  let(:channel) { dc_client.channel("8000000000000000003") }

  before do
    adapter.start
    allow(adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
  end

  it "puppets under the sender's own name instead of falling back to the bot" do
    event = { "type" => "Message", "_id" => "m1", "channel" => "CHAN01", "author" => "u-spacey",
              "content" => "hello from stoat" }
    message = prepared(inbound.message(event))

    adapter.deliver(message, discord_general)

    expect(hook.executed).not_to be_empty
    expect(hook.executed.first[:username]).to eq("River [owner_handle@stoat]")
    expect(channel.sent).to be_empty
  end
end
