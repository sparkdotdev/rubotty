# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# Scripts, the endpoints they call, and the numbers they record, over the API. Admin
# only throughout: a script is code this deployment runs and an endpoint decides which
# hosts it reaches, so a developer key never reaches either.
RSpec.describe "Rubotty::Api::App scripts", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 200) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }
  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def admin = { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'a').token}" }

  def developer
    token = keys.issue(scope: "developer", community: community, label: "d").token
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  def body = YAMLCamel.load(last_response.body)

  def create_script(**over)
    post "/admin/communities/sample/scripts", { name: "guard", kind: "processor", language: "lua",
                                        source: 'return { action = "allow" }',
                                        trigger_type: "always" }.merge(over), admin
    body
  end

  describe "the script surface" do
    it "creates one and reads it back" do
      created = create_script
      expect(last_response.status).to eq(201)
      expect(created["name"]).to eq("guard")
      expect(created["enabled"]).to be(false)

      get "/admin/communities/sample/scripts/#{created["id"]}", {}, admin
      expect(body["source"]).to include("allow")
    end

    it "names the condition separately from the kind" do
      created = create_script(kind: "command", trigger_type: "command")

      expect(created["kind"]).to eq("command")
      expect(created["condition"]).to eq("command")
    end

    it "takes the callback kind, which never runs on traffic" do
      expect(create_script(kind: "callback")["kind"]).to eq("callback")
    end

    # The data file beside a script. A partial update must not take it away, so it
    # falls back to what is stored.
    describe "the data file" do
      it "round trips as the document that was written" do
        created = create_script(yaml_data: "# a note\nwords:\n  - airdrop\n")

        expect(created["yaml_data"]).to include("# a note")
      end

      it "survives a patch that named only the source" do
        created = create_script(yaml_data: "words:\n  - airdrop\n")

        patch "/admin/communities/sample/scripts/#{created["id"]}",
              { source: 'return { action = "reject" }' }, admin

        expect(body["yaml_data"]).to include("airdrop")
      end

      it "refuses a document that will not parse" do
        post "/admin/communities/sample/scripts", { name: "broken", kind: "processor", language: "lua",
                                                  source: 'return { action = "allow" }',
                                                  trigger_type: "always",
                                                  yaml_data: "a:\n - one\n bad: yes\n" }, admin

        expect(last_response.status).to eq(422)
        expect(body["error"]).to include("not valid YAML")
      end
    end

    it "never returns the compiled Lua, which nobody should be asked to read" do
      expect(create_script.keys).not_to include("compiled")
    end

    it "lists them" do
      create_script
      get "/admin/communities/sample/scripts", {}, admin

      expect(body["scripts"].map { |row| row["name"] }).to include("guard")
    end

    it "reports a refusal as 422 with the reason" do
      post "/admin/communities/sample/scripts", { name: "  ", kind: "processor", source: "return 1",
                                          trigger_type: "always" }, admin

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("needs a name")
    end

    it "archives on delete and restores from the archive" do
      created = create_script
      delete "/admin/communities/sample/scripts/#{created["id"]}", {}, admin
      expect(last_response.status).to eq(204)

      get "/admin/communities/sample/scripts/archived", {}, admin
      expect(body["scripts"].map { |row| row["id"] }).to include(created["id"])

      post "/admin/communities/sample/scripts/#{created["id"]}/restore", {}, admin
      expect(body["archived"]).to be(false)
    end

    it "refuses to enable one that has not been checked" do
      created = create_script
      post "/admin/communities/sample/scripts/#{created["id"]}/enable", {}, admin

      expect(last_response.status).to eq(422)
    end

    it "403s a developer key, since running code is not its business" do
      get "/admin/communities/sample/scripts", {}, developer
      expect(last_response.status).to eq(403)
    end
  end

  # Every other write on this app takes either encoding, as the class comment promises.
  describe "the wire format" do
    it "accepts a YAML body" do
      post "/admin/communities/sample/scripts",
           YAMLCamel.dump({ "name" => "from-yaml", "kind" => "processor", "language" => "lua",
                            "source" => 'return { action = "allow" }', "trigger_type" => "always" }),
           admin.merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(201)
      expect(body["name"]).to eq("from-yaml")
    end

    it "answers 400 for a body it cannot read, rather than 500" do
      post "/admin/communities/sample/scripts", "name: [unclosed",
           admin.merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(400)
    end

    it "never emits JSON" do
      get "/admin/communities/sample/scripts", {}, admin
      expect(last_response.content_type).to start_with("application/yaml")
    end
  end

  # 403 whichever community is named. Checking the community first gives 403 for your
  # own and 404 for another, which leaks which is which.
  describe "the scope failure shape" do
    it "403s a developer key for its own community and for another alike" do
      models.community.create(slug: "other-co", name: "Other", status: "active", settings: "{}",
                              created_at: Time.now, updated_at: Time.now)

      get "/admin/communities/sample/scripts", {}, developer
      expect(last_response.status).to eq(403)

      get "/admin/communities/other-co/scripts", {}, developer
      expect(last_response.status).to eq(403)
    end
  end

  describe "capabilities" do
    it "says what a script may be, from the code rather than a fixed list" do
      get "/admin/scripting/capabilities", {}, admin

      expect(body["kinds"].map { |k| k["kind"] }).to eq(Rubotty::ControlPlane::Scripts::KINDS)
      expect(body["conditions"].map { |c| c["condition"] }).to match_array(Rubotty::Scripting::Triggers.type_names)
      expect(body["languages"]).to include("lua")
    end
  end

  describe "endpoints" do
    def create_endpoint(**over)
      post "/admin/communities/sample/endpoints", { name: "weather", url: "https://api.example.com/w",
                                            http_method: "GET" }.merge(over), admin
      body
    end

    it "creates one" do
      expect(create_endpoint["name"]).to eq("weather")
      expect(last_response.status).to eq(201)
    end

    # The API key an endpoint carries is the reason headers live there at all.
    it "never echoes the headers back, only whether there are any" do
      row = create_endpoint(headers: "Authorization: Bearer secret")

      expect(row.keys).not_to include("headers")
      expect(row["has_headers"]).to be(true)
    end

    it "refuses an address that is not http" do
      create_endpoint(name: "bad", url: "file:///etc/passwd")

      expect(last_response.status).to eq(422)
      expect(body["error"]).to include("http or https")
    end

    it "403s a developer key" do
      get "/admin/communities/sample/endpoints", {}, developer
      expect(last_response.status).to eq(403)
    end

    # A partial update reuses whatever it was not given, and stored headers are JSON
    # while a client sends header lines. Reusing the column as it stands reads the
    # document as one header line and destroys the API key, and headers are never
    # echoed, so nobody sees it happen.
    describe "a partial update, against what is already stored" do
      def stored(name)
        Rubotty::ControlPlane::ScriptEndpoints.stored_hash(
          models.script_endpoint.where(name: name).first.headers
        )
      end

      it "keeps the headers it was not given" do
        create_endpoint(headers: "Authorization: Bearer secret\nX-Key: abc")
        id = body["id"]

        patch "/admin/communities/sample/endpoints/#{id}", { description: "the weather" }, admin

        expect(stored("weather")).to eq("Authorization" => "Bearer secret", "X-Key" => "abc")
      end

      it "keeps them across repeated updates, rather than nesting them" do
        create_endpoint(headers: "Authorization: Bearer secret")
        id = body["id"]

        3.times { |n| patch "/admin/communities/sample/endpoints/#{id}", { description: "pass #{n}" }, admin }

        expect(stored("weather")).to eq("Authorization" => "Bearer secret")
      end

      it "keeps the query parameters too" do
        create_endpoint(query_params: "town: {town}\nunits: metric")
        id = body["id"]

        patch "/admin/communities/sample/endpoints/#{id}", { description: "again" }, admin

        params = Rubotty::ControlPlane::ScriptEndpoints.stored_hash(
          models.script_endpoint.where(name: "weather").first.query_params
        )
        expect(params).to eq("town" => "{town}", "units" => "metric")
      end

      it "still replaces them when it is given new ones" do
        create_endpoint(headers: "Authorization: Bearer secret")
        id = body["id"]

        patch "/admin/communities/sample/endpoints/#{id}", { headers: "X-Only: new" }, admin

        expect(stored("weather")).to eq("X-Only" => "new")
      end
    end
  end

  # The route somebody automating a check polls, for whether a script is working.
  describe "the error history" do
    def stored(created) = models.community_script[created["id"]]

    it "answers a clean record for a script that has never failed" do
      created = create_script

      get "/admin/communities/sample/scripts/#{created["id"]}/errors", {}, admin

      expect(last_response.status).to eq(200)
      expect(body["errors"]).to eq([])
      expect(body["consecutive_failures"]).to eq(0)
      expect(body["last_error"]).to eq("")
    end

    it "reads back what failed, newest first" do
      created = create_script
      deps.scripts.record_error(stored(created), "attempt to index a nil value")
      deps.scripts.record_error(stored(created).refresh, "attempt to compare a string")

      get "/admin/communities/sample/scripts/#{created["id"]}/errors", {}, admin

      expect(body["errors"].map { |e| e["message"] }).to eq(["attempt to compare a string",
                                                             "attempt to index a nil value"])
      expect(body["last_error"]).to include("compare a string")
      expect(body["last_error_at"]).not_to be_nil
    end

    # A client should not have to infer "off since Tuesday" from "failed twice today".
    it "reports the cutout separately from the count" do
      created = create_script
      5.times { deps.scripts.record_error(stored(created).refresh, "still broken") }

      get "/admin/communities/sample/scripts/#{created["id"]}/errors", {}, admin

      expect(body["consecutive_failures"]).to eq(5)
      expect(body["disabled_at"]).not_to be_nil
      expect(body["disabled_reason"]).to include("consecutive failures")
    end

    it "403s a developer key, like the rest of the scripting surface" do
      created = create_script

      get "/admin/communities/sample/scripts/#{created["id"]}/errors", {}, developer

      expect(last_response.status).to eq(403)
    end

    it "404s a script id that is not this community's" do
      other = models.community.create(slug: "other-co", name: "Other", status: "active", settings: "{}",
                                      created_at: Time.now, updated_at: Time.now)
      theirs = deps.scripts.save(community: other, name: "theirs", kind: "processor", language: "lua",
                                 source: 'return { action = "allow" }', trigger_type: "always")

      get "/admin/communities/sample/scripts/#{theirs.id}/errors", {}, admin

      expect(last_response.status).to eq(404)
    end
  end

  describe "script stats" do
    it "reads what scripts recorded, and is read only" do
      deps.script_stats.increment(community: community, stat: "commands", row: "roll")

      get "/admin/communities/sample/script-stats", {}, admin
      expect(body["stats"]["commands"].first["row"]).to eq("roll")
    end
  end
end
