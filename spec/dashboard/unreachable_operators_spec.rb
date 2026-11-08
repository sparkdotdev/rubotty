# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "yamlcamel"

# An operator a DM cannot reach still reads as an operator everywhere, so the
# audience an alert has looks bigger than the one it gets. This is the page
# that says otherwise.
RSpec.describe "Rubotty::Dashboard::App unreachable operators", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }
  let(:operator) { models.operator.where(community_id: community.id).first }

  def refuse_the_telegram_operator(reason: "chat not found")
    identity = models.person_identity.where(person_id: operator.person_id, adapter: "telegram").first
    deps.operator_reachability.refused(identity.id, reason)
    identity
  end

  before { post("/login", secret: secret) }

  it "says nothing while every operator can be reached" do
    get "/communities/sample/operators"

    expect(last_response.status).to eq(200)
    expect(last_response.body).not_to include("Operators nothing can reach")
  end

  it "names the operator, the platform and the reason once a DM is refused" do
    identity = refuse_the_telegram_operator

    get "/communities/sample/operators"

    expect(last_response.body).to include("Operators nothing can reach")
    expect(last_response.body).to include(identity.native_id)
    expect(last_response.body).to include("chat not found")
    expect(last_response.body).to include("/start")
  end

  it "drops the operator off the list again once a DM lands" do
    identity = refuse_the_telegram_operator
    deps.operator_reachability.delivered(identity.id)

    get "/communities/sample/operators"

    expect(last_response.body).not_to include("Operators nothing can reach")
  end

  # The themed sections read this rather than the staged ERB body, so the
  # warning has to be in both or it is invisible to everybody on a theme.
  it "carries the same list on the internal surface a themed section reads" do
    refuse_the_telegram_operator

    get "/internal/communities/sample/operators"

    rows = YAMLCamel.load(last_response.body)["unreachable"]
    expect(rows.length).to eq(1)
    expect(rows.first["adapter"]).to eq("telegram")
    expect(rows.first["reason"]).to eq("chat not found")
  end
end
