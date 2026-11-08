# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Who reads ONE community, over the REST API: a developer key confined to
# that community drives the ordinary path, and reaches no further than the
# key already reaches. The deployment-wide dimension stays under /admin/...,
# where the same key is refused.
RSpec.describe "Rubotty::Api::App community viewers", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other_community_id) do
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
  end
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
  let(:viewers) { deps.community_viewers }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  def filed
    viewers.request(community_id: community.id, adapter: "telegram",
                    native_id: "9001", username: "ada").request
  end

  describe "GET /communities/:slug/viewers" do
    it "lists the community's granted rows and the shipped floor apart" do
      viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", native_id: "9001",
                    label: "Ada", granted_by: "seeded")

      get "/communities/sample/viewers", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["viewers"].map { |row| row["handle"] }).to eq(["ada"])
      expect(body["viewers"].first["community_id"]).to eq(community.id)
      expect(body["baked_in"]).to eq([])
    end

    it "does not leak another community's list to a developer key" do
      other_community_id

      get "/communities/other-co/viewers", {}, developer

      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /communities/:slug/viewers" do
    it "lets a developer key hand out the read of its own community" do
      post "/communities/sample/viewers", { adapter: "telegram", handle: "@Ada", native_id: "9001", label: "Ada" }, developer

      expect(last_response.status).to eq(201)
      expect(body).to include("handle" => "ada", "native_id" => "9001", "requires_regrant" => false)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
    end

    it "does not let that key hand out the read of another community" do
      other_community_id

      post "/communities/other-co/viewers", { adapter: "telegram", handle: "mole" }, developer

      expect(last_response.status).to eq(404)
      expect(viewers.viewer?(community_id: other_community_id, adapter: "telegram",
                             username: "mole", native_id: "9002")).to be(false)
    end

    # The rule the split exists for: the deployment-wide dimension reads every
    # other community, so nothing below an administrator hands it out.
    it "does not let that key hand out the deployment-wide dimension" do
      post "/admin/viewers", { adapter: "telegram", handle: "mole" }, developer

      expect(last_response.status).to eq(403)
      expect(deps.dashboard_viewers.viewer?(adapter: "telegram", username: "mole", native_id: "9002")).to be(false)
    end

    it "answers 422 for a platform nothing would ever match on" do
      post "/communities/sample/viewers", { adapter: "carrier-pigeon", handle: "ada" }, developer

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("platforms a viewer can be named on")
    end
  end

  describe "DELETE /communities/:slug/viewers/:id" do
    it "takes a granted row back" do
      row = viewers.grant(community_id: community.id, adapter: "telegram", handle: "ada", native_id: "9001", granted_by: "seeded")

      delete "/communities/sample/viewers/#{row[:id]}", {}, developer

      expect(last_response.status).to eq(204)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: "9001")).to be(false)
    end

    it "answers 404 for an id that is not in this community" do
      delete "/communities/sample/viewers/99999", {}, developer

      expect(last_response.status).to eq(404)
    end

    it "answers 422 for a handle the deployment ships with" do
      floor = Rubotty::Security::DashboardViewers.new(usernames: ["shipped"])
      allow(Rubotty::Security::DashboardViewers).to receive(:default).and_return(floor)
      shipped = Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500)
      id = db[:community_viewers].insert(community_id: community.id, adapter: "telegram",
                                         handle: "shipped", granted_at: Time.now, granted_by: "seeded")

      shipped_app = Rubotty::Api::App.assemble(deps: shipped, env: {})
      session = Rack::Test::Session.new(Rack::MockSession.new(shipped_app))
      session.delete("/communities/sample/viewers/#{id}", {}, developer)

      expect(session.last_response.status).to eq(422)
      expect(db[:community_viewers].where(id: id).count).to eq(1)
    end
  end

  describe "the request queue" do
    it "lists the open asks" do
      filed

      get "/communities/sample/viewer-requests", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["viewer_requests"].map { |row| row["requester_username"] }).to eq(["ada"])
    end

    it "grants on approval" do
      request_row = filed

      post "/communities/sample/viewer-requests/#{request_row[:id]}/approve", {}, developer

      expect(last_response.status).to eq(200)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
    end

    it "grants nothing on denial" do
      request_row = filed

      post "/communities/sample/viewer-requests/#{request_row[:id]}/deny", {}, developer

      expect(last_response.status).to eq(200)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: "9001")).to be(false)
    end

    it "answers 422 for a request that has already been decided" do
      request_row = filed
      post "/communities/sample/viewer-requests/#{request_row[:id]}/deny", {}, developer

      post "/communities/sample/viewer-requests/#{request_row[:id]}/deny", {}, developer

      expect(last_response.status).to eq(422)
    end

    it "is reachable by an administrator key too" do
      get "/communities/sample/viewer-requests", {}, admin

      expect(last_response.status).to eq(200)
    end
  end
end
