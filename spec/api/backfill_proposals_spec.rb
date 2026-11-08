# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# The REST surface over a backfill sweep's held-back proposals. Counts travel
# with the list rather than only the single read, because `ours` is the check
# made before accepting one, and a zero there on a long-bridged channel means
# the ownership check has stopped recognising the bridge's own copies.
RSpec.describe "Rubotty::Api::App backfill proposals", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:relay_result) { Rubotty::Dashboard::BotNudge::RelayResult.new(ok: true, error: nil) }
  let(:bot_relay) { instance_double(Rubotty::Dashboard::BotNudge, relay_proposal: relay_result) }
  let(:deps) do
    Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500, bot_relay: bot_relay)
  end
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  # Written directly rather than through a sweep: no adapter is connected in
  # this process to find a gap on.
  def create_proposal(status: "pending", endpoint_id: "dc-general", ours: 40,
                      expires_at: Time.now + 86_400, items: [%w[m1 Alex@discord] + ["hello there"]])
    id = models.backfill_proposal.insert(
      community_id: community.id, endpoint_id: endpoint_id, status: status,
      fetched: 50, gaps: 3, ours: ours, claimed: 7, below_floor: 2,
      swept_since: Time.now - 3600, expires_at: expires_at, created_at: Time.now, updated_at: Time.now
    )
    items.each do |native_id, author_label, preview|
      models.backfill_proposal_item.insert(
        proposal_id: id, native_id: native_id, author_label: author_label, preview: preview,
        sent_at: Time.now - 60, created_at: Time.now
      )
    end
    id
  end

  describe "GET /admin/backfill-proposals" do
    it "lists what is waiting on a decision, with the counts the sweep saw" do
      create_proposal

      get "/admin/backfill-proposals", {}, admin

      expect(last_response.status).to eq(200)
      row = body["backfill_proposals"].first
      expect(row["endpoint_id"]).to eq("dc-general")
      expect(row["status"]).to eq("pending")
      expect(row["community"]).to eq("sample")
      expect(row.values_at("gaps", "ours", "claimed", "below_floor")).to eq([3, 40, 7, 2])
    end

    # The number the whole review exists for. A client that cannot show it
    # cannot be used to decide safely, so it is on the list row itself.
    it "reports a zero ours rather than leaving it off the row" do
      create_proposal(ours: 0)

      get "/admin/backfill-proposals", {}, admin

      expect(body["backfill_proposals"].first).to include("ours" => 0)
    end

    it "defaults to pending and filters by state when asked" do
      create_proposal(endpoint_id: "dc-general")
      create_proposal(endpoint_id: "dc-random", status: "relayed", items: [])

      get "/admin/backfill-proposals", {}, admin
      expect(body["backfill_proposals"].map { |row| row["endpoint_id"] }).to eq(["dc-general"])

      get "/admin/backfill-proposals", { state: "relayed" }, admin
      expect(body["backfill_proposals"].map { |row| row["endpoint_id"] }).to eq(["dc-random"])

      get "/admin/backfill-proposals", { state: "all" }, admin
      expect(body["backfill_proposals"].length).to eq(2)
    end

    it "refuses a state nobody defined rather than quietly listing something else" do
      get "/admin/backfill-proposals", { state: "whatever" }, admin

      expect(last_response.status).to eq(400)
      expect(body["error"]).to include("state must be")
    end

    # Leaving a decision too long has to read as expired, not as a row that
    # silently stopped existing.
    it "moves a proposal past its window out of pending" do
      create_proposal(expires_at: Time.now - 60)

      get "/admin/backfill-proposals", {}, admin
      expect(body["backfill_proposals"]).to be_empty

      get "/admin/backfill-proposals", { state: "expired" }, admin
      expect(body["backfill_proposals"].length).to eq(1)
    end
  end

  describe "GET /admin/backfill-proposals/:id" do
    it "reads one proposal with the messages it would send" do
      id = create_proposal

      get "/admin/backfill-proposals/#{id}", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["backfill_proposal"]["id"]).to eq(id)
      expect(body["items_pruned"]).to be(false)
      expect(body["items"].first).to include("native_id" => "m1", "preview" => "hello there")
    end

    it "answers 404 for a proposal that is not there" do
      get "/admin/backfill-proposals/999999", {}, admin

      expect(last_response.status).to eq(404)
    end

    # A preview lives only while the proposal needs one. An empty list on its
    # own would read as "the sweep was going to send nothing", which is the
    # opposite of what happened.
    it "says the previews were pruned rather than answering an empty list" do
      id = create_proposal
      post "/admin/backfill-proposals/#{id}/reject", {}, admin

      get "/admin/backfill-proposals/#{id}", {}, admin

      expect(body["items"]).to be_empty
      expect(body["items_pruned"]).to be(true)
      expect(body["items_note"]).to include("rejected")
      # The counts survive, so the row can still say what was proposed.
      expect(body["backfill_proposal"]["ours"]).to eq(40)
    end
  end

  describe "POST /admin/backfill-proposals/:id/approve" do
    it "accepts the list and hands it to the bot to relay" do
      id = create_proposal

      post "/admin/backfill-proposals/#{id}/approve", {}, admin

      expect(last_response.status).to eq(200)
      expect(bot_relay).to have_received(:relay_proposal).with(id)
      expect(body["relaying"]).to be(true)
      expect(body["item_count"]).to eq(1)
      expect(body["backfill_proposal"]["status"]).to eq("approved")
      expect(body["backfill_proposal"]["decided_by"]).to start_with("api:")
    end

    # Only the bot process holds the adapters, so an accept it never took has
    # to say so rather than reading as sent.
    it "says plainly when the bot could not be reached" do
      allow(bot_relay).to receive(:relay_proposal)
        .and_return(Rubotty::Dashboard::BotNudge::RelayResult.new(ok: false, error: "could not reach the bot process"))
      id = create_proposal

      post "/admin/backfill-proposals/#{id}/approve", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["relaying"]).to be(false)
      expect(body["errors"]["bot"]).to include("could not reach the bot")
    end

    it "refuses a proposal that is not waiting on a decision, and relays nothing" do
      id = create_proposal(status: "relayed", items: [])

      post "/admin/backfill-proposals/#{id}/approve", {}, admin

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("not waiting for a decision")
      expect(bot_relay).not_to have_received(:relay_proposal)
    end

    it "refuses one that ran out of time while nobody was looking" do
      id = create_proposal(expires_at: Time.now - 60)

      post "/admin/backfill-proposals/#{id}/approve", {}, admin

      expect(last_response.status).to eq(422)
      expect(bot_relay).not_to have_received(:relay_proposal)
    end
  end

  describe "POST /admin/backfill-proposals/:id/reject" do
    it "records the refusal and drops the previews with it" do
      id = create_proposal

      post "/admin/backfill-proposals/#{id}/reject", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["backfill_proposal"]["status"]).to eq("rejected")
      expect(models.backfill_proposal_item.where(proposal_id: id).count).to eq(0)
      expect(bot_relay).not_to have_received(:relay_proposal)
    end

    it "refuses a second decision on a proposal already decided" do
      id = create_proposal
      post "/admin/backfill-proposals/#{id}/reject", {}, admin

      post "/admin/backfill-proposals/#{id}/reject", {}, admin

      expect(last_response.status).to eq(422)
    end
  end

  # Writing the row is not sending anything: this process holds no adapters, so
  # an accept that never reaches the bot is never received. Driven over a real
  # health server on a real socket rather than a double, so the header, the
  # path and the body shape are all proven rather than assumed.
  describe "the handoff to the bot process" do
    let(:secret) { "s3cret" }
    let(:relay_calls) { [] }
    let(:outcome) { Rubotty::Core::BackfillProposalRelay::Outcome.new(ok: true, error: nil) }
    let(:health) do
      Rubotty::Core::HealthServer.new(
        liveness: -> { true }, logger: Rubotty::Log.null, port: 0, reload_secret: secret,
        relay_proposal: ->(proposal_id:) { relay_calls << proposal_id and outcome }
      )
    end
    let(:deps) do
      Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500,
                             bot_url: "http://127.0.0.1:#{health.bound_port}", bot_secret: secret)
    end

    around do |example|
      health.start
      example.run
    ensure
      health.stop
    end

    # The suite refuses real HTTP, and rightly: a spec reaching for the network
    # is a bug. Lifted for these two alone, where the far end is a server this
    # example started on the loopback a line earlier, because a double here
    # would prove the route calls something rather than that the bot hears it.
    before { allow(Net::HTTP).to receive(:start).and_call_original }

    it "makes the bot relay the proposal that was accepted" do
      id = create_proposal

      post "/admin/backfill-proposals/#{id}/approve", {}, admin

      expect(last_response.status).to eq(200)
      expect(relay_calls).to eq([id])
      expect(body["relaying"]).to be(true)
    end

    it "asks the bot for nothing when the decision itself was refused" do
      id = create_proposal(status: "rejected", items: [])

      post "/admin/backfill-proposals/#{id}/approve", {}, admin

      expect(last_response.status).to eq(422)
      expect(relay_calls).to be_empty
    end
  end

  # None of these routes is part of a developer key's addressable world,
  # whichever community it is scoped to, so the refusal is the flat 403 the
  # whole /admin/ path answers with.
  describe "a developer key" do
    it "gets 403 on every one of them" do
      id = create_proposal

      [["get", "/admin/backfill-proposals"],
       ["get", "/admin/backfill-proposals/#{id}"],
       ["post", "/admin/backfill-proposals/#{id}/approve"],
       ["post", "/admin/backfill-proposals/#{id}/reject"]].each do |verb, path|
        public_send(verb, path, {}, developer)

        expect(last_response.status).to eq(403), "#{verb.upcase} #{path} answered #{last_response.status}"
        expect(body["error"]).to eq("administrator scope required")
      end
    end
  end
end
