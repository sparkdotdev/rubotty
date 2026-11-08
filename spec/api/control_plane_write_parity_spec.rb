# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

RSpec.describe "the REST API's control-plane write parity", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def administrator
    { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: "administrator", label: "parity admin").token}" }
  end

  def developer
    { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: "developer", community: community, label: "parity developer").token}" }
  end

  def response_body = YAMLCamel.load(last_response.body)

  describe "room provisioning" do
    it "queues an administrator's room create and delete requests" do
      post "/admin/communities/sample/rooms",
           { "name" => "Book club", "platforms" => [{ "adapter" => "telegram", "account" => "telegram" }] }, administrator

      expect(last_response.status).to eq(202)
      expect(response_body).to eq("status" => "requested", "room" => nil)
      expect(db[:scheduled_jobs].where(kind: Rubotty::ControlPlane::RoomProvisioning::CREATE_KIND).count).to eq(1)

      delete "/admin/communities/sample/rooms/general",
             { "confirmed_name" => room.label || room.room_key }, administrator

      expect(last_response.status).to eq(202)
      expect(response_body.dig("room", "room_key")).to eq("general")
      expect(db[:scheduled_jobs].where(kind: Rubotty::ControlPlane::RoomProvisioning::DELETE_KIND).count).to eq(1)
    end

    it "keeps provisioning out of a developer key's addressable routes" do
      post "/admin/communities/sample/rooms", {}, developer

      expect(last_response.status).to eq(403)
    end
  end

  describe "community status" do
    it "suspends and starts a community through an administrator key" do
      put "/admin/communities/sample/status", { "status" => "suspended" }, administrator
      expect(last_response.status).to eq(200)
      expect(response_body["status"]).to eq("suspended")

      put "/admin/communities/sample/status", { "status" => "active" }, administrator
      expect(last_response.status).to eq(200)
      expect(response_body["status"]).to eq("active")
    end
  end

  describe "mutes" do
    it "creates, lists and lifts a mute through an administrator key" do
      post "/admin/communities/sample/mutes",
           { "adapter" => "telegram", "native_id" => "u-123", "username" => "trouble", "duration" => "1h" },
           administrator

      expect(last_response.status).to eq(201)
      mute = response_body
      expect(mute).to include("adapter" => "telegram", "native_id" => "u-123", "active" => true)

      get "/admin/communities/sample/mutes", {}, administrator
      expect(last_response.status).to eq(200)
      expect(response_body.fetch("mutes").map { |row| row.fetch("id") }).to include(mute.fetch("id"))

      delete "/admin/communities/sample/mutes/#{mute.fetch("id")}", {}, administrator
      expect(last_response.status).to eq(200)
      expect(response_body["active"]).to be(false)
    end
  end

  describe "events" do
    before do
      deps.feature_controls.enable(community: community, selector: room.room_key, feature: "events")
    end

    it "lets a developer create, edit and cancel its community's event" do
      post "/communities/sample/rooms/general/events",
           { "title" => "Planning", "starts_at" => "2030-01-01 20:00", "timezone" => "Europe/Lisbon",
             "kind" => "general", "description" => "Bring notes." }, developer

      expect(last_response.status).to eq(201)
      event = response_body
      expect(event).to include("title" => "Planning", "status" => "scheduled", "room_key" => "general")

      patch "/communities/sample/events/#{event.fetch("id")}", { "title" => "Planning session" }, developer
      expect(last_response.status).to eq(200)
      expect(response_body["title"]).to eq("Planning session")

      delete "/communities/sample/events/#{event.fetch("id")}", {}, developer
      expect(last_response.status).to eq(200)
      expect(response_body["status"]).to eq("cancelled")
    end
  end

  describe "irc networks" do
    it "lets an administrator create, edit and remove one, but keeps it out of a developer key's reach" do
      post "/admin/communities/sample/irc-networks",
           { "name" => "libera", "host" => "irc.libera.chat", "nick" => "rubotty" }, developer
      expect(last_response.status).to eq(403)

      post "/admin/communities/sample/irc-networks",
           { "name" => "libera", "host" => "irc.libera.chat", "nick" => "rubotty" }, administrator
      expect(last_response.status).to eq(201)
      network = response_body
      expect(network).to include("name" => "libera", "host" => "irc.libera.chat", "mode" => "per_room")

      get "/communities/sample/irc-networks/libera", {}, developer
      expect(last_response.status).to eq(200)

      patch "/admin/communities/sample/irc-networks/libera",
            { "mode" => "hub", "hub_channel" => "#sample" }, administrator
      expect(last_response.status).to eq(200)
      expect(response_body).to include("mode" => "hub", "hub_channel" => "#sample")

      delete "/admin/communities/sample/irc-networks/libera", {}, administrator
      expect(last_response.status).to eq(204)

      get "/communities/sample/irc-networks/libera", {}, administrator
      expect(last_response.status).to eq(404)
    end

    it "turns a hub network with no hub_channel into a 422 rather than a 500" do
      post "/admin/communities/sample/irc-networks",
           { "name" => "libera", "host" => "irc.libera.chat", "nick" => "rubotty", "mode" => "hub" },
           administrator

      expect(last_response.status).to eq(422)
      expect(response_body["error"]).to match(/hub_channel/)
      expect(models.irc_network.where(community_id: community.id).count).to eq(0)
    end
  end
end
