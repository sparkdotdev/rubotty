# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Who reads every community, over the REST API. Every verb is administrator
# only, because the dimension spans the deployment: a developer key confined to
# one community must never be able to hand out oversight of the rest.
RSpec.describe "Rubotty::Api::App viewers", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
  let(:viewers) { deps.dashboard_viewers }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  describe "GET /admin/viewers" do
    it "lists the granted rows and the shipped floor apart" do
      viewers.grant(adapter: "telegram", handle: "ada", native_id: "9001", label: "Ada", granted_by: "seeded")

      get "/admin/viewers", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["viewers"].map { |row| row["handle"] }).to eq(["ada"])
      expect(body["viewers"].first["removable"]).to be(true)
      expect(body["baked_in"]).to eq([])
    end
  end

  describe "POST /admin/viewers" do
    it "binds the grant to a native identity and answers the new entry" do
      post "/admin/viewers", { adapter: "telegram", handle: "@Ada", native_id: "9001", label: "Ada" }, admin

      expect(last_response.status).to eq(201)
      expect(body).to include("handle" => "ada", "native_id" => "9001", "requires_regrant" => false)
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
    end

    it "answers 422 for a platform nothing would ever match on" do
      post "/admin/viewers", { adapter: "carrier-pigeon", handle: "ada" }, admin

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("platforms a viewer can be named on")
    end

    it "answers 422 for a blank handle" do
      post "/admin/viewers", { adapter: "telegram", handle: "  " }, admin

      expect(last_response.status).to eq(422)
    end
  end

  describe "DELETE /admin/viewers/:id" do
    it "takes a granted row back" do
      row = viewers.grant(adapter: "telegram", handle: "ada", native_id: "9001", granted_by: "seeded")

      delete "/admin/viewers/#{row[:id]}", {}, admin

      expect(last_response.status).to eq(204)
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: "9001")).to be(false)
    end

    it "answers 404 for an id that was never granted" do
      delete "/admin/viewers/9999", {}, admin

      expect(last_response.status).to eq(404)
    end

    # The floor would carry on granting underneath, so the refusal is the honest
    # answer rather than a delete that changes nothing.
    it "refuses a handle the deployment ships with" do
      floor = Rubotty::Security::DashboardViewers.new(usernames: %w[shipped])
      allow(Rubotty::Security::DashboardViewers).to receive(:default).and_return(floor)
      shipped_deps = Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500)
      id = db[:dashboard_viewers].insert(adapter: "telegram", handle: "shipped",
                                         granted_at: Time.now, granted_by: "seeded")

      delete "/admin/viewers/#{id}", {},
             { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'b').token}" }

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("ships with the deployment")
      expect(shipped_deps.dashboard_viewers.viewer?(adapter: "telegram", username: "shipped")).to be(true)
      expect(db[:dashboard_viewers].where(id: id).count).to eq(1)
    end
  end

  describe "the request queue" do
    let(:filed) { viewers.request(adapter: "telegram", native_id: "9001", username: "ada", display: "Ada").request }

    it "lists what is open" do
      filed

      get "/admin/viewer-requests", {}, admin

      expect(body["viewer_requests"].map { |row| row["requester_username"] }).to eq(["ada"])
    end

    it "approves, and the requester then reads every community" do
      request_row = filed

      post "/admin/viewer-requests/#{request_row[:id]}/approve", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["request"]["state"]).to eq("approved")
      expect(body["viewer"]["handle"]).to eq("ada")
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
    end

    it "denies, and grants nothing" do
      request_row = filed

      post "/admin/viewer-requests/#{request_row[:id]}/deny", {}, admin

      expect(body["request"]["state"]).to eq("denied")
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: "9001")).to be(false)
    end

    it "answers 422 for a request already decided" do
      request_row = filed
      post "/admin/viewer-requests/#{request_row[:id]}/deny", {}, admin

      post "/admin/viewer-requests/#{request_row[:id]}/approve", {}, admin

      expect(last_response.status).to eq(422)
    end

    it "answers 404 for a request that does not exist" do
      post "/admin/viewer-requests/9999/approve", {}, admin

      expect(last_response.status).to eq(404)
    end
  end

  # The rule these routes exist to keep. A developer key is an operator of one
  # community by another name, and it gets the route-class 403 on every verb.
  describe "a developer key" do
    it "is refused every viewer route, and changes nothing" do
      row = viewers.grant(adapter: "telegram", handle: "ada", native_id: "9001", granted_by: "seeded")
      request_row = viewers.request(adapter: "telegram", native_id: "9002", username: "mole").request
      key = developer

      get "/admin/viewers", {}, key
      expect(last_response.status).to eq(403)

      post "/admin/viewers", { adapter: "telegram", handle: "mole" }, key
      expect(last_response.status).to eq(403)

      delete "/admin/viewers/#{row[:id]}", {}, key
      expect(last_response.status).to eq(403)

      get "/admin/viewer-requests", {}, key
      expect(last_response.status).to eq(403)

      post "/admin/viewer-requests/#{request_row[:id]}/approve", {}, key
      expect(last_response.status).to eq(403)

      post "/admin/viewer-requests/#{request_row[:id]}/deny", {}, key
      expect(last_response.status).to eq(403)

      expect(viewers.viewer?(adapter: "telegram", username: "mole", native_id: "9002")).to be(false)
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
      expect(viewers.find_request(id: request_row[:id])[:state]).to eq("pending")
    end
  end

  describe "no key at all" do
    it "answers 401 rather than doing the work" do
      post "/admin/viewers", adapter: "telegram", handle: "mole"

      expect(last_response.status).to eq(401)
      expect(viewers.granted).to be_empty
    end
  end
end
