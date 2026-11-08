# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The web half of the bot-DM to dashboard login handoff:
# `/operator-login?token=` and the admin view over outstanding tokens.
# Two steps: the GET draws a confirmation and spends nothing, the POST
# redeems, so a link preview fetching the GET never spends the link.
RSpec.describe "Rubotty::Dashboard::App operator login", :control_plane do
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

  def community_hash(row)
    { id: row.id, slug: row.slug, name: row.name }
  end

  # feature_settings is room-scoped, so the community-wide default row a selector
  # "all" write lands on is the one with a NULL room_id.
  def feature_row(comm, feature:)
    models.feature_setting.where(community_id: comm.id, room_id: nil, feature: feature).first
  end

  def enabled?(row)
    [true, 1, "1", "t", "true"].include?(row&.enabled)
  end

  def grant_operator!(comm, native_id: "80000012")
    deps.operators.promote(community_id: comm.id, adapter: "telegram", native_id: native_id, granted_by: "seeded")
  end

  def issue_token(identity_key: "telegram:telegram:80000012", communities: [community_hash(community)], native_id: "80000012")
    communities.each { |entry| grant_operator!(models.community[entry[:id] || entry["id"]], native_id: native_id) }
    deps.web_login.issue(
      identity_key: identity_key,
      operator: { adapter: "telegram", account: "telegram", native_id: native_id, label: "Alex" },
      communities: communities
    )
  end

  # The link in a DM. It draws the confirmation and must leave the token
  # exactly as it found it.
  describe "GET /operator-login" do
    it "draws a confirmation naming who it would sign in and when it stops working" do
      token = issue_token.token

      get "/operator-login", token: token

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Sign in as Alex?")
      expect(last_response.body).to include("stops working at")
    end

    it "establishes no session on its own" do
      token = issue_token.token

      get "/operator-login", token: token

      expect(last_request.env["rack.session"][:role]).to be_nil
    end

    it "names the administrator scope a link would open" do
      token = deps.web_login.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" },
        communities: [], administrator: true
      ).token

      get "/operator-login", token: token

      expect(last_response.body).to include("opens administrator control of the whole deployment")
    end

    it "names a deployment-wide viewer link's scope" do
      token = deps.web_login.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" },
        communities: [], viewer: true
      ).token

      get "/operator-login", token: token

      expect(last_response.body).to include("opens read access to every community")
    end

    # What a platform's link preview does. It has to leave a single-use token
    # spendable, or a preview would sign nobody in and burn the link.
    it "spends nothing, so a single-use token still works afterwards" do
      issued = deps.web_login.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" },
        communities: [community_hash(community)], single_use: true
      )

      get "/operator-login", token: issued.token
      get "/operator-login", token: issued.token
      post "/operator-login", token: issued.token

      expect(last_request.env["rack.session"][:role]).to eq("operator")
    end

    it "bounces a token that will not work, saying nothing about why" do
      get "/operator-login", token: "not-a-real-token"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/")
      expect(last_request.env["rack.session"][:role]).to be_nil
    end
  end

  describe "POST /operator-login" do
    it "establishes an operator session scoped to the token's communities" do
      token = issue_token.token

      post "/operator-login", token: token

      session = last_request.env["rack.session"]
      expect(session[:role]).to eq("operator")
      expect(session[:operator_communities]).to eq([community.id])
    end

    it "carries the token's operator label onto the session, for the audit trail to name" do
      token = issue_token.token

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:operator_handle]).to eq("Alex")
    end

    it "names the redeemed operator, not just the role, on a write that session makes" do
      observe_dashboard_identity(handle: "ada", community_id: community.id)
      token = issue_token.token
      post "/operator-login", token: token

      post "/communities/#{community.slug}/viewers", adapter: "telegram", handle: "@ada"

      row = deps.community_viewers.granted(community_id: community.id).first
      expect(row[:granted_by]).to eq("dashboard:Alex")
    end

    it "scopes the session to every community a multi-community token grants" do
      second = models.community.create(slug: "second", name: "Second", status: "active",
                                       settings: "{}", created_at: Time.now, updated_at: Time.now)
      token = issue_token(communities: [community_hash(community), community_hash(second)]).token

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:operator_communities]).to contain_exactly(community.id, second.id)
    end

    # The route writes the same session key current_role reads
    # (+:operator_communities+). If it wrote any other key the operator would be
    # logged in but scoped to nothing, and both writes below would 403.
    it "scopes write-own end-to-end: a redeemed operator writes to a granted community, not a non-granted one" do
      ungranted = models.community.create(slug: "ungranted", name: "Ungranted", status: "active",
                                          settings: "{}", created_at: Time.now, updated_at: Time.now)
      # The token grants only sample, never the ungranted community.
      token = issue_token(communities: [community_hash(community)]).token

      # Scoping alone is not sufficient, so the grant is handed over first; without
      # it both writes 403 and nothing about scoping is proved.
      deps.action_permissions.update({ "configure_word_filter" => "1", "toggle_word_filter" => "1" })

      post "/operator-login", token: token
      expect(last_request.env["rack.session"][:operator_communities]).to eq([community.id])

      # The operated community accepts the write, so current_role carried sample's id.
      post "/communities/#{community.slug}/word-filter", selector: "all", op: "enable"
      expect(last_response.status).to eq(302)
      expect(enabled?(feature_row(community, feature: "word_filter"))).to be(true)

      # A community the token never granted is refused, and nothing is written.
      post "/communities/#{ungranted.slug}/word-filter", selector: "all", op: "enable"
      expect(last_response.status).to eq(403)
      expect(enabled?(feature_row(ungranted, feature: "word_filter"))).to be(false)
    end

    it "drops a community an operator lost after the link was issued" do
      native_id = "24681357"
      token = issue_token(identity_key: "telegram:telegram:#{native_id}", native_id: native_id).token
      row = deps.operators.resolve_operator(community_id: community.id, adapter: "telegram", native_id: native_id)
      deps.operators.remove(community_id: community.id, id: row.id)

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:operator_communities]).to eq([])
    end

    it "leaves a revoked deployment-wide viewer claim out of the session" do
      row = deps.dashboard_viewers.grant(adapter: "telegram", handle: "alex", native_id: "80000012", granted_by: "seeded")
      token = deps.web_login.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", username: "alex", label: "Alex" },
        communities: [], viewer: true
      ).token
      deps.dashboard_viewers.revoke(id: row[:id], revoked_by: "seeded")

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:viewer]).to be(false)
    end

    it "leaves a revoked community viewer claim out of the session" do
      row = deps.community_viewers.grant(community_id: community.id, adapter: "telegram", handle: "alex", native_id: "80000012", granted_by: "seeded")
      token = deps.web_login.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", username: "alex", label: "Alex" },
        communities: [], viewer_communities: [community.id]
      ).token
      deps.community_viewers.revoke(community_id: community.id, id: row[:id], revoked_by: "seeded")

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:viewer_communities]).to eq([])
    end

    it "redirects to the bare dashboard root, with the token nowhere in it" do
      token = issue_token.token

      post "/operator-login", token: token

      expect(last_response.status).to eq(302)
      location = last_response.headers["location"]
      expect(location).to end_with("/")
      expect(location).not_to include("token")
      expect(location).not_to include(token)
    end

    it "establishes no session for an unknown token, and still strips it from the redirect" do
      post "/operator-login", token: "not-a-real-token"

      expect(last_request.env["rack.session"][:role]).to be_nil
      location = last_response.headers["location"]
      expect(location).to end_with("/")
      expect(location).not_to include("token")

      # No session, so the next request bounces to /login.
      get "/"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    it "clears an existing session when the token cannot be redeemed" do
      login!
      expect(last_request.env["rack.session"][:role]).to eq("administrator")

      post "/operator-login", token: "not-a-real-token"

      expect(last_request.env["rack.session"][:role]).to be_nil
      get "/"
      expect(last_response.headers["location"]).to end_with("/login")
    end

    it "rejects a blank token" do
      post "/operator-login"

      expect(last_request.env["rack.session"][:role]).to be_nil
      expect(last_response.status).to eq(302)
    end

    it "rejects an expired token" do
      # A second WebLoginTokens over the SAME connection deps.web_login reads, with a
      # negative ttl, so the row is already expired when anything reads it back and no
      # clock has to be travelled.
      store = Rubotty::Storage::SequelStore.new(db: db).tap(&:migrate!)
      expired = Rubotty::ControlPlane::WebLoginTokens.new(store: store, ttl: -10)
      token = expired.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" },
        communities: [community_hash(community)]
      ).token

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:role]).to be_nil
    end

    # An ordinary `web-login` token carries no single-use flag, so redeeming it
    # leaves it live for the rest of its TTL.
    it "is repeatable: a second redemption of the same token re-authenticates" do
      token = issue_token.token

      post "/operator-login", token: token
      expect(last_request.env["rack.session"][:role]).to eq("operator")

      post "/logout"
      expect(last_request.env["rack.session"][:role]).to be_nil

      post "/operator-login", token: token
      expect(last_request.env["rack.session"][:role]).to eq("operator")
    end
  end

  describe "operator token administration" do
    it "gates the list behind an administrator session" do
      get "/operator-tokens"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    context "when signed in as an administrator" do
      before { login! }

      it "lists an active token with its operator and communities" do
        issue_token
        get "/operator-tokens"

        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Alex")
        expect(last_response.body).to include("sample")
      end

      it "still shows a redeemed token, since redeeming it does not end it" do
        outcome = issue_token
        deps.web_login.redeem(token: outcome.token)

        get "/operator-tokens"
        expect(last_response.body).to include("Alex")
      end

      it "revokes an active token by its listed id, invalidating it" do
        outcome = issue_token
        id = deps.web_login.active_tokens.first[:id]

        post "/operator-tokens/#{id}/revoke"
        expect(last_response.status).to eq(302)
        expect(last_response.headers["location"]).to end_with("/operator-tokens")

        expect(deps.web_login.redeem(token: outcome.token).ok?).to be(false)

        get "/operator-tokens"
        expect(last_response.body).not_to include("Alex")
      end

      it "flashes an error revoking an unknown id, changing nothing" do
        post "/operator-tokens/does-not-exist/revoke"
        expect(last_response.status).to eq(302)

        follow_redirect!
        expect(last_response.body).to match(/no such active login link/i)
      end
    end
  end
end
