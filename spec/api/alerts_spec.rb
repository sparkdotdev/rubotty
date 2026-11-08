# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# What a community's scripts raised for its operators, over the API. Alone in the
# scripting family these are reachable with a developer key; script source and the
# hosts a script may call stay behind /admin/.
RSpec.describe "Rubotty::Api::App alerts", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  let(:other) do
    now = Time.now
    models.community.create(slug: "other-co", name: "Other Co", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  def raise_alert(community_id: community.id, **rest)
    deps.alerts.record(community_id: community_id, text: "somebody is posting airdrop links",
                       mode: "quiet", room_key: "general", script: "guard", **rest)
  end

  describe "GET /communities/:slug/alerts" do
    it "lists what the scripts raised, newest first" do
      raise_alert(text: "the older one")
      raise_alert(text: "the newer one")

      get "/communities/sample/alerts", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["alerts"].map { |row| row["text"] }).to eq(["the newer one", "the older one"])
    end

    # The count a monitor polls covers the whole outstanding set rather than this page.
    it "counts what is still unseen alongside the list" do
      3.times { |n| raise_alert(text: "alert #{n}") }
      deps.alerts.mark_seen(id: deps.alerts.recent(community_id: community.id).first.id,
                            community_id: community.id)

      get "/communities/sample/alerts", {}, admin

      expect(body["unseen"]).to eq(2)
    end

    it "says how far a loud alert actually got" do
      raise_alert(mode: "loud")

      get "/communities/sample/alerts", {}, admin

      expect(body["alerts"].first["mode"]).to eq("loud")
      expect(body["alerts"].first["delivered_to"]).to eq(0)
    end

    # Not behind /admin/, so a developer key reads its own community's alerts.
    it "answers a developer key for its own community" do
      raise_alert

      get "/communities/sample/alerts", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["alerts"].length).to eq(1)
    end

    it "never carries another community's alerts" do
      raise_alert(community_id: other.id, text: "not yours")
      raise_alert(text: "yours")

      get "/communities/sample/alerts", {}, admin

      expect(body["alerts"].map { |row| row["text"] }).to eq(["yours"])
    end

    # 404 rather than 403, since a 403 would confirm the other community exists.
    it "404s a developer key naming another community" do
      raise_alert(community_id: other.id)

      get "/communities/other-co/alerts", {}, developer

      expect(last_response.status).to eq(404)
      expect(body["error"]).to eq("not found")
    end
  end

  describe "POST /communities/:slug/alerts/:id/seen" do
    it "marks one and answers with it" do
      row = raise_alert

      post "/communities/sample/alerts/#{row.id}/seen", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["seen_at"]).not_to be_nil
      expect(deps.alerts.unseen_count(community_id: community.id)).to eq(0)
    end

    # The state the caller asked for already holds, and the original timestamp stays
    # put, since when it was first read is the fact worth having.
    it "leaves an already-seen alert alone and still answers 200" do
      row = raise_alert
      post "/communities/sample/alerts/#{row.id}/seen", {}, admin
      first_seen = body["seen_at"]

      post "/communities/sample/alerts/#{row.id}/seen", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["seen_at"]).to eq(first_seen)
    end

    it "404s an id that does not exist" do
      post "/communities/sample/alerts/9999/seen", {}, admin

      expect(last_response.status).to eq(404)
    end

    # Scoped in the query, so another community's id is not found rather than refused.
    it "404s another community's alert id, naming either community" do
      theirs = raise_alert(community_id: other.id)

      post "/communities/sample/alerts/#{theirs.id}/seen", {}, admin
      expect(last_response.status).to eq(404)

      post "/communities/other-co/alerts/#{theirs.id}/seen", {}, developer
      expect(last_response.status).to eq(404)
    end

    it "leaves the other community's alert unseen" do
      theirs = raise_alert(community_id: other.id)

      post "/communities/sample/alerts/#{theirs.id}/seen", {}, admin

      expect(theirs.refresh.seen_at).to be_nil
    end
  end

  describe "POST /communities/:slug/alerts/seen" do
    it "clears the whole backlog and says how many it cleared" do
      3.times { |n| raise_alert(text: "alert #{n}") }

      post "/communities/sample/alerts/seen", {}, developer

      expect(body["marked"]).to eq(3)
      expect(deps.alerts.unseen_count(community_id: community.id)).to eq(0)
    end

    it "answers zero when there was nothing outstanding" do
      post "/communities/sample/alerts/seen", {}, admin

      expect(body["marked"]).to eq(0)
    end

    it "never touches another community's backlog" do
      theirs = raise_alert(community_id: other.id)
      raise_alert

      post "/communities/sample/alerts/seen", {}, admin

      expect(theirs.refresh.seen_at).to be_nil
    end
  end
end
