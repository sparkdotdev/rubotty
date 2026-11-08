# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Room games page: the open session and round
# ControlPlane::Participation holds for each room, plus the one control
# that closes a stuck session. The page rides :view_community like
# Redirections and Alerts; closing a session is its own grant.
RSpec.describe "Rubotty::Dashboard::App room games", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }

  def login! = post("/login", secret: secret)

  def community_navigation_paths(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    document = JSON.parse(source)
    scope = document.fetch("scopes").find { |entry| entry.fetch("key") == "community" }
    scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("path") }
  end

  # Opens a session through the same service the route calls, so a test here
  # can never drift from what the page actually runs.
  def start_session(on: community, room_key: "general", kind: "trivia", label: "Friday quiz")
    deps.participation.open_session(community: on, room_key: room_key, kind: kind, label: label)
  end

  def open_round(on: community, room_key: "general")
    deps.participation.open_round(community: on, room_key: room_key)
  end

  def general_room(on: community)
    models.room.where(community_id: on.id, room_key: "general").first
  end

  describe "an administrator session" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    before { login! }

    it "renders, with a link in the community's own nav" do
      get "/communities/sample/participation"

      expect(last_response.status).to eq(200)
      expect(community_navigation_paths).to include("/communities/sample/participation")
    end

    it "says plainly that nothing is running in a room with no session" do
      get "/communities/sample/participation"

      expect(last_response.body).to include("Nothing is running in this room.")
    end

    it "shows the open session's kind, label and round count" do
      start_session
      open_round

      get "/communities/sample/participation"

      expect(last_response.body).to include("trivia").and include("Friday quiz")
      expect(last_response.body).to include("1 round")
    end

    it "says plainly when no round is open" do
      start_session

      get "/communities/sample/participation"

      expect(last_response.body).to include("No round is open right now.")
    end

    it "shows the open round's position" do
      start_session
      open_round

      get "/communities/sample/participation"

      expect(last_response.body).to include("Round 1")
    end

    it "never shows another community's session" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      models.room.create(community_id: other.id, room_key: "general", display_name: "{}",
                         created_at: Time.now, updated_at: Time.now)
      start_session(on: other, label: "Somebody Else's Quiz")

      get "/communities/sample/participation"

      expect(last_response.body).not_to include("Somebody Else's Quiz")
    end

    it "closes an open session" do
      start_session
      room = general_room

      post "/communities/sample/participation/#{room.id}/close"

      expect(deps.participation.session(community: community, room_key: "general")).to be_nil
      follow_redirect!
      expect(last_response.body).to include("Closed the session")
    end

    it "flashes a clear refusal for a room with nothing running" do
      room = general_room

      post "/communities/sample/participation/#{room.id}/close"

      follow_redirect!
      expect(last_response.body).to include("nothing is running in this room")
    end

    it "404s a room id from another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      elsewhere = models.room.create(community_id: other.id, room_key: "elsewhere", display_name: "{}",
                                     created_at: Time.now, updated_at: Time.now)
      start_session(on: other, room_key: "elsewhere")

      post "/communities/sample/participation/#{elsewhere.id}/close"

      expect(last_response.status).to eq(404)
      expect(deps.participation.session(community: other, room_key: "elsewhere")).not_to be_nil
    end
  end

  describe "unauthenticated" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

    it "redirects the room-games page to login" do
      unauthenticated = Rack::Test::Session.new(app)
      unauthenticated.get("/communities/sample/participation")
      expect(unauthenticated.last_response.status).to eq(302)
      expect(unauthenticated.last_response.headers["location"]).to end_with("/login")
    end
  end

  # The same stub role the redirections and moderation specs use, so the
  # routes can be checked apart from whatever the permission matrix decides.
  let(:stub_role_class) do
    Struct.new(:allowed_actions, :scoped_community_id) do
      def administrator? = false

      def operator? = true

      def kind = :operator

      def readable_community_ids = [scoped_community_id]

      def write_actions = allowed_actions

      def can?(action, community:)
        return false unless allowed_actions.include?(action)
        return true if community == Rubotty::Dashboard::Role::DEPLOYMENT

        !community.nil? && community.id == scoped_community_id
      end
    end
  end

  def app_as(role)
    operator_deps = deps
    Class.new(Rubotty::Dashboard::App) do
      set :deps, operator_deps
      helpers do
        define_method(:authenticated?) { true }
        define_method(:current_role) { role }
      end
    end
  end

  describe "an operator who runs this community, with no grant of their own" do
    let(:role) { stub_role_class.new([:view_community], community.id) }
    let(:app) { app_as(role) }

    it "may read the room games page without any grant of its own" do
      start_session
      get "/communities/sample/participation"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("trivia")
    end

    it "is offered a flat, disabled close button without the grant" do
      start_session
      get "/communities/sample/participation"

      expect(last_response.body).to include("Close session</button>")
      expect(last_response.body).to include(%(class="danger disabled" disabled title="Read only))
    end

    it "may not close a session without the grant" do
      start_session
      room = general_room

      post "/communities/sample/participation/#{room.id}/close"

      expect(last_response.status).to eq(403)
      expect(deps.participation.session(community: community, room_key: "general")).not_to be_nil
    end
  end

  describe "an operator holding the manage_participation grant" do
    let(:role) { stub_role_class.new(%i[view_community manage_participation], community.id) }
    let(:app) { app_as(role) }

    it "is offered the close button, live" do
      start_session
      get "/communities/sample/participation"

      expect(last_response.body).to include(%(<button type="submit" class="danger" data-grant="manage_participation">Close session</button>))
    end

    it "closes a session" do
      start_session
      room = general_room

      post "/communities/sample/participation/#{room.id}/close"

      expect(deps.participation.session(community: community, room_key: "general")).to be_nil
    end
  end

  describe "an operator whose grant does not cover this community" do
    let(:role) { stub_role_class.new(%i[view_community manage_participation], community.id + 999) }
    let(:app) { app_as(role) }

    it "cannot open the page at all" do
      get "/communities/sample/participation"

      expect(last_response.status).to eq(403)
    end

    it "cannot close a session in a community it does not operate" do
      start_session
      room = general_room

      post "/communities/sample/participation/#{room.id}/close"

      expect(last_response.status).to eq(403)
      expect(deps.participation.session(community: community, room_key: "general")).not_to be_nil
    end
  end
end
