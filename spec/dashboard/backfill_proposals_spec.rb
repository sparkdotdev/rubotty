# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The backfill proposals page: what a boot-time sweep held back
# instead of sending, listed per channel with the accept/reject/retry
# handoff to the bot process that holds the adapters. Administrator
# only, since judging a proposal means reading what would be sent.
RSpec.describe "Rubotty::Dashboard::App backfill proposals", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }

  let(:relay_result) { Rubotty::Dashboard::BotNudge::RelayResult.new(ok: true, error: nil) }
  let(:bot_nudge) { instance_double(Rubotty::Dashboard::BotNudge, nudge: true, relay_proposal: relay_result) }

  def login!
    post "/login", secret: secret
  end

  def create_proposal(status: "pending", endpoint_id: "dc-general", fetched: 50, gaps: 3, ours: 40,
                      claimed: 7, below_floor: 0, expires_at: Time.now + 86_400,
                      items: [["m1", "Alex@discord", "hello there", Time.now]])
    id = models.backfill_proposal.insert(
      community_id: community.id, endpoint_id: endpoint_id, status: status,
      fetched: fetched, gaps: gaps, ours: ours, claimed: claimed, below_floor: below_floor,
      swept_since: Time.now - 3600, expires_at: expires_at, created_at: Time.now, updated_at: Time.now
    )
    items.each do |native_id, author_label, preview, sent_at|
      models.backfill_proposal_item.insert(
        proposal_id: id, native_id: native_id, author_label: author_label, preview: preview,
        sent_at: sent_at, created_at: Time.now
      )
    end
    id
  end

  describe "unauthenticated" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env, bot_nudge: bot_nudge) }

    it "gates the page behind a session" do
      get "/backfill-proposals"

      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  describe "an administrator session" do
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env, bot_nudge: bot_nudge) }

    before { login! }

    it "lists a pending proposal with the counts the sweep saw" do
      create_proposal(endpoint_id: "dc-general", fetched: 50, gaps: 3, ours: 40, claimed: 7, below_floor: 0)
      get "/backfill-proposals"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("dc-general")
      expect(last_response.body).to include(">50<")
      expect(last_response.body).to include(">40<")
    end

    it "shows the items exactly as stored: author, time and preview" do
      create_proposal(items: [["m1", "Alex@discord", "a very specific preview", Time.utc(2026, 7, 1, 12, 0)]])
      get "/backfill-proposals"

      expect(last_response.body).to include("Alex@discord")
      expect(last_response.body).to include("a very specific preview")
    end

    it "warns loudly when ours is zero, the sign the ownership check is broken" do
      create_proposal(ours: 0)
      get "/backfill-proposals"

      expect(last_response.body).to include("Ours is zero")
    end

    it "does not warn when ours is positive" do
      create_proposal(ours: 40)
      get "/backfill-proposals"

      expect(last_response.body).not_to include("Ours is zero")
    end

    it "shows an expired proposal as expired instead of hiding it" do
      create_proposal(status: "expired", endpoint_id: "dc-media")
      get "/backfill-proposals"

      expect(last_response.body).to include("dc-media")
      expect(last_response.body).to include("Expired")
    end

    it "says so plainly when nothing is waiting" do
      get "/backfill-proposals"

      expect(last_response.body).to include("Nothing is waiting on a decision")
    end

    it "accepts a pending proposal, marks it approved, and asks the bot to relay it" do
      id = create_proposal
      post "/backfill-proposals/#{id}/accept"

      expect(models.backfill_proposal[id: id][:status]).to eq("approved")
      expect(bot_nudge).to have_received(:relay_proposal).with(id)
      follow_redirect!
      expect(last_response.body).to include("The bot is relaying it now")
    end

    it "rejects a pending proposal, marks it rejected, and never asks the bot to relay it" do
      id = create_proposal
      post "/backfill-proposals/#{id}/reject"

      expect(models.backfill_proposal[id: id][:status]).to eq("rejected")
      expect(bot_nudge).not_to have_received(:relay_proposal)
      follow_redirect!
      expect(last_response.body).to include("Rejected")
    end

    it "refuses to accept a proposal whose window has already passed" do
      id = create_proposal(expires_at: Time.now - 1)
      post "/backfill-proposals/#{id}/accept"

      expect(models.backfill_proposal[id: id][:status]).to eq("expired")
      expect(bot_nudge).not_to have_received(:relay_proposal)
      follow_redirect!
      expect(last_response.body).to include("not waiting for a decision")
    end

    it "refuses to reject a proposal whose window has already passed" do
      id = create_proposal(expires_at: Time.now - 1)
      post "/backfill-proposals/#{id}/reject"

      expect(models.backfill_proposal[id: id][:status]).to eq("expired")
    end

    it "surfaces an unreachable bot plainly rather than the page claiming success" do
      allow(bot_nudge).to receive(:relay_proposal).and_return(
        Rubotty::Dashboard::BotNudge::RelayResult.new(ok: false, error: "could not reach the bot process")
      )
      id = create_proposal
      post "/backfill-proposals/#{id}/accept"
      follow_redirect!

      # The decision itself still stuck: approve-by-id is not undone by a failed
      # push, since the bot's own poll or a retry can still pick it up later.
      expect(models.backfill_proposal[id: id][:status]).to eq("approved")
      expect(last_response.body).to include("Could not reach the bot")
    end

    it "keeps an unreachable acceptance visible instead of letting it vanish" do
      allow(bot_nudge).to receive(:relay_proposal).and_return(
        Rubotty::Dashboard::BotNudge::RelayResult.new(ok: false, error: "could not reach the bot process")
      )
      id = create_proposal(endpoint_id: "dc-media")
      post "/backfill-proposals/#{id}/accept"

      get "/backfill-proposals"
      expect(last_response.body).to include("Accepted, not yet confirmed sent")
      expect(last_response.body).to include("dc-media")
    end

    it "retries the relay for a proposal accepted but not yet confirmed sent" do
      id = create_proposal(status: "approved")
      post "/backfill-proposals/#{id}/retry-relay"

      expect(bot_nudge).to have_received(:relay_proposal).with(id)
      follow_redirect!
      expect(last_response.body).to include("Asked the bot to relay it again")
    end

    it "says so for a proposal id that does not exist" do
      post "/backfill-proposals/999999/accept"
      follow_redirect!

      expect(last_response.body).to include("no such proposal")
    end
  end

  describe "a non-administrator session" do
    let(:app) do
      operator_deps = deps
      Class.new(Rubotty::Dashboard::App) do
        set :deps, operator_deps
        helpers do
          define_method(:authenticated?) { true }
          define_method(:current_role) { Rubotty::Dashboard::Role.operator(community_ids: []) }
        end
      end
    end

    it "cannot reach the list, even with no community scope at all" do
      get "/backfill-proposals"

      expect(last_response.status).to eq(403)
    end

    it "cannot accept" do
      id = create_proposal
      post "/backfill-proposals/#{id}/accept"

      expect(last_response.status).to eq(403)
      expect(models.backfill_proposal[id: id][:status]).to eq("pending")
    end

    it "cannot reject" do
      id = create_proposal
      post "/backfill-proposals/#{id}/reject"

      expect(last_response.status).to eq(403)
      expect(models.backfill_proposal[id: id][:status]).to eq("pending")
    end

    it "cannot retry a relay" do
      id = create_proposal(status: "approved")
      post "/backfill-proposals/#{id}/retry-relay"

      expect(last_response.status).to eq(403)
    end
  end
end
