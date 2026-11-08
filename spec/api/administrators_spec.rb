# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# The deployment administrator roster, over the REST API. Every route is
# administrator only because this role reaches every community at once.
RSpec.describe "Rubotty::Api::App administrators", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
  let(:administrators) { deps.dashboard_administrators }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  describe "GET /admin/administrators" do
    it "lists the granted rows and the shipped floor apart" do
      administrators.grant(adapter: "telegram", handle: "ada", native_id: "9001", label: "Ada", granted_by: "seeded")

      get "/admin/administrators", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["administrators"].map { |row| row["handle"] }).to eq(["ada"])
      expect(body["administrators"].first["removable"]).to be(true)
      expect(body["baked_in"]).to eq([])
    end
  end

  describe "POST /admin/administrators" do
    it "binds the grant to a native identity and answers the new entry" do
      post "/admin/administrators", { adapter: "telegram", handle: "@Ada", native_id: "9001", label: "Ada" }, admin

      expect(last_response.status).to eq(201)
      expect(body).to include("handle" => "ada", "native_id" => "9001", "requires_regrant" => false)
      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
    end

    it "answers 422 for a platform nothing would ever match on" do
      post "/admin/administrators", { adapter: "carrier-pigeon", handle: "ada" }, admin

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("platforms an administrator can be named on")
    end

    it "answers 422 for a blank handle" do
      post "/admin/administrators", { adapter: "telegram", handle: "  " }, admin

      expect(last_response.status).to eq(422)
    end
  end

  describe "DELETE /admin/administrators/:id" do
    it "takes a granted row back" do
      row = administrators.grant(adapter: "telegram", handle: "ada", native_id: "9001", granted_by: "seeded")

      delete "/admin/administrators/#{row[:id]}", {}, admin

      expect(last_response.status).to eq(204)
      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: "9001")).to be(false)
    end

    it "answers 404 for an id that was never granted" do
      delete "/admin/administrators/9999", {}, admin

      expect(last_response.status).to eq(404)
    end

    it "refuses a handle the deployment ships with" do
      floor = Rubotty::Security::DashboardAdministrators.new(usernames: %w[shipped])
      allow(Rubotty::Security::DashboardAdministrators).to receive(:default).and_return(floor)
      shipped_deps = Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500)
      id = db[:dashboard_administrators].insert(adapter: "telegram", handle: "shipped",
                                                 granted_at: Time.now, granted_by: "seeded")

      delete "/admin/administrators/#{id}", {},
             { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'b').token}" }

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("ships with the deployment")
      expect(shipped_deps.dashboard_administrators.administrator?(adapter: "telegram", username: "shipped")).to be(true)
      expect(db[:dashboard_administrators].where(id: id).count).to eq(1)
    end
  end

  describe "a developer key" do
    it "is refused every administrator route, and changes nothing" do
      row = administrators.grant(adapter: "telegram", handle: "ada", native_id: "9001", granted_by: "seeded")
      key = developer

      get "/admin/administrators", {}, key
      expect(last_response.status).to eq(403)

      post "/admin/administrators", { adapter: "telegram", handle: "mole" }, key
      expect(last_response.status).to eq(403)

      delete "/admin/administrators/#{row[:id]}", {}, key
      expect(last_response.status).to eq(403)

      expect(administrators.administrator?(adapter: "telegram", username: "mole", native_id: "9002")).to be(false)
      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: "9001")).to be(true)
    end
  end

  describe "no key at all" do
    it "answers 401 rather than doing the work" do
      post "/admin/administrators", adapter: "telegram", handle: "mole"

      expect(last_response.status).to eq(401)
      expect(administrators.granted).to be_empty
    end
  end
end
