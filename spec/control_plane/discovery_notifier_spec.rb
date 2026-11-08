# frozen_string_literal: true

require "spec_helper"

# A discovery prompt reuses the operator-request medium: a post to the
# community's operator room.
RSpec.describe Rubotty::ControlPlane::DiscoveryNotifier do
  let(:community) { double("community", id: 7, slug: "sample", name: "Example Gaming Community") }
  let(:ops_room) { double("room", id: "ops", endpoints: %i[tg-ops dc-ops]) }

  # Answers the operator-room lookup: the config names the room and #rooms has it.
  let(:snap_community) do
    Class.new do
      def initialize(room) = @room = room

      def feature_config(_channel_or_key, feature)
        feature.to_s == "operator_requests" ? { "notify_room" => "ops" } : {}
      end

      def rooms = [@room]
    end.new(ops_room)
  end

  let(:registry) do
    snapshot = double("snapshot")
    allow(snapshot).to receive(:community_by_id).with(7).and_return(snap_community)
    double("registry", current: snapshot)
  end

  let(:ephemeral) do
    Class.new do
      attr_reader :posts

      def initialize = @posts = []

      def post(endpoints:, body:, name:, delete_after: 0)
        @posts << { endpoints: endpoints, body: body, name: name, delete_after: delete_after }
      end
    end.new
  end

  let(:descriptor) { { adapter: :discord, name: "announcements", route_key: "900001" } }

  subject(:notifier) do
    described_class.new(registry: registry, ephemeral: ephemeral, logger: Rubotty::Log.null)
  end

  it "posts a map prompt to the community's operator room endpoints" do
    notifier.prompt(community: community, descriptor: descriptor)

    expect(ephemeral.posts.size).to eq(1)
    post = ephemeral.posts.first
    expect(post[:endpoints]).to eq(%i[tg-ops dc-ops])
    expect(post[:body].to_s).to include("announcements")
    expect(post[:body].to_s).to include("map")
  end

  it "logs rather than posts when the community has no operator room configured" do
    allow(snap_community).to receive(:feature_config).and_return({})
    notifier.prompt(community: community, descriptor: descriptor)
    expect(ephemeral.posts).to be_empty
  end

  it "logs rather than posts when no ephemeral poster is available" do
    quiet = described_class.new(registry: registry, ephemeral: nil, logger: Rubotty::Log.null)
    expect { quiet.prompt(community: community, descriptor: descriptor) }.not_to raise_error
  end

  it "never raises out when posting fails" do
    allow(ephemeral).to receive(:post).and_raise(StandardError.new("boom"))
    expect { notifier.prompt(community: community, descriptor: descriptor) }.not_to raise_error
  end

  it "does nothing without a community" do
    notifier.prompt(community: nil, descriptor: descriptor)
    expect(ephemeral.posts).to be_empty
  end
end
