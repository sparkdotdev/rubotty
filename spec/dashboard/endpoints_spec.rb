# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The endpoints an operator's script may call. What matters is that one can be
# created at all, that a bad one is refused at the form rather than inside
# somebody's rule, and that the parts a script must never control stay with the
# administrator.
RSpec.describe "Rubotty::Dashboard::App endpoints", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }
  let(:community) { models.community.where(slug: "sample").first }

  before { post "/login", secret: secret }

  def create(name: "weather", url: "https://api.example.com/forecast", **rest)
    post "/communities/sample/endpoints", { name: name, url: url, http_method: "GET",
                                          timeout_seconds: "2", cache_seconds: "30",
                                          enabled: "1" }.merge(rest)
    deps.script_endpoints.find_by_name(community, name.downcase)
  end

  describe "the list" do
    it "says plainly that async_http has nothing to call yet" do
      get "/communities/sample/endpoints"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("No script endpoints yet")
    end

    it "shows one once it exists" do
      create

      get "/communities/sample/endpoints"
      expect(last_response.body).to include("weather").and include("api.example.com")
    end
  end

  describe "creating one" do
    it "takes a name a script can call" do
      row = create

      expect(row).not_to be_nil
      expect(row.http_method).to eq("GET")
      expect(row.enabled).to be_truthy
    end

    it "lowercases the name, since that is what a script types" do
      expect(create(name: "Weather").name).to eq("weather")
    end

    it "refuses an address that is not http or https" do
      post "/communities/sample/endpoints", name: "bad", url: "file:///etc/passwd", http_method: "GET"
      follow_redirect! if last_response.redirect?

      expect(last_response.body).to include("http or https")
      expect(deps.script_endpoints.find_by_name(community, "bad")).to be_nil
    end

    it "refuses a second endpoint with a name already taken" do
      create
      post "/communities/sample/endpoints", name: "weather", url: "https://elsewhere.example.com",
                                          http_method: "GET"
      follow_redirect! if last_response.redirect?

      expect(last_response.body).to include("already exists")
    end

    it "will not take a name a script could not write" do
      post "/communities/sample/endpoints", name: "not a name!", url: "https://api.example.com",
                                          http_method: "GET"
      follow_redirect! if last_response.redirect?

      expect(last_response.body).to include("needs a name")
    end
  end

  # The parts an administrator owns rather than the script: which host, with
  # which credentials, carrying which parameters.
  describe "what the administrator configures" do
    it "keeps headers, so a key never reaches a script" do
      row = create(headers: "Authorization: Bearer abc123\nAccept-Language: en")

      stored = Rubotty::ControlPlane::ScriptEndpoints.headers_to_lines(row.headers)
      expect(stored).to include("Authorization: Bearer abc123").and include("Accept-Language: en")
    end

    it "keeps query parameters, fixed ones and ones a script fills" do
      row = create(query_params: "town: {town}\nunits: metric")

      stored = Rubotty::ControlPlane::ScriptEndpoints.pairs_to_lines(row.query_params)
      expect(stored).to include("town: {town}").and include("units: metric")
    end

    # A body is the calling script's table, written out by Ruby, so there is nothing
    # here to configure and nothing to paste a value into.
    it "offers nothing to configure a body with" do
      get "/communities/sample/endpoints/new"

      expect(last_response.body).not_to include("body_template")
    end

    it "links to the documentation from the endpoint editor" do
      get "/communities/sample/endpoints/new"

      expect(last_response.body).to match(%r{<a href="[^"]*/documentation"})
    end

    it "clamps a timeout somebody set far too high" do
      row = create(timeout_seconds: "9999")

      expect(row.timeout_seconds).to eq(Rubotty::ControlPlane::ScriptEndpoints::MAX_TIMEOUT)
    end

    it "defaults to never letting a script wait, since waiting holds the room up" do
      expect(create.allow_sync).to be_falsey
    end
  end

  describe "deleting one" do
    it "removes it, so a script calling that name gets an error" do
      row = create

      post "/communities/sample/endpoints/#{row.id}/delete"

      expect(deps.script_endpoints.list(community)).to be_empty
    end
  end

  describe "authorization" do
    it "keeps an operator out, since an endpoint decides what this deployment reaches" do
      post "/logout"

      get "/communities/sample/endpoints"
      expect(last_response.status).to eq(302).or eq(403)
    end

    it "404s an endpoint id from another community" do
      row = create
      models.community.create(slug: "other", name: "Other", status: "active",
                              created_at: Time.now, updated_at: Time.now)

      get "/communities/other/endpoints/#{row.id}"
      expect(last_response.status).to eq(404)
    end
  end
end
