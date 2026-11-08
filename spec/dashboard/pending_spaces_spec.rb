# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The Onboarding page: accept a pending space as a new community or into an
# existing one, reject it, and clear a soft-blacklisted entry. Administrator-only
# throughout, driven with rack-test over the seeded SAMPLE control plane.
RSpec.describe "Rubotty::Dashboard::App onboarding", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  def login!
    post "/login", secret: secret
  end

  # A pending row created through the same service the dashboard uses, so the routes
  # run against real rows rather than hand-built fixtures.
  def create_pending!(external_id: "-100555", name: "Rando Group", inviter_native_id: "77",
                      inviter_username: "rando")
    deps.pending_spaces.on_join!(
      adapter: :telegram, account: "telegram", external_id: external_id, name: name,
      inviter_native_id: inviter_native_id, inviter_username: inviter_username
    ).row
  end

  describe "GET /onboarding" do
    it "lists a pending space to an administrator, with the accept/reject forms" do
      pending = create_pending!
      login!
      get "/onboarding"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Rando Group")
      expect(last_response.body).to include("/pending/#{pending.id}/approve")
      expect(last_response.body).to include("/pending/#{pending.id}/deny")
    end

    it "lists a denied space so it can be cleared" do
      pending = create_pending!
      deps.pending_spaces.deny(id: pending.id, admin: "test")
      login!
      get "/onboarding"

      expect(last_response.body).to include("Blacklisted spaces")
      expect(last_response.body).to include("/pending/#{pending.id}/clear")
    end

    it "promises a departure for a row that has a timer behind it" do
      create_pending!
      login!
      get "/onboarding"

      expect(last_response.body).not_to include("no timer, waits here until somebody decides")
    end

    # A protected title is pended with no timer, so the old blanket line promised
    # a departure that was never coming.
    it "says there is no timer for a row nothing will ever leave" do
      create_pending!(external_id: "-100556", name: "SECOND Lisbon")
      login!
      get "/onboarding"

      expect(last_response.body).to include("no timer, waits here until somebody decides")
    end

    it "says so when nothing is waiting" do
      login!
      get "/onboarding"
      expect(last_response.body).to include("Nothing is waiting on a decision")
    end

    it "is closed to an operator session" do
      create_pending!
      get "/onboarding", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [])

      expect(last_response.status).to eq(403)
    end
  end

  describe "the home page" do
    it "links an administrator to Onboarding with a count, and lists nothing itself" do
      create_pending!
      login!
      get "/"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("waiting on a decision")
      expect(last_response.body).to include("/onboarding")
      # The queue itself lives on one page, so the index never renders a card.
      expect(last_response.body).not_to include("Rando Group")
    end

    it "never mentions the queue to an operator session" do
      create_pending!
      get "/", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [])

      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("waiting on a decision")
      # The nav item is administrator-only too. Matched as the anchor rather than
      # the bare word, so a page that later mentions onboarding in plain text
      # nearby cannot slip the assertion.
      expect(last_response.body).not_to include(">Onboarding</a>")
    end

    it "shows no banner when there is no pending space" do
      login!
      get "/"
      expect(last_response.body).not_to include("waiting on a decision")
    end
  end

  describe "POST /pending/:id/approve" do
    it "requires an administrator session" do
      pending = create_pending!
      post "/pending/#{pending.id}/approve", { target: "new", new_community_name: "Rando" },
           "rack.session" => dashboard_session(role: "operator", operator_communities: [])

      expect(last_response.status).to eq(403)
      expect(models.pending_space[pending.id].state).to eq("pending")
    end

    it "creates a new community and maps the space, enabling no feature" do
      pending = create_pending!
      login!
      post "/pending/#{pending.id}/approve", target: "new", new_community_name: "Rando Community"

      expect(last_response.status).to eq(302)
      row = models.pending_space[pending.id]
      expect(row.state).to eq("approved")
      community = models.community[row.community_id]
      expect(community.name).to eq("Rando Community")
      connection = models.platform_connection.where(adapter: "telegram", external_id: "-100555").first
      expect(connection.community_id).to eq(community.id)
      expect(models.channel.where(community_id: community.id).count).to eq(0)
      expect(models.room.where(community_id: community.id).count).to eq(0)
    end

    it "attaches to an existing community when asked" do
      pending = create_pending!(external_id: "-777", name: "Second Space")
      login!
      sample = models.community.first
      post "/pending/#{pending.id}/approve", target: "existing", community_id: sample.id.to_s

      expect(last_response.status).to eq(302)
      row = models.pending_space[pending.id]
      expect(row.community_id).to eq(sample.id)
    end

    it "promotes the inviter to operator when asked" do
      pending = create_pending!
      login!
      post "/pending/#{pending.id}/approve", target: "new", new_community_name: "Rando", make_operator: "true"

      community = models.community[models.pending_space[pending.id].community_id]
      identity = models.person_identity.where(adapter: "telegram", native_id: "77").first
      expect(identity).not_to be_nil
      expect(models.operator.where(community_id: community.id, person_id: identity.person_id).first).not_to be_nil
    end

    it "does not promote anyone without the toggle" do
      pending = create_pending!
      login!
      post "/pending/#{pending.id}/approve", target: "new", new_community_name: "Rando"

      community = models.community[models.pending_space[pending.id].community_id]
      expect(models.operator.where(community_id: community.id).count).to eq(0)
    end

    it "404s for an unknown pending id" do
      login!
      post "/pending/999999/approve", target: "new", new_community_name: "Rando"
      expect(last_response.status).to eq(404)
    end

    it "returns to Onboarding by default" do
      pending = create_pending!
      login!
      post "/pending/#{pending.id}/approve", target: "new", new_community_name: "Rando"

      expect(last_response.headers["Location"]).to end_with("/onboarding")
    end

    it "returns to the community page a suggestion was accepted from" do
      pending = create_pending!
      login!
      sample = models.community.where(slug: "sample").first
      post "/pending/#{pending.id}/approve", target: "existing", community_id: sample.id.to_s,
                                             from_community: "sample"

      expect(models.pending_space[pending.id].community_id).to eq(sample.id)
      expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms?state=unroomed")
    end

    it "ignores a from_community that names no community, rather than redirecting to it" do
      pending = create_pending!
      login!
      post "/pending/#{pending.id}/approve", target: "new", new_community_name: "Rando",
                                             from_community: "https://example.invalid/"

      expect(last_response.headers["Location"]).to end_with("/onboarding")
    end
  end

  describe "POST /pending/:id/deny" do
    it "requires an administrator session" do
      pending = create_pending!
      post "/pending/#{pending.id}/deny", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [])

      expect(last_response.status).to eq(403)
      expect(models.pending_space[pending.id].state).to eq("pending")
    end

    it "denies and records the soft-blacklist entry" do
      pending = create_pending!
      login!
      post "/pending/#{pending.id}/deny"

      expect(last_response.status).to eq(302)
      row = models.pending_space[pending.id]
      expect(row.state).to eq("denied")
      expect(row.decided_by).to eq("dashboard:administrator")
    end
  end

  describe "POST /pending/:id/clear" do
    it "requires an administrator session" do
      pending = create_pending!
      deps.pending_spaces.deny(id: pending.id, admin: "test")
      post "/pending/#{pending.id}/clear", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [])

      expect(last_response.status).to eq(403)
      expect(models.pending_space[pending.id]).not_to be_nil
    end

    it "clears a denied entry" do
      pending = create_pending!
      deps.pending_spaces.deny(id: pending.id, admin: "test")
      login!
      post "/pending/#{pending.id}/clear"

      expect(last_response.status).to eq(302)
      expect(models.pending_space[pending.id]).to be_nil
    end
  end
end
