# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"

# The REST admin API, driven in-process with rack-test over the seeded SAMPLE control
# plane, so no socket ever opens. The two authorization-failure shapes are what these
# watch hardest: a developer key on an admin-only route gets 403, while a developer
# key naming another community's slug on a route it can generally use gets 404.
RSpec.describe Rubotty::Api::App, :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 3) }
  let(:app) { Rubotty::Api::App.assemble(deps: deps, env: {}) }

  let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }

  def other_community
    models.community.create(
      slug: "other-co", name: "Other Co", status: "active", settings: "{}",
      created_at: Time.now, updated_at: Time.now
    )
  end

  def developer_token(on: community)
    keys.issue(scope: "developer", community: on, label: "test developer key").token
  end

  def administrator_token
    keys.issue(scope: "administrator", label: "test admin key").token
  end

  def bearer(token)
    { "HTTP_AUTHORIZATION" => "Bearer #{token}" }
  end

  describe "GET /healthz" do
    it "answers without a bearer token, as plain text" do
      get "/healthz"
      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("text/plain")
      expect(last_response.body).to include("ok")
    end

    # The one unauthenticated path here, so it must not hand an anonymous
    # caller the exact release this deployment is running.
    it "does not carry the build version" do
      get "/healthz"

      expect(last_response.headers).not_to have_key(Rubotty::Api::App::VERSION_HEADER)
    end
  end

  # Answers "has the fix deployed yet" in one request, rather than leaving it
  # to be inferred from whether some unrelated payload has gained a field.
  describe "the build version" do
    it "rides on an authenticated response" do
      get "/communities/sample", {}, bearer(developer_token)

      expect(last_response.headers[Rubotty::Api::App::VERSION_HEADER]).to eq(Rubotty::VERSION.to_s)
    end
  end

  describe "authentication" do
    it "rejects a request with no Authorization header" do
      get "/communities/sample"
      expect(last_response.status).to eq(401)
      expect(last_response.content_type).to start_with("application/yaml")
    end

    it "rejects a malformed Authorization header" do
      get "/communities/sample", {}, { "HTTP_AUTHORIZATION" => "Token abc" }
      expect(last_response.status).to eq(401)
    end

    it "rejects an unknown token" do
      get "/communities/sample", {}, bearer("not-a-real-token")
      expect(last_response.status).to eq(401)
    end

    it "rejects a revoked key's token" do
      issued = keys.issue(scope: "developer", community: community, label: "revoked")
      keys.revoke_by_public_id(public_id: issued.key_row.public_id)
      get "/communities/sample", {}, bearer(issued.token)
      expect(last_response.status).to eq(401)
    end

    it "accepts a live developer token and stamps last_used_at" do
      token = developer_token
      get "/communities/sample", {}, bearer(token)
      expect(last_response.status).to eq(200)
      row = models.api_key.where(key_hash: Rubotty::ControlPlane::ApiKeys.hash_token(token)).first
      expect(row.last_used_at).not_to be_nil
    end

    it "429s once the per-key request budget (3, set above) is exhausted" do
      token = developer_token
      3.times { get "/communities/sample", {}, bearer(token) }
      get "/communities/sample", {}, bearer(token)
      expect(last_response.status).to eq(429)
      expect(last_response.headers["Retry-After"]).not_to be_nil
    end
  end

  describe "GET /communities/:slug" do
    it "returns YAML, never JSON" do
      get "/communities/sample", {}, bearer(developer_token)
      expect(last_response.content_type).to start_with("application/yaml")
      body = YAMLCamel.load(last_response.body)
      expect(body["slug"]).to eq("sample")
      expect(body["name"]).to eq(community.name)
    end

    it "lets an administrator key read any community" do
      other = other_community
      get "/communities/#{other.slug}", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
    end

    it "404s, not 403, when a developer key names another community's real slug" do
      other_community
      get "/communities/other-co", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "404s identically for a slug that does not exist at all" do
      get "/communities/does-not-exist", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end
  end

  describe "room and channel topology" do
    it "lists a community's rooms, each carrying its channels' endpoint_keys" do
      get "/communities/sample/rooms", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      rooms = YAMLCamel.load(last_response.body)["rooms"]
      general = rooms.find { |row| row["room_key"] == "general" }
      expect(general["channels"]).to include("tg-general", "dc-general")
    end

    it "reads a single room by room_key" do
      get "/communities/sample/rooms/general", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["room_key"]).to eq("general")
    end

    it "404s a room_key that exists in a DIFFERENT community, not this one" do
      other_community
      get "/communities/sample/rooms/does-not-exist-here", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "lists a community's channels" do
      get "/communities/sample/channels", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      endpoint_keys = YAMLCamel.load(last_response.body)["channels"].map { |row| row["endpoint_key"] }
      expect(endpoint_keys).to include("tg-general", "dc-general")
    end

    it "reads a single channel by endpoint_key" do
      get "/communities/sample/channels/tg-general", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["endpoint_key"]).to eq("tg-general")
      expect(body["adapter"]).to eq("telegram")
    end

    it "404s a developer key reading another community's room, not 403" do
      other = other_community
      models.room.create(
        community_id: other.id, room_key: "secret", display_name: "{}",
        created_at: Time.now, updated_at: Time.now
      )
      get "/communities/#{other.slug}/rooms/secret", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end
  end

  describe "people, operators and operator requests" do
    def create_person(name: "Alex")
      models.person.create(community_id: community.id, name: name, created_at: Time.now, updated_at: Time.now)
    end

    it "lists people with their linked identities" do
      person = create_person
      models.person_identity.create(
        person_id: person.id, adapter: "telegram", native_id: "123", username: "alex", created_at: Time.now
      )
      get "/communities/sample/people", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      row = YAMLCamel.load(last_response.body)["people"].find { |entry| entry["id"] == person.id }
      expect(row["identities"]).to eq([{ "adapter" => "telegram", "native_id" => "123", "username" => "alex" }])
    end

    it "reads a single person by id" do
      person = create_person
      get "/communities/sample/people/#{person.id}", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["name"]).to eq("Alex")
    end

    it "lists operators, resolving the person's name and the parsed JSON action/scope columns" do
      person = create_person
      created = models.operator.create(
        community_id: community.id, person_id: person.id, actions: '"all"', scope: '"all"',
        granted_at: Time.now, granted_by: "dashboard:administrator"
      )
      get "/communities/sample/operators", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      row = YAMLCamel.load(last_response.body)["operators"].find { |entry| entry["id"] == created.id }
      expect(row["person"]).to eq("Alex")
      expect(row["actions"]).to eq("all")
    end

    it "lists operator requests regardless of state" do
      models.operator_request.create(
        community_id: community.id, adapter: "telegram", requester_native_id: "999",
        state: "pending", requested_at: Time.now
      )
      get "/communities/sample/operator-requests", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["operator_requests"].size).to eq(1)
    end

    it "404s, not 403, for a person id that belongs to another community" do
      other = other_community
      person = models.person.create(community_id: other.id, name: "Ghost", created_at: Time.now, updated_at: Time.now)
      get "/communities/sample/people/#{person.id}", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end
  end

  describe "GET /communities/:slug/discovered-channels" do
    it "lists a discovered, unmapped channel and excludes a mapped one" do
      connection = models.platform_connection.where(community_id: community.id, adapter: "discord").first
      unmapped = models.channel.create(
        community_id: community.id, platform_connection_id: connection.id, adapter: "discord",
        account: connection.account, route_key: "999888777", endpoint_key: "discovered:discord:new-channel",
        created_at: Time.now, updated_at: Time.now
      )
      get "/communities/sample/discovered-channels", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      keys = YAMLCamel.load(last_response.body)["discovered_channels"].map { |row| row["endpoint_key"] }
      expect(keys).to include(unmapped.endpoint_key)
      expect(keys).not_to include("tg-general")
    end
  end

  describe "feature toggles and per-scope config" do
    let(:feature_controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

    it "reads the community-wide default for a feature" do
      feature_controls.enable(community: community, selector: "all", feature: "faq")
      get "/communities/sample/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["scope"]).to eq("community")
      expect(body["enabled"]).to be(true)
    end

    it "404s a feature with no row at the requested scope" do
      get "/communities/sample/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "reads a room's own feature override, distinct from the community default" do
      feature_controls.enable(community: community, selector: "all", feature: "faq")
      feature_controls.disable(community: community, selector: "general", feature: "faq")
      get "/communities/sample/rooms/general/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["scope"]).to eq("room")
      expect(body["room_key"]).to eq("general")
      expect(body["enabled"]).to be(false)
      expect(body["inherited"]).to be(false)
    end

    # This used to 404 for any room with no row of its own, which is the
    # ordinary case, so the read could not answer whether a room had overridden
    # anything. The room exists and the community has the feature, so there is
    # an answer to give.
    it "reads the inherited community default for a room with no override of its own" do
      feature_controls.enable(community: community, selector: "all", feature: "faq")
      feature_controls.set(community: community, selector: "all", feature: "faq", key: "prefix", value: "!")

      get "/communities/sample/rooms/general/features/faq", {}, bearer(developer_token)

      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["inherited"]).to be(true)
      expect(body["scope"]).to eq("community")
      expect(body["room_key"]).to eq("general")
      expect(body["enabled"]).to be(true)
      expect(body["config"]["prefix"]).to eq("!")
    end

    it "404s a room feature neither the room nor the community has configured" do
      get "/communities/sample/rooms/general/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "404s a room feature read naming a room that does not exist" do
      feature_controls.enable(community: community, selector: "all", feature: "faq")
      get "/communities/sample/rooms/does-not-exist/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "404s a room feature read for another community's slug, never 403" do
      other = other_community
      feature_controls.enable(community: other, selector: "all", feature: "faq")
      get "/communities/other-co/rooms/general/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "lists every explicitly-set feature for a room" do
      feature_controls.enable(community: community, selector: "general", feature: "faq")
      get "/communities/sample/rooms/general/features", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      features = YAMLCamel.load(last_response.body)["features"].map { |row| row["feature"] }
      expect(features).to include("faq")
    end

    it "404s a room that does not exist rather than an empty features list" do
      get "/communities/sample/rooms/does-not-exist/features", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "PATCHes the community-wide default's enabled state, form-encoded" do
      patch "/communities/sample/features/faq", { "enabled" => "true" }, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["enabled"]).to be(true)
      expect(body["scope"]).to eq("community")
    end

    it "PATCHes a room's config via a YAML body, in the same request as enabling it" do
      yaml_body = YAMLCamel.dump({ "enabled" => true, "config" => { "mode" => "warn" } })
      patch "/communities/sample/rooms/general/features/word_filter", yaml_body,
            bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["enabled"]).to be(true)
      expect(body["config"]["mode"]).to eq("warn")
    end

    it "PATCHes a list-of-mappings config field via a YAML body without corrupting it" do
      entries = [
        { "word" => "foo", "action" => "warn" },
        { "word" => "bar", "action" => "delete" }
      ]
      yaml_body = YAMLCamel.dump({ "config" => { "entries" => entries } })
      patch "/communities/sample/features/word_filter", yaml_body,
            bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["config"]["entries"]).to eq(entries)
    end

    it "400s a YAML body that isn't a mapping" do
      patch "/communities/sample/features/faq", "- just\n- an\n- array\n",
            bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(400)
    end

    it "400s when config is present but not a mapping" do
      patch "/communities/sample/features/faq", { "config" => "not-a-hash" }, bearer(developer_token)
      expect(last_response.status).to eq(400)
    end

    it "rejects a non-mapping config before changing the enabled state" do
      feature_controls.enable(community: community, selector: "all", feature: "faq")
      patch "/communities/sample/features/faq", YAMLCamel.dump({ "enabled" => false, "config" => [] }),
            bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(400)
      expect(feature_controls.list(community, selector: "all").find { |row| row[:feature] == "faq" }[:enabled]).to be(true)
    end

    it "rolls back the toggle and earlier config keys when a later config key is refused" do
      feature_controls.enable(community: community, selector: "general", feature: "backfill")
      before = feature_controls.list(community, selector: "general").find { |row| row[:feature] == "backfill" }
      patch "/communities/sample/rooms/general/features/backfill",
            YAMLCamel.dump({ "enabled" => false, "config" => {
              "auto_relay_limit" => 5, "safe_horizon_seconds" => Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL
            } }), bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(422)
      after = feature_controls.list(community, selector: "general").find { |row| row[:feature] == "backfill" }
      expect(after).to eq(before)
    end

    # A safe_horizon_seconds equal to relay_claim_ttl let a message at the
    # edge of the window lose its dedup claim the instant the sweep re-read it.
    # FeatureControls refuses that regardless of which surface writes it; this is
    # the API's own path to the same check the dashboard and CLI go through.
    it "422s a backfill safe_horizon_seconds too close to relay_claim_ttl" do
      ttl = Rubotty::Config::Model::DEFAULT_RELAY_CLAIM_TTL
      patch "/communities/sample/features/backfill", { "config" => { "safe_horizon_seconds" => ttl.to_s } },
            bearer(developer_token)
      expect(last_response.status).to eq(422)
      expect(YAMLCamel.load(last_response.body)["error"]).to match(/relay_claim_ttl/)
    end

    it "DELETE resets a room's override back to inheriting the community default" do
      feature_controls.enable(community: community, selector: "all", feature: "faq")
      feature_controls.disable(community: community, selector: "general", feature: "faq")

      delete "/communities/sample/rooms/general/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(204)

      get "/communities/sample/rooms/general/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["inherited"]).to be(true)
      expect(body["enabled"]).to be(true)
    end

    it "DELETE 404s when there was no room override to remove" do
      delete "/communities/sample/rooms/general/features/faq", {}, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end
  end

  describe "word filter, FAQ and join-link entries" do
    it "reads the community-wide word filter list" do
      Rubotty::ControlPlane::WordFilterEntries.new(feature_controls: Rubotty::ControlPlane::FeatureControls.new(models: models))
                                              .replace(community: community, selector: "all", entries: ["banned"])
      get "/communities/sample/word-filter/entries", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["entries"]).to eq(["banned"])
    end

    it "reads FAQ entries with their stable ids" do
      Rubotty::ControlPlane::FaqEntries.new(feature_controls: Rubotty::ControlPlane::FeatureControls.new(models: models))
                                       .add(community: community, selector: "all", trigger: "rules", response: "be nice",
                                            trigger_type: "command")
      get "/communities/sample/faq/entries", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      entry = YAMLCamel.load(last_response.body)["entries"].first
      expect(entry["response"]).to eq("be nice")
      expect(entry["id"]).not_to be_nil
    end

    it "reads the community's public join links" do
      Rubotty::ControlPlane::PlatformLinks.new(feature_controls: Rubotty::ControlPlane::FeatureControls.new(models: models))
                                          .replace(community: community, selector: "all",
                                                    entries: [{ platform: "discord", url: "https://discord.gg/x" }])
      get "/communities/sample/join-links", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      link = YAMLCamel.load(last_response.body)["join_links"].first
      expect(link["url"]).to eq("https://discord.gg/x")
    end
  end

  describe "structural connection config" do
    it "lists platform connections" do
      get "/communities/sample/platform-connections", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      adapters = YAMLCamel.load(last_response.body)["platform_connections"].map { |row| row["adapter"] }
      expect(adapters).to include("telegram", "discord")
    end

    it "reads a single IRC network by name, exposing only the env var NAME for its SASL password" do
      models.irc_network.create(
        community_id: community.id, name: "libera", host: "irc.libera.chat", port: 6697, tls: true, nick: "rubotty",
        sasl_password_env: "LIBERA_SASL_PASSWORD", channels: "[]", mode: "per_room",
        created_at: Time.now, updated_at: Time.now
      )
      get "/communities/sample/irc-networks/libera", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["sasl_password_env"]).to eq("LIBERA_SASL_PASSWORD")
    end

    it "reads a single Fluxer instance by label, exposing only the env var NAME for its API key" do
      models.fluxer_instance.create(
        community_id: community.id, label: "Self-hosted", kind: "self_hosted", endpoint_url: "https://fluxer.example",
        api_key_env: "FLUXER_API_KEY", created_at: Time.now, updated_at: Time.now
      )
      get "/communities/sample/fluxer-instances/Self-hosted", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["api_key_env"]).to eq("FLUXER_API_KEY")
    end
  end

  describe "GET /communities/:slug/guest-invites" do
    it "lists an invite without ever exposing its token" do
      room = models.room.where(community_id: community.id, room_key: "general").first
      Rubotty::ControlPlane::FeatureControls.new(models: models)
                                            .enable(community: community, selector: "general", feature: "guest_portal")
      invite = Rubotty::ControlPlane::GuestInvites.new(models: models)
                                                   .issue(community: community, room: room, nickname: "Reviewer", ttl_seconds: 3600)
      get "/communities/sample/guest-invites", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      body = last_response.body
      expect(body).not_to include(invite.token)
      row = YAMLCamel.load(body)["guest_invites"].first
      expect(row["nickname"]).to eq("Reviewer")
      expect(row["room_key"]).to eq("general")
    end
  end

  describe "events" do
    let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

    before do
      Rubotty::ControlPlane::FeatureControls.new(models: models)
                                            .enable(community: community, selector: "general", feature: "events")
    end

    it "lists a room's upcoming events" do
      Rubotty::ControlPlane::EventScheduling.new(models: models).create(
        community: community, room: room, as: "operator", title: "Movie night",
        starts_at: Time.now + 86_400, kind: "general"
      )
      get "/communities/sample/rooms/general/events", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      titles = YAMLCamel.load(last_response.body)["events"].map { |row| row["title"] }
      expect(titles).to include("Movie night")
    end

    it "reads a single event by id" do
      created = Rubotty::ControlPlane::EventScheduling.new(models: models).create(
        community: community, room: room, as: "operator", title: "Movie night",
        starts_at: Time.now + 86_400, kind: "general"
      )
      get "/communities/sample/events/#{created.id}", {}, bearer(developer_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["title"]).to eq("Movie night")
    end
  end

  describe "GET /admin/communities/:slug/stats" do
    it "403s a developer key outright" do
      get "/admin/communities/sample/stats", {}, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "returns the community's analytics overview for an administrator key" do
      get "/admin/communities/sample/stats", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body).to have_key("moderation")
      expect(body).to have_key("members")
    end
  end

  describe "GET /admin/accounts" do
    it "403s a developer key outright" do
      get "/admin/accounts", {}, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    def create_account
      models.account.create(
        adapter: "telegram", name: "telegram", settings: '{"token_env":"TELEGRAM_BOT_TOKEN"}',
        source: "dashboard", created_at: Time.now, updated_at: Time.now
      )
    end

    it "lists accounts for an administrator key, settings included, never a raw secret" do
      create_account
      get "/admin/accounts", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      row = YAMLCamel.load(last_response.body)["accounts"].first
      expect(row["settings"]).to eq({ "token_env" => "TELEGRAM_BOT_TOKEN" })
    end

    it "reads a single account by adapter and name" do
      account = create_account
      get "/admin/accounts/#{account.adapter}/#{account.name}", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["adapter"]).to eq(account.adapter)
    end
  end

  describe "GET /admin/action-permissions" do
    it "403s a developer key outright" do
      get "/admin/action-permissions", {}, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "lists every action in the catalog for an administrator key" do
      get "/admin/action-permissions", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      rows = YAMLCamel.load(last_response.body)["permissions"]
      expect(rows.map { |row| row["action"] }).to include("toggle_word_filter", "moderate_user")
      row = rows.first
      expect(row.keys).to contain_exactly("action", "label", "group", "operator_writable")
    end
  end

  describe "PATCH /admin/action-permissions" do
    it "403s a developer key outright" do
      patch "/admin/action-permissions", { "permissions" => { "moderate_user" => "1" } }, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "400s a body with no permissions mapping" do
      patch "/admin/action-permissions", {}, bearer(administrator_token)
      expect(last_response.status).to eq(400)
    end

    it "makes every listed action writable and every unlisted one not, on one call" do
      patch "/admin/action-permissions", { "permissions" => { "moderate_user" => "1", "manage_rooms" => "1" } },
            bearer(administrator_token)
      expect(last_response.status).to eq(200)
      rows = YAMLCamel.load(last_response.body)["permissions"]
      writable = rows.select { |row| row["operator_writable"] }.map { |row| row["action"] }
      expect(writable).to contain_exactly("moderate_user", "manage_rooms")
    end

    it "is a full replace, not a merge: a second call drops what the first named" do
      patch "/admin/action-permissions", { "permissions" => { "moderate_user" => "1" } }, bearer(administrator_token)
      patch "/admin/action-permissions", { "permissions" => { "manage_rooms" => "1" } }, bearer(administrator_token)
      rows = YAMLCamel.load(last_response.body)["permissions"]
      writable = rows.select { |row| row["operator_writable"] }.map { |row| row["action"] }
      expect(writable).to contain_exactly("manage_rooms")
    end

    it "treats an explicit false as not writable, not as merely present" do
      patch "/admin/action-permissions", { "permissions" => { "moderate_user" => "1", "manage_rooms" => "0" } },
            bearer(administrator_token)
      rows = YAMLCamel.load(last_response.body)["permissions"]
      writable = rows.select { |row| row["operator_writable"] }.map { |row| row["action"] }
      expect(writable).to contain_exactly("moderate_user")
    end
  end

  describe "GET /admin/api-keys" do
    it "403s a developer key outright" do
      get "/admin/api-keys", {}, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "lists every issued key without ever exposing a token" do
      issued = keys.issue(scope: "developer", community: community, label: "Discord relay bot")
      get "/admin/api-keys", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include(issued.token)
      row = YAMLCamel.load(last_response.body)["api_keys"].find { |entry| entry["public_id"] == issued.key_row.public_id }
      expect(row["label"]).to eq("Discord relay bot")
      expect(row["community"]).to eq("sample")
    end
  end

  describe "GET /admin/integrations" do
    let(:integrations) { Rubotty::ControlPlane::Integrations.new(models: models) }

    it "403s a developer key outright" do
      get "/admin/integrations", {}, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "lists every known integration, configured or not, and never a raw key" do
      integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "shh")
      get "/admin/integrations", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("shh")
      row = YAMLCamel.load(last_response.body)["integrations"].find { |entry| entry["name"] == "libretranslate" }
      expect(row["url"]).to eq("https://lt.example")
      expect(row["api_key_set"]).to be(true)
    end

    it "reads a single integration by name, unconfigured answering api_key_set false" do
      get "/admin/integrations/libretranslate", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["name"]).to eq("libretranslate")
      expect(body["url"]).to be_nil
      expect(body["api_key_set"]).to be(false)
    end

    it "404s a name this deployment has no integration for at all" do
      get "/admin/integrations/not-a-real-one", {}, bearer(administrator_token)
      expect(last_response.status).to eq(404)
    end
  end

  describe "PATCH /admin/integrations/:name" do
    let(:integrations) { Rubotty::ControlPlane::Integrations.new(models: models) }

    it "403s a developer key outright" do
      patch "/admin/integrations/openarc", { url: "http://openarc:8000/v1" }, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "saves url, api_key and config, never echoing the key, and round-trips on a later GET" do
      patch "/admin/integrations/openarc",
            { url: "http://openarc:8000/v1", api_key: "sekret", config: { model: "Qwen3-4B" } },
            bearer(administrator_token)

      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("sekret")
      saved = YAMLCamel.load(last_response.body)
      expect(saved["url"]).to eq("http://openarc:8000/v1")
      expect(saved["api_key_set"]).to be(true)
      expect(saved["config"]).to eq("model" => "Qwen3-4B")

      get "/admin/integrations/openarc", {}, bearer(administrator_token)
      round_tripped = YAMLCamel.load(last_response.body)
      expect(round_tripped["url"]).to eq("http://openarc:8000/v1")
      expect(round_tripped["config"]).to eq("model" => "Qwen3-4B")
    end

    it "leaves a previously stored api_key untouched when the field is blank" do
      integrations.save(name: "openarc", url: "http://openarc:8000/v1", api_key: "original")

      patch "/admin/integrations/openarc", { url: "http://openarc:9000/v1", api_key: "" }, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      expect(integrations.find("openarc").api_key).to eq("original")
      expect(integrations.find("openarc").url).to eq("http://openarc:9000/v1")
    end

    it "404s a name this deployment has no integration for at all, matching the GET route" do
      patch "/admin/integrations/not-a-real-one", { url: "https://example.org" }, bearer(administrator_token)
      expect(last_response.status).to eq(404)
    end

    it "turns a URL that is not http or https into a 422 rather than a 500, and saves nothing" do
      patch "/admin/integrations/openarc", { url: "not-a-url" }, bearer(administrator_token)

      expect(last_response.status).to eq(422)
      expect(integrations.find("openarc")).to be_nil
    end
  end

  describe "GET /admin/communities" do
    it "403s a developer key outright, a route-class failure" do
      get "/admin/communities", {}, bearer(developer_token)
      expect(last_response.status).to eq(403)
    end

    it "lists every community for an administrator key" do
      other_community
      get "/admin/communities", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      slugs = YAMLCamel.load(last_response.body)["communities"].map { |row| row["slug"] }
      expect(slugs).to include("sample", "other-co")
    end
  end

  describe "automatic mapping" do
    def discovered(label, route:)
      connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
      now = Time.now
      models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "telegram", account: "telegram", route_key: route,
        endpoint_key: "discovered:telegram:telegram:#{route}", label: label,
        created_at: now, updated_at: now
      )
    end

    it "proposes without writing anything" do
      channel = discovered("Awaiting Biometrics", route: "api-auto-1")
      get "/communities/sample/discovered-channels/mapping-proposals", {}, bearer(developer_token)

      expect(last_response.status).to eq(200)
      row = YAMLCamel.load(last_response.body)["proposals"].find { |p| p["endpoint_key"] == channel.endpoint_key }
      expect(row["action"]).to eq("create")
      expect(row["room_key"]).to eq("awaiting-biometrics")
      expect(models.room_channel.where(channel_id: channel.id).first).to be_nil
    end

    it "reports a skip with its reason rather than omitting the channel" do
      discovered("Permanent Residency", route: "api-auto-2")
      discovered("ARI Permanent Residency", route: "api-auto-3")
      models.room.create(community_id: community.id, room_key: "residency", label: "Residency",
                         display_name: "{}", created_at: Time.now, updated_at: Time.now)

      get "/communities/sample/discovered-channels/mapping-proposals", {}, bearer(developer_token)
      rows = YAMLCamel.load(last_response.body)["proposals"]
              .select { |p| p["endpoint_key"].include?("api-auto-") }
      expect(rows.map { |r| r["action"] }).to all(eq("skip"))
      expect(rows.first["reason"]).to include("Residency")
    end

    it "applies only what the body names" do
      keep = discovered("Legal Action", route: "api-auto-4")
      drop = discovered("Media PR", route: "api-auto-5")
      body = YAMLCamel.dump({ "mappings" => [{ "endpoint_key" => keep.endpoint_key, "room_key" => "legal-action" }] })

      post "/communities/sample/discovered-channels/mapping-proposals/apply", body,
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(YAMLCamel.load(last_response.body)["applied"]).to eq(1)
      expect(models.room_channel.where(channel_id: keep.id).first).not_to be_nil
      expect(models.room_channel.where(channel_id: drop.id).first).to be_nil
    end

    it "400s a body whose mappings is not a list" do
      post "/communities/sample/discovered-channels/mapping-proposals/apply",
           YAMLCamel.dump({ "mappings" => "nope" }),
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(400)
    end

    it "maps one channel into a room of its own" do
      channel = discovered("Book Club", route: "api-map-1")

      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map",
           { "solo" => "true", "label" => "Book Club" }, bearer(developer_token)

      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["room"]["room_key"]).to eq("book-club")
      expect(body["channels"].map { |row| row["endpoint_key"] }).to eq([channel.endpoint_key])
      expect(models.room_channel.where(channel_id: channel.id).first).not_to be_nil
    end

    it "maps one channel into a room that already exists" do
      channel = discovered("Legal", route: "api-map-2")
      models.room.create(community_id: community.id, room_key: "legal", label: "Legal",
                         display_name: "{}", created_at: Time.now, updated_at: Time.now)

      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map",
           { "room_key" => "legal" }, bearer(developer_token)

      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["room"]["room_key"]).to eq("legal")
    end

    it "422s a map that names no destination at all" do
      channel = discovered("Nowhere", route: "api-map-3")
      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map", {}, bearer(developer_token)
      expect(last_response.status).to eq(422)
    end

    it "404s a map naming a channel that is already in a room" do
      channel = discovered("Taken", route: "api-map-4")
      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map",
           { "solo" => "true" }, bearer(developer_token)
      expect(last_response.status).to eq(200)

      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map",
           { "solo" => "true" }, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    it "404s a map naming another community's slug, never 403" do
      other_community
      post "/communities/other-co/discovered-channels/discovered:telegram:telegram:x/map",
           { "solo" => "true" }, bearer(developer_token)
      expect(last_response.status).to eq(404)
    end

    # A YAML 1.2 client (yamlcamel, the Swift client library) writes a plain
    # scalar like "No" unquoted, which is spec-correct for it. Written as a
    # raw string rather than through the dumper, which quotes an ambiguous
    # word defensively and would hide what this spec is about.
    it "keeps a label given as an unquoted No, which YAML 1.2 reads as the word" do
      channel = discovered("No", route: "api-map-bool")

      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map",
           "solo: true\nlabel: No\n",
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(200)
    end

    it "400s a label given as a real YAML boolean rather than stringifying it" do
      channel = discovered("No", route: "api-map-bool")

      post "/communities/sample/discovered-channels/#{channel.endpoint_key}/map",
           "solo: true\nlabel: true\n",
           bearer(developer_token).merge("CONTENT_TYPE" => "application/yaml")

      expect(last_response.status).to eq(400)
      expect(YAMLCamel.load(last_response.body)["error"]).to include("YAML boolean")
    end
  end

  describe "onboarding" do
    def pending_space(name: "SAMPLE Chat", external_id: "-100111", state: "pending", inviter: "4242")
      now = Time.now
      models.pending_space.create(
        adapter: "telegram", account: "telegram", external_id: external_id, name: name,
        inviter_native_id: inviter, inviter_username: "founder", inviter_display: "Founder",
        member_count: 12, sample_channels: '["general"]', state: state,
        expires_at: now + 1800, created_at: now, updated_at: now,
        decided_at: state == "pending" ? nil : now, decided_by: state == "pending" ? nil : "someone"
      )
    end

    it "lists what is awaiting a decision" do
      space = pending_space
      get "/admin/pending-spaces", {}, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      rows = YAMLCamel.load(last_response.body)["pending_spaces"]
      expect(rows.map { |row| row["id"] }).to eq([space.id])
      expect(rows.first["name"]).to eq("SAMPLE Chat")
      expect(rows.first["can_make_operator"]).to be(true)
      expect(rows.first["sample_channels"]).to eq(["general"])
    end

    it "lists the refused rows when asked for them, and not alongside the pending ones" do
      pending_space
      refused = pending_space(name: "Turned Away", external_id: "-100222", state: "denied")

      get "/admin/pending-spaces", { "state" => "denied" }, bearer(administrator_token)
      expect(YAMLCamel.load(last_response.body)["pending_spaces"].map { |row| row["id"] }).to eq([refused.id])

      get "/admin/pending-spaces", { "state" => "all" }, bearer(administrator_token)
      expect(YAMLCamel.load(last_response.body)["pending_spaces"].length).to eq(2)
    end

    it "400s an unknown state rather than falling back to the default" do
      get "/admin/pending-spaces", { "state" => "whatever" }, bearer(administrator_token)
      expect(last_response.status).to eq(400)
    end

    it "reads one space, and 404s an id that is not one" do
      space = pending_space
      get "/admin/pending-spaces/#{space.id}", {}, bearer(administrator_token)
      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["external_id"]).to eq("-100111")

      get "/admin/pending-spaces/999999", {}, bearer(administrator_token)
      expect(last_response.status).to eq(404)
    end

    it "accepts a space onto an existing community, named by slug" do
      space = pending_space

      post "/admin/pending-spaces/#{space.id}/approve", { "community" => "sample" }, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      body = YAMLCamel.load(last_response.body)
      expect(body["community"]["slug"]).to eq("sample")
      expect(body["pending_space"]["state"]).to eq("approved")
      connection = models.platform_connection.where(adapter: "telegram", external_id: "-100111").first
      expect(connection.community_id).to eq(community.id)
    end

    it "accepts a space as a brand new community, leaving it dormant" do
      space = pending_space

      post "/admin/pending-spaces/#{space.id}/approve",
           { "new_community_name" => "Wandering Albatross" }, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      created = YAMLCamel.load(last_response.body)["community"]
      expect(created["slug"]).to eq("wandering-albatross")
      expect(models.room.where(community_id: models.community.where(slug: created["slug"]).first.id).count).to eq(0)
    end

    it "promotes the inviter when asked, and only when an identity was captured" do
      space = pending_space
      post "/admin/pending-spaces/#{space.id}/approve",
           { "community" => "sample", "make_operator" => "1" }, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      operator = models.operator.where(community_id: community.id).all
                       .find { |row| row.granted_by.to_s.start_with?("pending-space-approval") }
      expect(operator).not_to be_nil
    end

    it "422s an approve that names neither an existing nor a new community" do
      space = pending_space
      post "/admin/pending-spaces/#{space.id}/approve", {}, bearer(administrator_token)
      expect(last_response.status).to eq(422)
    end

    it "404s an approve naming a community slug that does not exist" do
      space = pending_space
      post "/admin/pending-spaces/#{space.id}/approve", { "community" => "nope" }, bearer(administrator_token)
      expect(last_response.status).to eq(404)
    end

    it "422s a second decision on a space already decided" do
      space = pending_space
      post "/admin/pending-spaces/#{space.id}/approve", { "community" => "sample" }, bearer(administrator_token)
      expect(last_response.status).to eq(200)

      post "/admin/pending-spaces/#{space.id}/reject", {}, bearer(administrator_token)
      expect(last_response.status).to eq(422)
      expect(YAMLCamel.load(last_response.body)["error"]).to include("already been decided")
    end

    it "refuses a space and leaves the row standing as a refusal" do
      space = pending_space

      post "/admin/pending-spaces/#{space.id}/reject", {}, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      expect(YAMLCamel.load(last_response.body)["state"]).to eq("denied")
      expect(models.pending_space[space.id].state).to eq("denied")
    end

    it "records which key made the decision" do
      space = pending_space
      issued = keys.issue(scope: "administrator", label: "onboarding key")
      post "/admin/pending-spaces/#{space.id}/reject", {}, bearer(issued.token)

      expect(models.pending_space[space.id].decided_by).to eq("api:#{issued.key_row.public_id}")
    end

    it "clears a refused row, and refuses to clear one still awaiting a decision" do
      still_open = pending_space
      refused = pending_space(name: "Turned Away", external_id: "-100222", state: "denied")

      delete "/admin/pending-spaces/#{still_open.id}", {}, bearer(administrator_token)
      expect(last_response.status).to eq(422)

      delete "/admin/pending-spaces/#{refused.id}", {}, bearer(administrator_token)
      expect(last_response.status).to eq(204)
      expect(models.pending_space[refused.id]).to be_nil
    end

    it "suggests a space whose name matches the community, and none that does not" do
      matching = pending_space
      pending_space(name: "Wandering Albatross", external_id: "-100222")

      get "/admin/communities/sample/space-suggestions", {}, bearer(administrator_token)

      expect(last_response.status).to eq(200)
      rows = YAMLCamel.load(last_response.body)["suggestions"]
      expect(rows.map { |row| row["pending_space"]["id"] }).to eq([matching.id])
      expect(rows.first["matched"]).to eq(["sample"])
    end

    # A pending space belongs to no community, so there is nothing for a
    # developer key to be scoped to and every route here is a route-class
    # failure for one: 403, never 404.
    it "answers 403 to a developer key on every onboarding route" do
      space = pending_space
      routes = [
        [:get, "/admin/pending-spaces", {}],
        [:get, "/admin/pending-spaces/#{space.id}", {}],
        [:post, "/admin/pending-spaces/#{space.id}/approve", { "community" => "sample" }],
        [:post, "/admin/pending-spaces/#{space.id}/reject", {}],
        [:delete, "/admin/pending-spaces/#{space.id}", {}],
        [:get, "/admin/communities/sample/space-suggestions", {}]
      ]

      # A fresh key each time, so the small per-key budget this file sets is
      # never what answers instead of the scope check.
      routes.each do |verb, path, body|
        public_send(verb, path, body, bearer(developer_token))
        expect(last_response.status).to eq(403), "#{verb.upcase} #{path} answered #{last_response.status}"
      end
    end

    # 403 even for the developer key's OWN slug, since the route class is out
    # of reach before any slug is looked at.
    it "leaves the space untouched when a developer key tries to decide it" do
      space = pending_space
      post "/admin/pending-spaces/#{space.id}/reject", {}, bearer(developer_token)

      expect(last_response.status).to eq(403)
      expect(models.pending_space[space.id].state).to eq("pending")
    end
  end

  describe "admin debug endpoints" do
    let(:log_buffer) do
      Rubotty::RingBuffer.new.tap do |buffer|
        buffer << "2026-07-27T12:00:00Z INFO  web process started\n"
        buffer << "2026-07-27T12:00:05Z WARN  something to look at\n"
      end
    end

    def fake_bot_connection(entries_yaml:, status_class: Net::HTTPOK, code: "200")
      response = status_class.new("1.1", code, "")
      allow(response).to receive(:body).and_return(entries_yaml)
      fake_http = instance_double(Net::HTTP, request: response)
      allow(Net::HTTP).to receive(:start) do |*_args, **_kwargs, &block|
        block.call(fake_http)
      end
    end

    describe "GET /admin/debug/info" do
      let(:deps) do
        Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 3, log_buffer: log_buffer)
      end

      it "403s a developer key outright" do
        get "/admin/debug/info", {}, bearer(developer_token)
        expect(last_response.status).to eq(403)
      end

      it "reports the web process's own build facts by default" do
        get "/admin/debug/info", {}, bearer(administrator_token)
        expect(last_response.status).to eq(200)
        body = YAMLCamel.load(last_response.body)
        expect(body["web"]["version"]).to eq(Rubotty::VERSION)
        expect(body["web"]).not_to have_key("bot")
        expect(body).not_to have_key("bot")
      end

      # A rock that will not install is allowed to fail, so a missing transpiler shows
      # up only as a shorter dropdown, with the reason in a build transcript this
      # process never saw.
      it "reports the Lua toolchain, naming every dialect and whether it is there" do
        get "/admin/debug/info", {}, bearer(administrator_token)
        scripting = YAMLCamel.load(last_response.body)["web"]["scripting"]

        expect(scripting["dialects"].keys).to match_array(Rubotty::Scripting::Dialects.names)
        expect(scripting["dialects"]["lua"]).to eq("built in")
        expect(scripting["dialects"]["teal"]).to start_with("tl: ")
        expect(scripting).to have_key("interpreter").and have_key("searched")
      end

      it "reports missing transpilers independently of the runner's installed tools" do
        allow(Rubotty::Scripting::Dialects).to receive(:installed?).and_return(false)
        get "/admin/debug/info", {}, bearer(administrator_token)
        expect(last_response.status).to eq(200)
        dialects = YAMLCamel.load(last_response.body)["web"]["scripting"]["dialects"]
        expect(dialects["teal"]).to eq("tl: not on PATH")
        expect(dialects["lua"]).to eq("built in")
      end

      it "reports an installed transpiler without changing its dialect name" do
        allow(Rubotty::Scripting::Dialects).to receive(:installed?).and_return(true)
        get "/admin/debug/info", {}, bearer(administrator_token)
        expect(last_response.status).to eq(200)
        dialects = YAMLCamel.load(last_response.body)["web"]["scripting"]["dialects"]
        expect(dialects["teal"]).to eq("tl: found")
      end

      it "reports the bot as unreachable when no internal URL/secret is configured" do
        get "/admin/debug/info?source=bot", {}, bearer(administrator_token)
        body = YAMLCamel.load(last_response.body)
        expect(body["bot"]["reachable"]).to be(false)
        expect(body["bot"]["error"]).to include("not configured")
      end

      it "reports the bot's OWN version and commit, which is the point of asking it rather than assuming" do
        fake_bot_connection(entries_yaml: "version: 0.1.9\ncommit: deadbee\npid: 7\nhealthy: true\n")
        configured_deps = Rubotty::Api::Deps.new(
          db: db, logger: Rubotty::Log.null, rate_max: 3,
          bot_url: "http://bot:8080", bot_secret: "s3cret"
        )
        app_with_bot = Rubotty::Api::App.assemble(deps: configured_deps, env: {})
        session = Rack::Test::Session.new(Rack::MockSession.new(app_with_bot))
        session.get("/admin/debug/info?source=all", {}, bearer(administrator_token))

        body = YAMLCamel.load(session.last_response.body)
        expect(body["bot"]["reachable"]).to be(true)
        # The bot reports 0.1.9 while this process is on VERSION, a deploy skew the
        # endpoint shows rather than assuming one image everywhere.
        expect(body["bot"]["version"]).to eq("0.1.9")
        expect(body["bot"]["commit"]).to eq("deadbee")
        expect(body["web"]["version"]).to eq(Rubotty::VERSION)
      end

      it "400s an unknown source" do
        get "/admin/debug/info?source=nowhere", {}, bearer(administrator_token)
        expect(last_response.status).to eq(400)
      end
    end

    describe "GET /admin/debug/logs" do
      let(:deps) do
        Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 3, log_buffer: log_buffer)
      end

      it "403s a developer key outright" do
        get "/admin/debug/logs", {}, bearer(developer_token)
        expect(last_response.status).to eq(403)
      end

      it "reads this process's own recent lines by default (source=web)" do
        get "/admin/debug/logs", {}, bearer(administrator_token)
        expect(last_response.status).to eq(200)
        entries = YAMLCamel.load(last_response.body)["entries"]
        expect(entries.map { |e| e["source"] }).to eq(%w[web web])
        expect(entries.first["text"]).to include("web process started")
      end

      it "filters by level" do
        get "/admin/debug/logs?level=warn", {}, bearer(administrator_token)
        entries = YAMLCamel.load(last_response.body)["entries"]
        expect(entries.map { |e| e["level"] }).to eq(["WARN"])
      end

      it "reports an honest error for source=bot when the bot process is unreachable, rather than an empty list" do
        get "/admin/debug/logs?source=bot", {}, bearer(administrator_token)
        body = YAMLCamel.load(last_response.body)
        expect(body["entries"]).to eq([])
        expect(body["errors"]["bot"]).not_to be_nil
      end

      it "merges web and bot entries into one timestamp-sorted list for source=all" do
        fake_bot_connection(
          entries_yaml: "entries:\n- time: '2026-07-27T12:00:03Z'\n  level: ERROR\n  text: bot-side problem\n"
        )
        configured_deps = Rubotty::Api::Deps.new(
          db: db, logger: Rubotty::Log.null, rate_max: 3, log_buffer: log_buffer,
          bot_url: "http://bot:8080", bot_secret: "s3cret"
        )
        app_with_bot = Rubotty::Api::App.assemble(deps: configured_deps, env: {})
        session = Rack::Test::Session.new(Rack::MockSession.new(app_with_bot))
        session.get("/admin/debug/logs?source=all", {}, bearer(administrator_token))

        body = YAMLCamel.load(session.last_response.body)
        expect(body["entries"].map { |e| e["source"] }).to eq(%w[web bot web])
        texts = body["entries"].map { |e| e["text"] }
        expect(texts[0]).to include("web process started")
        expect(texts[1]).to eq("bot-side problem")
        expect(texts[2]).to include("something to look at")
      end
    end

    describe "GET /admin/debug/backfill-gaps" do
      let(:deps) { Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 3) }

      it "403s a developer key outright" do
        get "/admin/debug/backfill-gaps", {}, bearer(developer_token)
        expect(last_response.status).to eq(403)
      end

      it "reports the bot as unreachable when no internal URL/secret is configured, never an empty report" do
        get "/admin/debug/backfill-gaps", {}, bearer(administrator_token)
        expect(last_response.status).to eq(200)
        body = YAMLCamel.load(last_response.body)
        expect(body["channels"]).to eq([])
        expect(body["errors"]["bot"]).to include("not configured")
      end

      it "relays the bot's own sweep, worst channel first, with no message body anywhere in it" do
        fake_bot_connection(
          entries_yaml: "channels:\n" \
                        "- endpoint_id: dc-general\n" \
                        "  community: sample\n" \
                        "  since: '2026-07-27T00:00:00Z'\n" \
                        "  fetched: 3\n" \
                        "  gaps: 1\n" \
                        "  ours: 1\n" \
                        "  claimed: 1\n" \
                        "  below_floor: 0\n" \
                        "  error:\n" \
                        "  samples:\n" \
                        "  - endpoint_id: dc-general\n" \
                        "    native_id: '900'\n" \
                        "    timestamp: '2026-07-27T00:01:00Z'\n"
        )
        configured_deps = Rubotty::Api::Deps.new(
          db: db, logger: Rubotty::Log.null, rate_max: 3,
          bot_url: "http://bot:8080", bot_secret: "s3cret"
        )
        app_with_bot = Rubotty::Api::App.assemble(deps: configured_deps, env: {})
        session = Rack::Test::Session.new(Rack::MockSession.new(app_with_bot))
        session.get("/admin/debug/backfill-gaps", {}, bearer(administrator_token))

        expect(session.last_response.status).to eq(200)
        body = YAMLCamel.load(session.last_response.body)
        expect(body).not_to have_key("errors")
        row = body["channels"].first
        expect(row["endpoint_id"]).to eq("dc-general")
        expect(row["gaps"]).to eq(1)
        expect(row["samples"].first.keys).to match_array(%w[endpoint_id native_id timestamp])
      end
    end
  end
end
