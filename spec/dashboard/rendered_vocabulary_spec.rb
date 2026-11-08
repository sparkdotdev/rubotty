# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# Theme renderers own the visible vocabulary. The server keeps each page body in
# an unpainted staging node until a theme adopts it, so this covers the no-flash
# boundary while client_rendered_vocabulary_spec.rb covers the rendered sections.
RSpec.describe "the dashboard theme staging boundary", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  def response_for(path)
    get path
    expect(last_response.status).to eq(200)

    last_response.body
  end

  before { post "/login", secret: secret }

  it "keeps every server page unpainted until the required theme mounts" do
    ["/", "/accounts", "/communities/sample", "/settings/datastore"].each do |path|
      body = response_for(path)

      expect(body).to include('<div id="rb-shell" hidden></div>')
      expect(body).to include('<div id="rb-staging" hidden>')
      expect(body).to include("dashboard-boot.js")
      expect(body).not_to include('id="rb-chrome"')
    end
  end

  it "ships the selected theme and swatch stylesheets over an inlined floor" do
    body = response_for("/")

    expect(body).to include('href="/dashboard.css"')
    expect(body).to include('href="/swatch-clay.css"')
    expect(body).to include("@layer rubotty-fallback")
    expect(body).not_to include('href="/fallback.css"')
  end

end
