# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# What a person is bridged as, over the REST API. Reading it back is the whole
# point: checking whether a name saved used to mean signing into the dashboard
# or waiting for somebody to talk and reading the label off the relay log.
RSpec.describe "Rubotty::Api::App person nicknames", :control_plane do
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
  let(:person) { community.people.first }
  let(:nicknames) { deps.bridged_nicknames }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  # Somebody else in the same community, for the first-come-wins refusal.
  def another_person
    now = Time.now
    models.person.create(community_id: community.id, name: "Rival", created_at: now, updated_at: now)
  end

  describe "GET /communities/:slug/people" do
    it "carries what each person is bridged as, keyed by the platform it is shown on" do
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "Sam")

      get "/communities/sample/people", {}, developer

      expect(last_response.status).to eq(200)
      expect(body["people"].first["nicknames"]).to eq("discord" => "Sam")
    end

    it "carries an empty mapping for somebody who has chosen none" do
      get "/communities/sample/people", {}, developer

      expect(body["people"].first["nicknames"]).to eq({})
    end
  end

  describe "GET /communities/:slug/people/:id" do
    it "answers the same names the list does" do
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "Sam")

      get "/communities/sample/people/#{person.id}", {}, developer

      expect(body["nicknames"]).to eq("discord" => "Sam")
    end
  end

  describe "PUT /communities/:slug/people/:id/nicknames/:adapter" do
    it "saves the name and answers the person, so what saved can be read back" do
      put "/communities/sample/people/#{person.id}/nicknames/discord", { nickname: "Sam" }, developer

      expect(last_response.status).to eq(200)
      expect(body["nicknames"]).to eq("discord" => "Sam")
      expect(nicknames.for_person(community_id: community.id, person_id: person.id)).to eq("discord" => "Sam")
    end

    it "replaces the name held on that platform and leaves the others alone" do
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "Sam")
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "telegram", nickname: "Sammy")

      put "/communities/sample/people/#{person.id}/nicknames/discord", { nickname: "Samuel" }, developer

      expect(body["nicknames"]).to eq("discord" => "Samuel", "telegram" => "Sammy")
    end

    it "refuses a name somebody else already answers to there" do
      nicknames.set(community_id: community.id, person_id: another_person.id, adapter: "discord", nickname: "Sam")

      put "/communities/sample/people/#{person.id}/nicknames/discord", { nickname: "Sam" }, developer

      expect(last_response.status).to eq(422)
      expect(nicknames.for_person(community_id: community.id, person_id: person.id)).to eq({})
    end

    it "refuses a name the chat command would refuse too" do
      put "/communities/sample/people/#{person.id}/nicknames/discord", { nickname: "a" }, developer

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("characters")
    end

    it "refuses a body with no name in it" do
      put "/communities/sample/people/#{person.id}/nicknames/discord", {}, developer

      expect(last_response.status).to eq(400)
    end

    # A YAML 1.2 client (yamlcamel, the Swift client library) writes a plain
    # scalar like "No" unquoted, which is spec-correct for it. Written as a
    # raw string rather than through the dumper, which quotes an ambiguous
    # word defensively and would hide what this spec is about.
    it "keeps a nickname given as an unquoted No, which YAML 1.2 reads as the word" do
      put "/communities/sample/people/#{person.id}/nicknames/discord", "nickname: No\n",
          developer.merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(200)
      expect(body["nicknames"]).to eq("discord" => "No")
    end

    it "400s a nickname given as a real YAML boolean rather than stringifying it" do
      put "/communities/sample/people/#{person.id}/nicknames/discord", "nickname: true\n",
          developer.merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(400)
      expect(body["error"]).to include("YAML boolean")
      expect(nicknames.for_person(community_id: community.id, person_id: person.id)).to eq({})
    end

    it "refuses outright in a community that hands out no names at all" do
      deps.feature_controls.set(community: community, selector: "all", feature: "nickname",
                                key: "who_can_set", value: "nobody")

      put "/communities/sample/people/#{person.id}/nicknames/discord", { nickname: "Sam" }, developer

      expect(last_response.status).to eq(422)
      expect(nicknames.for_person(community_id: community.id, person_id: person.id)).to eq({})
    end

    it "does not reach a person in another community" do
      elsewhere = models.person.create(community_id: other_community.id, name: "Stranger",
                                       created_at: Time.now, updated_at: Time.now)

      put "/communities/sample/people/#{elsewhere.id}/nicknames/discord", { nickname: "Sam" }, developer

      expect(last_response.status).to eq(404)
    end
  end

  describe "DELETE /communities/:slug/people/:id/nicknames/:adapter" do
    it "drops the name held on that platform" do
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "Sam")

      delete "/communities/sample/people/#{person.id}/nicknames/discord", {}, developer

      expect(last_response.status).to eq(204)
      expect(nicknames.for_person(community_id: community.id, person_id: person.id)).to eq({})
    end

    it "answers 404 when they hold none there" do
      delete "/communities/sample/people/#{person.id}/nicknames/discord", {}, developer

      expect(last_response.status).to eq(404)
    end

    it "still works where the community hands out no new names, which is the point of it" do
      nicknames.set(community_id: community.id, person_id: person.id, adapter: "discord", nickname: "Sam")
      deps.feature_controls.set(community: community, selector: "all", feature: "nickname",
                                key: "who_can_set", value: "nobody")

      delete "/communities/sample/people/#{person.id}/nicknames/discord", {}, admin

      expect(last_response.status).to eq(204)
      expect(nicknames.for_person(community_id: community.id, person_id: person.id)).to eq({})
    end
  end
end
