# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# allow_sync and cache_seconds are deprecated and inert: the blocking fetch
# they configured is gone, so neither decides anything. They stay on the wire
# rather than being dropped, because removing a field from a published spec
# on a deployed service breaks whoever is reading it.
RSpec.describe "the deprecated script endpoint settings (#429)", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def admin
    { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'admin').token}" }
  end

  def create!(extra = {})
    post "/admin/communities/sample/endpoints",
         { name: "weather", url: "https://api.example.invalid/w", http_method: "GET" }.merge(extra),
         admin
    YAMLCamel.load(last_response.body)
  end

  describe "the wire contract, which must not move" do
    it "still accepts both on a write rather than refusing them" do
      create!(allow_sync: "1", cache_seconds: "45")

      expect(last_response.status).to eq(201)
    end

    it "still reports both on a read" do
      body = create!(allow_sync: "1", cache_seconds: "45")

      expect(body).to have_key("allow_sync")
      expect(body).to have_key("cache_seconds")
    end

    it "round trips what was sent, so a client reading its own write is not surprised" do
      body = create!(allow_sync: "1", cache_seconds: "45")

      expect(body["allow_sync"]).to be(true)
      expect(body["cache_seconds"]).to eq(45)
    end

    it "still defaults them for a client that sends neither" do
      body = create!

      expect(body["allow_sync"]).to be(false)
      expect(body["cache_seconds"]).to eq(30)
    end
  end

  # The half that makes this a deprecation rather than a silent lie.
  describe "the published spec", :api_spec_document do
    let(:document) { YAMLCamel.load_file(ApiSpecDocument::PATH) }

    let(:read_schema) { document.dig("components", "schemas", "ScriptEndpoint", "properties") }
    let(:write_schema) { document.dig("components", "schemas", "ScriptEndpointWriteBody", "properties") }

    %w[allow_sync cache_seconds].each do |field|
      it "marks #{field} deprecated where a client reads it" do
        expect(read_schema.fetch(field)["deprecated"]).to be(true)
      end

      it "marks #{field} deprecated where a client writes it" do
        expect(write_schema.fetch(field)["deprecated"]).to be(true)
      end

      it "says #{field} does nothing, rather than only flagging it" do
        expect(read_schema.fetch(field)["description"].to_s).to match(/inert/i)
      end
    end

    # Kept required on the response on purpose: a consumer that reads the field
    # today keeps getting it, which is the whole point of deprecating rather
    # than removing.
    %w[allow_sync cache_seconds].each do |field|
      it "keeps #{field} in the response's required list" do
        required = document.dig("components", "schemas", "ScriptEndpoint", "required")

        expect(required).to include(field)
      end
    end
  end

  # What "inert" means, asserted as behaviour rather than by grepping source.
  describe "and they really do nothing" do
    let(:resolver) { ->(_host) { ["93.184.216.34"] } }
    let(:endpoints) do
      Rubotty::Scripting::Endpoints.new(models: models, logger: Rubotty::Log.null, resolver: resolver,
                                      executor: ->(work) { work.call })
    end

    it "offers no blocking call for allow_sync to permit" do
      expect(endpoints).not_to respond_to(:fetch)
    end

    it "asks again on a repeat, however long cache_seconds says to keep it" do
      now = Time.now
      models.script_endpoint.create(
        community_id: community.id, name: "weather", url: "https://api.example.com/w",
        http_method: "GET", allow_sync: true, timeout_seconds: 2, cache_seconds: 86_400,
        enabled: true, created_at: now, updated_at: now
      )
      response = streaming_response("---\ntemp: 19\n", "application/yaml")
      http = instance_double(Net::HTTP)
      allow(Net::HTTP).to receive(:new).and_return(http)
      %i[use_ssl= ipaddr= open_timeout= read_timeout=].each { |setter| allow(http).to receive(setter) }
      sent = 0
      allow(http).to receive(:request) { |_req, &block| sent += 1; block.call(response) }

      3.times { endpoints.enqueue(community, "weather", {}) { |job| job.call } }

      expect(sent).to eq(3)
    end
  end
end
