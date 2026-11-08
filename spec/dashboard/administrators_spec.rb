# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "json"

# The Administrators page: who holds total control of this deployment, handed out
# and taken back without a deploy, and the sign-in link that goes with it.
# Administrator only on every route, which is the load-bearing rule, because
# anybody who could reach it could hand themselves everything.
RSpec.describe "Rubotty::Dashboard::App administrators", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:administrators) { deps.dashboard_administrators }

  # An operator of one community. The whole point of the rule is that this
  # session cannot widen itself into the deployment.
  let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

  # Somebody who already reads every community. Reading everything is not a
  # licence to start changing it.
  let(:viewer_session) { dashboard_session(role: "operator", operator_communities: [], viewer: true) }

  before { observe_dashboard_identity(handle: "ada") }

  def sign_in_admin = post("/login", secret: secret)

  def shell_navigation_labels(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    JSON.parse(source).fetch("scopes").flat_map do |scope|
      scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("label") }
    end
  end

  def grant_row(handle: "ada", adapter: "telegram")
    administrators.grant(adapter: adapter, handle: handle, native_id: dashboard_native_id(handle), granted_by: "seeded")
  end

  # A shipped-list entry standing over a row, which is what "protected" means on
  # this page.
  def with_shipped(handle)
    floor = Rubotty::Security::DashboardAdministrators.new(usernames: [handle])
    allow(Rubotty::Security::DashboardAdministrators).to receive(:default).and_return(floor)
    Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null)
  end

  describe "as an administrator" do
    before { sign_in_admin }

    it "reaches the page" do
      get "/administrators"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Administrators")
    end

    it "grants the role by handle" do
      post "/administrators", adapter: "telegram", handle: "@Ada", label: "Ada Lovelace"

      expect(last_response.status).to eq(302)
      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "never grants on the display name it was given" do
      post "/administrators", adapter: "telegram", handle: "ada", label: "Ada Lovelace"

      expect(administrators.administrator?(adapter: "telegram", username: "adalovelace", native_id: dashboard_native_id("adalovelace"))).to be(false)
    end

    it "revokes a granted row" do
      row = grant_row

      post "/administrators/#{row[:id]}/revoke"

      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end

    it "flashes a refusal rather than a 500 for a platform nothing would match on" do
      post "/administrators", adapter: "carrier-pigeon", handle: "ada"
      follow_redirect!

      expect(last_response.body).to include("platforms an administrator can be named on")
      expect(administrators.granted).to be_empty
    end

    it "lists a granted handle on the page" do
      grant_row

      get "/administrators"

      expect(last_response.body).to include("ada")
    end

    it "shows every grant and revocation on the page" do
      row = grant_row
      post "/administrators/#{row[:id]}/revoke"

      get "/administrators"

      expect(last_response.body).to include("administrator_granted")
      expect(last_response.body).to include("administrator_revoked")
    end

    it "mints a token that hands the role over, and shows it exactly once" do
      post "/administrator-tokens", label: "the handover", ttl_hours: "2"
      follow_redirect!

      expect(last_response.body).to include("shown once")
      minted = deps.auth_tokens.list(community_id: nil).first
      expect(deps.auth_tokens.administrator_token?(minted)).to be(true)
      expect(deps.auth_tokens.grant_words(minted)).to include("administrator")
    end

    it "does not show a minted token again on a reload" do
      post "/administrator-tokens", label: "the handover"
      follow_redirect!
      shown = last_response.body[%r{<pre[^>]*>([A-Za-z0-9_-]{20,})</pre>}, 1]

      get "/administrators"

      expect(shown).not_to be_nil
      expect(last_response.body).not_to include(shown)
    end

    it "revokes a token it minted" do
      post "/administrator-tokens", label: "the handover"
      minted = deps.auth_tokens.list(community_id: nil).first

      post "/administrator-tokens/#{minted[:public_id]}/revoke"

      expect(deps.auth_tokens.live?(deps.auth_tokens.find(public_id: minted[:public_id], every: true)))
        .to be(false)
    end

    # The two deployment-wide pages hand out different roles, so neither lists
    # the other's tokens as though it could take them back.
    it "keeps its token list apart from the viewer page's" do
      post "/administrator-tokens", label: "deployment-handover"
      post "/auth-tokens", label: "oversight-handover"

      get "/viewers"
      expect(last_response.body).to include("oversight-handover")
      expect(last_response.body).not_to include("deployment-handover")

      get "/administrators"
      expect(last_response.body).to include("deployment-handover")
      expect(last_response.body).not_to include("oversight-handover")
    end
  end

  # The shipped list is the floor. A row sitting over one of its handles is
  # shown, and the revoke it offers is refused, because deleting the row would
  # read as a revocation while the floor kept granting underneath.
  describe "a handle the deployment ships with" do
    let(:shipped_deps) { with_shipped("shipped") }
    let(:app) { Rubotty::Dashboard::App.assemble(deps: shipped_deps, env: env) }

    before { sign_in_admin }

    it "renders as not removable" do
      get "/administrators"

      expect(last_response.body).to include("Protected")
    end

    it "cannot be revoked through the dashboard" do
      id = db[:dashboard_administrators].insert(adapter: "telegram", handle: "shipped",
                                                granted_at: Time.now, granted_by: "seeded")

      post "/administrators/#{id}/revoke"
      follow_redirect!

      expect(last_response.body).to include("cannot be revoked from here")
      expect(shipped_deps.dashboard_administrators.administrator?(adapter: "telegram", username: "shipped"))
        .to be(true)
      expect(db[:dashboard_administrators].where(id: id).count).to eq(1)
    end

    it "cannot be granted a second time as a removable row" do
      post "/administrators", adapter: "telegram", handle: "shipped"
      follow_redirect!

      expect(last_response.body).to include("shipped list")
    end
  end

  # The rule the whole page exists to keep. Administrator is everything, so
  # nobody below an administrator hands it out, the same rule viewer keeps and
  # for the stronger version of the same reason.
  describe "as anybody but an administrator" do
    let(:granted) { grant_row }

    def refused(session, verb, path, params = {})
      public_send(verb, path, params, "rack.session" => session)
      expect(last_response.status).to eq(403)
    end

    it "refuses an operator of a community the page itself" do
      refused(operator_session, :get, "/administrators")
    end

    it "refuses an operator of a community the grant" do
      refused(operator_session, :post, "/administrators", { adapter: "telegram", handle: "mole" })

      expect(administrators.administrator?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    it "refuses an operator of a community the revoke" do
      row = granted

      refused(operator_session, :post, "/administrators/#{row[:id]}/revoke")

      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    # The token is the grant taken in advance, so the mint is gated exactly as
    # the grant is.
    it "refuses an operator of a community the token that would hand it over" do
      refused(operator_session, :post, "/administrator-tokens", { label: "for me" })

      expect(deps.auth_tokens.list(community_id: nil)).to be_empty
    end

    it "refuses an existing viewer the grant" do
      refused(viewer_session, :post, "/administrators", { adapter: "telegram", handle: "mole" })

      expect(administrators.administrator?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    it "refuses an existing viewer the revoke" do
      row = granted

      refused(viewer_session, :post, "/administrators/#{row[:id]}/revoke")

      expect(administrators.administrator?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "refuses an existing viewer the page" do
      refused(viewer_session, :get, "/administrators")
    end

    it "sends somebody with no session to the login page" do
      post "/administrators", adapter: "telegram", handle: "mole"

      expect(last_response.status).to eq(302)
      expect(last_response.location).to end_with("/login")
      expect(administrators.administrator?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end
  end

  # The sign-in link. The token carries a claim from when it was minted; the
  # roster is the authority at the moment it is used.
  describe "a web-login link claiming the administrator role" do
    def issue(administrator: true, username: "ada", native_id: dashboard_native_id(username))
      deps.web_login.issue(
        identity_key: "telegram:telegram:#{username}",
        operator: { adapter: "telegram", account: "telegram", native_id: native_id,
                    username: username, label: "Ada" },
        communities: [], administrator: administrator
      )
    end

    it "opens an administrator session for somebody still on the roster" do
      grant_row
      token = issue.token

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:role]).to eq("administrator")
    end

    it "opens nothing more than an operator session once the row is revoked" do
      row = grant_row
      token = issue.token
      administrators.revoke(id: row[:id], revoked_by: "admin")

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:role]).to eq("operator")
    end

    it "leaves a revoked administrator refused at the page they used to reach" do
      row = grant_row
      token = issue.token
      administrators.revoke(id: row[:id], revoked_by: "admin")
      post "/operator-login", token: token

      get "/administrators"

      expect(last_response.status).to eq(403)
    end

    # A token that simply asserts the role for a handle nobody granted is the
    # same case, and it has to answer the same way.
    it "opens no administrator session for a handle that was never granted" do
      token = issue(username: "stranger").token

      post "/operator-login", token: token

      expect(last_request.env["rack.session"][:role]).to eq("operator")
    end

    it "gives an administrator's link a shorter life than an ordinary one" do
      grant_row
      outcome = issue

      expect(outcome.expires_at)
        .to be_within(5).of(Time.now + Rubotty::ControlPlane::WebLoginTokens::ADMINISTRATOR_TTL)
      expect(Rubotty::ControlPlane::WebLoginTokens::ADMINISTRATOR_TTL)
        .to be < Rubotty::ControlPlane::WebLoginTokens::DEFAULT_TTL
    end
  end

  describe "the navigation" do
    it "offers the page to an administrator" do
      sign_in_admin
      get "/"

      expect(shell_navigation_labels).to include("Administrators")
    end

    it "offers it to nobody else, so nobody is sent to a 403" do
      get "/", {}, "rack.session" => viewer_session

      expect(shell_navigation_labels).not_to include("Administrators")
    end
  end
end
