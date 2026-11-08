# frozen_string_literal: true

require "spec_helper"

# Issue #905: Inbound#parse_markdown called Discord::Markdown.parse with
# no resolver, so every mention inside a Stoat message body fell through
# to the shared parser's generic fallback_mention regardless of whether
# the member was cached. This is the only coverage of the real capture path.
RSpec.describe "Stoat mention capture prefers the server member over the bot wide user" do
  let(:client) do
    StoatFakes::Client.new(
      users: {
        "MTNULID01" => { "username" => "alex", "display_name" => "Global Alex" }
      },
      members: {
        "SRV1/MTNULID01" => { "nickname" => "Server Alex" }
      }
    )
  end
  let(:gateway) { StoatFakes::Gateway.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:st) { endpoint("st-general", adapter: :stoat, settings: { channel_id: "CHAN01", server_id: "SRV1" }) }

  subject(:adapter) do
    Rubotty::Adapters::Stoat::Adapter.new(
      account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [st]
    ).replace_client(client).replace_gateway(gateway)
  end

  def incoming(content)
    StoatFakes.message_event(channel: "CHAN01", content: content)
  end

  before { adapter.start }

  it "reads the server member's nickname when the channel's server has it cached" do
    message = adapter.handle_event(incoming("hi <@MTNULID01>"))

    expect(message.body.text).to eq("hi @Server Alex")
  end

  it "falls back to the bot wide user's name with no member cached for this server" do
    client.instance_variable_get(:@members).clear

    message = adapter.handle_event(incoming("hi <@MTNULID01>"))

    expect(message.body.text).to eq("hi @Global Alex")
  end

  it "falls back to the bot wide user's name when the channel belongs to no known server" do
    unmapped = endpoint("st-unmapped", adapter: :stoat, settings: { channel_id: "CHAN01" })
    unscoped = Rubotty::Adapters::Stoat::Adapter.new(
      account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [unmapped]
    ).replace_client(client).replace_gateway(StoatFakes::Gateway.new)
    unscoped.start

    message = unscoped.handle_event(incoming("hi <@MTNULID01>"))

    expect(message.body.text).to eq("hi @Global Alex")
  end

  describe "a mention nobody, member or user, has ever been seen for" do
    let(:logger) { instance_double(Logger, info: nil, warn: nil, error: nil, debug: nil) }
    let(:warnings) { [] }

    subject(:adapter) do
      Rubotty::Adapters::Stoat::Adapter.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: logger, endpoints: [st]
      ).replace_client(client).replace_gateway(gateway)
    end

    before do
      allow(logger).to receive(:warn) { |&block| warnings << block.call }
      adapter.start
    end

    it "degrades to the raw id rather than the generic @unknown-user marker" do
      message = adapter.handle_event(incoming("hi <@NOBODYKNOWSME01>"))

      expect(message.body.text).to eq("hi @NOBODYKNOWSME01")
      expect(message.body.text).not_to include("unknown-user")
    end

    it "logs the failure so it is diagnosable" do
      adapter.handle_event(incoming("hi <@NOBODYKNOWSME01>"))

      expect(warnings).to include(a_string_matching(/could not resolve a mention of NOBODYKNOWSME01/))
    end
  end
end
