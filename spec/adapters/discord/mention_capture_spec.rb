# frozen_string_literal: true

require "spec_helper"

# A native Discord mention's text was captured through `bot.user(id)`, a
# bot-wide User with only a global name, never `server.member(id)`, the
# guild-aware Member that carries the per-server nickname Discord's client
# shows. This is the only coverage of that path through real Inbound/Adapter.
RSpec.describe "Discord mention capture prefers the guild member over the bot-wide user" do
  let(:client) { DiscordFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:dc) { endpoint("dc-general", adapter: :discord, settings: { channel_id: "chan-1" }) }

  subject(:adapter) do
    Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [dc]
    ).replace_client(client)
  end

  after { adapter.stop }

  let(:author) { DiscordFakes.user(id: "1", username: "author") }

  def incoming(content)
    DiscordFakes::MessageEvent.new(
      message: DiscordFakes::Message.new(id: "700", content: content, author: author),
      channel: client.channel("chan-1")
    )
  end

  before do
    adapter.start
    # The bot-wide User: a real Discordrb::User carries only a global name,
    # never a per-server nickname.
    client.known_users["55"] = DiscordFakes.user(id: "55", username: "alex", global_name: "Global Alex")
  end

  it "reads the server nickname when the channel's guild has the member cached" do
    client.channel("chan-1").server = double("server", member: double("member", display_name: "Server Alex"))

    client.fire(:message, incoming("hi <@55>"))

    expect(dispatcher.messages.last.body.text).to eq("hi @Server Alex")
  end

  it "falls back to the bot-wide user's name with no cached member (a DM, or nobody home)" do
    client.channel("chan-1").server = double("server", member: nil)

    client.fire(:message, incoming("hi <@55>"))

    expect(dispatcher.messages.last.body.text).to eq("hi @Global Alex")
  end

  it "falls back to the bot-wide user's name when the channel has no server at all (a DM)" do
    client.fire(:message, incoming("hi <@55>"))

    expect(dispatcher.messages.last.body.text).to eq("hi @Global Alex")
  end
end
