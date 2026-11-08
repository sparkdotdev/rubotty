# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Viewers page: who reads every community, handed out and taken back without
# a deploy. Administrator only on every route, which is the load-bearing rule
# here, because the dimension spans the whole deployment.
RSpec.describe "Rubotty::Dashboard::App viewers", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:viewers) { deps.dashboard_viewers }

  # An operator of one community. The whole point of the rule is that this
  # session cannot widen itself into oversight of the others.
  let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

  # Somebody who already reads every community. Reading everything is not a
  # licence to hand the same reach to anybody else.
  let(:viewer_session) { dashboard_session(role: "operator", operator_communities: [], viewer: true) }

  before { observe_dashboard_identity(handle: "ada") }

  def sign_in_admin = post("/login", secret: secret)

  def shell_document(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    JSON.parse(source)
  end

  def grant_row(handle: "ada", adapter: "telegram")
    viewers.grant(adapter: adapter, handle: handle, native_id: dashboard_native_id(handle), granted_by: "seeded")
  end

  # A shipped-list entry standing over a row, which is what "deployment-configured" means on
  # this page.
  def with_shipped(handle)
    floor = Rubotty::Security::DashboardViewers.new(usernames: [handle])
    allow(Rubotty::Security::DashboardViewers).to receive(:default).and_return(floor)
    Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null)
  end

  describe "as an administrator" do
    before { sign_in_admin }

    it "reaches the page" do
      get "/viewers"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Viewers")
    end

    it "grants viewer status by handle" do
      post "/viewers", adapter: "telegram", handle: "@Ada", label: "Ada Lovelace"

      expect(last_response.status).to eq(302)
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "revokes a granted row" do
      row = grant_row

      post "/viewers/#{row[:id]}/revoke"

      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end

    it "flashes a refusal rather than a 500 for a platform nothing would match on" do
      post "/viewers", adapter: "carrier-pigeon", handle: "ada"
      follow_redirect!

      expect(last_response.body).to include("platforms a viewer can be named on")
      expect(viewers.granted).to be_empty
    end

    it "lists a granted handle on the page" do
      grant_row

      get "/viewers"

      expect(last_response.body).to include("ada")
    end

    it "approves a pending request, and the requester then reads every community" do
      filed = viewers.request(adapter: "telegram", native_id: dashboard_native_id("ada"), username: "ada", display: "Ada").request

      post "/viewer-requests/#{filed[:id]}/approve"

      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
      expect(viewers.find_request(id: filed[:id])[:state]).to eq("approved")
    end

    it "denies a pending request and grants nothing" do
      filed = viewers.request(adapter: "telegram", native_id: dashboard_native_id("ada"), username: "ada").request

      post "/viewer-requests/#{filed[:id]}/deny"

      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
      expect(viewers.find_request(id: filed[:id])[:state]).to eq("denied")
    end

    it "shows every grant and revocation on the page" do
      row = grant_row
      post "/viewers/#{row[:id]}/revoke"

      get "/viewers"

      expect(last_response.body).to include("viewer_granted")
      expect(last_response.body).to include("viewer_revoked")
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
      get "/viewers"

      expect(last_response.body).to include("deployment-configured")
      expect(last_response.body).to include("protected, cannot be removed")
    end

    it "cannot be revoked through the dashboard" do
      id = db[:dashboard_viewers].insert(adapter: "telegram", handle: "shipped",
                                         granted_at: Time.now, granted_by: "seeded")

      post "/viewers/#{id}/revoke"
      follow_redirect!

      expect(last_response.body).to include("cannot be revoked from here")
      expect(shipped_deps.dashboard_viewers.viewer?(adapter: "telegram", username: "shipped")).to be(true)
      expect(db[:dashboard_viewers].where(id: id).count).to eq(1)
    end

    it "cannot be granted a second time as a removable row" do
      post "/viewers", adapter: "telegram", handle: "shipped"
      follow_redirect!

      expect(last_response.body).to include("shipped list")
    end
  end

  # The rule the whole page exists to keep: viewer spans every community, so
  # nobody below an administrator hands it out.
  describe "as anybody but an administrator" do
    let(:granted) { grant_row }
    let(:filed) { viewers.request(adapter: "telegram", native_id: dashboard_native_id("ada"), username: "ada").request }

    def refused(session, verb, path, params = {})
      public_send(verb, path, params, "rack.session" => session)
      expect(last_response.status).to eq(403)
    end

    it "refuses an operator of a community the page itself" do
      refused(operator_session, :get, "/viewers")
    end

    it "refuses an operator of a community the grant" do
      refused(operator_session, :post, "/viewers", { adapter: "telegram", handle: "mole" })

      expect(viewers.viewer?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    it "refuses an operator of a community the revoke" do
      row = granted

      refused(operator_session, :post, "/viewers/#{row[:id]}/revoke")

      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "refuses an operator of a community the approval" do
      request_row = filed

      refused(operator_session, :post, "/viewer-requests/#{request_row[:id]}/approve")

      expect(viewers.find_request(id: request_row[:id])[:state]).to eq("pending")
      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end

    it "refuses an operator of a community the denial" do
      request_row = filed

      refused(operator_session, :post, "/viewer-requests/#{request_row[:id]}/deny")

      expect(viewers.find_request(id: request_row[:id])[:state]).to eq("pending")
    end

    it "refuses an existing viewer the grant" do
      refused(viewer_session, :post, "/viewers", { adapter: "telegram", handle: "mole" })

      expect(viewers.viewer?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    it "refuses an existing viewer the revoke" do
      row = granted

      refused(viewer_session, :post, "/viewers/#{row[:id]}/revoke")

      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "refuses an existing viewer the approval" do
      request_row = filed

      refused(viewer_session, :post, "/viewer-requests/#{request_row[:id]}/approve")

      expect(viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end

    it "sends somebody with no session to the login page" do
      post "/viewers", adapter: "telegram", handle: "mole"

      expect(last_response.status).to eq(302)
      expect(last_response.location).to end_with("/login")
      expect(viewers.viewer?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end
  end

  describe "the navigation" do
    it "offers the page to an administrator" do
      sign_in_admin
      get "/"

      items = shell_document.fetch("scopes").first.fetch("groups").flat_map { |group| group.fetch("items") }
      expect(items).to include(include("key" => "viewers"))
    end

    it "offers it to nobody else, so nobody is sent to a 403" do
      get "/", {}, "rack.session" => viewer_session

      items = shell_document.fetch("scopes").first.fetch("groups").flat_map { |group| group.fetch("items") }
      expect(items).not_to include(include("key" => "viewers"))
    end
  end
end
