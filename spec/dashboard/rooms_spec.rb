# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The dashboard's room-provisioning surface: create and delete a meta-channel,
# admin-only, behind the channel_management flag, driving the SAME
# ControlPlane::RoomProvisioning request side the bot DM console does. This process
# holds no adapters, so every write only enqueues a durable job.
RSpec.describe Rubotty::Dashboard::App, "room provisioning", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, config: sample_model) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  def enable_channel_management!
    deps.feature_controls.enable(community: community, selector: "all", feature: "channel_management")
  end

  before { login! }

  describe "GET /communities/:slug/rooms" do
    it "shows the opt-in notice, and no create form, when the feature is off" do
      get "/communities/sample/rooms"
      expect(last_response.body).to include("Channel management is off")
      expect(last_response.body).not_to include("Create room")
    end

    it "shows the create form and existing rooms once the feature is enabled" do
      enable_channel_management!
      get "/communities/sample/rooms"
      expect(last_response.body).to include("Create a room")
      expect(last_response.body).to include("general")
    end
  end

  describe "POST /communities/:slug/rooms" do
    before { enable_channel_management! }

    it "enqueues a create request and writes an audit line, with no room created yet" do
      expect do
        post "/communities/sample/rooms", name: "Gaming & Scheduling", "platforms[]": ["discord/discord"]
      end.not_to change { models.room.count }

      follow_redirect!
      expect(last_response.body).to include("Requested room")

      event = deps.audit.query(community: "sample", action: "room_create_requested").first
      expect(event).not_to be_nil
      expect(event.metadata["name"]).to eq("Gaming & Scheduling")
    end

    it "flashes a clear error and enqueues nothing for an empty name" do
      post "/communities/sample/rooms", name: "  ", "platforms[]": ["discord/discord"]
      follow_redirect!
      expect(last_response.body).to include("name")
      expect(deps.audit.query(community: "sample", action: "room_create_requested")).to be_empty
    end

    it "404s nothing but refuses (flash + redirect) when the feature is off" do
      deps.feature_controls.disable(community: community, selector: "all", feature: "channel_management")
      post "/communities/sample/rooms", name: "Gaming", "platforms[]": ["discord/discord"]
      follow_redirect!
      expect(last_response.body).to include("not enabled")
    end
  end

  describe "POST /communities/:slug/rooms/:id/delete" do
    before { enable_channel_management! }

    let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

    it "refuses without the room name typed back, enqueuing nothing" do
      post "/communities/sample/rooms/#{room.id}/delete", confirm_name: "wrong"
      follow_redirect!
      expect(last_response.body).to include("type")
      expect(deps.audit.query(community: "sample", action: "room_delete_requested")).to be_empty
    end

    it "enqueues a delete request and writes an audit line when the name matches" do
      post "/communities/sample/rooms/#{room.id}/delete", confirm_name: room.room_key
      follow_redirect!
      expect(last_response.body).to include("Requested deletion")

      event = deps.audit.query(community: "sample", action: "room_delete_requested").first
      expect(event.target_ref).to eq(room.room_key)
    end

    it "404s a room id from another community" do
      now = Time.now
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: now, updated_at: now)
      elsewhere = models.room.create(community_id: other.id, room_key: "elsewhere", label: "Elsewhere",
                                     display_name: "{}", created_at: now, updated_at: now)
      post "/communities/sample/rooms/#{elsewhere.id}/delete", confirm_name: elsewhere.room_key
      expect(last_response.status).to eq(404)
    end
  end

  describe "authorization" do
    it "redirects the room-provisioning page to login when not authenticated" do
      unauthenticated = Rack::Test::Session.new(app)
      unauthenticated.get("/communities/sample/rooms")
      expect(unauthenticated.last_response.status).to eq(302)
      expect(unauthenticated.last_response.headers["location"]).to end_with("/login")
    end
  end
end
