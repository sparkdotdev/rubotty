# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Rooms board's automatic mapping: propose, show for confirmation, apply
# only what was ticked.
RSpec.describe "dashboard automatic mapping", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:connection) { models.platform_connection.where(community_id: community.id, adapter: "telegram").first }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret }) }

  before { post "/login", secret: secret }

  def discovered(label, route:)
    now = Time.now
    models.channel.create(
      community_id: community.id, platform_connection_id: connection.id,
      adapter: "telegram", account: "telegram", route_key: route,
      endpoint_key: "discovered:telegram:telegram:#{route}", label: label,
      created_at: now, updated_at: now
    )
  end

  it "starts the themed confirmation from the Rooms board" do
    channel = discovered("Banking in Portugal", route: "auto-1")
    post "/communities/sample/discovered/auto-map"

    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms/automatic-mapping")
    get last_response.headers.fetch("Location")
    expect(last_response.body).to include("Loading the proposed channel mappings")
    expect(models.room_channel.where(channel_id: channel.id).first).to be_nil
  end

  it "applies only the ticked rows" do
    keep = discovered("Legal Action", route: "auto-3")
    drop = discovered("Media PR", route: "auto-4")

    post "/communities/sample/discovered/auto-map/apply",
         "apply" => [keep.endpoint_key]

    expect(models.room_channel.where(channel_id: keep.id).first).not_to be_nil
    expect(models.room_channel.where(channel_id: drop.id).first).to be_nil
  end

  it "ignores a tick for a channel that has since been mapped by someone else" do
    channel = discovered("Travel EES", route: "auto-5")
    Rubotty::ControlPlane::ChannelMapper.new(models: models)
                                        .resolve_selection(community: community, channel: channel,
                                                           room_key: "travel-ees")
    before_count = models.room_channel.where(channel_id: channel.id).count

    post "/communities/sample/discovered/auto-map/apply",
         "apply" => [channel.endpoint_key],
         "room_key" => { channel.endpoint_key => "somewhere-else" },
         "label" => { channel.endpoint_key => "Travel EES" }

    expect(models.room_channel.where(channel_id: channel.id).count).to eq(before_count)
  end
end
