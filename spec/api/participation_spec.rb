# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# The REST surface over ControlPlane::Participation: a room's open session
# and round, with a way to close a stuck one. Both routes call straight into
# the same service a script's session()/close_session() calls reach, so the
# dashboard, the API and a script can never disagree about what is running.
RSpec.describe "Rubotty::Api::App room games", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def developer_token(on: community)
    keys.issue(scope: "developer", community: on, label: "test developer key").token
  end

  def bearer(token)
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def other_community
    models.community.create(
      slug: "other-co", name: "Other Co", status: "active", settings: "{}",
      created_at: Time.now, updated_at: Time.now
    )
  end

  # Opens a session the way a script does, through the same service the
  # routes call, so a test here can never drift from what they actually run.
  def start_session(on: community, room_key: "general", kind: "trivia", label: "Friday quiz")
    deps.participation.open_session(community: on, room_key: room_key, kind: kind, label: label)
  end

  def open_round(on: community, room_key: "general")
    deps.participation.open_round(community: on, room_key: room_key)
  end

  describe "GET /communities/:slug/rooms/:room_key/participation" do
    it "answers a null session and a null round when nothing is running" do
      get "/communities/sample/rooms/general/participation", {}, bearer(developer_token)

      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["session"]).to be_nil
      expect(body["round"]).to be_nil
    end

    it "reports the open session's kind, label and round count" do
      start_session
      open_round

      get "/communities/sample/rooms/general/participation", {}, bearer(developer_token)

      body = YAMLCamel.load(last_response.body)
      expect(body["session"]).to include("kind" => "trivia", "label" => "Friday quiz",
                                         "state" => "open", "rounds" => 1)
    end

    it "reports the open round's position" do
      start_session
      open_round

      get "/communities/sample/rooms/general/participation", {}, bearer(developer_token)

      expect(YAMLCamel.load(last_response.body)["round"]).to include("position" => 1)
    end

    it "404s a room that does not exist in this community" do
      get "/communities/sample/rooms/does-not-exist/participation", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /communities/:slug/rooms/:room_key/participation/close" do
    it "closes the open session and whatever round is open inside it" do
      start_session

      post "/communities/sample/rooms/general/participation/close", {}, bearer(developer_token)

      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)).to eq("closed" => true)
      expect(deps.participation.session(community: community, room_key: "general")).to be_nil
    end

    it "refuses with 422 when nothing is running in the room" do
      post "/communities/sample/rooms/general/participation/close", {}, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(YAMLCamel.load(last_response.body)["error"]).to include("nothing is running")
    end

    it "404s a room that does not exist in this community" do
      post "/communities/sample/rooms/does-not-exist/participation/close", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end
  end

  # The reason this file exists: a developer key confined to one community
  # must never see or touch another community's session, and finding out one
  # is running elsewhere must not be possible either.
  describe "community scope" do
    it "never confuses another community's session with its own room of the same key" do
      elsewhere = other_community
      models.room.create(community_id: elsewhere.id, room_key: "general", display_name: "{}",
                         created_at: Time.now, updated_at: Time.now)
      start_session(on: elsewhere, label: "Their quiz")

      # sample's OWN "general" room, addressed with sample's own key: nothing is
      # running there, and the answer must not be "elsewhere"'s session just
      # because the room_key string happens to match.
      get "/communities/sample/rooms/general/participation", {}, bearer(developer_token)

      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["session"]).to be_nil
    end

    it "never leaks another community's open session through this community's own key" do
      elsewhere = other_community
      models.room.create(community_id: elsewhere.id, room_key: "elsewhere-room", display_name: "{}",
                         created_at: Time.now, updated_at: Time.now)
      start_session(on: elsewhere, room_key: "elsewhere-room", label: "Their quiz")

      get "/communities/#{elsewhere.slug}/rooms/elsewhere-room/participation", {}, bearer(developer_token)

      expect(last_response.status).to eq(404)
    end

    it "leaves another community's session open when closing its own room of the same key" do
      elsewhere = other_community
      models.room.create(community_id: elsewhere.id, room_key: "general", display_name: "{}",
                         created_at: Time.now, updated_at: Time.now)
      start_session(on: elsewhere)

      # Nothing is running in sample's own "general" room, so this 422s rather
      # than reaching across and closing "elsewhere"'s session of the same key.
      post "/communities/sample/rooms/general/participation/close", {}, bearer(developer_token)

      expect(last_response.status).to eq(422)
      expect(deps.participation.session(community: elsewhere, room_key: "general")).not_to be_nil
    end

    it "404s, not 422, closing another community's real room by slug, not touching its session" do
      elsewhere = other_community
      models.room.create(community_id: elsewhere.id, room_key: "general", display_name: "{}",
                         created_at: Time.now, updated_at: Time.now)
      start_session(on: elsewhere)

      post "/communities/#{elsewhere.slug}/rooms/general/participation/close", {}, bearer(developer_token)

      expect(last_response.status).to eq(404)
      expect(deps.participation.session(community: elsewhere, room_key: "general")).not_to be_nil
    end

    it "lets an administrator key read and close any community's session" do
      elsewhere = other_community
      models.room.create(community_id: elsewhere.id, room_key: "general", display_name: "{}",
                         created_at: Time.now, updated_at: Time.now)
      start_session(on: elsewhere)
      admin_token = keys.issue(scope: "administrator", label: "test admin key").token

      get "/communities/#{elsewhere.slug}/rooms/general/participation", {}, bearer(admin_token)
      expect(last_response.status).to eq(200)

      post "/communities/#{elsewhere.slug}/rooms/general/participation/close", {}, bearer(admin_token)
      expect(last_response.status).to eq(200)
      expect(deps.participation.session(community: elsewhere, room_key: "general")).to be_nil
    end
  end
end
