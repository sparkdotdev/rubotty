# frozen_string_literal: true

require "spec_helper"

# Issue #1856, the sibling of #1800 and #1836 in a third adapter. The
# selection ran across every bridged channel of the server regardless of
# which community mapped it, so a server member join or leave fanned out into
# every tenant that bridged a channel of it.
RSpec.describe Rubotty::Adapters::Stoat::Adapter, "server member fan-out across tenants" do
  let(:client) { StoatFakes::Client.new }
  let(:gateway) { StoatFakes::Gateway.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }
  let(:alpha) { CollidingCommunities::ALPHA }
  let(:beta) { CollidingCommunities::BETA }

  def stoat_endpoints_of(spec)
    colliding_endpoints(spec[:slug], spec[:id], adapters: [:stoat])
  end

  def member_adapter(endpoints)
    described_class.new(
      account: "shared", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
      dispatcher: dispatcher, logger: logger, endpoints: endpoints
    ).replace_client(client).replace_gateway(gateway)
  end

  # Each community's channel discovered on the given server, the way
  # ChannelCreate teaches the adapter which server a channel lives on.
  def place(spec, server_id)
    channel_id = "#{spec[:slug]}-stoat-chan"
    adapter_under_test.handle_event(
      StoatFakes.channel_create_event(StoatFakes.channel(id: channel_id, server: server_id, name: "general"))
    )
  end

  def join_in(server_id)
    StoatFakes.member_event(type: "ServerMemberJoin", server: server_id, user: "u-ada")
  end

  context "with each community on its own server" do
    let(:adapter_under_test) { member_adapter(stoat_endpoints_of(alpha) + stoat_endpoints_of(beta)) }

    it "delivers a join to the one community that bridges the server" do
      place(alpha, "SRV-A")
      place(beta, "SRV-B")
      messages = adapter_under_test.handle_event(join_in("SRV-B"))

      expect(messages.map { |m| m.origin.id }).to eq(["beta-stoat"])
    end

    it "still does nothing for a server no endpoint bridges" do
      place(beta, "SRV-B")
      messages = adapter_under_test.handle_event(join_in("SRV-NOBODY"))

      expect(messages).to eq([])
    end
  end

  context "with both communities bridging channels of one server" do
    let(:adapter_under_test) { member_adapter(stoat_endpoints_of(alpha) + stoat_endpoints_of(beta)) }

    before do
      place(alpha, "SRV-SHARED")
      place(beta, "SRV-SHARED")
    end

    it "refuses the fan-out rather than announcing one tenant's arrivals in the other's channels" do
      messages = adapter_under_test.handle_event(join_in("SRV-SHARED"))

      expect(messages).to eq([])
      expect(dispatcher.messages).to be_empty
    end

    it "names both communities it could not choose between, at error level" do
      adapter_under_test.handle_event(join_in("SRV-SHARED"))

      expect(logs.string).to include("REFUSED", alpha[:id].to_s, beta[:id].to_s)
    end
  end
end
