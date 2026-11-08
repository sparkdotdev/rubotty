# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

RSpec.describe "API content-policy misfires", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:token) { deps.api_keys.issue(scope: "developer", community: community, label: "misfire fixture").token }
  let(:auth) { { "HTTP_AUTHORIZATION" => "Bearer #{token}" } }
  let(:now) { Time.utc(2026, 11, 5, 12) }
  let(:other) do
    models.community.create(slug: "other-co", name: "Other Co", status: "active", settings: "{}",
                            created_at: now, updated_at: now)
  end

  def sample(community_id: community.id, **attributes)
    models.content_policy_misfire.create(
      **{ community_id: community_id, kind: "false_positive", policy: "Room language", action: "flag_notify",
          adapter: "telegram", endpoint_id: "tg-general", body: "ordinary venting",
          reasoning: "mistook frustration for a personal attack", confidence: 0.75,
          statement: "aimed at nobody", reversed_by: "telegram:operator", context: nil,
          acted_at: now - 60, created_at: now }.merge(attributes)
    )
  end

  def response_body = YAMLCamel.load(last_response.body)

  it "returns the judged text and structured context with separate action and reversal times" do
    context = { "recent_messages" => [{ "author" => "member 1", "text" => "a delayed appointment" }] }
    row = sample(context: JSON.generate(context))

    get "/communities/sample/content-policy/misfires", {}, auth

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to start_with("application/yaml")
    expect(response_body.fetch("misfires")).to eq([
      { "id" => row.id, "kind" => "false_positive", "policy" => "Room language", "action" => "flag_notify",
        "adapter" => "telegram", "endpoint_id" => "tg-general", "body" => "ordinary venting",
        "reasoning" => "mistook frustration for a personal attack", "confidence" => 0.75,
        "statement" => "aimed at nobody", "context" => context, "reversed_by" => "telegram:operator",
        "acted_at" => (now - 60).to_s, "created_at" => now.to_s }
    ])
  end

  it "keeps legacy and damaged context readable without dropping the sample or exposing raw JSON" do
    legacy = sample
    damaged = sample(context: "{incomplete", created_at: now + 1)

    get "/communities/sample/content-policy/misfires", {}, auth

    expect(last_response.status).to eq(200)
    rows = response_body.fetch("misfires")
    expect(rows.map { |row| row.fetch("id") }).to eq([damaged.id, legacy.id])
    expect(rows.map { |row| row.fetch("context") }).to eq([nil, nil])
    expect(rows.map { |row| row.fetch("body") }).to eq(["ordinary venting", "ordinary venting"])
    expect(last_response.body).not_to include("{incomplete")
  end

  it "lists only this community's samples and honors the requested page size" do
    sample(community_id: other.id, body: "private other-community sample", created_at: now + 2)
    sample(body: "older")
    newest = sample(body: "newest", created_at: now + 1)

    get "/communities/sample/content-policy/misfires", { limit: 1 }, auth

    expect(last_response.status).to eq(200)
    expect(response_body.fetch("misfires").map { |row| row.fetch("id") }).to eq([newest.id])
    expect(last_response.body).not_to include("private other-community sample")
  end

  it "does not disclose whether a different community's corpus exists" do
    sample(community_id: other.id)

    get "/communities/other-co/content-policy/misfires", {}, auth
    hidden = [last_response.status, response_body]
    get "/communities/unknown/content-policy/misfires", {}, auth

    expect(hidden).to eq([404, { "error" => "not found" }])
    expect([last_response.status, response_body]).to eq(hidden)
  end

  it "deletes only an owned sample and returns the same missing result for another community's id" do
    own = sample
    theirs = sample(community_id: other.id)

    delete "/communities/sample/content-policy/misfires/#{theirs.id}", {}, auth
    expect(last_response.status).to eq(404)
    expect(response_body).to eq("error" => "not found")
    expect(models.content_policy_misfire[theirs.id]).not_to be_nil

    delete "/communities/sample/content-policy/misfires/#{own.id}", {}, auth
    expect(last_response.status).to eq(204)
    expect(last_response.body).to be_empty
    expect(models.content_policy_misfire[own.id]).to be_nil

    delete "/communities/sample/content-policy/misfires/#{own.id}", {}, auth
    expect(last_response.status).to eq(404)
    expect(response_body).to eq("error" => "not found")
  end
end
