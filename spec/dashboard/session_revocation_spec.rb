# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

RSpec.describe "Dashboard session authorization", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:env) { { "DASHBOARD_SECRET" => "fixture-password" } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:identity) { { adapter: "telegram", native_id: "910001", username: "session-fixture" } }

  def sign_in_operator(single_use: false)
    deps.operators.promote(community_id: community.id, **identity, granted_by: "fixture")
    issued = deps.web_login.issue(identity_key: "session-fixture", operator: identity,
                                 communities: [{ id: community.id }], single_use: single_use)
    post "/operator-login", token: issued.token
    issued
  end

  it "removes write permission from an established browser when its operator grant is removed" do
    sign_in_operator
    operator = deps.operators.resolve_operator(community_id: community.id, **identity)
    expect(deps.operators.remove(community_id: community.id, id: operator.id)).to be_removed

    post "/communities/sample/viewers", adapter: "telegram", handle: "ungranted-fixture"

    expect(last_response.status).to eq(403)
    expect(db[:community_viewers].where(handle: "ungranted-fixture").count).to eq(0)
  end

  it "ends an existing browser session when its original login token is revoked" do
    issued = sign_in_operator
    expect(deps.web_login.revoke(id: Rubotty::ControlPlane::WebLoginTokens.digest(issued.token))).to be(true)

    get "/internal/shell", path: "/"

    expect(last_response.status).to eq(401)
    expect(last_request.env["rack.session"][:role]).to be_nil
  end

  it "prevents a revoked administrator from issuing another administrator grant through an old cookie" do
    row = deps.dashboard_administrators.grant(adapter: identity[:adapter], handle: identity[:username],
                                            native_id: identity[:native_id], granted_by: "fixture")
    issued = deps.web_login.issue(identity_key: "administrator-session", operator: identity,
                                 communities: [], administrator: true)
    post "/operator-login", token: issued.token
    expect(last_request.env["rack.session"][:role]).to eq("administrator")
    expect(deps.dashboard_administrators.revoke(id: row[:id], revoked_by: "fixture")).to be_removed
    grants_before = db[:auth_tokens].count

    post "/administrator-tokens", ttl_hours: "1"

    expect(last_response.status).to eq(403)
    expect(db[:auth_tokens].count).to eq(grants_before)
    expect(last_request.env["rack.session"][:role]).to eq("operator")
  end

  it "allows the first single-use login to browse but rejects reuse and explicit revocation" do
    issued = sign_in_operator(single_use: true)
    get "/"
    expect(last_response.status).to eq(200)
    expect(deps.web_login.redeem(token: issued.token)).not_to be_ok
    expect(deps.web_login.revoke(id: Rubotty::ControlPlane::WebLoginTokens.digest(issued.token))).to be(true)

    get "/internal/shell", path: "/"
    expect(last_response.status).to eq(401)
  end

  it "ends an operator browser session at its server-side expiry" do
    issued = sign_in_operator
    allow(Time).to receive(:now).and_return(issued.expires_at + 1)

    get "/internal/shell", path: "/"

    expect(last_response.status).to eq(401)
  end

  it "expires password sessions and binds them to the configured password" do
    now = Time.now
    post "/login", secret: env["DASHBOARD_SECRET"]
    allow(Time).to receive(:now).and_return(now + Rubotty::Dashboard::App::PASSWORD_SESSION_TTL + 1)
    get "/internal/shell", path: "/"
    expect(last_response.status).to eq(401)

    allow(Time).to receive(:now).and_return(now)
    post "/login", secret: env["DASHBOARD_SECRET"]
    app.set :dashboard_env, { "DASHBOARD_SECRET" => "rotated-fixture-password" }
    get "/internal/shell", path: "/"
    expect(last_response.status).to eq(401)
  end

  it "rejects legacy cookies carrying a role without a verifiable login" do
    get "/internal/shell", { path: "/" }, "rack.session" => { role: "administrator" }

    expect(last_response.status).to eq(401)
  end
end
