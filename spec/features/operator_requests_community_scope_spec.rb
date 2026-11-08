# frozen_string_literal: true

require "spec_helper"

# Issue #1804. A room key from a community's own config was looked up in the
# merged boot topology whenever the request carried no community, and room keys
# are unique only inside a community, so "general" could resolve to another
# tenant's room and post the requester's name and community into it.
RSpec.describe Rubotty::Features::OperatorRequests, "resolving notify_room in one community only" do
  let(:snapshot) { colliding_snapshot }
  let(:topo) { snapshot.topology }
  let(:shared_key) { CollidingCommunities::SHARED_ROOM_KEY }

  # Real rows for the request the notification is about.
  let(:plane) { colliding_control_plane }
  let(:models) { plane[1] }
  let(:flow) { Rubotty::ControlPlane::OperatorFlow.new(models: models, logger: Rubotty::Log.null) }

  # One fake adapter serves every endpoint, so every post lands on one recorder.
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(adapters: adapters, session_id: "s", topology: topo,
                                        logger: Rubotty::Log.null)
  end

  subject(:feature) do
    described_class.new(topology: topo, adapters: adapters, logger: Rubotty::Log.null,
                        operator_flow: flow, ephemeral: ephemeral)
  end

  def channel_at(endpoint_key) = snapshot.channel_by_endpoint_key(endpoint_key)

  def newcomer = Rubotty::Core::Author.new(native_id: "999888", username: "newbie")

  # A newcomer asks in +slug+'s own telegram channel, with +slug+'s own config.
  def request_in(slug, notify_room: shared_key)
    channel = channel_at("#{slug}-telegram")
    msg = message(channel.endpoint, text: "/operator request", native_id: "m-#{slug}", author: newcomer)
    feature.call(Rubotty::Features::Context.new(
                   message: msg, community: snapshot.community(slug),
                   channel: channel, config: { notify_room: notify_room }
                 ))
  end

  # Just the operator notifications delivered to +endpoint_id+, so the
  # requester's own acknowledgement on the origin endpoint is not counted.
  def notified(endpoint_id)
    adapter.delivered_to(endpoint_id).map { |msg| msg.body.text }.grep(/New operator request/)
  end

  it "hands alpha's identically keyed room to a merged lookup, which is what the fallback read" do
    expect(topo.rooms.find { |room| room.id == shared_key }.endpoints.map(&:id))
      .to eq(%w[alpha-telegram alpha-discord])
  end

  describe "a request in beta, whose configured notify_room key alpha also uses" do
    before { request_in("beta") }

    it "notifies every endpoint of beta's own room" do
      expect(notified("beta-telegram")).not_to be_empty
      expect(notified("beta-discord")).not_to be_empty
    end

    it "names beta and nobody else in what it posts" do
      expect(notified("beta-telegram").last).to include("BETA")
      expect(notified("beta-telegram").last).not_to include("ALPHA")
    end

    it "posts nothing whatsoever into alpha" do
      expect(adapter.delivered_to("alpha-telegram")).to be_empty
      expect(adapter.delivered_to("alpha-discord")).to be_empty
    end
  end

  # The same key from the other side, so beta's result is not a coincidence.
  it "notifies alpha's own room for a request in alpha, and leaves beta alone" do
    request_in("alpha")

    expect(notified("alpha-telegram")).not_to be_empty
    expect(adapter.delivered_to("beta-telegram")).to be_empty
  end

  it "still records the request and posts no notification when no room is configured" do
    request_in("beta", notify_room: nil)

    expect(notified("beta-telegram")).to be_empty
    expect(notified("beta-discord")).to be_empty
    expect(flow.pending(community_id: snapshot.community("beta").id).size).to eq(1)
  end

  # #call refuses before this, so a community-less context cannot arrive here
  # through the pipeline. The resolver is asked directly because it is the one
  # place the merged topology was read, and the only input that can tell the
  # two versions apart.
  it "resolves no room at all from a context that carries no community" do
    context = Rubotty::Features::Context.new(
      message: message(channel_at("beta-telegram").endpoint, text: "/operator request", author: newcomer),
      config: { notify_room: shared_key }
    )

    expect(feature.send(:notify_room, context)).to be_nil
  end
end
