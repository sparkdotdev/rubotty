# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The word-filter page copy: the "Custom words" field has to say that those words
# are ADDED ON TOP of the selected mode, on every scope's own card.
RSpec.describe "Rubotty::Dashboard::App word-filter copy", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  def login!
    post "/login", secret: secret
  end

  before { login! }

  it "labels the extra-words field as additive to the mode, not a replacement for it" do
    post "/communities/sample/word-filter", selector: "all", op: "enable"

    get "/communities/sample/word-filter"
    body = last_response.body

    expect(body).to include("Extra words to filter, on top of the mode above")
    expect(body).to include("ADDED")
  end

  it "carries the same additive framing on every configured scope, not just the first" do
    post "/communities/sample/word-filter", selector: "all", op: "enable"
    post "/communities/sample/word-filter", selector: "general", op: "enable"

    get "/communities/sample/word-filter"
    body = last_response.body

    expect(body.scan("Extra words to filter, on top of the mode above").length).to be >= 2
  end
end
