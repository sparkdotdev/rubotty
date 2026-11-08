# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The operator's polls page: list every open poll and scheduling session and
# cancel one, driven with rack-test over the seeded SAMPLE control plane through
# the SAME Rubotty::Polls::Lifecycle the /poll and /schedule "cancel" reply
# already goes through.
RSpec.describe "Rubotty::Dashboard::App polls", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  def login! = post("/login", secret: secret)

  def open_poll(kind: Rubotty::Polls::Poll::KIND_POLL, question: "Which map?",
                options: [{ label: "Dust II" }, { label: "Inferno" }])
    deps.polls.open(community: community, room: room, kind: kind, question: question, options: options)
  end

  describe "unauthenticated" do
    it "gates the polls page behind a session" do
      get "/communities/sample/polls"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end
  end

  context "as an administrator session" do
    before { login! }

    describe "GET /communities/:slug/polls" do
      it "says so when there are no open polls" do
        get "/communities/sample/polls"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("No open polls.")
      end

      it "lists an open poll, tagged as a poll" do
        open_poll
        get "/communities/sample/polls"
        expect(last_response.body).to include("Which map?")
        expect(last_response.body).to include("Poll")
      end

      it "lists an open scheduling session, tagged as scheduling" do
        open_poll(kind: Rubotty::Polls::Poll::KIND_SCHEDULE, question: "Raid night",
                  options: [{ label: "Tue 7pm" }, { label: "Wed 7pm" }])
        get "/communities/sample/polls"
        expect(last_response.body).to include("Raid night")
        expect(last_response.body).to include("Scheduling")
      end

      it "does not list a poll that has already closed" do
        poll = open_poll
        deps.polls.close(poll: poll)
        get "/communities/sample/polls"
        expect(last_response.body).to include("No open polls.")
        expect(last_response.body).not_to include("Which map?")
      end
    end

    describe "POST /communities/:slug/polls/:id/cancel" do
      it "cancels through Polls::Lifecycle, which also withdraws the armed close job" do
        poll = open_poll
        deps.poll_lifecycle.announce(poll)
        expect(db[:scheduled_jobs].where(kind: "poll_close", status: "pending").count).to eq(1)

        post "/communities/sample/polls/#{poll.id}/cancel"

        expect(models.poll[poll.id].status).to eq("closed")
        # A raw ControlPlane::Polls#close would have flipped the status and left
        # this job armed; going through Lifecycle#close is what withdraws it too.
        expect(db[:scheduled_jobs].where(kind: "poll_close", status: "pending").count).to eq(0)
        follow_redirect!
        expect(last_response.body).to include("Poll cancelled.")
      end

      it "stops the poll from taking any further votes or options once cancelled" do
        poll = open_poll
        post "/communities/sample/polls/#{poll.id}/cancel"

        reloaded = deps.polls.by_id(poll.id)
        expect(reloaded).to be_closed
        # The same guard every vote-accepting surface (reaction and reply) checks
        # before it ever reaches the ballot.
        expect(reloaded).not_to be_open
        expect { deps.polls.add_option(poll: reloaded, label: "Nuke") }
          .to raise_error(Rubotty::ControlPlane::Polls::Invalid, /already closed/)
      end

      it "reports no such poll for an unknown id" do
        post "/communities/sample/polls/999999/cancel"
        follow_redirect!
        expect(last_response.body).to include("No such poll")
      end
    end
  end

  # An operator session may manage polls only for a community it is granted.
  context "an operator-role stub" do
    let(:other_community_id) do
      Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    end
    let(:other_community) { models.community[other_community_id] }

    let(:app) do
      operator_deps = deps
      operator_community_id = community.id
      Class.new(Rubotty::Dashboard::App) do
        set :deps, operator_deps
        helpers do
          define_method(:authenticated?) { true }
          define_method(:current_role) do
            # An operator starts with no write grants, so the one these examples
            # exercise is handed over explicitly.
            Rubotty::Dashboard::Role.operator(community_ids: [operator_community_id],
                                              write_actions: %i[configure_poll])
          end
        end
      end
    end

    it "reaches the polls page for the community it operates" do
      get "/communities/sample/polls"
      expect(last_response.status).to eq(200)
    end

    it "is denied the polls page for a community it does not operate" do
      get "/communities/#{other_community.slug}/polls"
      expect(last_response.status).to eq(403)
    end

    it "cancels a poll inside its own community" do
      poll = open_poll
      post "/communities/sample/polls/#{poll.id}/cancel"
      expect(last_response.status).to eq(302)
      expect(models.poll[poll.id].status).to eq("closed")
    end

    it "is denied cancelling a poll for a community it does not operate" do
      post "/communities/#{other_community.slug}/polls/1/cancel"
      expect(last_response.status).to eq(403)
    end
  end
end
