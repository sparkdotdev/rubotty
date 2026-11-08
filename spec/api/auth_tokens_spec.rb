# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Minting, listing and revoking the tokens that hand somebody a role, over the
# REST API. The scope rule is the whole point: a community-scoped token sits on
# the community path where a developer key reaches it, and the deployment-wide
# one sits under /admin/... where the same key is refused.
RSpec.describe "Rubotty::Api::App auth tokens", :control_plane do
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
  let(:tokens) { deps.auth_tokens }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  describe "POST /communities/:slug/auth-tokens" do
    it "mints a viewer token for the community a developer key runs, and shows it once" do
      post "/communities/sample/auth-tokens", { viewer: "true", label: "Ada" }, developer

      expect(last_response.status).to eq(201)
      expect(body["token"]).not_to be_empty
      expect(body["grants"]).to eq("viewer")
      expect(body["community"]).to eq("sample")
    end

    it "takes both roles at once for an administrator key" do
      post "/communities/sample/auth-tokens", { operator: "true", viewer: "true" }, admin

      expect(body["grants"]).to eq("operator and viewer")
    end

    # A developer key is read-write inside one community without being an
    # operator of it, so a token minting a human operator would reach past what
    # the key itself holds.
    it "refuses a developer key the operator half" do
      post "/communities/sample/auth-tokens", { operator: "true" }, developer

      expect(last_response.status).to eq(422)
      expect(body["error"]).to match(/needs an operator/)
      expect(tokens.list(every: true)).to be_empty
    end

    it "refuses a developer key the operator half even alongside a viewer half" do
      post "/communities/sample/auth-tokens", { operator: "true", viewer: "true" }, developer

      expect(last_response.status).to eq(422)
      expect(tokens.list(every: true)).to be_empty
    end

    it "lets an administrator key mint the operator token a developer key cannot" do
      post "/communities/sample/auth-tokens", { operator: "true" }, admin

      expect(last_response.status).to eq(201)
      expect(body["grants"]).to eq("operator")
    end

    it "refuses a token that grants nothing" do
      post "/communities/sample/auth-tokens", { label: "nothing at all" }, developer

      expect(last_response.status).to eq(422)
      expect(body["error"]).to match(/grant something/)
    end

    it "refuses a lifetime past the ceiling" do
      post "/communities/sample/auth-tokens", { viewer: "true", ttl_seconds: 99_999_999 }, developer

      expect(last_response.status).to eq(422)
    end

    # The resource-level scope failure this app answers with 404 rather than
    # 403, so a developer key never learns another community's slug exists.
    it "does not let a developer key mint into a community it does not run" do
      other_community_id

      post "/communities/other-co/auth-tokens", { viewer: "true" }, developer

      expect(last_response.status).to eq(404)
      expect(tokens.list(every: true)).to be_empty
    end

    # The scope is the path's. Nothing sent in the body can widen a token here
    # into the one that reads every community.
    it "cannot be talked into minting the deployment-wide token" do
      post "/communities/sample/auth-tokens", { viewer: "true", community_id: "" }, developer

      expect(body["community"]).to eq("sample")
      expect(tokens.list(community_id: nil)).to be_empty
    end
  end

  describe "POST /admin/auth-tokens" do
    it "mints the deployment-wide token for an administrator key" do
      post "/admin/auth-tokens", { label: "the handover" }, admin

      expect(last_response.status).to eq(201)
      expect(body["token"]).not_to be_empty
      expect(body["grants"]).to eq("viewer of every community")
      expect(body["community"]).to be_nil
    end

    # The rule that stops anybody widening their own reach by writing themselves
    # a token, at the surface a client actually meets.
    it "refuses a developer key outright, whichever community it runs" do
      post "/admin/auth-tokens", { label: "nice try" }, developer

      expect(last_response.status).to eq(403)
      expect(tokens.list(every: true)).to be_empty
    end

    it "defaults the lifetime rather than making a client pick one" do
      post "/admin/auth-tokens", {}, admin

      expect(body["expires_at"]).not_to be_empty
      expect(body["state"]).to eq("live")
    end
  end

  describe "GET the lists" do
    before do
      post "/communities/sample/auth-tokens", { viewer: "true", label: "here" }, developer
      post "/admin/auth-tokens", { label: "everywhere" }, admin
    end

    it "shows a community only its own" do
      get "/communities/sample/auth-tokens", {}, developer

      expect(body["auth_tokens"].map { |row| row["label"] }).to eq(["here"])
    end

    it "shows an administrator every token there is" do
      get "/admin/auth-tokens", {}, admin

      expect(body["auth_tokens"].map { |row| row["label"] }).to contain_exactly("here", "everywhere")
    end

    # The token string is answered exactly once, by the mint route. Only its
    # digest is stored, so no list can hand it back.
    it "never carries the token itself" do
      get "/admin/auth-tokens", {}, admin

      expect(body["auth_tokens"].flat_map(&:keys)).not_to include("token")
    end

    it "refuses the admin list to a developer key" do
      get "/admin/auth-tokens", {}, developer

      expect(last_response.status).to eq(403)
    end
  end

  describe "DELETE an auth token" do
    def mint_here
      post "/communities/sample/auth-tokens", { viewer: "true" }, developer
      body
    end

    it "takes an unused one back" do
      minted = mint_here

      delete "/communities/sample/auth-tokens/#{minted['public_id']}", {}, developer

      expect(last_response.status).to eq(204)
      expect(tokens.state_of(tokens.find(public_id: minted["public_id"], every: true))).to eq("revoked")
    end

    it "answers 404 for a token that is not this community's" do
      post "/admin/auth-tokens", {}, admin
      wide = body

      delete "/communities/sample/auth-tokens/#{wide['public_id']}", {}, developer

      expect(last_response.status).to eq(404)
    end

    it "refuses to rewrite one that has already been used" do
      minted = mint_here
      tokens_service = Rubotty::ControlPlane::AuthTokens.new(models: models, logger: Rubotty::Log.null)
      tokens_service.redeem(token: minted["token"], adapter: "telegram", native_id: "77", username: "ada")

      delete "/communities/sample/auth-tokens/#{minted['public_id']}", {}, developer

      expect(last_response.status).to eq(422)
      expect(body["error"]).to match(/already been redeemed/)
    end

    it "refuses the admin revoke to a developer key" do
      post "/admin/auth-tokens", {}, admin
      wide = body

      delete "/admin/auth-tokens/#{wide['public_id']}", {}, developer

      expect(last_response.status).to eq(403)
    end
  end
end
