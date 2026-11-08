# frozen_string_literal: true

require "spec_helper"

# Issue #904: a native Fluxer mention's text was captured through
# Client#fetch_user, a bot-wide user with only a global name, never a
# per-guild member (nickname-aware, what Fluxer's own client actually
# shows). Fluxer's REST client had no member-fetching method at all until this.
RSpec.describe "Fluxer mention capture prefers the guild member over the bot-wide user" do
  let(:client) do
    FluxerFakes::Client.new(
      users: { "55" => { "id" => "55", "username" => "alex", "global_name" => "Global Alex" } }
    )
  end
  let(:gateway) { FluxerFakes::Gateway.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:fx) { endpoint("fx-general", adapter: :fluxer, settings: { channel_id: "111111111", webhook: :off }) }

  subject(:adapter) do
    Rubotty::Adapters::Fluxer::Adapter.new(
      account: "fx", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [fx]
    ).replace_client(client).replace_gateway(gateway)
  end

  def incoming(content, guild_id: "guild-1")
    FluxerFakes.dispatch(
      "MESSAGE_CREATE",
      FluxerFakes.message_data(channel: "111111111", content: content, guild_id: guild_id)
    )
  end

  it "reads the guild member's nickname when the guild has the member cached" do
    client.members["guild-1/55"] = { "nick" => "Server Alex", "user" => { "username" => "alex" } }

    message = adapter.handle_event(incoming("hi <@55>"))

    expect(message.body.text).to eq("hi @Server Alex")
  end

  it "falls back to the bot-wide user's name with no cached member (nobody home)" do
    message = adapter.handle_event(incoming("hi <@55>"))

    expect(message.body.text).to eq("hi @alex")
  end

  it "falls back to the bot-wide user's name when the message carries no guild_id at all (a DM)" do
    message = adapter.handle_event(incoming("hi <@55>", guild_id: nil))

    expect(message.body.text).to eq("hi @alex")
  end

  it "prefers the member's own username over the bot-wide global name when there is no nickname set" do
    client.members["guild-1/55"] = { "nick" => nil, "user" => { "username" => "member-alex" } }

    message = adapter.handle_event(incoming("hi <@55>"))

    expect(message.body.text).to eq("hi @member-alex")
  end
end
