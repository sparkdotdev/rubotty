# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Issue #1836, the sibling of #1800 one adapter over. The selection ran across
# every endpoint on the account, so a guild member add or remove fanned a join
# or leave into every bridged channel of that guild across every tenant that
# mapped one in it.
RSpec.describe Rubotty::Adapters::Fluxer::Adapter, "guild member fan-out across tenants" do
  let(:client) { FluxerFakes::Client.new }
  let(:gateway) { FluxerFakes::Gateway.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:logs) { StringIO.new }
  let(:logger) { Rubotty::Log.build(level: "error", io: logs) }
  let(:alpha) { CollidingCommunities::ALPHA }
  let(:beta) { CollidingCommunities::BETA }

  # The fixture's endpoints, given the guild each community bridges. A Fluxer
  # endpoint names its guild directly, which is what ban and kick need.
  def fluxer_endpoints_of(spec, guild_id)
    colliding_endpoints(spec[:slug], spec[:id], adapters: [:discord]).map do |ep|
      Rubotty::Core::Endpoint.owned_by(
        ep.community_id, id: "#{spec[:slug]}-fluxer", adapter_name: :fluxer, account: "shared",
        settings: { channel_id: "#{spec[:slug]}-chan", guild_id: guild_id, webhook: :off }
      )
    end
  end

  def member_adapter(endpoints)
    described_class.new(
      account: "shared", settings: { token: "t", token_env: "FLUXER_BOT_TOKEN" },
      dispatcher: dispatcher, logger: logger, endpoints: endpoints
    ).replace_client(client).replace_gateway(gateway)
  end

  def join_in(guild_id)
    FluxerFakes.dispatch("GUILD_MEMBER_ADD", FluxerFakes.member_data(guild_id: guild_id))
  end

  it "delivers a join to the one community that bridges the guild" do
    adapter = member_adapter(fluxer_endpoints_of(alpha, "GLD-A") + fluxer_endpoints_of(beta, "GLD-B"))
    adapter.handle_event(join_in("GLD-B"))

    expect(dispatcher.messages.map { |m| m.origin.id }).to eq(["beta-fluxer"])
  end

  it "refuses rather than delivering into both tenants that bridge one guild" do
    adapter = member_adapter(fluxer_endpoints_of(alpha, "GLD-SHARED") + fluxer_endpoints_of(beta, "GLD-SHARED"))
    adapter.handle_event(join_in("GLD-SHARED"))

    expect(dispatcher.messages).to be_empty
  end

  it "names both communities it could not choose between, at error level" do
    adapter = member_adapter(fluxer_endpoints_of(alpha, "GLD-SHARED") + fluxer_endpoints_of(beta, "GLD-SHARED"))
    adapter.handle_event(join_in("GLD-SHARED"))

    expect(logs.string).to include("REFUSED", alpha[:id].to_s, beta[:id].to_s)
  end

  it "still does nothing for a guild no endpoint bridges" do
    adapter = member_adapter(fluxer_endpoints_of(beta, "GLD-B"))
    adapter.handle_event(join_in("GLD-NOBODY"))

    expect(dispatcher.messages).to be_empty
  end
end
