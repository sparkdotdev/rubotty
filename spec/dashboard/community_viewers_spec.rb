# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The community-scoped viewer: reads one community, changes nothing in it, and
# an operator of that community can hand it out. That last rule is the
# load-bearing one, and its other half is that the deployment-wide dimension
# stays administrator-only, because it reads every OTHER community too.
RSpec.describe "Rubotty::Dashboard::App community viewers", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other_community_id) do
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
  end
  let(:other_community) { models.community[other_community_id] }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:viewers) { deps.community_viewers }

  # An operator of sample and nothing else.
  let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

  # Somebody who READS sample and operates nothing anywhere.
  let(:community_viewer_session) do
    dashboard_session(role: "operator", operator_communities: [], viewer_communities: [community.id])
  end

  before { observe_dashboard_identity(handle: "ada") }

  def sign_in_admin = post("/login", secret: secret)

  def grant_row(handle: "ada", in_community: community)
    viewers.grant(community_id: in_community.id, adapter: "telegram", handle: handle, native_id: dashboard_native_id(handle), granted_by: "seeded")
  end

  def filed(in_community: community)
    viewers.request(community_id: in_community.id, adapter: "telegram",
                    native_id: dashboard_native_id("ada"), username: "ada").request
  end

  describe "as an operator of the community" do
    # The form has to be somewhere the operator who may use it can reach, and
    # that is this page.
    it "opens the Operators page and finds the grant form live on it" do
      get "/communities/sample/operators", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Viewers of this community")
      expect(last_response.body).to include(%(action="/communities/sample/viewers"))
      expect(last_response.body).not_to include("What operators may change")
    end

    it "grants a viewer of the community it operates" do
      post "/communities/sample/viewers", { adapter: "telegram", handle: "@Ada" },
           "rack.session" => operator_session

      expect(last_response.status).to eq(302)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "revokes one it granted" do
      row = grant_row

      post "/communities/sample/viewers/#{row[:id]}/revoke", {}, "rack.session" => operator_session

      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end

    it "approves a pending request" do
      request_row = filed

      post "/communities/sample/viewer-requests/#{request_row[:id]}/approve", {},
           "rack.session" => operator_session

      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)
    end

    it "denies a pending request and grants nothing" do
      request_row = filed

      post "/communities/sample/viewer-requests/#{request_row[:id]}/deny", {},
           "rack.session" => operator_session

      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
      expect(viewers.find_request(community_id: community.id, id: request_row[:id])[:state]).to eq("denied")
    end

    # The reach it hands out is its own reach, and no further.
    it "cannot grant one in a community it does not operate" do
      other_community

      post "/communities/other-co/viewers", { adapter: "telegram", handle: "mole" },
           "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(viewers.viewer?(community_id: other_community.id, adapter: "telegram",
                             username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    # THE rule. Reading every community is a bigger ask than operating one, so
    # an operator can never hand it out.
    it "cannot grant the deployment-wide viewer" do
      post "/viewers", { adapter: "telegram", handle: "mole" }, "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(deps.dashboard_viewers.viewer?(adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    it "cannot approve a deployment-wide viewer request either" do
      request_row = deps.dashboard_viewers.request(adapter: "telegram", native_id: dashboard_native_id("ada"),
                                                   username: "ada").request

      post "/viewer-requests/#{request_row[:id]}/approve", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(deps.dashboard_viewers.viewer?(adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end
  end

  describe "as an administrator" do
    before { sign_in_admin }

    it "lists the community's viewers on its Operators page, with the grant form" do
      grant_row

      get "/communities/sample/operators"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Viewers of this community")
      expect(last_response.body).to include("ada")
    end

    it "grants and revokes there too" do
      post "/communities/sample/viewers", adapter: "telegram", handle: "ada"
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(true)

      row = viewers.granted(community_id: community.id).first
      post "/communities/sample/viewers/#{row[:id]}/revoke"
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "ada", native_id: dashboard_native_id("ada"))).to be(false)
    end

    it "flashes a refusal rather than a 500 for a platform nothing would match on" do
      post "/communities/sample/viewers", adapter: "carrier-pigeon", handle: "ada"
      follow_redirect!

      expect(last_response.body).to include("platforms a viewer can be named on")
      expect(viewers.granted(community_id: community.id)).to be_empty
    end

    # The shipped list reads every community, so it is the floor here as well.
    it "cannot revoke a handle the deployment ships with" do
      floor = Rubotty::Security::DashboardViewers.new(usernames: ["shipped"])
      allow(Rubotty::Security::DashboardViewers).to receive(:default).and_return(floor)
      shipped_deps = Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null)
      id = db[:community_viewers].insert(community_id: community.id, adapter: "telegram",
                                         handle: "shipped", granted_at: Time.now, granted_by: "seeded")

      shipped_app = Rubotty::Dashboard::App.assemble(deps: shipped_deps, env: env)
      session = Rack::Test::Session.new(Rack::MockSession.new(shipped_app))
      session.post("/login", secret: secret)
      session.post("/communities/sample/viewers/#{id}/revoke")
      session.follow_redirect!

      expect(session.last_response.body).to include("cannot be revoked from here")
      expect(db[:community_viewers].where(id: id).count).to eq(1)
    end
  end

  # What the grant actually buys: this community, read-only, and nothing of any
  # other community at all.
  describe "as a viewer of one community" do
    def visit(path)
      get path, {}, "rack.session" => community_viewer_session
    end

    it "reads the community it was granted" do
      visit "/communities/sample"

      expect(last_response.status).to eq(200)
    end

    %w[features moderation people alerts webhooks analytics audit].each do |section|
      it "reads #{section} in that community" do
        visit "/communities/sample/#{section}"

        expect(last_response.status).to eq(200)
      end
    end

    # The administration screens a plain operator is refused: oversight of the
    # one community it reads.
    %w[platforms rooms operators endpoints].each do |section|
      it "reads the #{section} screen of that community" do
        visit "/communities/sample/#{section}"

        expect(last_response.status).to eq(200)
      end
    end

    it "cannot read another community at all" do
      other_community

      visit "/communities/other-co"
      expect(last_response.body).to include("not an operator of this community")

      visit "/communities/other-co/operators"
      expect(last_response.status).to eq(403)
    end

    it "is not offered the deployment-wide Viewers page" do
      visit "/"

      expect(last_response.body).not_to include(">Viewers<")
    end

    it "is refused the deployment-wide Viewers page itself" do
      visit "/viewers"

      expect(last_response.status).to eq(403)
    end

    # Reading is not a licence to hand the same reading to anybody else.
    it "cannot grant a viewer of the community it reads" do
      post "/communities/sample/viewers", { adapter: "telegram", handle: "mole" },
           "rack.session" => community_viewer_session

      expect(last_response.status).to eq(403)
      expect(viewers.viewer?(community_id: community.id, adapter: "telegram", username: "mole", native_id: dashboard_native_id("mole"))).to be(false)
    end

    it "is refused every write in the community it reads" do
      writes = [
        ["/communities/sample/features", { feature: "faq", op: "enable" }],
        ["/communities/sample/start", {}],
        ["/communities/sample/rooms", { room_key: "new-room" }],
        ["/communities/sample/viewers", { adapter: "telegram", handle: "mole" }]
      ]
      writes.each do |path, params|
        post path, params, "rack.session" => community_viewer_session
        expect(last_response.status).to eq(403), "expected #{path} to be refused"
      end
    end

    # Disabled rather than absent, so a reader sees what they would be changing.
    it "sees the save buttons drawn flat and unclickable" do
      visit "/communities/sample/operators"

      expect(last_response.body).to include("Read only: you cannot change this here.")
    end
  end
end
