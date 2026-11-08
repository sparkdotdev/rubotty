# frozen_string_literal: true

require "spec_helper"

# A hub group writes several channel rows sharing one
# (adapter, account, route_key), which #build_route_index used to index
# with "last one loaded wins", silently disregarding receives entirely.
# #resolve has to answer with the receiving row regardless of load order.
RSpec.describe Rubotty::ControlPlane::Snapshot, "resolving a hub group's shared route_key" do
  def hub_community(channels)
    rooms = channels.map { |channel| Rubotty::Core::Room.new(id: channel.endpoint.id, endpoints: [channel.endpoint]) }
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: 1, slug: "hub", name: "hub", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new(rooms), channels: channels,
      operators: Rubotty::Core::Moderation::Directory.new([]),
      people: Rubotty::Core::Directory.new([])
    )
  end

  def channel(id, receives:)
    ep = endpoint(id, adapter: :irc, account: "irc-hub", settings: { channel: "#sample" }, receives: receives)
    Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: "#sample")
  end

  it "picks the receiving row when it loads first" do
    travel = channel("irc-hub-travel", receives: true)
    gaming = channel("irc-hub-gaming", receives: false)
    snapshot = described_class.new(communities: [hub_community([travel, gaming])])

    expect(snapshot.resolve(:irc, "irc-hub", "#sample").endpoint_key).to eq("irc-hub-travel")
  end

  it "picks the receiving row when it loads last, order does not decide this" do
    gaming = channel("irc-hub-gaming", receives: false)
    travel = channel("irc-hub-travel", receives: true)
    snapshot = described_class.new(communities: [hub_community([gaming, travel])])

    expect(snapshot.resolve(:irc, "irc-hub", "#sample").endpoint_key).to eq("irc-hub-travel")
  end

  it "falls back to the first-loaded row when nothing in the group receives (a read-only hub)" do
    gaming = channel("irc-hub-gaming", receives: false)
    travel = channel("irc-hub-travel", receives: false)
    snapshot = described_class.new(communities: [hub_community([gaming, travel])])

    expect(snapshot.resolve(:irc, "irc-hub", "#sample").endpoint_key).to eq("irc-hub-gaming")
  end

  it "keeps every hub member independently addressable by endpoint_key, for delivery" do
    travel = channel("irc-hub-travel", receives: true)
    gaming = channel("irc-hub-gaming", receives: false)
    snapshot = described_class.new(communities: [hub_community([travel, gaming])])

    expect(snapshot.channel_by_endpoint_key("irc-hub-travel").endpoint_key).to eq("irc-hub-travel")
    expect(snapshot.channel_by_endpoint_key("irc-hub-gaming").endpoint_key).to eq("irc-hub-gaming")
  end
end
