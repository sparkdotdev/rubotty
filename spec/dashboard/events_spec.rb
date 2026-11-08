# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The operator's events page: list, create and cancel, driven with rack-test over
# the seeded SAMPLE control plane through the SAME ControlPlane::EventScheduling and
# ControlPlane::EventPolicy the /event command uses.
RSpec.describe "Rubotty::Dashboard::App events", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login! = post("/login", secret: secret)

  # Events start off everywhere, so turn it on for the "gaming" room.
  def allow_gaming!(who: "operators")
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    controls.enable(community: community, selector: "gaming", feature: "events")
    controls.set(community: community, selector: "gaming", feature: "events",
                 key: "who_can_create", value: who)
  end

  # Always a day out: a fixed calendar date eventually falls into the past, and
  # EventScheduling's "upcoming" query rightly stops listing it.
  def future_starts_at
    (Time.now.utc + 86_400).strftime("%Y-%m-%d %H:%M")
  end

  def create_params(overrides = {})
    {
      room: "gaming", title: "Friday Raid Night", starts_at: future_starts_at,
      timezone: "Europe/Lisbon", kind: "gaming", game_title: "Counter-Strike 2",
      server_address: "1.2.3.4:7777", rsvp_mode: "affirm"
    }.merge(overrides)
  end

  describe "unauthenticated" do
    it "gates the events page behind a session" do
      get "/communities/sample/events"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  context "as an administrator session" do
    before { login! }

    describe "GET /communities/:slug/events" do
      it "renders the events page listing the community's rooms" do
        get "/communities/sample/events"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("GAMING &amp; SCHEDULING")
      end

      # The room picker of the schedule form, named for its own field: a room
      # key also appears in the scope picker of the schema form at the bottom
      # of the page, so the bare key is no longer a reading of this.
      it "shows a room's events feature as off until it is turned on" do
        get "/communities/sample/events"
        expect(last_response.body).to include("No room has events turned on yet")
        expect(last_response.body).not_to include('<select name="room">')
      end

      it "offers a room to schedule into once its events feature is on" do
        allow_gaming!
        get "/communities/sample/events"
        expect(last_response.body).to include('<select name="room">')
        expect(last_response.body).to include('value="gaming"')
      end

      it "lists an upcoming event" do
        allow_gaming!
        deps.event_scheduling.create(
          community: community, room: models.room.where(community_id: community.id, room_key: "gaming").first,
          as: :operator, title: "Friday Raid Night", starts_at: future_starts_at, kind: "gaming"
        )
        get "/communities/sample/events"
        expect(last_response.body).to include("Friday Raid Night")
      end
    end

    describe "POST /communities/:slug/events (create)" do
      it "refuses to create for a room whose events feature is off" do
        expect do
          post "/communities/sample/events", create_params
        end.not_to change { models.event.count }
        follow_redirect!
        expect(last_response.body).to include("not enabled")
      end

      it "creates an event for an enabled room" do
        allow_gaming!
        expect do
          post "/communities/sample/events", create_params
        end.to change { models.event.where(community_id: community.id).count }.by(1)

        event = models.event.where(community_id: community.id).order(:id).last
        expect(event.title).to eq("Friday Raid Night")
        expect(event.kind).to eq("gaming")
        expect(event.game_title).to eq("Counter-Strike 2")
        expect(event.rsvp_mode).to eq("affirm")
        expect(event.created_by).to eq("dashboard:administrator")
      end

      it "turns a blank title into a flash error and creates nothing" do
        allow_gaming!
        expect do
          post "/communities/sample/events", create_params(title: "")
        end.not_to change { models.event.count }
        follow_redirect!
        expect(last_response.body).to include("title")
      end

      it "turns an unparsable start time into a flash error" do
        allow_gaming!
        expect do
          post "/communities/sample/events", create_params(starts_at: "whenever")
        end.not_to change { models.event.count }
        follow_redirect!
        expect(last_response.body).to include("start time")
      end
    end

    describe "POST /communities/:slug/events/:id/cancel" do
      it "cancels an existing event" do
        allow_gaming!
        post "/communities/sample/events", create_params
        event = models.event.where(community_id: community.id).order(:id).last

        post "/communities/sample/events/#{event.id}/cancel"
        expect(event.refresh.status).to eq("cancelled")
        follow_redirect!
        expect(last_response.body).to include("cancelled")
      end

      it "reports no such event for an unknown id" do
        post "/communities/sample/events/999999/cancel"
        follow_redirect!
        expect(last_response.body).to include("No such event")
      end
    end
  end

  # An operator session may manage events only for a community it is granted.
  context "an operator-role stub" do
    let(:other_community_id) do
      Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    end
    let(:other_community) { models.community[other_community_id] }

    let(:app) do
      operator_deps = deps
      operator_community_id = community.id
      Class.new(Rubotty::Dashboard::App) do
        set :deps, operator_deps
        helpers do
          define_method(:authenticated?) { true }
          define_method(:current_role) do
            # An operator starts with no write grants, so the one these examples
            # exercise is handed over explicitly.
            Rubotty::Dashboard::Role.operator(community_ids: [operator_community_id],
                                              write_actions: %i[configure_events])
          end
        end
      end
    end

    it "reaches the events page for the community it operates" do
      get "/communities/sample/events"
      expect(last_response.status).to eq(200)
    end

    it "is denied the events page for a community it does not operate" do
      get "/communities/#{other_community.slug}/events"
      expect(last_response.status).to eq(403)
    end

    it "creates an event inside its own community" do
      allow_gaming!
      post "/communities/sample/events", create_params
      expect(last_response.status).to eq(302)
      expect(models.event.where(community_id: community.id).count).to eq(1)
    end

    it "is denied creating an event for a community it does not operate" do
      post "/communities/#{other_community.slug}/events", create_params(room: "general")
      expect(last_response.status).to eq(403)
      expect(models.event.where(community_id: other_community.id).count).to eq(0)
    end

    it "is denied cancelling an event for a community it does not operate" do
      post "/communities/#{other_community.slug}/events/1/cancel"
      expect(last_response.status).to eq(403)
    end
  end
end
