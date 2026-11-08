# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The old Discovered connections address is deliberately only a migration
# path now. A channel is a channel whether it arrived from discovery,
# provisioning or a topic scan, and the Rooms board owns its state.
RSpec.describe "Rubotty::Dashboard::App legacy discovered connections route", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  it "redirects an administrator to the unroomed Rooms view" do
    login!

    get "/communities/sample/discovered"

    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms?state=unroomed")
  end

  it "keeps the legacy address closed to an operator session without room access" do
    get "/communities/sample/discovered", {},
        "rack.session" => dashboard_session(role: "operator", operator_communities: [community.id])

    expect(last_response.status).to eq(403)
  end
end
