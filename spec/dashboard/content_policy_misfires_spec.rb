# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The page a policy gets tuned from. What matters here is that the four things
# a tuning pass needs are all on it, and that the message text it carries is
# reachable only by somebody who may read the community.
RSpec.describe "Rubotty::Dashboard::App policy misfires", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.first }

  def sign_in = post("/login", secret: secret)

  def add_misfire(**overrides)
    now = Time.now
    models.content_policy_misfire.create(
      **{ community_id: community.id, adapter: "telegram", endpoint_id: "tg-general",
          policy: "Potentially offensive language", action: "flag_notify",
          body: "this whole process is bullshit", reasoning: "Uses a vulgarity",
          confidence: 0.61, statement: "ordinary venting, aimed at nobody",
          reversed_by: "telegram:mel", acted_at: now - 60, created_at: now }.merge(overrides)
    )
  end

  before { sign_in }

  it "shows the four things a tuning pass needs, on one row" do
    add_misfire
    get "/communities/#{community.slug}/content-policy/misfires"

    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("this whole process is bullshit")
    expect(last_response.body).to include("Uses a vulgarity")
    expect(last_response.body).to include("ordinary venting, aimed at nobody")
    expect(last_response.body).to include("0.61")
  end

  it "counts them per policy, so the description worth rewriting is obvious" do
    add_misfire
    add_misfire
    add_misfire(policy: "Racially insensitive language")
    get "/communities/#{community.slug}/content-policy/misfires"

    expect(last_response.body).to include("Which description is drawing them")
    expect(last_response.body).to include("Potentially offensive language")
  end

  it "says so plainly when nothing has been reversed yet" do
    get "/communities/#{community.slug}/content-policy/misfires"

    expect(last_response.body).to include("/vindicate")
    expect(last_response.body).not_to include("Which description is drawing them")
  end

  it "names the ceiling the samples lapse on, read off the store's own constant" do
    get "/communities/#{community.slug}/content-policy/misfires"

    expect(last_response.body)
      .to include(Rubotty::ControlPlane::ContentPolicyMisfires::MAX_WINDOW_DAYS.to_s)
  end

  it "drops one sample on request" do
    row = add_misfire
    post "/communities/#{community.slug}/content-policy/misfires/#{row.id}/delete"

    follow_redirect!
    expect(last_response.body).not_to include("this whole process is bullshit")
  end

  it "carries message text, so a signed-out reader never reaches it" do
    add_misfire
    clear_cookies
    get "/communities/#{community.slug}/content-policy/misfires"

    expect(last_response.status).to be_between(302, 403)
    expect(last_response.body).not_to include("this whole process is bullshit")
  end

  it "is reachable from the navigation rather than only by typing the path" do
    get "/communities/#{community.slug}"

    expect(last_response.body).to include("content-policy/misfires")
  end
end
