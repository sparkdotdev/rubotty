# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "json"

# The dashboard half of search: the Role to Scope translation the command bar's
# authorization rests on, and the route that serves it. What the service does
# with a scope, and the cross-community property, are in
# spec/control_plane/search_isolation_spec.rb.
RSpec.describe "Rubotty::Dashboard search", :control_plane do
  include Rack::Test::Methods

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let!(:mine) { search_community(models, slug: "alpha-co", marker: "alpha") }
  let!(:theirs) { search_community(models, slug: "beta-co", marker: "beta") }

  def scope_for(role) = Rubotty::Dashboard::SearchScope.for(role: role, communities: models.community.order(:id).all)

  describe "translating a role into a scope" do
    it "gives an administrator every community and every action, Files included" do
      scope = scope_for(Rubotty::Dashboard::Role.administrator)

      expect(scope).to be_deployment_wide
      expect(scope.allows?(Rubotty::ControlPlane::Search::FILES_ACTION, community_id: mine.id)).to be(true)
      expect(scope.anywhere?(:view_rooms)).to be(true)
    end

    it "gives a deployment-wide viewer every community and every read except the administrator's Files page" do
      scope = scope_for(Rubotty::Dashboard::Role.viewer)

      expect(scope).to be_deployment_wide
      expect(scope.anywhere?(:view_rooms)).to be(true)
      expect(scope.anywhere?(:view_audit_log)).to be(true)
      expect(scope.allows?(Rubotty::ControlPlane::Search::FILES_ACTION, community_id: mine.id)).to be(false)
    end

    it "gives a plain operator their own community only, and only the reads an operator holds there" do
      scope = scope_for(Rubotty::Dashboard::Role.operator(community_ids: [mine.id]))

      expect(scope).not_to be_deployment_wide
      expect(scope.community_ids(:view_community)).to eq([mine.id])
      # The oversight reads (Rooms, Platforms, Scripts, Endpoints, Discovered,
      # Guests) need viewer status, which operating a community does not confer.
      expect(scope.community_ids(:view_rooms)).to be_empty
      expect(scope.community_ids(:view_scripts)).to be_empty
      expect(scope.community_ids(:view_operators)).to eq([mine.id])
    end

    it "gives a community-scoped viewer more of the community they read than of the one they run" do
      role = Rubotty::Dashboard::Role.community_viewer(
        viewer_community_ids: [theirs.id], community_ids: [mine.id]
      )
      scope = scope_for(role)

      expect(scope.community_ids(:view_rooms)).to eq([theirs.id])
      expect(scope.community_ids(:view_community)).to match_array([mine.id, theirs.id])
      expect(scope.allows?(Rubotty::ControlPlane::Search::FILES_ACTION, community_id: theirs.id)).to be(false)
    end

    it "gives a session with no role nothing at all" do
      scope = scope_for(nil)

      expect(scope.anywhere?(:view_community)).to be(false)
      expect(scope.community_ids(:view_community)).to be_empty
    end

    it "answers every action the search service asks about, so none of them defaults to permitted" do
      scope = scope_for(Rubotty::Dashboard::Role.operator(community_ids: [mine.id]))

      Rubotty::ControlPlane::Search::ACTIONS.each do |action|
        expect([true, false]).to include(scope.allows?(action, community_id: theirs.id))
        expect(scope.allows?(action, community_id: theirs.id)).to be(false)
      end
    end
  end

  describe "the route" do
    def payload = JSON.parse(last_response.body)

    it "requires a session like every other page" do
      get "/search.json?q=alpha"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    context "with an administrator session" do
      before { post "/login", secret: secret }

      it "answers JSON with both result kinds kept apart" do
        get "/search.json?q=alpha-co"

        expect(last_response.status).to eq(200)
        expect(last_response.content_type).to include("application/json")
        expect(payload["entities"].map { |entry| entry["kind"] }).to eq(["community"])
        expect(payload["destinations"]).not_to be_empty
      end

      it "reads both communities" do
        get "/search.json?q=Assembly"

        expect(payload["entities"].map { |entry| entry["community_slug"] }.uniq)
          .to match_array(%w[alpha-co beta-co])
      end

      it "puts the mount point back on a path so the caller can follow it" do
        get "/search.json?q=alpha%20Lounge"

        expect(payload["entities"].first["path"]).to eq("/communities/alpha-co/rooms")
      end

      it "answers an empty result rather than an error for a query that is too short" do
        get "/search.json?q=a"

        expect(last_response.status).to eq(200)
        expect(payload["entities"]).to be_empty
        expect(payload["destinations"]).to be_empty
      end
    end

    context "with an operator session scoped to one community" do
      let(:session) { dashboard_session(role: "operator", operator_communities: [mine.id]) }

      it "answers nothing about the community it does not run" do
        get "/search.json?q=beta", {}, "rack.session" => session

        expect(last_response.status).to eq(200)
        expect(payload["entities"]).to be_empty
        expect(payload["destinations"]).to be_empty
      end

      it "answers nothing for another community's resource asked for by name" do
        get "/search.json?q=beta%20Lounge", {}, "rack.session" => session

        expect(payload["entities"]).to be_empty
      end

      it "still answers its own community's alerts, which an operator may read" do
        get "/search.json?q=alpha%20needs", {}, "rack.session" => session

        expect(payload["entities"].map { |entry| entry["kind"] }).to eq(["alert"])
        expect(payload["entities"].first["community_slug"]).to eq("alpha-co")
      end

      it "offers no page an operator would be refused at the door" do
        get "/search.json?q=rooms", {}, "rack.session" => session

        expect(payload["destinations"]).to be_empty
      end
    end

    context "with a community-scoped viewer session" do
      let(:session) do
        dashboard_session(role: "operator", operator_communities: [], viewer: false, viewer_communities: [mine.id])
      end

      it "reads the community it was named in and nothing outside it" do
        get "/search.json?q=Lounge", {}, "rack.session" => session

        expect(payload["entities"].map { |entry| entry["community_slug"] }).to eq(["alpha-co"])
      end
    end
  end
end
