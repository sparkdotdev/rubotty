# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# What a non-operator's topic command named, waiting on a decision. On the
# ordinary community path, matching the discovered-channel routes beside it: the
# same page settles both, and neither reaches past the community in the path.
RSpec.describe "Rubotty::Api::App suggested channels", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:other_community) do
    Rubotty::ControlPlane::Seed.from_model(sample_model, models: models, slug: "other-co")
    models.community.where(slug: "other-co").first
  end
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 500) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  # A channel a topic command named, in whichever community, still flagged.
  def suggest(owner, route_key:, label: "recipes", suggested: true)
    now = Time.now
    models.channel.create(
      community_id: owner.id, platform_connection_id: models.platform_connection.first.id,
      adapter: "telegram", account: "telegram", route_key: route_key,
      endpoint_key: "discovered:telegram:#{route_key}", label: label, suggested: suggested,
      receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
      created_at: now, updated_at: now
    )
  end

  describe "GET /communities/:slug/suggested-channels" do
    it "lists only what is still waiting, with the id the decisions take" do
      waiting = suggest(community, route_key: "-100997")
      suggest(community, route_key: "-100995", label: "settled", suggested: false)

      get "/communities/sample/suggested-channels", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["suggested_channels"].map { |row| row["id"] }).to eq([waiting.id])
      expect(body["suggested_channels"].first["label"]).to eq("recipes")
    end

    it "answers an empty list rather than a 404 when nothing is waiting" do
      get "/communities/sample/suggested-channels", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["suggested_channels"]).to eq([])
    end

    it "does not answer for another community to a developer key" do
      other_community

      get "/communities/other-co/suggested-channels", {}, developer

      expect(last_response.status).to eq(404)
    end
  end

  describe "POST /communities/:slug/suggested-channels/:id/approve" do
    it "stops it being a suggestion and changes nothing else about it" do
      waiting = suggest(community, route_key: "-100997")

      post "/communities/sample/suggested-channels/#{waiting.id}/approve", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["endpoint_key"]).to eq(waiting.endpoint_key)
      expect(body["label"]).to eq("recipes")
      expect(models.channel[waiting.id].suggested).to be_falsey
    end

    it "answers 404 the second time, since the decision has been taken" do
      waiting = suggest(community, route_key: "-100997")
      post "/communities/sample/suggested-channels/#{waiting.id}/approve", {}, developer

      post "/communities/sample/suggested-channels/#{waiting.id}/approve", {}, developer

      expect(last_response.status).to eq(404)
    end

    it "does not reach another community's suggestion" do
      elsewhere = suggest(other_community, route_key: "-100994")

      post "/communities/sample/suggested-channels/#{elsewhere.id}/approve", {}, developer

      expect(last_response.status).to eq(404)
      expect(models.channel[elsewhere.id].suggested).to be_truthy
    end
  end

  describe "POST /communities/:slug/suggested-channels/:id/reject" do
    it "clears the suggested name and keeps the record" do
      waiting = suggest(community, route_key: "-100997")

      post "/communities/sample/suggested-channels/#{waiting.id}/reject", {}, developer

      expect(last_response.status).to eq(204)
      expect(last_response.body).to eq("")
      expect(models.channel[waiting.id].label).to be_nil
      expect(models.channel[waiting.id].suggested).to be(false)
    end

    it "cannot delete a real channel by naming its id" do
      real = community.channels.first

      post "/communities/sample/suggested-channels/#{real.id}/reject", {}, developer

      expect(last_response.status).to eq(404)
      expect(models.channel[real.id]).not_to be_nil
    end

    it "does not reach another community's suggestion" do
      elsewhere = suggest(other_community, route_key: "-100994")

      post "/communities/sample/suggested-channels/#{elsewhere.id}/reject", {}, developer

      expect(last_response.status).to eq(404)
      expect(models.channel[elsewhere.id]).not_to be_nil
    end
  end
end
