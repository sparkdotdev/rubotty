# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# Minting a token on the dashboard: the deployment-wide one on the Viewers page,
# the community-scoped one on that community's Operators page. Who may mint what
# follows the role the session already holds, which is what stops anybody
# writing themselves a token bigger than they are.
RSpec.describe "Rubotty::Dashboard::App auth tokens", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other) do
    id = Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    models.community[id]
  end
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:tokens) { deps.auth_tokens }

  # An operator of one community, which is the session the scope rule is about.
  let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

  def sign_in_admin = post("/login", secret: secret)

  describe "as an administrator" do
    before { sign_in_admin }

    it "mints a deployment-wide token and shows it exactly once" do
      post "/auth-tokens", label: "the handover", ttl_hours: "6"

      follow_redirect!
      expect(last_response.body).to include("shown once")
      minted = tokens.list(community_id: nil).first
      expect(minted[:label]).to eq("the handover")
      expect(minted[:expires_at].to_time).to be_within(60).of(Time.now + (6 * 3600))
    end

    it "does not show the token again on a reload" do
      post "/auth-tokens", label: "the handover"
      follow_redirect!
      shown = last_response.body[%r{<code>([A-Za-z0-9_-]{20,})</code>}, 1]

      get "/viewers"

      expect(shown).not_to be_nil
      expect(last_response.body).not_to include(shown)
    end

    it "mints a community-scoped token from that community's page" do
      post "/communities/sample/auth-tokens", operator: "1", label: "Ada"

      expect(last_response.status).to eq(302)
      minted = tokens.list(community_id: community.id).first
      expect(tokens.grant_words(minted)).to eq("operator")
    end

    it "refuses a community token that grants neither role, and says why" do
      post "/communities/sample/auth-tokens", label: "nothing at all"

      follow_redirect!
      expect(last_response.body).to include("grant something")
      expect(tokens.list(every: true)).to be_empty
    end

    it "revokes a token that has not been used" do
      minted = mint_for(community)

      post "/communities/sample/auth-tokens/#{minted.row[:public_id]}/revoke"

      follow_redirect!
      expect(last_response.body).to include("no longer works")
    end

    it "says so rather than pretending when the token has already been used" do
      minted = mint_for(community)
      redeem(minted.token)

      post "/communities/sample/auth-tokens/#{minted.row[:public_id]}/revoke"

      follow_redirect!
      expect(last_response.body).to include("already been used")
    end

    it "lists a spent token with who spent it" do
      minted = mint_for(community)
      redeem(minted.token)

      get "/communities/sample/operators"

      expect(last_response.body).to include("spent")
      expect(last_response.body).to include("used by ada")
    end
  end

  # The rule the whole feature turns on, at the surface an operator meets.
  describe "as an operator of one community" do
    def as_operator(verb, path, params = {})
      public_send(verb, path, params, "rack.session" => operator_session)
    end

    it "mints a token for the community it runs" do
      as_operator(:post, "/communities/sample/auth-tokens", { viewer: "1" })

      expect(last_response.status).to eq(302)
      expect(tokens.list(community_id: community.id).size).to eq(1)
    end

    it "cannot mint the deployment-wide token" do
      as_operator(:post, "/auth-tokens", { label: "nice try" })

      expect(last_response.status).to eq(403)
      expect(tokens.list(every: true)).to be_empty
    end

    it "cannot mint into a community it does not run" do
      other

      as_operator(:post, "/communities/other-co/auth-tokens", { operator: "1" })

      expect(last_response.status).to eq(403)
      expect(tokens.list(every: true)).to be_empty
    end

    it "cannot revoke a token in a community it does not run" do
      minted = mint_for(other)

      as_operator(:post, "/communities/other-co/auth-tokens/#{minted.row[:public_id]}/revoke")

      expect(last_response.status).to eq(403)
      expect(tokens.state_of(tokens.find(public_id: minted.row[:public_id], every: true))).to eq("live")
    end
  end

  def mint_for(row)
    minter = Rubotty::ControlPlane::AuthTokens::Minter.new(
      administrator: true, community_ids: [], label: "spec"
    )
    tokens.mint(minter: minter, community_id: row.id, viewer: true, label: "Ada")
  end

  # Redeeming happens in a DM to the bot, so the dashboard's own service is not
  # wired to apply a grant; a service built here is what spends the token.
  def redeem(token)
    Rubotty::ControlPlane::AuthTokens.new(models: models, logger: Rubotty::Log.null)
                                     .redeem(token: token, adapter: "telegram", native_id: "77",
                                             username: "ada")
  end
end
