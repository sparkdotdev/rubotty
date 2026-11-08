# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Who may moderate a community, over the REST API. The read is on the ordinary
# community path, since it tells a developer key nothing about a community it
# does not already reach. Granting and revoking are under /admin/, because
# deciding who runs a community is not the same thing as reading who does.
RSpec.describe "Rubotty::Api::App operators", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other_community) do
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    models.community.where(slug: "other-co").first
  end
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  describe "GET /communities/:slug/operators" do
    it "reports the deployment-configured owners, which used to be missing entirely" do
      get "/communities/sample/operators", {}, developer

      expect(last_response.status).to eq(200)
      baked = body["operators"].select { |entry| entry["baked_in"] }
      expect(baked).not_to be_empty
      expect(baked.map { |entry| entry["handle"] })
        .to match_array(Rubotty::Security::ProtectedOperators.default.entries.map { |entry| entry[:handle] })
    end

    it "answers a non-empty list for a community with no granted rows at all" do
      models.operator.where(community_id: community.id).delete

      get "/communities/sample/operators", {}, developer

      expect(body["operators"]).not_to be_empty
      expect(body["operators"]).to all(include("baked_in" => true))
    end

    it "says of every entry whether the revoke route can touch it" do
      get "/communities/sample/operators", {}, developer

      granted = body["operators"].reject { |entry| entry["baked_in"] }
      expect(granted).not_to be_empty
      expect(granted).to all(include("removable" => true))
      expect(body["operators"].select { |entry| entry["baked_in"] }).to all(include("removable" => false))
    end

    it "lists the shipped owners before the granted rows" do
      get "/communities/sample/operators", {}, developer

      marks = body["operators"].map { |entry| entry["baked_in"] }
      expect(marks).to eq(marks.sort_by { |baked| baked ? 0 : 1 })
    end

    it "does not answer for another community to a developer key" do
      other_community

      get "/communities/other-co/operators", {}, developer

      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /admin/communities/:slug/operators" do
    it "promotes a platform account nobody has a record for yet" do
      post "/admin/communities/sample/operators",
           { adapter: "telegram", native_id: "7788", username: "deputy", display: "Deputy" }, admin

      expect(last_response.status).to eq(201)
      expect(body["baked_in"]).to be(false)
      expect(body["removable"]).to be(true)
      expect(body["person"]).to eq("Deputy")
      expect(models.operator.where(community_id: community.id).count).to eq(2)
    end

    it "keeps the record somebody already has rather than writing a second" do
      post "/admin/communities/sample/operators", { adapter: "telegram", native_id: "7788" }, admin
      first = body["id"]
      post "/admin/communities/sample/operators", { adapter: "telegram", native_id: "7788" }, admin

      expect(last_response.status).to eq(201)
      expect(body["id"]).to eq(first)
      expect(models.operator.where(community_id: community.id).count).to eq(2)
    end

    it "refuses a body that names no account" do
      post "/admin/communities/sample/operators", { adapter: "telegram" }, admin

      expect(last_response.status).to eq(400)
    end

    it "refuses a developer key on the route itself, whichever community it names" do
      post "/admin/communities/sample/operators", { adapter: "telegram", native_id: "7788" }, developer

      expect(last_response.status).to eq(403)
      expect(models.operator.where(community_id: community.id).count).to eq(1)
    end
  end

  describe "DELETE /admin/communities/:slug/operators/:id" do
    def granted
      post "/admin/communities/sample/operators", { adapter: "telegram", native_id: "7788" }, admin
      body["id"]
    end

    it "removes a granted record" do
      id = granted

      delete "/admin/communities/sample/operators/#{id}", {}, admin

      expect(last_response.status).to eq(204)
      expect(models.operator[id]).to be_nil
    end

    it "refuses somebody the shipped floor also names, which no delete could really revoke" do
      seeded_operator = models.operator.where(community_id: community.id).first

      delete "/admin/communities/sample/operators/#{seeded_operator.id}", {}, admin

      expect(last_response.status).to eq(422)
      expect(models.operator[seeded_operator.id]).not_to be_nil
    end

    it "answers 404 for an id this community has no record under" do
      delete "/admin/communities/sample/operators/9999", {}, admin

      expect(last_response.status).to eq(404)
    end

    it "does not reach another community's record" do
      other_community
      post "/admin/communities/other-co/operators", { adapter: "telegram", native_id: "7788" }, admin
      elsewhere = body["id"]

      delete "/admin/communities/sample/operators/#{elsewhere}", {}, admin

      expect(last_response.status).to eq(404)
      expect(models.operator[elsewhere]).not_to be_nil
    end

    it "refuses a developer key on the route itself" do
      id = granted

      delete "/admin/communities/sample/operators/#{id}", {}, developer

      expect(last_response.status).to eq(403)
      expect(models.operator[id]).not_to be_nil
    end
  end
end
