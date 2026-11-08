# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# An open stream is metered for as long as it is held: charge, never check.
# An established stream is not killed retroactively by a limit it did not
# exceed when it opened, but holding it costs budget, so a key cannot open
# more concurrent streams than its allowance.
RSpec.describe "metering an open stream (#443)", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  # A one-second window, so a handful of passes crosses several of them and the
  # spec does not have to sit for a minute.
  let(:deps) do
    Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200, rate_window: 1)
  end
  let(:app) do
    Rubotty::Api::App.assemble(
      deps: deps, env: { "API_SSE_MAX_PASSES" => "4", "API_SSE_METER_SECONDS" => "1" }
    )
  end
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  let(:issued) { keys.issue(scope: "developer", community: community, label: "watcher") }

  def bearer = { "HTTP_AUTHORIZATION" => "Bearer #{issued.token}" }

  def charges = models.api_request_log.where(api_key_id: issued.key_row.id).count

  def watch!
    get "/communities/sample/rooms/general/stream", { since: 0 }, bearer
  end

  it "charges more than the single request the open itself was" do
    watch!

    expect(charges).to be > 1
  end

  it "keeps charging roughly once per window rather than once per pass" do
    watch!

    # Four passes at a second each across a one-second window: a few charges,
    # not one per pass and not one for the whole stream.
    expect(charges).to be_between(2, 5)
  end

  # The half that matters most, and the call I am making here: an established
  # stream is never closed by a limit it did not exceed when it opened. The
  # charge is recorded, never checked, inside the loop.
  it "does not close a stream even while the key is over its limit" do
    calls = 0
    allow(deps.rate_limiter).to receive(:allow?).and_wrap_original do |original, key|
      calls += 1
      calls == 1 ? original.call(key) : false
    end
    reads = 0
    allow(deps.live_room_feed).to receive(:since).and_wrap_original do |original, **kwargs|
      reads += 1
      original.call(**kwargs)
    end

    watch!

    expect(reads).to eq(4)
  end

  # And the half that gives the charge its teeth: the budget a held stream eats
  # is the same budget a fresh request is measured against, so a key sitting on
  # streams cannot also open new ones indefinitely.
  it "refuses a fresh request from a key whose open stream has eaten the budget" do
    tight = Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 2, rate_window: 3600)
    tight_app = Rubotty::Api::App.assemble(
      deps: tight, env: { "API_SSE_MAX_PASSES" => "4", "API_SSE_METER_SECONDS" => "1" }
    )
    session = Rack::Test::Session.new(tight_app)
    header = { "HTTP_AUTHORIZATION" => "Bearer #{issued.token}" }

    session.get("/communities/sample/rooms/general/stream", { since: 0 }, header)
    session.get("/communities/sample", {}, header)

    expect(session.last_response.status).to eq(429)
  end
end
