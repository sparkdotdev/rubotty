# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"

# The operator web dashboard, driven in-process with rack-test over the seeded
# SAMPLE control plane, so a write is proved to land in the SAME control-plane rows
# the bot reads, through the SAME services the CLI and the chat commands use.
RSpec.describe Rubotty::Dashboard::App, :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  # The real SAMPLE configuration, which is what lets the Platforms page resolve an
  # account's compiled settings and its token_env NAME.
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, config: sample_model) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  let(:community) { models.community.where(slug: "sample").first }

  def login!
    post "/login", secret: secret
  end

  # The server hands every themed shell one document to render. The browser
  # owns the chrome now, so dashboard navigation assertions inspect that
  # document rather than an obsolete server-rendered header.
  def shell_document(body = last_response.body)
    source = body[%r{<script id="rb-shell-data" type="application/json">(.*?)</script>}m, 1]
    JSON.parse(source)
  end

  def scope_document(key, document: shell_document)
    document.fetch("scopes").find { |scope| scope.fetch("key") == key }
  end

  def navigation_labels(scope)
    scope.fetch("groups").flat_map { |group| group.fetch("items") }.map { |item| item.fetch("label") }
  end

  def feature_row(feature:, room_id: nil)
    models.feature_setting
          .where(community_id: community.id, room_id: room_id, feature: feature).first
  end

  def room_id_for(room_key)
    models.room.where(community_id: community.id, room_key: room_key).first.id
  end

  # tg-general and dc-general are both bridged into the "general" room, which is
  # what a channel-scoped selector resolves to.
  def general_room_id
    room_id_for("general")
  end

  def enabled?(row)
    [true, 1, "1", "t", "true"].include?(row.enabled)
  end

  describe "authentication" do
    it "redirects an unauthenticated request to the login form" do
      get "/"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    # The session cookie is the whole credential, so a cross-site form post must
    # not carry it. Secure is on in a deployment and off here, since rack-test
    # speaks plain http; see the note in spec_helper.
    it "marks the session cookie HttpOnly and SameSite=Lax" do
      post "/login", secret: secret

      cookie = last_response.headers["set-cookie"].to_s
      expect(cookie.downcase).to include("httponly")
      expect(cookie.downcase).to include("samesite=lax")
    end

    it "gates a community page behind the session too" do
      get "/communities/sample"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    it "gates a write behind the session, performing no change" do
      post "/communities/sample/features", selector: "all", feature: "faq", op: "enable"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
      expect(feature_row(feature: "faq")).to be_nil
    end

    it "serves the login form without a session" do
      get "/login"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("Dashboard secret")
    end

    it "answers the liveness probe without a session" do
      get "/healthz"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("ok")
    end

    it "rejects a wrong secret with 401 and no session" do
      post "/login", secret: "not-it"
      expect(last_response.status).to eq(401)

      get "/"
      expect(last_response.status).to eq(302)
    end

    it "accepts the correct secret and then serves protected pages" do
      login!
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/")

      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("sample")
    end

    it "logs out, dropping the session" do
      login!
      post "/logout"
      expect(last_response.status).to eq(302)

      get "/"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
    end

    context "when the login secret is not configured" do
      let(:env) { {} }

      it "refuses the login with a 503 and a clear message rather than letting anyone in" do
        post "/login", secret: ""
        expect(last_response.status).to eq(503)
        expect(last_response.body).to include("DASHBOARD_SECRET")

        get "/"
        expect(last_response.status).to eq(302)
      end
    end
  end

  describe "read views" do
    before { login! }

    it "lists communities with their status on the index" do
      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("sample")
      expect(last_response.body).to include("active")
    end

    it "keeps the index to a lede and a link to Documentation, not the whole README" do
      Rubotty::Dashboard::ReadmeRenderer.reset!
      get "/"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include(%(href="/documentation"))
      expect(last_response.body)
        .not_to include(Rubotty::Dashboard::ReadmeRenderer.render(app_root: ""))
    ensure
      # ReadmeRenderer caches at the class level, so leave it unrendered or
      # readme_renderer_spec.rb's fixtures silently hit this real README instead.
      Rubotty::Dashboard::ReadmeRenderer.reset!
    end

    it "renders the README on Documentation, alongside the scripting reference" do
      Rubotty::Dashboard::ReadmeRenderer.reset!
      get "/documentation"
      expect(last_response.status).to eq(200)
      # Only that the route wires the README in; readme_renderer_spec.rb covers the rest.
      # The root matches what the route passes, so the README's own links to documents
      # this dashboard serves land here rather than on a private repository.
      expect(last_response.body)
        .to include(Rubotty::Dashboard::ReadmeRenderer.render(app_root: ""))
    ensure
      Rubotty::Dashboard::ReadmeRenderer.reset!
    end

    it "shows platform connections and their channels" do
      get "/communities/sample/platforms"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("tg-general")
    end

    it "shows operators" do
      get "/communities/sample/operators"
      expect(last_response.status).to eq(200)
      person = models.person[models.operator.where(community_id: community.id).first.person_id]
      expect(last_response.body).to include(person.name)
    end

    it "renders the feature, word-filter and faq screens" do
      %w[features word-filter faq].each do |section|
        get "/communities/sample/#{section}"
        expect(last_response.status).to eq(200)
      end
    end

    it "shows readable communities' audit events, newest first" do
      deps.audit.record(community: "sample", source: "moderation", action: "delete",
                        actor: "alex", reason: "spam")
      get "/audit"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("delete")
      expect(last_response.body).to include("spam")
    end

    it "404s an unknown community" do
      get "/communities/nope"
      expect(last_response.status).to eq(404)
    end
  end

  # Word filter, FAQ, Events and Guests moved from their own subnav tabs to under
  # Features's Config link, each being one feature's config.
  describe "community nav" do
    before { login! }

    it "no longer lists word filter, FAQ, events or guests as their own tabs" do
      get "/communities/sample"
      %w[/word-filter /faq /events /guests].each do |path|
        expect(last_response.body).not_to include(%(href="/communities/sample#{path}"))
      end
    end

    it "still routes to those pages directly, only the tab moved" do
      get "/communities/sample/word-filter"
      expect(last_response.status).to eq(200)
    end

    it "sends a feature with its own bespoke page (word filter) there, not the generic form" do
      get "/communities/sample/features"
      expect(last_response.body).to include('href="/communities/sample/word-filter"')
      expect(last_response.body).not_to include("/features/word_filter/config")
    end

    # #1099: a schema-driven feature with no bespoke page used to only link
    # out to its own /config page. It expands inline in the row now too.
    it "expands a schema-driven feature with no bespoke page (link annotation) inline in its row" do
      get "/communities/sample/features"
      expect(last_response.body).to include('data-grant="configure_link_annotation"')
    end

    # The order is Nav::COMMUNITY_GROUPS' own, since every theme renders that
    # catalogue rather than a list of its own. Same document Series A's
    # sidebar draws from, so the two can never disagree about what a community
    # has in it.
    it "lists the sub-navigation entries grouped, Overview first" do
      get "/communities/sample"

      expected = ["Overview", "Analytics", "Alerts", "Files", "Audit log",
                  "Rooms", "Platforms",
                  "Features", "Room games", "Redirections", "Webhooks",
                  "Scripts (alpha)", "Script endpoints",
                  "Moderation", "Policy misfires", "Operators"]

      expect(navigation_labels(scope_document("community"))).to eq(expected)
    end

    it "no longer renders the community links as a second bar of their own" do
      get "/communities/sample"
      expect(last_response.body).not_to match(/<nav class="subnav">/)
    end

    it "keeps Overview apart from each named community navigation group" do
      get "/communities/sample"
      groups = scope_document("community").fetch("groups")

      expect(groups.map { |group| group.fetch("label") }).to eq(
          [nil, "Activity", "Bridge", "Automation", "Scripting", "People and safety"]
      )
    end

    it "marks the group entry for the page in hand" do
      get "/communities/sample/rooms"
      groups = scope_document("community").fetch("groups")
      bridge = groups.find { |group| group.fetch("key") == "bridge" }
      automation = groups.find { |group| group.fetch("key") == "automation" }

      expect(bridge.fetch("items").find { |item| item.fetch("key") == "rooms" }).to include("current" => true)
      expect(automation.fetch("items")).not_to include(include("current" => true))
    end

    it "carries a breadcrumb back to the community index, the community, and the page in hand" do
      get "/communities/sample/rooms"

      expect(shell_document.fetch("crumbs")).to eq([
        { "label" => "Communities", "path" => "/", "current" => false },
        { "label" => community.name, "path" => "/communities/sample", "current" => false },
        { "label" => "Rooms", "path" => nil, "current" => true }
      ])
    end

    it "carries deployment navigation alongside the community navigation" do
      get "/communities/sample"
      document = shell_document
      deployment = scope_document("deployment", document: document)

      expect(document.fetch("scopes").map { |scope| scope.fetch("key") }).to eq(%w[community deployment])
      expect(deployment.fetch("label")).to eq("Deployment")
      expect(navigation_labels(deployment)).to include("Backfill proposals")
    end

    it "shows no community nav on the request-access dead end for a community not run here" do
      other = models.community.create(
        slug: "walled-off", name: "Walled Off", status: "active", settings: "{}",
        created_at: Time.now, updated_at: Time.now
      )

      get "/communities/#{other.slug}", {}, "rack.session" => dashboard_session(role: "operator", operator_communities: [community.id])

      expect(shell_document.fetch("scopes").map { |scope| scope.fetch("key") }).to eq(["deployment"])
    end
  end

  # The deployment navigation reads its entries out of Nav::DEPLOYMENT_GROUPS,
  # in that catalogue's own order: Communities on its own, then each named
  # heading every theme groups them under.
  # Visibility is asserted in authorization_spec.rb; this is only about order.
  describe "top nav" do
    it "lists the deployment-wide entries grouped, Communities first" do
      login!
      get "/"

      expected = ["Communities", "Analytics", "Audit log", "Backfill proposals", "Jobs", "Logs",
                  "Accounts", "Integrations", "API keys", "Operator logins", "Viewers",
                  "Administrators", "Onboarding", "Datastore"]

      deployment = scope_document("deployment")
      expect(navigation_labels(deployment)).to eq(expected)
      expect(deployment.fetch("groups").map { |group| group.fetch("label") }).to eq(
        [nil, "Activity", "Connections", "Access", "Settings"]
      )
    end
  end

  describe "the shell's version and build commit" do
    before { login! }

    it "always shows the version" do
      get "/"
      expect(shell_document.fetch("brand").fetch("version")).to eq(Rubotty::VERSION)
    end

    it "shows no commit sha when SOURCE_COMMIT is unset" do
      get "/"
      expect(shell_document.fetch("brand").fetch("commit")).to be_nil
    end

    it "shows the short (7-char) commit sha when SOURCE_COMMIT is set" do
      other_env = env.merge("SOURCE_COMMIT" => "a1b2c3d4e5f6")
      other_app = Rubotty::Dashboard::App.assemble(deps: deps, env: other_env)
      session = Rack::Test::Session.new(Rack::MockSession.new(other_app))
      session.post("/login", secret: secret)
      session.get("/")
      expect(shell_document(session.last_response.body).fetch("brand")).to include(
        "version" => Rubotty::VERSION, "commit" => "a1b2c3d"
      )
    end
  end

  # A merge that never deploys leaves the queue empty and the container healthy,
  # so the running version is the only thing that gives it away. The shell
  # carries those facts, so every theme can show the same warning.
  describe "the shell's deployment drift warning" do
    def shell_of(checker)
      other_app = Rubotty::Dashboard::App.assemble(deps: deps, env: env, deploy_drift: checker)
      session = Rack::Test::Session.new(Rack::MockSession.new(other_app))
      session.post("/login", secret: secret)
      session.get("/")
      shell_document(session.last_response.body).fetch("brand")
    end

    def checker_saying(*warnings)
      instance_double(Rubotty::Core::DeployDrift, warnings: warnings)
    end

    it "shows nothing when the running version matches the head of main" do
      brand = shell_of(checker_saying)

      expect(brand).to include("version" => Rubotty::VERSION, "drift" => [])
    end

    it "shows nothing on a deployment with no upstream configured" do
      expect(shell_of(Rubotty::Core::DeployDrift.new).fetch("drift")).to be_empty
    end

    it "carries a warning when the deployment is behind main" do
      brand = shell_of(checker_saying("main is at 9f1a2b3 and this deployment is still running 4acb0e3"))

      expect(brand.fetch("drift")).to include("main is at 9f1a2b3 and this deployment is still running 4acb0e3")
    end

    it "surfaces a bot and web version mismatch in the same place" do
      brand = shell_of(checker_saying("the bot process is running 0.5.53 and this one is running 0.5.55"))

      expect(brand.fetch("drift")).to include("the bot process is running 0.5.53 and this one is running 0.5.55")
    end

    it "builds an inert check for a deployment that configured no upstream" do
      checker = Rubotty::Dashboard::App.build_deploy_drift(config: nil, env: {})

      expect(checker.configured?).to be(false)
      expect(checker.warnings).to eq([])
    end

    it "builds a live check from the configured upstream" do
      config = instance_double(
        Rubotty::Config::Model, deploy_head_url: "https://upstream.example/head",
                                deploy_head_token_env: "DEPLOY_HEAD_TOKEN", deploy_drift_grace: 60
      )
      checker = Rubotty::Dashboard::App.build_deploy_drift(
        config: config, env: { "DEPLOY_HEAD_TOKEN" => "t0ken" }
      )

      expect(checker.configured?).to be(true)
    end

    it "still renders the version when the check itself blows up" do
      exploding = instance_double(Rubotty::Core::DeployDrift)
      allow(exploding).to receive(:warnings).and_raise(Errno::ECONNREFUSED)

      brand = shell_of(exploding)

      expect(brand).to include("version" => Rubotty::VERSION, "drift" => [])
    end
  end

  describe "feature toggles" do
    before { login! }

    it "enables a feature at the community scope, landing an enabled feature_settings row" do
      post "/communities/sample/features", selector: "all", feature: "faq", op: "enable"
      expect(last_response.status).to eq(302)

      row = feature_row(feature: "faq")
      expect(row).not_to be_nil
      expect(row.room_id).to be_nil
      expect(enabled?(row)).to be(true)
    end

    it "enables a feature at a room scope by room key" do
      post "/communities/sample/features", selector: "general", feature: "word_filter", op: "enable"
      row = feature_row(feature: "word_filter", room_id: general_room_id)
      expect(row).not_to be_nil
      expect(enabled?(row)).to be(true)
    end

    it "enables a feature by an endpoint key, resolving to that endpoint's room" do
      post "/communities/sample/features", selector: "tg-general", feature: "word_filter", op: "enable"
      row = feature_row(feature: "word_filter", room_id: general_room_id)
      expect(row).not_to be_nil
      expect(enabled?(row)).to be(true)
    end

    it "disables a feature without dropping the row" do
      post "/communities/sample/features", selector: "all", feature: "faq", op: "enable"
      post "/communities/sample/features", selector: "all", feature: "faq", op: "disable"
      expect(enabled?(feature_row(feature: "faq"))).to be(false)
    end

    it "merges a config key through FeatureControls" do
      post "/communities/sample/features",
           selector: "all", feature: "link_filter", op: "set", key: "posture", value: "block_all"
      expect(feature_row(feature: "link_filter").json_value(:config)).to eq("posture" => "block_all")
    end

    it "turns an unknown feature into a flash error, not a 500 or a row" do
      post "/communities/sample/features", selector: "all", feature: "not_a_feature", op: "enable"
      expect(last_response.status).to eq(302)
      expect(feature_row(feature: "not_a_feature")).to be_nil
    end

    # The dashboard's own path to FeatureControls gives a flash error
    # rather than a 500 or a silently-clamped row, the same refusal the API and
    # the CLI give for the identical write.
    it "turns a backfill safe_horizon_seconds too close to relay_claim_ttl into a flash error, not a row" do
      ttl = sample_model.relay_claim_ttl
      post "/communities/sample/features",
           selector: "all", feature: "backfill", op: "set", key: "safe_horizon_seconds", value: ttl.to_s
      expect(last_response.status).to eq(302)
      expect(feature_row(feature: "backfill")).to be_nil

      follow_redirect!
      expect(last_response.body).to include("relay_claim_ttl")
    end
  end

  # Every config_schema field gets a typed form input here, including the features
  # with no bespoke settings page of their own.
  describe "generic feature config editor" do
    before { login! }

    it "renders one field per config_schema key, pre-filled with the schema default" do
      get "/communities/sample/features/link_filter/config"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('name="posture"')
      expect(last_response.body).to include('name="whitelist"')
      expect(last_response.body).to include('name="exempt_operators"')
    end

    it "pre-fills a field from an existing row over the schema default" do
      post "/communities/sample/features",
           selector: "all", feature: "link_filter", op: "set", key: "posture", value: "block_all"
      get "/communities/sample/features/link_filter/config"
      expect(last_response.body).to match(/<option value="block_all" selected/)
    end

    it "404s for a feature with no config_schema at all" do
      get "/communities/sample/features/channel_management/config"
      expect(last_response.status).to eq(404)
    end

    it "404s for an unknown feature" do
      get "/communities/sample/features/not_a_feature/config"
      expect(last_response.status).to eq(404)
    end

    it "writes a scalar field" do
      post "/communities/sample/features/link_filter/config", selector: "all", posture: "block_all"
      expect(feature_row(feature: "link_filter").json_value(:config)).to include("posture" => "block_all")
    end

    it "leaves a blank scalar field untouched rather than clearing it" do
      post "/communities/sample/features",
           selector: "all", feature: "link_filter", op: "set", key: "posture", value: "block_all"
      post "/communities/sample/features/link_filter/config", selector: "all", posture: ""
      expect(feature_row(feature: "link_filter").json_value(:config)).to include("posture" => "block_all")
    end

    it "writes true from a checked boolean checkbox" do
      post "/communities/sample/features/link_filter/config",
           selector: "all", exempt_operators: "true"
      expect(feature_row(feature: "link_filter").json_value(:config)["exempt_operators"]).to be(true)
    end

    it "writes false from an unchecked boolean checkbox (only the hidden fallback submits)" do
      post "/communities/sample/features/link_filter/config", selector: "all", exempt_operators: "false"
      expect(feature_row(feature: "link_filter").json_value(:config)["exempt_operators"]).to be(false)
    end

    it "writes an array field from newline-separated textarea lines" do
      post "/communities/sample/features/link_filter/config",
           selector: "all", whitelist: "example.com\nexample.org\n"
      expect(feature_row(feature: "link_filter").json_value(:config)["whitelist"])
        .to eq(%w[example.com example.org])
    end

    it "leaves an array field alone when the textarea was blank to begin with" do
      post "/communities/sample/features/link_filter/config", selector: "all", whitelist: ""
      expect(feature_row(feature: "link_filter")&.json_value(:config)&.key?("whitelist")).to be_falsey
    end

    it "writes an empty array when a list the scope had written is cleared" do
      post "/communities/sample/features/link_filter/config", selector: "all", whitelist: "example.com"
      post "/communities/sample/features/link_filter/config", selector: "all", whitelist: ""
      expect(feature_row(feature: "link_filter").json_value(:config)["whitelist"]).to eq([])
    end

    it "writes at a room scope" do
      post "/communities/sample/features/link_filter/config", selector: "general", posture: "block_invites"
      row = feature_row(feature: "link_filter", room_id: general_room_id)
      expect(row.json_value(:config)).to include("posture" => "block_invites")
    end
  end

  describe "word-filter edits" do
    before { login! }

    it "saves a mode, a custom word list and the action" do
      post "/communities/sample/word-filter",
           selector: "all", op: "save", mode: "slurs_profanity", custom: "housebanned\nother thing\n",
           action: "flag"

      config = feature_row(feature: "word_filter").json_value(:config)
      expect(config["mode"]).to eq("slurs_profanity")
      expect(config["custom"]).to eq(["housebanned", "other thing"])
      expect(config["action"]).to eq("flag")
    end

    it "defaults the mode to off when the form submits none, preserving dormancy" do
      post "/communities/sample/word-filter", selector: "all", op: "save", custom: "onlyme"

      config = feature_row(feature: "word_filter").json_value(:config)
      expect(config["mode"]).to eq("off")
      expect(config["custom"]).to eq(["onlyme"])
    end

    it "saves an empty custom list when the textarea is blank" do
      post "/communities/sample/word-filter", selector: "all", op: "save", mode: "slurs", custom: ""

      config = feature_row(feature: "word_filter").json_value(:config)
      expect(config["mode"]).to eq("slurs")
      expect(config["custom"]).to eq([])
    end

    it "enables the word filter at a scope" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"
      expect(enabled?(feature_row(feature: "word_filter"))).to be(true)
    end
  end

  describe "word-filter mode UI" do
    before { login! }

    # The primary controls are a mode dropdown and a custom-words textarea. The
    # legacy `entries` list stays out of them; it is reachable only from the
    # schema form at the bottom of the page, with every other key this page
    # does not draw itself.
    it "renders a mode dropdown and a custom-words textarea as the primary controls" do
      post "/communities/sample/word-filter", selector: "all", op: "enable"

      get "/communities/sample/word-filter"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('name="mode"')
      expect(last_response.body).to include('name="custom"')
      expect(last_response.body).to include("Slurs + profanity")

      primary = last_response.body.split('<form id="schema-config-form"', 2).first
      expect(primary).not_to include('name="entries"')
    end

    it "shows a legacy vulgarity_mode config folded onto its mode equivalent" do
      post "/communities/sample/features",
           selector: "all", feature: "word_filter", op: "set", key: "vulgarity_mode", value: "all"

      get "/communities/sample/word-filter"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to match(/<option value="slurs_profanity"[^>]*selected/)
    end
  end

  describe "FAQ edits" do
    before { login! }

    it "adds a command entry and then removes it by id" do
      post "/communities/sample/faq",
           selector: "all", trigger_type: "command", trigger: "rules", response: "Be kind.", op: "add"

      entries = feature_row(feature: "faq").json_value(:config)["entries"]
      expect(entries.length).to eq(1)
      expect(entries.first).to include("response" => "Be kind.", "command" => "rules")
      entry_id = entries.first["id"]
      expect(entry_id).not_to be_nil

      post "/communities/sample/faq", selector: "all", id: entry_id, op: "remove"
      expect(feature_row(feature: "faq").json_value(:config)["entries"]).to eq([])
    end

    it "adds a keyword entry" do
      post "/communities/sample/faq",
           selector: "all", trigger_type: "keyword", trigger: "hours", response: "9 to 5", op: "add"
      entries = feature_row(feature: "faq").json_value(:config)["entries"]
      expect(entries.length).to eq(1)
      expect(entries.first).to include("response" => "9 to 5", "keyword" => "hours")
    end

    it "rejects an entry missing its response" do
      post "/communities/sample/faq", selector: "all", trigger_type: "command", trigger: "x", op: "add"
      expect(feature_row(feature: "faq")).to be_nil
    end
  end

  # Adapter identity, token status and per-account behaviour settings.
  describe "platform connections" do
    # Runtime and the dashboard alike resolve an account from the accounts
    # table alone now, so seed it the way a real deployment's one-time seed
    # already would; deps' config: sample_model is not consulted here.
    before do
      login!
      Rubotty::ControlPlane::Accounts.new(models: models).seed_from_config(sample_model)
    end

    def telegram_connection
      models.platform_connection.where(community_id: community.id, adapter: "telegram").first
    end

    def discord_connection
      models.platform_connection.where(community_id: community.id, adapter: "discord").first
    end

    it "shows the token env name as dormant when the key is not in this process's environment" do
      get "/communities/sample/platforms"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("TELEGRAM_BOT_TOKEN")
      expect(last_response.body).to include("dormant (waiting for key)")
    end

    context "when the token env var is set in the dashboard's own environment" do
      let(:env) { { "DASHBOARD_SECRET" => secret, "TELEGRAM_BOT_TOKEN" => "tg-token" } }

      it "shows the token env as key present" do
        get "/communities/sample/platforms"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("key present")
      end
    end

    # A deployment with no configuration file has no boot-time config at all;
    # Deps' own config, wherever set, is never part of this resolution.
    context "with no boot-time config at all" do
      let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }

      it "still names the connection's token variable on the Platforms page" do
        get "/communities/sample/platforms"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("TELEGRAM_BOT_TOKEN")
      end

      it "saves a behaviour setting rather than refusing every one of them" do
        connection = telegram_connection
        post "/communities/sample/platforms/#{connection.id}/settings", setting: { reaction_policy: "drop" }

        expect(last_response.status).to eq(302)
        expect(connection.refresh.json_value(:settings)).to include("reaction_policy" => "drop")
      end
    end

    it "renders each adapter's editable behaviour settings with their compiled defaults" do
      get "/communities/sample/platforms"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("reaction_policy")
      expect(last_response.body).to include("cross_delete_on_discord")
      expect(last_response.body).to include("album_window")
      expect(last_response.body).to include("max_upload_bytes")
    end

    it "edits a per-platform behaviour setting, persisting it to the connection's own settings" do
      connection = telegram_connection
      post "/communities/sample/platforms/#{connection.id}/settings",
           setting: { reaction_policy: "drop", cross_delete_on_discord: "false", album_window: "3" }
      expect(last_response.status).to eq(302)

      stored = connection.refresh.json_value(:settings)
      expect(stored).to eq("reaction_policy" => "drop", "cross_delete_on_discord" => false, "album_window" => 3.0)
    end

    it "edits a different adapter's behaviour setting independently" do
      connection = discord_connection
      post "/communities/sample/platforms/#{connection.id}/settings", setting: { max_upload_bytes: "1000000" }
      expect(last_response.status).to eq(302)
      expect(connection.refresh.json_value(:settings)).to eq("max_upload_bytes" => 1_000_000)
    end

    it "rejects an out of range value, writing nothing" do
      connection = telegram_connection
      post "/communities/sample/platforms/#{connection.id}/settings", setting: { reaction_policy: "not-a-policy" }
      expect(last_response.status).to eq(302)
      expect(connection.refresh.json_value(:settings)).to eq({})

      get "/communities/sample/platforms"
      expect(last_response.body).to include("must be one of")
    end

    it "updates a connection's adapter, account, external id and label" do
      # sample is protected, so generic identity-edit mechanics need a community the
      # guard does not cover.
      now = Time.now
      row = models.community.create(slug: "editable-co", name: "Editable Co", status: "active",
                                     bootstrap_source: "seed", created_at: now, updated_at: now)
      connection = models.platform_connection.create(
        community_id: row.id, adapter: "discord", account: "discord", external_id: "1",
        label: "Old label", created_at: now, updated_at: now
      )

      post "/communities/editable-co/platforms/#{connection.id}", adapter: "discord", account: "discord",
                                                                    external_id: connection.external_id,
                                                                    label: "Main server"
      expect(last_response.status).to eq(302)
      expect(connection.refresh.label).to eq("Main server")
    end

    it "refuses to edit a protected community's connection identity" do
      connection = discord_connection
      original_external_id = connection.external_id

      post "/communities/sample/platforms/#{connection.id}", adapter: "discord", account: "discord",
                                                             external_id: "999999999", label: "Renamed"
      expect(last_response.status).to eq(302)
      expect(connection.refresh.external_id).to eq(original_external_id)
      expect(connection.refresh.label).not_to eq("Renamed")
    end

    it "rejects an adapter outside the known dropdown values, changing nothing" do
      connection = discord_connection
      post "/communities/sample/platforms/#{connection.id}", adapter: "not-a-real-adapter",
                                                            account: connection.account,
                                                            external_id: connection.external_id
      expect(last_response.status).to eq(302)
      expect(connection.refresh.adapter).to eq("discord")
    end

    it "gates a behaviour-setting write behind the session, performing no change" do
      post "/logout"
      connection = telegram_connection
      post "/communities/sample/platforms/#{connection.id}/settings", setting: { reaction_policy: "drop" }
      expect(last_response.status).to eq(302)
      expect(last_response.headers["location"]).to end_with("/login")
      expect(connection.refresh.json_value(:settings)).to eq({})
    end

    describe "adding a new platform connection" do
      it "creates a connection for a platform this community had none for" do
        expect do
          post "/communities/sample/platforms/connections",
               adapter: "stoat", account: "stoat", external_id: "stoat-server-1", label: "SAMPLE Stoat"
        end.to change { models.platform_connection.where(community_id: community.id).count }.by(1)
        expect(last_response.status).to eq(302)

        created = models.platform_connection.where(community_id: community.id, adapter: "stoat").first
        expect(created.account).to eq("stoat")
        expect(created.external_id).to eq("stoat-server-1")
        expect(created.label).to eq("SAMPLE Stoat")
      end

      it "rejects an adapter outside the known dropdown values, creating nothing" do
        expect do
          post "/communities/sample/platforms/connections",
               adapter: "not-a-real-adapter", account: "x", external_id: "y"
        end.not_to(change { models.platform_connection.count })
        expect(last_response.status).to eq(302)
      end

      it "rejects a blank account or external id, creating nothing" do
        expect do
          post "/communities/sample/platforms/connections", adapter: "stoat", account: "", external_id: ""
        end.not_to(change { models.platform_connection.count })
      end

      it "rejects a duplicate (adapter, account, external_id), leaving the existing row alone" do
        existing = discord_connection
        expect do
          post "/communities/sample/platforms/connections",
               adapter: existing.adapter, account: existing.account, external_id: existing.external_id
        end.not_to(change { models.platform_connection.count })

        get "/communities/sample/platforms"
        expect(last_response.body).to include("already exists")
      end

      it "gates connection creation behind the session, performing no change" do
        post "/logout"
        expect do
          post "/communities/sample/platforms/connections", adapter: "stoat", account: "stoat", external_id: "z"
        end.not_to(change { models.platform_connection.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end

    # Until this existed the only way to drop a mistakenly added or now-defunct
    # connection was to delete the row in the database by hand.
    describe "removing a platform connection" do
      let(:editable) do
        now = Time.now
        models.community.create(slug: "editable-co", name: "Editable Co", status: "active",
                                bootstrap_source: "seed", created_at: now, updated_at: now)
      end

      def editable_connection
        now = Time.now
        models.platform_connection.create(
          community_id: editable.id, adapter: "stoat", account: "stoat", external_id: "gone-1",
          label: "Retired", created_at: now, updated_at: now
        )
      end

      it "removes a connection, taking its channels with it" do
        connection = editable_connection
        now = Time.now
        models.channel.create(
          community_id: editable.id, platform_connection_id: connection.id, adapter: "stoat",
          account: "stoat", route_key: "r1", endpoint_key: "stoat:stoat:r1", label: "gone",
          settings: "{}", relay: "{}", display_name: "{}", created_at: now, updated_at: now
        )

        expect do
          post "/communities/editable-co/platforms/#{connection.id}/delete"
        end.to change { models.platform_connection.where(id: connection.id).count }.by(-1)
        expect(last_response.status).to eq(302)
        expect(models.channel.where(platform_connection_id: connection.id).count).to eq(0)
      end

      it "refuses to remove a protected community's connection" do
        connection = discord_connection

        expect do
          post "/communities/sample/platforms/#{connection.id}/delete"
        end.not_to(change { models.platform_connection.count })
        get "/communities/sample/platforms"
        expect(last_response.body).to include("protected community")
      end

      it "404s removing another community's connection by id" do
        connection = editable_connection

        post "/communities/sample/platforms/#{connection.id}/delete"
        expect(last_response.status).to eq(404)
        expect(models.platform_connection.where(id: connection.id).count).to eq(1)
      end

      it "gates connection removal behind the session, performing no change" do
        connection = editable_connection
        post "/logout"

        expect do
          post "/communities/editable-co/platforms/#{connection.id}/delete"
        end.not_to(change { models.platform_connection.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end
  end

  # A community's flagship and self-hosted Fluxer connections, in the same
  # DB-plus-panel-config bucket irc_networks uses, managed from the Platforms page
  # apart from the platform_connection CRUD above.
  describe "fluxer instances" do
    before { login! }

    def fluxer_instances
      models.fluxer_instance.where(community_id: community.id).all
    end

    describe "adding an instance" do
      it "adds a flagship instance from a label and api key env var alone" do
        expect do
          post "/communities/sample/platforms/fluxer",
               label: "Flagship", kind: "flagship", endpoint_url: "", api_key_env: "FLUXER_FLAGSHIP_API_KEY"
        end.to change { fluxer_instances.count }.by(1)
        expect(last_response.status).to eq(302)

        created = fluxer_instances.find { |row| row.label == "Flagship" }
        expect(created.kind).to eq("flagship")
        expect(created.endpoint_url).to be_nil
        expect(created.api_key_env).to eq("FLUXER_FLAGSHIP_API_KEY")
      end

      it "adds a self-hosted instance carrying its endpoint URL" do
        post "/communities/sample/platforms/fluxer",
             label: "Our server", kind: "self_hosted", endpoint_url: "https://fluxer.example.org",
             api_key_env: "FLUXER_SELF_API_KEY"
        expect(last_response.status).to eq(302)

        created = fluxer_instances.find { |row| row.label == "Our server" }
        expect(created.kind).to eq("self_hosted")
        expect(created.endpoint_url).to eq("https://fluxer.example.org")
      end

      it "rejects a self-hosted instance with no endpoint URL, creating nothing" do
        expect do
          post "/communities/sample/platforms/fluxer",
               label: "Our server", kind: "self_hosted", endpoint_url: "", api_key_env: "FLUXER_API_KEY"
        end.not_to(change { fluxer_instances.count })

        get "/communities/sample/platforms"
        expect(last_response.body).to include("endpoint_url")
      end

      it "rejects a blank label, creating nothing" do
        expect do
          post "/communities/sample/platforms/fluxer", label: "", kind: "flagship", api_key_env: "FLUXER_API_KEY"
        end.not_to(change { fluxer_instances.count })
      end

      it "rejects a duplicate label within the same community" do
        post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                    api_key_env: "FLUXER_API_KEY"
        expect do
          post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                      api_key_env: "FLUXER_API_KEY_2"
        end.not_to(change { fluxer_instances.count })

        get "/communities/sample/platforms"
        expect(last_response.body).to include("already exists")
      end

      it "gates instance creation behind the session, performing no change" do
        post "/logout"
        expect do
          post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                      api_key_env: "FLUXER_API_KEY"
        end.not_to(change { fluxer_instances.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end

    describe "listing instances" do
      it "shows each instance's kind, endpoint (self-hosted only) and api key env presence" do
        post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                    api_key_env: "FLUXER_FLAGSHIP_API_KEY"
        post "/communities/sample/platforms/fluxer", label: "Our server", kind: "self_hosted",
                                                    endpoint_url: "https://fluxer.example.org",
                                                    api_key_env: "FLUXER_SELF_API_KEY"

        get "/communities/sample/platforms"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Flagship")
        expect(last_response.body).to include("Our server")
        expect(last_response.body).to include("https://fluxer.example.org")
        expect(last_response.body).to include("FLUXER_FLAGSHIP_API_KEY")
        expect(last_response.body).to include("not set in this process")
      end

      it "shows key present once the env var is set in the dashboard's own environment" do
        post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                    api_key_env: "FLUXER_FLAGSHIP_API_KEY"
        # Rack::Test reuses the same #app, so a fresh env-bearing app is built here.
        env_app = Rubotty::Dashboard::App.assemble(
          deps: deps, env: { "DASHBOARD_SECRET" => secret, "FLUXER_FLAGSHIP_API_KEY" => "some-key" }
        )
        session = Rack::Test::Session.new(Rack::MockSession.new(env_app))
        session.post "/login", secret: secret
        session.get "/communities/sample/platforms"
        expect(session.last_response.body).to include("key present")
      end

      it "does not show another community's instances" do
        row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      bootstrap_source: "seed", created_at: Time.now, updated_at: Time.now)
        models.fluxer_instance.create(community_id: row.id, label: "Not mine", kind: "flagship",
                                      api_key_env: "FLUXER_OTHER", created_at: Time.now, updated_at: Time.now)

        get "/communities/sample/platforms"
        expect(last_response.body).not_to include("Not mine")
      end
    end

    describe "editing an instance" do
      def flagship
        post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                    api_key_env: "FLUXER_API_KEY"
        fluxer_instances.find { |row| row.label == "Flagship" }
      end

      it "switches an instance from flagship to self-hosted" do
        instance = flagship
        post "/communities/sample/platforms/fluxer/#{instance.id}",
             label: "Our server", kind: "self_hosted", endpoint_url: "https://fluxer.example.org",
             api_key_env: "FLUXER_API_KEY"
        expect(last_response.status).to eq(302)

        updated = instance.refresh
        expect(updated.label).to eq("Our server")
        expect(updated.kind).to eq("self_hosted")
        expect(updated.endpoint_url).to eq("https://fluxer.example.org")
      end

      it "rejects an invalid edit, leaving the row unchanged" do
        instance = flagship
        post "/communities/sample/platforms/fluxer/#{instance.id}",
             label: "", kind: "flagship", api_key_env: "FLUXER_API_KEY"
        expect(last_response.status).to eq(302)
        expect(instance.refresh.label).to eq("Flagship")
      end

      it "404s editing another community's instance by id" do
        row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      bootstrap_source: "seed", created_at: Time.now, updated_at: Time.now)
        other_instance = models.fluxer_instance.create(
          community_id: row.id, label: "Not mine", kind: "flagship", api_key_env: "FLUXER_OTHER",
          created_at: Time.now, updated_at: Time.now
        )
        post "/communities/sample/platforms/fluxer/#{other_instance.id}",
             label: "Hijacked", kind: "flagship", api_key_env: "FLUXER_OTHER"
        expect(last_response.status).to eq(404)
        expect(other_instance.refresh.label).to eq("Not mine")
      end
    end

    describe "removing an instance" do
      def flagship
        post "/communities/sample/platforms/fluxer", label: "Flagship", kind: "flagship",
                                                    api_key_env: "FLUXER_API_KEY"
        fluxer_instances.find { |row| row.label == "Flagship" }
      end

      it "removes an instance" do
        instance = flagship
        expect do
          post "/communities/sample/platforms/fluxer/#{instance.id}/delete"
        end.to change { fluxer_instances.count }.by(-1)
        expect(last_response.status).to eq(302)
      end

      it "does not remove another community's instance by id" do
        row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      bootstrap_source: "seed", created_at: Time.now, updated_at: Time.now)
        other_instance = models.fluxer_instance.create(
          community_id: row.id, label: "Not mine", kind: "flagship", api_key_env: "FLUXER_OTHER",
          created_at: Time.now, updated_at: Time.now
        )
        post "/communities/sample/platforms/fluxer/#{other_instance.id}/delete"
        expect(last_response.status).to eq(302)
        expect(models.fluxer_instance[other_instance.id]).not_to be_nil
      end

      it "gates instance removal behind the session, performing no change" do
        instance = flagship
        post "/logout"
        expect do
          post "/communities/sample/platforms/fluxer/#{instance.id}/delete"
        end.not_to(change { fluxer_instances.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end
  end

  describe "irc networks" do
    before { login! }

    def irc_networks
      models.irc_network.where(community_id: community.id).all
    end

    describe "adding a network" do
      it "adds a per_room network from its connection fields alone" do
        expect do
          post "/communities/sample/platforms/irc-networks",
               name: "Libera", host: "irc.libera.chat", port: "6697", tls: "true", nick: "rubotty", mode: "per_room"
        end.to change { irc_networks.count }.by(1)
        expect(last_response.status).to eq(302)

        created = irc_networks.find { |row| row.name == "Libera" }
        expect(created.host).to eq("irc.libera.chat")
        expect(created.mode).to eq("per_room")
        expect(created.hub_channel).to be_nil
      end

      it "adds a hub network carrying its hub_channel and channels" do
        post "/communities/sample/platforms/irc-networks",
             name: "Libera", host: "irc.libera.chat", port: "6697", tls: "true", nick: "rubotty", mode: "hub",
             hub_channel: "#sample", channels: "#general\n#offtopic"
        expect(last_response.status).to eq(302)

        created = irc_networks.find { |row| row.name == "Libera" }
        expect(created.hub_channel).to eq("#sample")
        expect(JSON.parse(created.channels)).to eq(%w[#general #offtopic])
      end

      it "saves channel key rows into channel_keys" do
        post "/communities/sample/platforms/irc-networks",
             name: "Libera", host: "irc.libera.chat", port: "6697", tls: "true", nick: "rubotty", mode: "per_room",
             channel_key_channel: ["#ops"], channel_key_env: ["IRC_OPS_CHANNEL_KEY"]

        created = irc_networks.find { |row| row.name == "Libera" }
        expect(JSON.parse(created.channel_keys)).to eq({ "#ops" => "IRC_OPS_CHANNEL_KEY" })
      end

      it "rejects a hub network with no hub_channel, creating nothing" do
        expect do
          post "/communities/sample/platforms/irc-networks",
               name: "Libera", host: "irc.libera.chat", nick: "rubotty", mode: "hub"
        end.not_to(change { irc_networks.count })

        get "/communities/sample/platforms"
        expect(last_response.body).to include("hub_channel")
      end

      it "rejects a blank name, creating nothing" do
        expect do
          post "/communities/sample/platforms/irc-networks", name: "", host: "irc.libera.chat", nick: "rubotty"
        end.not_to(change { irc_networks.count })
      end

      it "rejects a duplicate name within the same community" do
        post "/communities/sample/platforms/irc-networks", name: "Libera", host: "irc.libera.chat", nick: "rubotty"
        expect do
          post "/communities/sample/platforms/irc-networks", name: "Libera", host: "irc.libera.chat", nick: "rubotty2"
        end.not_to(change { irc_networks.count })

        get "/communities/sample/platforms"
        expect(last_response.body).to include("already exists")
      end

      it "gates network creation behind the session, performing no change" do
        post "/logout"
        expect do
          post "/communities/sample/platforms/irc-networks", name: "Libera", host: "irc.libera.chat", nick: "rubotty"
        end.not_to(change { irc_networks.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end

    describe "listing networks" do
      it "shows each network's host, mode and channels" do
        post "/communities/sample/platforms/irc-networks",
             name: "Libera", host: "irc.libera.chat", nick: "rubotty", mode: "hub", hub_channel: "#sample"

        get "/communities/sample/platforms"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Libera")
        expect(last_response.body).to include("irc.libera.chat")
        expect(last_response.body).to include("#sample")
      end

      it "does not show another community's networks" do
        row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      bootstrap_source: "seed", created_at: Time.now, updated_at: Time.now)
        models.irc_network.create(community_id: row.id, name: "Not mine", host: "irc.example.org", nick: "bot",
                                  channels: "[]", created_at: Time.now, updated_at: Time.now)

        get "/communities/sample/platforms"
        expect(last_response.body).not_to include("Not mine")
      end
    end

    describe "editing a network" do
      def libera
        post "/communities/sample/platforms/irc-networks", name: "Libera", host: "irc.libera.chat", nick: "rubotty"
        irc_networks.find { |row| row.name == "Libera" }
      end

      it "switches a network from per_room to hub" do
        network = libera
        post "/communities/sample/platforms/irc-networks/#{network.id}",
             name: "Libera", host: "irc.libera.chat", nick: "rubotty", mode: "hub", hub_channel: "#sample"
        expect(last_response.status).to eq(302)

        updated = network.refresh
        expect(updated.mode).to eq("hub")
        expect(updated.hub_channel).to eq("#sample")
      end

      it "rejects an invalid edit, leaving the row unchanged" do
        network = libera
        post "/communities/sample/platforms/irc-networks/#{network.id}", name: "", host: "irc.libera.chat", nick: "rubotty"
        expect(last_response.status).to eq(302)
        expect(network.refresh.name).to eq("Libera")
      end

      it "404s editing another community's network by id" do
        row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      bootstrap_source: "seed", created_at: Time.now, updated_at: Time.now)
        other_network = models.irc_network.create(community_id: row.id, name: "Not mine", host: "irc.example.org",
                                                   nick: "bot", channels: "[]", created_at: Time.now, updated_at: Time.now)
        post "/communities/sample/platforms/irc-networks/#{other_network.id}",
             name: "Hijacked", host: "irc.example.org", nick: "bot"
        expect(last_response.status).to eq(404)
        expect(other_network.refresh.name).to eq("Not mine")
      end
    end

    describe "removing a network" do
      def libera
        post "/communities/sample/platforms/irc-networks", name: "Libera", host: "irc.libera.chat", nick: "rubotty"
        irc_networks.find { |row| row.name == "Libera" }
      end

      it "removes a network" do
        network = libera
        expect do
          post "/communities/sample/platforms/irc-networks/#{network.id}/delete"
        end.to change { irc_networks.count }.by(-1)
        expect(last_response.status).to eq(302)
      end

      it "does not remove another community's network by id" do
        row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                      bootstrap_source: "seed", created_at: Time.now, updated_at: Time.now)
        other_network = models.irc_network.create(community_id: row.id, name: "Not mine", host: "irc.example.org",
                                                   nick: "bot", channels: "[]", created_at: Time.now, updated_at: Time.now)
        post "/communities/sample/platforms/irc-networks/#{other_network.id}/delete"
        expect(last_response.status).to eq(302)
        expect(models.irc_network[other_network.id]).not_to be_nil
      end

      it "gates network removal behind the session, performing no change" do
        network = libera
        post "/logout"
        expect do
          post "/communities/sample/platforms/irc-networks/#{network.id}/delete"
        end.not_to(change { irc_networks.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end
  end

  # The write must land in the SAME utility_commands config the /platforms command
  # reads, so the command advertises it.
  describe "platform invite links" do
    before { login! }

    def platforms_config(room_id: nil)
      feature_row(feature: "utility_commands", room_id: room_id)&.json_value(:config)&.fetch("platforms", nil)
    end

    # Run the real /platforms feature over a stored config and return its reply.
    def platforms_reply(config)
      tg = endpoint("tg")
      adapter = Fakes::ReactingAdapter.new
      adapters = Hash.new(adapter)
      top = topology(room("r", tg))
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: top, logger: Rubotty::Log.null
      )
      feature = Rubotty::Features::UtilityCommands.new(
        topology: top, adapters: adapters, logger: Rubotty::Log.null, ephemeral: ephemeral
      )
      # A real Snapshot::Community sharing the DB row's id, not the raw row
      # itself: #command_prefixes reads feature_config off it, which the raw
      # model row above does not answer.
      snapshot_community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: community.id, slug: community.slug, name: community.name, status: community.status,
        settings: {}, topology: Rubotty::Core::Topology.new([]), channels: [],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new
      )
      feature.call(Rubotty::Features::Context.new(
                     message: message(tg, text: "/platforms", author: author(native_id: "u1")),
                     config: config, community: snapshot_community
                   ))
      adapter.delivered_to("tg").last&.body&.text
    end

    it "persists the edited links to the utility_commands config for a scope" do
      post "/communities/sample/platforms", selector: "all",
           platform: %w[discord telegram], label: ["Our Discord", "Telegram group"],
           url: ["https://discord.gg/abc", "https://t.me/xyz"]
      expect(last_response.status).to eq(302)

      expect(platforms_config).to eq(
        [
          { "platform" => "discord", "label" => "Our Discord", "url" => "https://discord.gg/abc" },
          { "platform" => "telegram", "label" => "Telegram group", "url" => "https://t.me/xyz" }
        ]
      )
    end

    it "drops a row with no url and defaults a missing label to the platform name" do
      post "/communities/sample/platforms", selector: "all",
           platform: %w[matrix irc], label: ["", ""],
           url: ["https://matrix.to/#/room", ""]

      expect(platforms_config).to eq(
        [{ "platform" => "matrix", "label" => "Matrix", "url" => "https://matrix.to/#/room" }]
      )
    end

    it "targets a room scope by endpoint key, leaving the community default untouched" do
      post "/communities/sample/platforms", selector: "tg-general",
           platform: %w[discord], label: ["Our Discord"], url: ["https://discord.gg/abc"]

      expect(platforms_config).to be_nil
      expect(platforms_config(room_id: general_room_id))
        .to eq([{ "platform" => "discord", "label" => "Our Discord", "url" => "https://discord.gg/abc" }])
    end

    it "is advertised live by the /platforms feature reading the same config" do
      post "/communities/sample/platforms", selector: "all",
           platform: %w[discord telegram], label: ["Our Discord", "Telegram group"],
           url: ["https://discord.gg/abc", "https://t.me/xyz"]

      expect(platforms_reply(feature_row(feature: "utility_commands").json_value(:config))).to eq(
        "Join this community on:\n- Our Discord: https://discord.gg/abc\n- Telegram group: https://t.me/xyz"
      )
    end
  end

  # A dashboard surface over the rows ChannelDiscovery records, driving the SAME
  # ControlPlane::ChannelMapper the bot DM console's `map` command drives.
  describe "discovered channels" do
    before { login! }

    # A discovered-but-unmapped channel row, the same shape ChannelDiscovery writes,
    # on an existing connection so it is a real addressable channel.
    def discovered_channel(adapter: "telegram", route_key:, label: nil)
      connection = models.platform_connection.where(community_id: community.id, adapter: adapter).first
      settings = adapter == "telegram" ? { chat_id: route_key } : { channel_id: route_key }
      prefix = Rubotty::ControlPlane::ChannelDiscovery::ENDPOINT_KEY_PREFIX
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: adapter, account: connection.account, route_key: route_key,
        endpoint_key: "#{prefix}:#{adapter}:#{connection.account}:#{route_key}",
        label: label, receives: true, sends: true, relay: "{}", display_name: "{}",
        settings: JSON.generate(settings), created_at: Time.now, updated_at: Time.now
      )
    end

    # An ordinary unmapped channel row, carrying no discovery prefix. A channel
    # still needs a room whatever created it, so it belongs in the same list.
    def normal_unmapped_channel(route_key:)
      connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "telegram", account: connection.account, route_key: route_key,
        endpoint_key: "manual-#{route_key}", label: "Manually added", receives: true, sends: true,
        relay: "{}", display_name: "{}", settings: JSON.generate(chat_id: route_key),
        created_at: Time.now, updated_at: Time.now
      )
    end

    describe "GET /communities/:slug/discovered" do
      it "keeps an old bookmark useful by redirecting to the unroomed Rooms view" do
        discovered_channel(adapter: "discord", route_key: "999888", label: "random-chat")
        get "/communities/sample/discovered"
        expect(last_response.status).to eq(302)
        expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms?state=unroomed")
      end
    end

    describe "POST /communities/:slug/discovered/:id/map" do
      it "maps an unroomed channel into an existing room and returns to Rooms" do
        channel = discovered_channel(adapter: "discord", route_key: "999888", label: "random-chat")

        post "/communities/sample/discovered/#{channel.id}/map", room_key: "general"
        expect(last_response.status).to eq(302)
        expect(last_response.headers["Location"]).to end_with("/communities/sample/rooms?state=unroomed")

        room = models.room.where(community_id: community.id, room_key: "general").first
        expect(models.room_channel.where(room_id: room.id, channel_id: channel.id).first).not_to be_nil
      end

      it "pairs two discovered channels into a fresh room when no existing room is picked" do
        a = discovered_channel(adapter: "telegram", route_key: "-100777", label: "tg-new")
        b = discovered_channel(adapter: "discord", route_key: "555000", label: "dc-new")

        post "/communities/sample/discovered/#{a.id}/map", partner: b.endpoint_key, label: "New Room"
        expect(last_response.status).to eq(302)

        room = models.room.where(community_id: community.id, room_key: "new-room").first
        expect(room).not_to be_nil
        channel_ids = models.room_channel.where(room_id: room.id).select_map(:channel_id)
        expect(channel_ids).to contain_exactly(a.id, b.id)
      end

      it "enables no feature as a side effect of mapping: the channel stays dormant" do
        channel = discovered_channel(adapter: "discord", route_key: "999888")
        before_count = models.feature_setting.count

        post "/communities/sample/discovered/#{channel.id}/map", room_key: "general"

        expect(models.feature_setting.count).to eq(before_count)
      end

      it "flashes a clear error and changes nothing when neither a room nor a partner is chosen" do
        channel = discovered_channel(adapter: "discord", route_key: "999888")

        expect { post "/communities/sample/discovered/#{channel.id}/map" }
          .not_to change { models.room_channel.count }
        follow_redirect!
        expect(last_response.body).to include("pick exactly one destination")
      end

      it "404s mapping a channel id that is not discovered-and-unmapped (already mapped)" do
        mapped = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first
        post "/communities/sample/discovered/#{mapped.id}/map", room_key: "general"
        expect(last_response.status).to eq(404)
      end
    end
  end

  # A suggested channel is a real row from the moment it exists, flagged until an
  # operator approves or rejects it from the Rooms board.
  describe "suggested topics (the /identify-topic non-operator path)" do
    before { login! }

    def suggested_channel(adapter: "telegram", route_key:, label: "Suggested Name")
      connection = models.platform_connection.where(community_id: community.id, adapter: adapter).first
      settings = adapter == "telegram" ? { chat_id: route_key } : { channel_id: route_key }
      prefix = Rubotty::ControlPlane::ChannelDiscovery::ENDPOINT_KEY_PREFIX
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: adapter, account: connection.account, route_key: route_key,
        endpoint_key: "#{prefix}:#{adapter}:#{connection.account}:#{route_key}",
        label: label, suggested: true, receives: true, sends: true, relay: "{}", display_name: "{}",
        settings: JSON.generate(settings), created_at: Time.now, updated_at: Time.now
      )
    end

    describe "GET /communities/:slug/rooms" do
      it "lists a suggested channel with its suggested name" do
        suggested_channel(route_key: "-100999", label: "Lisbon Meetup")
        get "/communities/sample/rooms"
        expect(last_response.body).to include("Lisbon Meetup")
      end

      it "shows nothing extra when there are no suggestions" do
        get "/communities/sample/rooms"
        expect(last_response.body).not_to include("Suggested topics")
      end
    end

    describe "POST /communities/:slug/suggested/:id/approve" do
      it "clears the suggested flag, leaving the row otherwise untouched" do
        channel = suggested_channel(route_key: "-100999")
        post "/communities/sample/suggested/#{channel.id}/approve"
        expect(last_response.status).to eq(302)
        expect(channel.reload.suggested).to be(false)
        expect(channel.reload.label).to eq("Suggested Name")
      end

      it "404s for a channel id that is not a pending suggestion" do
        mapped = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first
        post "/communities/sample/suggested/#{mapped.id}/approve"
        expect(last_response.status).to eq(404)
      end
    end

    describe "POST /communities/:slug/suggested/:id/reject" do
      it "clears the suggested name without removing the channel" do
        channel = suggested_channel(route_key: "-100999")
        post "/communities/sample/suggested/#{channel.id}/reject"
        expect(last_response.status).to eq(302)
        expect(channel.reload.label).to be_nil
        expect(channel.reload.suggested).to be(false)
      end

      it "404s for a channel id that is not a pending suggestion (never deletes a real channel)" do
        mapped = models.channel.where(community_id: community.id, endpoint_key: "tg-general").first
        post "/communities/sample/suggested/#{mapped.id}/reject"
        expect(last_response.status).to eq(404)
        expect(models.channel[mapped.id]).not_to be_nil
      end
    end
  end

  # A plain Telegram group with no forum topics is exactly ONE channel and can never
  # be paired, so a room may hold a single channel. These drive that through the real
  # dashboard write paths rather than a hand-seeded room row.
  describe "a community that lives on one channel" do
    before { login! }

    # The community as it arrives: approved, with one discovered channel and no room.
    def solo_community!
      now = Time.now
      account = models.platform_connection.where(community_id: community.id, adapter: "telegram").first.account
      row = models.community.create(
        slug: "sample_travel-mods", name: "TRAVEL Volunteer Moderators", status: "active",
        bootstrap_source: "pending-space-approval", created_at: now, updated_at: now
      )
      connection = models.platform_connection.create(
        community_id: row.id, adapter: "telegram", account: account, external_id: "-1001111",
        label: "TRAVEL Volunteer Moderators", created_at: now, updated_at: now
      )
      prefix = Rubotty::ControlPlane::ChannelDiscovery::ENDPOINT_KEY_PREFIX
      channel = models.channel.create(
        community_id: row.id, platform_connection_id: connection.id, adapter: "telegram",
        account: account, route_key: "-1001111",
        endpoint_key: "#{prefix}:telegram:#{account}:-1001111", label: "TRAVEL Volunteer Moderators",
        receives: true, sends: true, relay: "{}", display_name: "{}",
        settings: JSON.generate(chat_id: "-1001111"), created_at: now, updated_at: now
      )
      [row, channel]
    end

    # Map the lone channel into a room of its own and return the room that created.
    def map_solo!(channel)
      post "/communities/sample_travel-mods/discovered/#{channel.id}/map", solo: "1", label: "Main Group"
      models.room.where(community_id: models.community.where(slug: "sample_travel-mods").first.id).first
    end

    def solo_feature_row(room, feature)
      models.feature_setting.where(room_id: room.id, feature: feature).first
    end

    describe "the dead end, before anything is mapped" do
      it "explains it on the Guests page instead of showing a bare empty table" do
        solo_community!
        get "/communities/sample_travel-mods/guests"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("no rooms yet")
        expect(last_response.body).to include("a room may hold a single channel")
        # The old advice named a control that is not on the page.
        expect(last_response.body).not_to include("No room allows guests yet")
      end

      it "carries the same hint on the other room-scoped pages" do
        solo_community!
        %w[word-filter faq events].each do |section|
          get "/communities/sample_travel-mods/#{section}"
          expect(last_response.status).to eq(200)
          expect(last_response.body).to include("no rooms yet")
        end
      end

      it "leaves a community that HAS rooms alone" do
        get "/communities/sample/guests"
        expect(last_response.body).not_to include("no rooms yet")
      end
    end

    describe "mapping the lone channel into a room of its own" do
      it "creates a room holding just that channel and leaves it out of Needs a room" do
        _row, channel = solo_community!

        expect { map_solo!(channel) }.to change { models.room.count }.by(1)
        room = models.room.where(room_key: "main-group").first
        expect(models.room_channel.where(room_id: room.id).select_map(:channel_id)).to eq([channel.id])

        get "/internal/communities/sample_travel-mods/rooms", state: "unroomed"
        payload = YAMLCamel.load(last_response.body)
        expect(payload.fetch("channels").map { |row| row.fetch("endpoint_key") }).not_to include(channel.endpoint_key)
      end

      it "enables no feature: the channel is in a room and still dormant" do
        _row, channel = solo_community!

        expect { map_solo!(channel) }.not_to change { models.feature_setting.count }
      end

      it "makes every room-scoped feature configurable, through the dashboard's own write paths" do
        _row, channel = solo_community!
        room = map_solo!(channel)

        post "/communities/sample_travel-mods/word-filter", selector: room.room_key, op: "enable"
        post "/communities/sample_travel-mods/faq", selector: room.room_key, op: "enable"
        post "/communities/sample_travel-mods/features", selector: room.room_key, feature: "events", op: "enable"
        post "/communities/sample_travel-mods/guests/access", room: room.room_key, allowed: "on",
                                                    who_can_invite: "operators"

        expect(enabled?(solo_feature_row(room, "word_filter"))).to be(true)
        expect(enabled?(solo_feature_row(room, "faq"))).to be(true)
        expect(enabled?(solo_feature_row(room, "events"))).to be(true)
        expect(enabled?(solo_feature_row(room, "guest_portal"))).to be(true)
      end

      it "offers the room on the Guests page, and issues a guest link scoped to it" do
        _row, channel = solo_community!
        room = map_solo!(channel)
        post "/communities/sample_travel-mods/guests/access", room: room.room_key, allowed: "on",
                                                    who_can_invite: "operators"

        get "/communities/sample_travel-mods/guests"
        expect(last_response.body).to include("Main Group")
        expect(last_response.body).not_to include("no rooms yet")

        expect { post "/communities/sample_travel-mods/guests", room: room.room_key, nickname: "Visiting Reviewer", ttl_hours: "2" }
          .to change { models.guest_invite.where(room_id: room.id).count }.by(1)
      end

      it "adds a second platform's channel to that SAME room later, creating no duplicate" do
        row, channel = solo_community!
        room = map_solo!(channel)

        now = Time.now
        account = models.platform_connection.where(community_id: community.id, adapter: "discord").first.account
        connection = models.platform_connection.create(
          community_id: row.id, adapter: "discord", account: account, external_id: "777000",
          label: "TRAVEL on Discord", created_at: now, updated_at: now
        )
        prefix = Rubotty::ControlPlane::ChannelDiscovery::ENDPOINT_KEY_PREFIX
        later = models.channel.create(
          community_id: row.id, platform_connection_id: connection.id, adapter: "discord",
          account: account, route_key: "777000",
          endpoint_key: "#{prefix}:discord:#{account}:777000", label: "mods-chat",
          receives: true, sends: true, relay: "{}", display_name: "{}",
          settings: JSON.generate(channel_id: "777000"), created_at: now, updated_at: now
        )

        expect { post "/communities/sample_travel-mods/discovered/#{later.id}/map", room_key: room.room_key }
          .not_to change { models.room.where(community_id: row.id).count }
        expect(models.room_channel.where(room_id: room.id).select_map(:channel_id))
          .to contain_exactly(channel.id, later.id)
      end
    end
  end

  describe "community start/stop" do
    before { login! }

    it "stops and restarts a community through CommunityLifecycle" do
      # sample is protected (config/protected_communities.yml), so generic stop/start
      # mechanics need a community the guard does not cover.
      now = Time.now
      row = models.community.create(slug: "stoppable-co", name: "Stoppable Co", status: "active",
                                     bootstrap_source: "seed", created_at: now, updated_at: now)

      post "/communities/stoppable-co/stop"
      expect(row.refresh.status).to eq("suspended")

      post "/communities/stoppable-co/start"
      expect(row.refresh.status).to eq("active")
    end

    it "preserves configured community protection after a display-name change" do
      policy = Rubotty::ControlPlane::ProtectedCommunities.new(community_slugs: [community.slug])
      allow(Rubotty::ControlPlane::ProtectedCommunities).to receive(:default).and_return(policy)
      community.update(name: "Renamed")

      post "/communities/sample/stop"

      expect(community.refresh.status).to eq("active")
    end

    it "refuses to stop a protected community" do
      post "/communities/sample/stop"
      expect(community.refresh.status).to eq("active")
    end
  end

  describe "operator requests" do
    before { login! }

    def make_request
      deps.operators.request(community_id: community.id, adapter: "telegram",
                             native_id: "424242", username: "newbie", display: "New Bie").request
    end

    it "approves a pending request, promoting the requester to operator" do
      request = make_request
      expect { post "/communities/sample/operators/#{request.id}/approve" }
        .to change { models.operator.where(community_id: community.id).count }.by(1)
      expect(request.refresh.state).to eq("approved")
    end

    it "denies a pending request without promoting anyone" do
      request = make_request
      expect { post "/communities/sample/operators/#{request.id}/deny" }
        .not_to change { models.operator.where(community_id: community.id).count }
      expect(request.refresh.state).to eq("denied")
    end

    it "saves operator-editable permission switches" do
      post "/operator-permissions", back: "/communities/sample/operators",
                                    permissions: { "configure_faq" => "1" }

      expect(last_response.status).to eq(302)
      expect(deps.action_permissions.operator_write_actions).to eq([:configure_faq])
    end
  end

  # The deployment-configured "always operators" fail-safe, displayed and protected.
  describe "deployment-configured operators (issue #153)" do
    before { login! }

    # OperatorFlow#promote, not request+approve: a request from a deployment-configured
    # username now resolves as already an operator, since #resolve_operator
    # asks the floor. promote already assumes the grant is deserved.
    def promote(native_id:, username:, display: "Someone")
      deps.operators.promote(community_id: community.id, adapter: "telegram", native_id: native_id,
                             username: username, display: display, granted_by: "test")
    end

    it "shows the deployment-configured always-operators (issue #119) as protected rows" do
      get "/communities/sample/operators"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("maintainer")
      expect(last_response.body).to include("owner_handle")
      expect(last_response.body).to include("@owner:matrix.example.org")
      expect(last_response.body).to include("deployment-configured")
      expect(last_response.body).to include("issue #119")
    end

    it "renders no delete control for a deployment-configured row" do
      get "/communities/sample/operators"
      # A deployment-configured row carries no operator id, so the delete forms on the page must
      # number exactly the real DB operator rows.
      delete_forms = last_response.body.scan(%r{/operators/\d+/delete}).uniq
      expect(delete_forms.size).to eq(models.operator.where(community_id: community.id).count)
    end

    it "deletes an ordinary DB operator row" do
      operator = promote(native_id: "424242", username: "newbie")
      expect { post "/communities/sample/operators/#{operator.id}/delete" }
        .to change { models.operator.where(community_id: community.id).count }.by(-1)
    end

    it "refuses to delete a DB operator row whose person is also a deployment-configured owner, even invoked directly" do
      operator = promote(native_id: "5551212", username: "maintainer")

      expect { post "/communities/sample/operators/#{operator.id}/delete" }
        .not_to change { models.operator.where(id: operator.id).count }
      follow_redirect!
      expect(last_response.body).to include("baked in and protected")
    end
  end

  # The deployment's credentialed gateway connections. One bot token serves every
  # community, so these routes are top-level and take no slug.
  describe "accounts" do
    before { login! }

    def accounts_rows = models.account.order(:adapter, :name).all

    describe "the listing page" do
      it "renders for an administrator" do
        get "/accounts"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("Accounts")
      end

      it "offers every registered adapter in the picker, not a hardcoded list" do
        get "/accounts"
        expect(last_response.body).to include("telegram").and include("discord")
      end

      # Each adapter declares its own account_schema, so the add form has no fields
      # until one is chosen.
      it "renders the chosen adapter's OWN schema fields once one is picked" do
        get "/accounts", adapter: "telegram"
        expect(last_response.body).to include("token_env").and include("transport")
        expect(last_response.body).to include("skip_backlog")
      end

      it "renders a different adapter's different fields" do
        get "/accounts", adapter: "discord"
        expect(last_response.body).to include("intents")
        expect(last_response.body).not_to include("skip_backlog")
      end

      it "flashes rather than 500s on an adapter nothing is registered under" do
        get "/accounts", adapter: "nosuchplatform"
        expect(last_response.status).to eq(200)
        expect(last_response.body).to include("unknown adapter")
      end

      it "shows a stored account and whether its env var is set in this process" do
        deps.accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "DASHBOARD_SECRET" })
        get "/accounts"
        expect(last_response.body).to include("telegram/tg")
        expect(last_response.body).to include("DASHBOARD_SECRET")
        expect(last_response.body).to include("key present")
      end

      it "shows an account whose env var is NOT set as not set, without revealing anything" do
        deps.accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "NOT_SET_ANYWHERE" })
        get "/accounts"
        expect(last_response.body).to include("not set in this process")
      end

      # The page shows the env var NAME; no secret is stored, so none is redacted.
      it "never renders a resolved token, only the variable's name" do
        deps.accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "DASHBOARD_SECRET" })
        get "/accounts"
        expect(last_response.body).not_to include(secret)
      end

      it "labels a yaml_seed row differently from an operator-added one" do
        deps.accounts.create(adapter: "telegram", name: "from_file", settings: { "token_env" => "A" },
                             source: Rubotty::ControlPlane::Accounts::SOURCE_YAML)
        deps.accounts.create(adapter: "telegram", name: "from_panel", settings: { "token_env" => "B" })
        get "/accounts"
        expect(last_response.body).to include("from bridge.config.yaml").and include("added here")
      end
    end

    describe "adding an account" do
      it "creates a row from the adapter, name and its schema fields" do
        expect do
          post "/accounts", adapter: "telegram", name: "tg_second", token_env: "TG_SECOND"
        end.to change { accounts_rows.count }.by(1)
        expect(last_response.status).to eq(302)

        created = accounts_rows.find { |row| row.name == "tg_second" }
        expect(created.adapter).to eq("telegram")
        expect(created.json_value(:settings)).to include("token_env" => "TG_SECOND")
        expect(created.source).to eq(Rubotty::ControlPlane::Accounts::SOURCE_DASHBOARD)
      end

      it "keeps a non-default field the operator changed" do
        post "/accounts", adapter: "telegram", name: "tg_hook", token_env: "TG_HOOK",
                          transport: "webhook", webhook_url: "https://example.test/hook"
        expect(accounts_rows.find { |row| row.name == "tg_hook" }.json_value(:settings))
          .to include("transport" => "webhook")
      end

      it "rejects settings the target adapter's own schema refuses, creating nothing" do
        expect do
          post "/accounts", adapter: "telegram", name: "tg", token_env: "T", transport: "carrier_pigeon"
        end.not_to(change { accounts_rows.count })
        follow_redirect!
        expect(last_response.body).to include("must be one of")
      end

      it "rejects a missing required field, creating nothing" do
        expect do
          post "/accounts", adapter: "telegram", name: "tg", token_env: ""
        end.not_to(change { accounts_rows.count })
        follow_redirect!
        expect(last_response.body).to include("token_env")
      end

      it "rejects a blank name, creating nothing" do
        expect do
          post "/accounts", adapter: "telegram", name: "", token_env: "T"
        end.not_to(change { accounts_rows.count })
      end

      it "rejects a duplicate (adapter, name)" do
        post "/accounts", adapter: "telegram", name: "tg", token_env: "T"
        expect do
          post "/accounts", adapter: "telegram", name: "tg", token_env: "T2"
        end.not_to(change { accounts_rows.count })
        follow_redirect!
        expect(last_response.body).to include("already exists")
      end

      it "rejects an unknown adapter, creating nothing" do
        expect do
          post "/accounts", adapter: "nosuchplatform", name: "x", token_env: "T"
        end.not_to(change { accounts_rows.count })
      end

      # The form reader whitelists the adapter's declared fields, so a hand-crafted
      # POST carrying a raw `token` is never read at all.
      it "ignores a raw token posted alongside, storing only the declared fields" do
        post "/accounts", adapter: "telegram", name: "tg", token_env: "TG_TOKEN", token: "123:abc"
        created = accounts_rows.find { |row| row.name == "tg" }
        expect(created.json_value(:settings)).to eq("token_env" => "TG_TOKEN")
        expect(created.settings).not_to include("123:abc")
      end
    end

    describe "editing an account" do
      let!(:row) do
        deps.accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "TG_TOKEN" })
      end

      it "saves the submitted schema fields" do
        post "/accounts/#{row.id}", token_env: "TG_OTHER", poll_timeout: "60"
        expect(row.reload.json_value(:settings)).to eq("token_env" => "TG_OTHER", "poll_timeout" => 60)
      end

      it "refuses an invalid edit, leaving the row alone" do
        post "/accounts/#{row.id}", token_env: "TG_OTHER", transport: "nope"
        expect(row.reload.json_value(:settings)).to eq("token_env" => "TG_TOKEN")
        follow_redirect!
        expect(last_response.body).to include("must be one of")
      end

      it "404s for an id that is not there" do
        post "/accounts/999999", token_env: "X"
        expect(last_response.status).to eq(404)
      end
    end

    describe "removing an account" do
      it "removes the row" do
        row = deps.accounts.create(adapter: "telegram", name: "tg", settings: { "token_env" => "T" })
        expect { post "/accounts/#{row.id}/delete" }.to change { accounts_rows.count }.by(-1)
      end

      it "reports an id that is not there rather than 500ing" do
        post "/accounts/999999/delete"
        expect(last_response.status).to eq(302)
        follow_redirect!
        expect(last_response.body).to include("No such account")
      end
    end

    describe "the session gate" do
      it "gates the listing behind a session" do
        post "/logout"
        get "/accounts"
        expect(last_response.headers["location"]).to end_with("/login")
      end

      it "gates a create behind a session, performing no change" do
        post "/logout"
        expect do
          post "/accounts", adapter: "telegram", name: "tg", token_env: "T"
        end.not_to(change { accounts_rows.count })
        expect(last_response.headers["location"]).to end_with("/login")
      end
    end
  end

  # The push nudge fires after a write POST, and only then.
  describe "the push nudge" do
    let(:nudge) { instance_double(Rubotty::Dashboard::BotNudge) }
    let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env, bot_nudge: nudge) }

    before { allow(nudge).to receive(:nudge).and_return(true) }

    it "nudges the bot after a control-plane write" do
      login!
      expect(nudge).to receive(:nudge).with(reason: a_string_matching(%r{/communities/sample/features}))
      post "/communities/sample/features", selector: "all", feature: "faq", op: "enable"
    end

    it "does not nudge on a GET, which writes nothing" do
      login!
      expect(nudge).not_to receive(:nudge)
      get "/communities/sample/features"
    end

    it "does not nudge on the login POST, which touches no control-plane row" do
      expect(nudge).not_to receive(:nudge)
      login!
    end
  end

  describe "the licence page" do
    it "serves the standard licence and full contribution policy inline" do
      login!
      get "/licence"

      expect(last_response.status).to eq(200)
      expect(last_response.body)
        .to include("PolyForm Strict License 1.0.0")
        .and include("Spark Contribution Agreement 1.1.0")
        .and include("Rubotty Deployment Addendum 1.0.0")
    end

    it "shows the running version and links the footer to the public licence" do
      stub_const("Rubotty::VERSION", "1.2.3+fixture")
      login!
      get "/"

      footer = last_response.body[%r{<footer[^>]*id="rb-footer".*?</footer>}m]
      expect(footer).to include("Rubotty v1.2.3+fixture. Copyright Spark Software Development, LLC.")
      expect(footer).to include(
        %(Operation requires adherence to our <a href="https://github.com/sparkdotdev/rubotty/blob/main/LICENSE.MD">License Terms</a>.)
      )
    end

    # Derived from the map rather than spelled out, so adding a route there is
    # covered without anyone remembering to widen this.
    it "uses local links inside the rendered documents" do
      login!
      get "/documentation"
      documentation = last_response.body
      get "/licence"
      rendered = (documentation + last_response.body).gsub(%r{<footer[^>]*id="rb-footer".*?</footer>}m, "")

      Rubotty::Dashboard::ReadmeRenderer::IN_APP_DOCS.each do |target, _route|
        expect(rendered).not_to include("github.com/sparkdotdev/rubotty/blob/main/#{target}")
      end
      expect(rendered).to include(%(href="/licence"))
      expect(rendered).to include(%(href="/licence#contribution-policy"))
    end

    # Whether you may deploy at all is the question the licence answers, and the
    # person asking it has no session yet.
    it "is readable without logging in" do
      get "/licence"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("PolyForm Strict License 1.0.0")
    end
  end
end
