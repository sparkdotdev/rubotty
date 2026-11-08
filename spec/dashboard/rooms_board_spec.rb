# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

RSpec.describe "the Rooms board detail actions", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret }) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:general) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:gaming) { models.room.where(community_id: community.id, room_key: "gaming").first }
  let(:channel) do
    id = models.room_channel.where(room_id: general.id).order(:channel_id).first.channel_id
    models.channel[id]
  end

  before { post "/login", secret: secret }

  it "serves a themed channel detail route for a channel on the board" do
    get "/communities/sample/rooms/channels/#{channel.id}"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("Loading the channel details")
    expect(last_response.body).to include(%(data-rb-themed-section="true"))
  end

  it "saves a channel name without silently approving a proposed name" do
    channel.update(label: "Proposed", suggested: true)

    post "/communities/sample/rooms/channels/#{channel.id}/name", label: "General chat"

    expect(channel.refresh).to have_attributes(label: "General chat", suggested: true)
    expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms/channels/#{channel.id}")
  end

  it "moves a channel only after its new mapping is present" do
    post "/communities/sample/rooms/channels/#{channel.id}/mapping",
         destination: "room", room_key: gaming.room_key

    linked_room_ids = models.room_channel.where(channel_id: channel.id).select_map(:room_id)
    expect(linked_room_ids).to contain_exactly(gaming.id)
    expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms/channels/#{channel.id}")
  end

  it "removes a channel from one room without deleting the room" do
    post "/communities/sample/rooms/channels/#{channel.id}/unlink", room_key: general.room_key

    expect(models.room[general.id]).not_to be_nil
    expect(models.room_channel.where(room_id: general.id, channel_id: channel.id).first).to be_nil
  end

  it "renames a room through its own detail route" do
    post "/communities/sample/rooms/#{general.room_key}/name", label: "Main chat"

    expect(general.refresh.label).to eq("Main chat")
    expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms/general")
  end
end
