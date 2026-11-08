# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

RSpec.describe "the fixed dashboard appearance", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:env) do
    { "DASHBOARD_SECRET" => secret, "DASHBOARD_THEME" => "code-monkey",
      "DASHBOARD_SWATCH" => "forest", "DASHBOARD_CHART_ENGINE" => "rough-viz" }
  end
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  def expect_fixed_appearance(prefix = "")
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("#{prefix}/dashboard.css", "#{prefix}/swatch-clay.css",
                                        "#{prefix}/dashboard-runtime.js", "#{prefix}/chart-engine.js")
    expect(last_response.body).not_to include("code-monkey", "forest", "rough-viz", "settings/theme")
  end

  before { post "/login", secret: secret }

  it "renders login and authenticated pages with the fixed assets despite obsolete environment settings" do
    post "/logout"
    get "/login"
    expect_fixed_appearance
    post "/login", secret: secret
    get "/communities/sample"
    expect_fixed_appearance
  end

  it "ignores saved legacy choices and leaves existing datastore rows untouched" do
    db[:dashboard_appearances].insert(name: "default", theme: "command-centre", swatch: "harbour",
                                     chart_style: "rough-viz", created_at: Time.now, updated_at: Time.now)
    original = db[:dashboard_appearances].all
    get "/communities/sample/analytics"
    expect_fixed_appearance
    expect(last_response.body).to include("rb-chart")
    expect(db[:dashboard_appearances].all).to eq(original)
  end

  it "works under a mounted dashboard path" do
    get "/", {}, "SCRIPT_NAME" => "/admin-panel"
    expect_fixed_appearance("/admin-panel")
  end

  it "no longer offers or accepts appearance settings, without changing stored data" do
    original = db[:dashboard_appearances].all
    get "/internal/shell"
    expect(last_response.body).not_to include("settings/theme")
    get "/settings/theme"
    expect(last_response.status).to eq(404)
    get "/internal/settings/theme"
    expect(last_response.status).to eq(404)
    post "/settings/theme", theme: "code-monkey", swatch: "forest", chart_style: "rough-viz"
    expect(last_response.status).to eq(404)
    expect(db[:dashboard_appearances].all).to eq(original)
  end
end
