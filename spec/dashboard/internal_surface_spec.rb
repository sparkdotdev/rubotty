# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "rack/test"
require "yamlcamel"
require "stringio"
require "fileutils"
require "tmpdir"

# The internal YAML surface a themed section reads from. The property
# worth holding: an unreadable community must answer exactly like a
# nonexistent slug, so no response ever confirms another community's
# resource exists. Section-level refusals are separate, and ordered.
RSpec.describe "the dashboard's internal YAML surface", :control_plane do
  include Rack::Test::Methods

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:secret) { "open-sesame" }
  let(:env) { { "DASHBOARD_SECRET" => secret } }
  let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null) }
  let(:app) { Rubotty::Dashboard::App.assemble(deps: deps, env: env) }

  let(:community) { models.community.where(slug: "sample").first }

  # A second community, with a room under the same room_key sample uses:
  # room_key is unique only within a community, so this collision is the
  # ordinary case worth checking. Built by hand rather than seeded twice,
  # since a second seed would move sample's channel rows onto this community.
  let(:other_community) do
    now = Time.now
    row = models.community.create(slug: "other-co", name: "Other Co", status: "active",
                                  created_at: now, updated_at: now)
    connection = models.platform_connection.create(
      community_id: row.id, adapter: "telegram", account: "main", external_id: "-100999",
      label: "Other Co", created_at: now, updated_at: now
    )
    channel = models.channel.create(
      community_id: row.id, platform_connection_id: connection.id, adapter: "telegram",
      account: "main", route_key: "-100999/1", endpoint_key: "other-co-general",
      label: "general", created_at: now, updated_at: now
    )
    room = models.room.create(community_id: row.id, room_key: "general", label: "General",
                              created_at: now, updated_at: now)
    models.room_channel.create(room_id: room.id, channel_id: channel.id, created_at: now)
    row
  end

  # An operator of sample and nothing else, with no viewer grant anywhere.
  let(:operator_session) { dashboard_session(role: "operator", operator_communities: [community.id]) }

  # Reads sample without operating it, which is the grant the oversight sections
  # (rooms among them) are gated on.
  let(:community_viewer_session) { dashboard_session(role: "operator", viewer_communities: [community.id]) }

  def body = YAMLCamel.load(last_response.body)

  def admin!
    post "/login", secret: secret
  end

  describe "the always-available surface" do
    let(:env) { { "DASHBOARD_SECRET" => secret } }

    it "answers for an administrator with no opt-in setting" do
      admin!
      get "/internal/communities"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("communities")
    end

    it "answers a nested section with no opt-in setting" do
      admin!
      get "/internal/communities/sample/rooms"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("rooms")
    end

    it "starts Series A on the ordinary page" do
      admin!
      get "/"

      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("swatch-clay.css")
      expect(last_response.body).to include("theme-runtime.js")
    end
  end

  describe "authentication" do
    it "refuses a signed-out read in YAML rather than redirecting to the login form" do
      get "/internal/communities"

      expect(last_response.status).to eq(401)
      expect(last_response.content_type).to start_with("application/yaml")
      expect(body).to eq("error" => "not signed in")
    end

    it "refuses a nested section path the same way, rather than only the index" do
      get "/internal/communities/sample/rooms"

      expect(last_response.status).to eq(401)
      expect(body).to eq("error" => "not signed in")
    end

    it "answers YAML, never HTML, once signed in" do
      admin!
      get "/internal/communities"

      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("application/yaml")
      expect(body["section"]).to eq("communities")
    end
  end

  describe "the community index" do
    it "lists the deployment for an administrator, marking every one readable" do
      other_community
      admin!
      get "/internal/communities"

      rows = body["communities"]
      expect(rows.map { |row| row["slug"] }).to include("sample", "other-co")
      expect(rows.map { |row| row["readable"] }.uniq).to eq([true])
    end

    # Listing is global on purpose (Role::GLOBAL_READ_ACTIONS): somebody has to
    # see a community exists before they can ask for access to it, and the row
    # carries a name and counts, nothing said inside. What it must not do is
    # claim they can open one, or a theme would draw a link that 404s.
    it "tells an operator which of them they can actually open" do
      other_community
      get "/internal/communities", {}, "rack.session" => operator_session

      readable = body["communities"].to_h { |row| [row["slug"], row["readable"]] }
      expect(readable).to eq("sample" => true, "other-co" => false)
    end
  end

  describe "one community's overview" do
    it "reads the community this operator runs" do
      get "/internal/communities/sample", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("overview")
      expect(body["community"]["slug"]).to eq("sample")
      expect(body["counts"]["channels"]).to eq(models.channel.where(community_id: community.id).count)
    end

    it "answers 404 for a community this operator does not run" do
      get "/internal/communities/#{other_community.slug}", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    # manage_community_lifecycle is answered here rather than left to a
    # themed Button to ask a Role directly, since the browser has none to
    # ask. Nothing grants it (Role::WRITE_ACTIONS never names it), so this
    # stays true for an administrator and false for every operator.
    it "tells an administrator they may manage the community's lifecycle" do
      admin!
      get "/internal/communities/sample"

      expect(body["may"]).to eq("manage_lifecycle" => true)
    end

    it "tells an operator of the community they may not, with no grant reaching that far" do
      get "/internal/communities/sample", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("manage_lifecycle" => false)
    end

    # The whole point of the rule: the refusal for a real community out of reach
    # and the refusal for a slug nobody has ever created have to be identical,
    # or the difference between them is an enumeration oracle.
    it "refuses a real community out of reach exactly as it refuses an invented slug" do
      get "/internal/communities/#{other_community.slug}", {}, "rack.session" => operator_session
      real = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community", {}, "rack.session" => operator_session
      invented = [last_response.status, last_response.body]

      expect(real).to eq(invented)
    end
  end

  describe "one community's endpoints" do
    let(:endpoint) do
      Rubotty::ControlPlane::ScriptEndpoints.new(models: models).save(
        community: community, name: "weather", url: "https://api.example.com/forecast",
        http_method: "GET", timeout_seconds: 5, enabled: true, created_by: "administrator"
      )
    end

    it "reads the community's endpoints for a community-scoped viewer" do
      endpoint
      get "/internal/communities/sample/endpoints", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("endpoints")
      names = body["endpoints"].map { |row| row["name"] }
      expect(names).to eq(["weather"])
    end

    it "leaves the raw second count on the wire, since Format.duration is a client concern" do
      endpoint
      get "/internal/communities/sample/endpoints", {}, "rack.session" => community_viewer_session

      expect(body["endpoints"].first["timeout_seconds"]).to eq(5)
    end

    it "answers one endpoint editor as a task document with headers redacted for a viewer" do
      endpoint.update(headers: Rubotty::ControlPlane::Models.dump_json("Authorization" => "Bearer secret"))
      get "/internal/communities/sample/endpoints/#{endpoint.id}", {}, "rack.session" => community_viewer_session

      expect(body).to include("section" => "endpoint_edit", "http_methods" => %w[GET POST])
      expect(body.dig("endpoint", "headers")).to eq("[redacted]")
      expect(body.dig("may", "manage_endpoints")).to be(false)
    end

    it "gives an administrator the real editor values and a new endpoint's safe defaults" do
      endpoint.update(headers: Rubotty::ControlPlane::Models.dump_json("Authorization" => "Bearer secret"))
      admin!

      get "/internal/communities/sample/endpoints/#{endpoint.id}"
      expect(body.dig("endpoint", "headers")).to eq("Authorization: Bearer secret")
      expect(body.dig("may", "manage_endpoints")).to be(true)

      get "/internal/communities/sample/endpoints/new"
      expect(body.dig("endpoint", "http_method")).to eq("GET")
      expect(body.dig("endpoint", "enabled")).to be(true)
    end

    # endpoints is an oversight read (Role::OVERSIGHT_READ_ACTIONS), which
    # operating a community does not carry on its own, same as rooms above.
    it "answers 403 to an operator of that community who holds no viewer grant" do
      get "/internal/communities/sample/endpoints", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(body).to eq("error" => "forbidden")
    end

    it "answers 404, not 403, for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/endpoints", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/endpoints", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    # view_endpoints is true by construction, the same read that got this
    # far at all. manage_endpoints is never granted (not in
    # ActionPermissions::ACTIONS), so it stays true for an administrator
    # and false for a viewer, the same shape as manage_lifecycle above.
    it "tells an administrator they may manage endpoints" do
      admin!
      get "/internal/communities/sample/endpoints"

      expect(body["may"]).to eq("view_endpoints" => true, "manage_endpoints" => true)
    end

    it "tells a viewer they may not" do
      get "/internal/communities/sample/endpoints", {}, "rack.session" => community_viewer_session

      expect(body["may"]).to eq("view_endpoints" => true, "manage_endpoints" => false)
    end
  end

  describe "one community's scripts" do
    let(:script) do
      Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null).save(
        community: community, name: "greeter", kind: "processor", source: 'return { action = "allow" }',
        trigger_type: "always", trigger_config: {}, created_by: "administrator"
      )
    end

    it "reads the community's live and archived scripts for a community-scoped viewer" do
      script
      get "/internal/communities/sample/scripts", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("scripts")
      names = body["scripts"].map { |row| row["name"] }
      expect(names).to eq(["greeter"])
      expect(body["archived"]).to eq([])
    end

    # The numbers scripts record for themselves ride along with the scripts,
    # since a stat row carries no script name and cannot be read on one
    # script's own page. A themed reader draws this screen from here, so a
    # section missing from the payload is a section missing from the screen.
    it "carries the numbers this community's scripts recorded for themselves" do
      script
      deps.script_stats.increment(community: community, stat: "commands", row: "roll", step: 4)
      deps.script_stats.flush

      get "/internal/communities/sample/scripts", {}, "rack.session" => community_viewer_session

      expect(body["recorded"]).to eq([{ "stat" => "commands", "row" => "roll", "value" => 4,
                                        "room" => "any room" }])
    end

    it "tells the reader whether a script is live and whether it is checked" do
      script
      get "/internal/communities/sample/scripts", {}, "rack.session" => community_viewer_session

      row = body["scripts"].first
      # A fresh save is disabled and unverified, the same gate
      # scripts_spec.rb holds saving to, so both read false here.
      expect(row["live"]).to eq(false)
      expect(row["verified"]).to eq(false)
    end

    # A themed reader draws one script's own page from this payload the same
    # way it draws the scripts list from "recorded" above, so the failure
    # counter, the run count and the alerts it raised all have to ride along.
    it "carries what one script has been up to on its own page" do
      row = script
      deps.scripts.record_error(row, "attempt to index a nil value")
      deps.scripts.record_run(row)
      deps.scripts.flush_runs
      deps.alerts.record(community_id: community.id, text: "hello there", room_key: "general",
                         script: "greeter")

      get "/internal/communities/sample/scripts/#{row.id}", {}, "rack.session" => community_viewer_session

      activity = body["activity"]
      expect(activity["errors"].first["message"]).to eq("attempt to index a nil value")
      expect(activity["alerts"].first["text"]).to eq("hello there")
      runs_stat = activity["stats"].find { |value, caption, _detail| caption == "runs" && value == 1 }
      expect(runs_stat).not_to be_nil
    end

    # scripts is an oversight read (Role::OVERSIGHT_READ_ACTIONS), which
    # operating a community does not carry on its own, same as endpoints above.
    it "answers 403 to an operator of that community who holds no viewer grant" do
      get "/internal/communities/sample/scripts", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(body).to eq("error" => "forbidden")
    end

    it "answers 404, not 403, for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/scripts", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/scripts", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    # view_scripts is true by construction, the same read that got this far
    # at all. manage_scripts is never granted (not in ActionPermissions::ACTIONS),
    # so it stays true for an administrator and false for a viewer regardless of
    # what else they hold on sample, the same shape as endpoints' manage_endpoints.
    it "tells an administrator they may manage scripts" do
      admin!
      get "/internal/communities/sample/scripts"

      expect(body["may"]).to eq("view_scripts" => true, "manage_scripts" => true)
    end

    it "tells a viewer they may not" do
      get "/internal/communities/sample/scripts", {}, "rack.session" => community_viewer_session

      expect(body["may"]).to eq("view_scripts" => true, "manage_scripts" => false)
    end
  end

  describe "one community's features" do
    def set_bridge_config(key, value)
      Rubotty::ControlPlane::FeatureControls.new(models: models).set(
        community: community, selector: "all", feature: "bridge", key: key, value: value
      )
    end

    it "reads every known feature for a community-scoped viewer" do
      get "/internal/communities/sample/features", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("features")
      expect(body["feature_rows"].map { |row| row["feature"] }).to include("bridge", "word_filter")
    end

    # Catalog.dashboard_names is pipeline order, which is what the router
    # runs and what an operator scanning the page has no reason to know.
    # feature_rows sorts by the displayed label at render time; Catalog's
    # own order is untouched.
    it "ships features alphabetised by label, not in pipeline order" do
      get "/internal/communities/sample/features", {}, "rack.session" => community_viewer_session

      listed = body["feature_rows"].map { |row| row["label"] }

      expect(listed).to eq(listed.sort)
    end

    it "marks an always-enabled feature locked and on, rather than reading its absent row as off" do
      get "/internal/communities/sample/features", {}, "rack.session" => community_viewer_session

      identify_topic = body["feature_rows"].find { |row| row["feature"] == "identify_topic" }
      expect(identify_topic["locked"]).to be(true)
      expect(identify_topic["enabled"]).to be(true)

      bridge = body["feature_rows"].find { |row| row["feature"] == "bridge" }
      expect(bridge["locked"]).to be(false)
    end

    # view_community is a SCOPED_READ_ACTION, not an OVERSIGHT_READ_ACTION
    # like rooms and endpoints above, so a plain operator (no separate
    # viewer grant) reads this the same as the ERB route already lets
    # them: authorize!(:view_community) is what that route checks too.
    it "reads it for a plain operator of the community too, with no viewer grant" do
      get "/internal/communities/sample/features", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
    end

    it "draws an untouched feature's config as no rows at all, not a placeholder" do
      get "/internal/communities/sample/features", {}, "rack.session" => operator_session

      row = body["feature_rows"].find { |entry| entry["feature"] == "word_filter" }
      expect(row["config_pairs"]).to eq([])
    end

    # config_pairs ships [label, value, format] rather than pre-rendered text,
    # so the boolean stays a real boolean on the wire; Format.boolean (Yes/No)
    # is a client concern the same way Format.duration is for endpoints above.
    it "ships a set boolean as a raw value with a boolean format, not pre-rendered text" do
      set_bridge_config("cross_platform_mentions", "false")
      get "/internal/communities/sample/features", {}, "rack.session" => operator_session

      row = body["feature_rows"].find { |entry| entry["feature"] == "bridge" }
      expect(row["config_pairs"]).to include(
        "label" => "Cross platform mentions", "value" => false, "format" => "boolean"
      )
    end

    # A *_seconds key ships the raw second count with a duration format hint,
    # the same reasoning endpoints' timeout_seconds gets: Format.duration on
    # the client is what turns it into a short string, not this surface
    # pre-formatting it.
    it "ships a duration-keyed value raw with a duration format hint" do
      Rubotty::ControlPlane::FeatureControls.new(models: models).set(
        community: community, selector: "all", feature: "backfill", key: "lookback_seconds", value: "7200"
      )
      get "/internal/communities/sample/features", {}, "rack.session" => operator_session

      row = body["feature_rows"].find { |entry| entry["feature"] == "backfill" }
      expect(row["config_pairs"]).to include("label" => "Lookback seconds", "value" => 7200, "format" => "duration")
    end

    it "answers 404, not 403, for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/features", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/features", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    # A toggle_<feature> grant per known feature, view_community carried
    # alongside since every themed Config link spends it.
    it "tells an administrator they may toggle every feature" do
      admin!
      get "/internal/communities/sample/features"

      expect(body["may"]["view_community"]).to eq(true)
      expect(body["may"]["toggle_bridge"]).to eq(true)
      expect(body["may"]["toggle_word_filter"]).to eq(true)
    end

    it "tells a plain operator with no permission grants they may toggle nothing" do
      get "/internal/communities/sample/features", {}, "rack.session" => operator_session

      expect(body["may"]["toggle_bridge"]).to eq(false)
    end
  end

  describe "one feature's config" do
    it "reads a feature's schema fields for a community-scoped viewer" do
      get "/internal/communities/sample/features/bridge/config", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("feature_config")
      expect(body["fields"].map { |field| field["name"] }).to include("cross_platform_mentions")
    end

    it "reads it for a plain operator of the community too, matching view_community's scoped read" do
      get "/internal/communities/sample/features/bridge/config", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
    end

    # A boolean field is a toggle Field (a Yes/No select), never a checkbox:
    # the primitive vocabulary has no checkbox field type left to draw one
    # with, which is the fix for the ERB page's own checkbox pile-up.
    it "draws a boolean config_schema field as a toggle type" do
      get "/internal/communities/sample/features/bridge/config", {}, "rack.session" => operator_session

      field = body["fields"].find { |entry| entry["name"] == "cross_platform_mentions" }
      expect(field["type"]).to eq("toggle")
    end

    it "draws a symbol field with one_of as a select, carrying its options" do
      get "/internal/communities/sample/features/bridge/config", {}, "rack.session" => operator_session

      field = body["fields"].find { |entry| entry["name"] == "reaction_notices" }
      expect(field["type"]).to eq("select")
      expect(field["options"]).to eq(%w[native notice both])
    end

    # Cut here, the rest was gone: no theme could offer it and the reader had
    # nowhere to go for it. The display limit belongs to the Field primitive,
    # which cuts what it draws and keeps the whole of it on hover.
    it "ships a schema description whole, however long it runs" do
      get "/internal/communities/sample/features/bridge/config", {}, "rack.session" => operator_session

      hint = body["fields"].find { |entry| entry["name"] == "timestamp_timezones" }["hint"]
      described = Rubotty::Features::Catalog.config_schema("bridge")
                                            .fields.fetch(:timestamp_timezones).description

      expect(hint.length).to be > 140
      expect(hint).to eq(described)
      expect(hint).to include("set it to an empty list to render nothing but the fixed zone")
    end

    it "answers 404 for a feature the catalog knows but declares no config_schema for" do
      get "/internal/communities/sample/features/channel_management/config", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    it "answers 404 for a feature name the catalog does not know at all, the same refusal" do
      get "/internal/communities/sample/features/not-a-real-feature/config", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    it "answers 404, not 403, for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/features/bridge/config", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/features/bridge/config", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "tells an administrator they may configure the feature" do
      admin!
      get "/internal/communities/sample/features/bridge/config"

      expect(body["may"]).to eq("view_community" => true, "configure_bridge" => true)
    end

    it "tells a plain operator with no permission grants they may not" do
      get "/internal/communities/sample/features/bridge/config", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("view_community" => true, "configure_bridge" => false)
    end
  end

  describe "one community's participation" do
    let(:participation) { Rubotty::ControlPlane::Participation.new(models: models) }

    before do
      participation.open_session(community: community, kind: "trivia", room_key: "general",
                                 label: "Friday trivia")
      participation.open_round(community: community, room_key: "general",
                               close_after: 300, on_close: "score_round")
    end

    it "reads the room with an open session for a community-scoped viewer" do
      get "/internal/communities/sample/participation", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("participation")
      expect(body["rooms"].map { |row| row["room"] }).to eq(["General"])
    end

    # Seven other rooms are seeded on sample besides "general", none with a
    # session open; a row of dashes for each would be noise, so
    # ViewData#participation_row drops them rather than the table drawing one.
    it "leaves out every room with nothing running" do
      get "/internal/communities/sample/participation", {}, "rack.session" => community_viewer_session

      expect(body["rooms"].length).to eq(1)
    end

    # The label already says "trivia", so joining kind and label the plain
    # way would read as "trivia: Friday trivia".
    it "carries the session label alone once it already says the kind" do
      get "/internal/communities/sample/participation", {}, "rack.session" => community_viewer_session

      row = body["rooms"].first
      expect(row["session"]).to eq("Friday trivia")
      expect(row["rounds"]).to eq(1)
    end

    # round_closes_at is still a real Time crossing YAMLCamel's Time-free
    # surface, so it needs the iso8601 conversion the Format spec covers.
    # round_opened_at is already relative text instead, since Room games is
    # scanned for recency, and a String needs no such conversion.
    it "leaves round_opened_at as a relative distance and round_closes_at as ISO 8601 text" do
      get "/internal/communities/sample/participation", {}, "rack.session" => community_viewer_session

      row = body["rooms"].first
      expect(row["round_opened_at"]).to match(/\A(just now|\d+ \w+s? ago)\z/)
      expect(row["round_closes_at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
    end

    # view_community is a scoped read (Role::SCOPED_READ_ACTIONS), not an
    # oversight one, so unlike endpoints above, an operator of the community
    # reads this on the strength of running it, no separate viewer grant
    # needed, the same as the dashboard route's own authorize! already allows.
    it "answers 200 to a plain operator of the community, with no viewer grant" do
      get "/internal/communities/sample/participation", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
    end

    it "answers 404, not 403, for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/participation", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/participation", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    # manage_participation is never granted by default (Role::DEFAULT_WRITE_ACTIONS
    # is empty), so it stays true for an administrator and false for an
    # operator regardless of what else they hold on sample, the same shape as
    # overview's manage_lifecycle and endpoints' manage_endpoints above.
    it "tells an administrator they may manage participation" do
      admin!
      get "/internal/communities/sample/participation"

      expect(body["may"]).to eq("manage_participation" => true)
    end

    it "tells an operator with no grant they may not" do
      get "/internal/communities/sample/participation", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("manage_participation" => false)
    end
  end

  describe "the alerts section" do
    it "reads a community's alerts for an operator of it, an ordinary scoped read" do
      get "/internal/communities/sample/alerts", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("alerts")
      expect(body["community"]["slug"]).to eq("sample")
      expect(body["alerts"]).to eq([])
    end

    it "answers 404 for a community out of reach" do
      get "/internal/communities/#{other_community.slug}/alerts", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    it "tells an administrator they may manage alerts" do
      admin!
      get "/internal/communities/sample/alerts"

      expect(body["may"]).to eq("manage_alerts" => true)
    end

    it "tells an operator with no alerts grant they may not" do
      get "/internal/communities/sample/alerts", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("manage_alerts" => false)
    end

    # Every assertion above reads a community with no alerts recorded, so
    # the row payload never runs. YAMLCamel raises UnsupportedTypeError on
    # a raw Time, so one recorded alert was enough to answer 500 until
    # ViewData#relative got in the way; this seeds the row to exercise that.
    it "serves a recorded alert with its timestamp as a relative distance, never a raw Time" do
      deps.alerts.record(community_id: community.id, text: "disk usage high",
                         mode: Rubotty::ControlPlane::Alerts::LOUD,
                         room_key: "general", script: "diskwatch")
      get "/internal/communities/sample/alerts", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["alerts"].first["created_at"]).to match(/\A(just now|\d+ \w+s? ago)\z/)
    end
  end

  describe "the files section" do
    it "reads a community's files for an administrator" do
      admin!
      get "/internal/communities/sample/files"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("files")
      expect(body["community"]["slug"]).to eq("sample")
      expect(body["may"]).to eq("manage_files" => true)
    end

    # Admin-only, the same shape require_admin! holds the ERB route to:
    # nothing in Role::WRITE_ACTIONS ever names a files grant, so an operator
    # of the community is refused regardless of what else they hold on it.
    it "answers 403 to an operator of the community" do
      get "/internal/communities/sample/files", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(body).to eq("error" => "forbidden")
    end

    it "answers 403 to a viewer of the community too, since viewing is not administering" do
      get "/internal/communities/sample/files", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(403)
      expect(body).to eq("error" => "forbidden")
    end

    it "answers 404, not 403, for a community out of reach" do
      get "/internal/communities/#{other_community.slug}/files", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    # The themed Files screen's own "serves left" column reads these three
    # fields; the ERB view stays under its view-vocabulary tag budget and
    # does not draw them, see lib/rubotty/dashboard/views/files.erb.
    context "with a file store configured" do
      let(:store_dir) { Dir.mktmpdir("rubotty-internal-files-spec") }
      let(:deps) { Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: store_dir) }

      after { FileUtils.remove_entry(store_dir) }

      it "carries a file's serve ceiling and how many serves are left" do
        deps.rehosted_files.store_file(community_id: community.id, source: StringIO.new("hello"),
                                       filename: "clip.mp4", content_type: "video/mp4", room_key: "general")
        admin!

        get "/internal/communities/sample/files"

        row = body["files"].first
        expect(row["serve_limit"]).to eq(Rubotty::ControlPlane::RehostedFiles::SERVE_LIMIT_FLAT)
        expect(row["served_count"]).to eq(0)
        expect(row["serves_remaining"]).to eq(Rubotty::ControlPlane::RehostedFiles::SERVE_LIMIT_FLAT)
      end
    end
  end

  describe "the redirections section" do
    # Mirrors the move helper spec/dashboard/redirections_spec.rb already
    # uses against the ERB route, so the two stay reading the same fixture.
    def move(community_row, status: Rubotty::ControlPlane::Redirections::POSTING)
      now = Time.now
      models.redirection.create(
        community_id: community_row.id, source_endpoint_id: "tg-general", target_room_id: "right-room",
        operator: "sample_owner", message_count: 3, status: status, step_index: 0,
        plan: "[]", created_at: now, updated_at: now
      )
    end

    # redirections rides :view_community like overview does, not an
    # oversight action, so an operator who simply runs the community (no
    # separate viewer grant) reads it too.
    it "reads this community's moves for an operator who runs it" do
      move(community)
      get "/internal/communities/sample/redirections", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("redirections")
      expect(body["redirections"].first["operator"]).to eq("sample_owner")
    end

    it "never shows another community's moves" do
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      created_at: Time.now, updated_at: Time.now)
      move(other)
      get "/internal/communities/sample/redirections", {}, "rack.session" => operator_session

      expect(body["redirections"]).to be_empty
    end

    # The same two-phase wording app.rb's own redirection_state ERB helper
    # draws, so a themed reader and the ERB reader see the same words.
    it "turns a posting move's status into the same wording the ERB helper draws" do
      move(community, status: Rubotty::ControlPlane::Redirections::POSTING)
      get "/internal/communities/sample/redirections", {}, "rack.session" => operator_session

      expect(body["redirections"].first["state"]).to eq("reposting")
    end

    it "turns a deleting move's status into the same wording the ERB helper draws" do
      move(community, status: Rubotty::ControlPlane::Redirections::DELETING)
      get "/internal/communities/sample/redirections", {}, "rack.session" => operator_session

      expect(body["redirections"].first["state"]).to eq("clearing the original")
    end

    # The half that must not be stoppable: once the reposts are all in, the
    # run exists in both rooms and stopping it would leave it there.
    it "only lets a still-posting move say it can be stopped" do
      move(community, status: Rubotty::ControlPlane::Redirections::DELETING)
      get "/internal/communities/sample/redirections", {}, "rack.session" => operator_session

      expect(body["redirections"].first["can_stop"]).to eq(false)
    end

    it "answers 404 for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/redirections", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/redirections", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "tells an administrator they may stop a move" do
      admin!
      get "/internal/communities/sample/redirections"

      expect(body["may"]).to eq("manage_redirection" => true)
    end

    it "tells a plain operator, granted nothing beyond running the community, they may not" do
      get "/internal/communities/sample/redirections", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("manage_redirection" => false)
    end
  end

  describe "the people section" do
    it "reads this community's directory for an operator who runs it" do
      deps.identities.record(community_id: community.id, adapter: "telegram", native_id: "1",
                             username: "ripley", display: "Ripley")
      get "/internal/communities/sample/people", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("people")
      expect(body["identities"].map { |row| row["username"] }).to eq(["ripley"])
    end

    it "answers 404 for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/people", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/people", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "tells an administrator they may set a nickname" do
      admin!
      get "/internal/communities/sample/people"

      expect(body["may"]).to eq("view_community" => true, "configure_nickname" => true)
    end

    it "tells a plain operator with no grant they may not" do
      get "/internal/communities/sample/people", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("view_community" => true, "configure_nickname" => false)
    end
  end

  describe "the moderation section" do
    it "answers no identities until a search is given, matching the ERB page" do
      get "/internal/communities/sample/moderation", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("moderation")
      expect(body["identities"]).to eq([])
    end

    it "searches this community's directory once a query is given" do
      deps.identities.record(community_id: community.id, adapter: "telegram", native_id: "1",
                             username: "rando", display: "Rando")
      get "/internal/communities/sample/moderation", { q: "rando" }, "rack.session" => operator_session

      expect(body["identities"].map { |row| row["username"] }).to eq(["rando"])
    end

    it "reads this community's active mutes" do
      deps.moderation.mute(community: community, adapter: "telegram", native_id: "1", username: "rando",
                           duration: "1h", issued_by: "seeded")
      get "/internal/communities/sample/moderation", {}, "rack.session" => operator_session

      expect(body["active_mutes"].first["subject"]).to include("rando")
    end

    it "answers 404 for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/moderation", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/moderation", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "tells an administrator they may moderate" do
      admin!
      get "/internal/communities/sample/moderation"

      expect(body["may"]).to eq("view_community" => true, "moderate_user" => true)
    end

    it "tells a plain operator with no grant they may not" do
      get "/internal/communities/sample/moderation", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("view_community" => true, "moderate_user" => false)
    end
  end

  describe "the events section" do
    it "reads this community's room access and upcoming events for an operator who runs it" do
      get "/internal/communities/sample/events", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("events")
      expect(body["room_access"]).not_to be_empty
      expect(body["events"]).to eq([])
    end

    it "carries an upcoming event once one is scheduled" do
      room = models.room.where(community_id: community.id, room_key: "general").first
      deps.feature_controls.enable(community: community, selector: "general", feature: "events")
      deps.event_scheduling.create(community: community, room: room, as: :operator, title: "Friday raid night",
                                   starts_at: Time.now + 3600, kind: "gaming", created_by: "seeded")
      get "/internal/communities/sample/events", {}, "rack.session" => operator_session

      expect(body["events"].first["title"]).to eq("Friday raid night")
    end

    it "answers 404 for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/events", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/events", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "tells an administrator they may schedule an event" do
      admin!
      get "/internal/communities/sample/events"

      expect(body["may"]).to eq("configure_events" => true)
    end

    it "tells a plain operator with no grant they may not" do
      get "/internal/communities/sample/events", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("configure_events" => false)
    end
  end

  describe "the webhooks section" do
    let(:webhooks) { deps.webhooks }

    def subscribe(**rest)
      webhooks.create(community_id: community.id, url: "https://example.invalid/hook",
                      event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED], **rest)
    end

    def emit
      webhooks.emit(community_id: community.id, event_type: Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED,
                    room_key: "general", data: { "body" => "hi" })
    end

    def dead_letter!
      row = models.webhook_delivery.order(:id).last
      Rubotty::ControlPlane::Webhooks::MAX_ATTEMPTS.times do
        webhooks.failed(row.refresh, error: "HTTP 500: down", response_status: 500)
      end
      row.refresh
    end

    it "reads this community's subscriptions for an operator who runs it" do
      subscribe(label: "ticket filer")
      get "/internal/communities/sample/webhooks", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("webhooks")
      expect(body["subscriptions"].first["label"]).to eq("ticket filer")
    end

    it "never carries the signing secret" do
      created = subscribe
      get "/internal/communities/sample/webhooks", {}, "rack.session" => operator_session

      expect(last_response.body).not_to include(created.secret)
    end

    it "says a rotation window is still open, the same as the ERB page" do
      created = subscribe
      webhooks.rotate(community_id: community.id, public_id: created.row.public_id, overlap: 3600)
      get "/internal/communities/sample/webhooks", {}, "rack.session" => operator_session

      expect(body["subscriptions"].first["state"]).to eq("on, rotating")
    end

    it "shows a dead-lettered delivery as given up on, and that it can be retried" do
      subscribe
      emit
      dead_letter!
      get "/internal/communities/sample/webhooks", {}, "rack.session" => operator_session

      delivery = body["deliveries"].first
      expect(delivery["outcome"]).to eq("given up")
      expect(delivery["can_retry"]).to eq(true)
      expect(delivery["last_error"]).to include("HTTP 500")
    end

    # The deployment-wide count, not the length of the (capped) deliveries
    # list, since a community with more dead letters than the cap would
    # otherwise read this number as too low.
    it "carries the full failed count separately from the deliveries list" do
      subscribe
      emit
      dead_letter!
      get "/internal/communities/sample/webhooks", {}, "rack.session" => operator_session

      expect(body["failed_count"]).to eq(1)
    end

    it "answers 404 for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/webhooks", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/webhooks", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "tells an administrator they may send a delivery again" do
      admin!
      get "/internal/communities/sample/webhooks"

      expect(body["may"]).to eq("manage_webhooks" => true)
    end

    it "tells a plain operator, granted nothing beyond running the community, they may not" do
      get "/internal/communities/sample/webhooks", {}, "rack.session" => operator_session

      expect(body["may"]).to eq("manage_webhooks" => false)
    end
  end

  describe "the audit section" do
    it "reads one community without exposing another one's history" do
      deps.audit.record(community: community.slug, source: "moderation", action: "delete",
                        subject: "Ada", channel: "general", reason: "spam")
      deps.audit.record(community: other_community.slug, source: "moderation", action: "ban",
                        subject: "Mallory", reason: "raid")

      get "/internal/communities/sample/audit", {}, "rack.session" => operator_session

      expect(body["section"]).to eq("audit")
      expect(body["community"]["slug"]).to eq("sample")
      expect(body["events"]).to contain_exactly(include("action" => "delete", "subject" => "Ada in general"))
    end

    it "reads every readable community at deployment scope and carries their names" do
      deps.audit.record(community: community.slug, source: "moderation", action: "delete")
      deps.audit.record(community: other_community.slug, source: "dashboard", action: "start")
      admin!

      get "/internal/audit"

      expect(body["community"]).to be_nil
      expect(body["events"].map { |event| event["community"] }).to contain_exactly("sample", other_community.slug)
    end

    it "carries source and action filters through the themed surface" do
      deps.audit.record(community: community.slug, source: "moderation", action: "delete")
      deps.audit.record(community: community.slug, source: "dashboard", action: "mute")

      get "/internal/communities/sample/audit", { source: "dashboard", action: "mute" },
          "rack.session" => operator_session

      expect(last_request.params).to include("source" => "dashboard", "action" => "mute")
      expect(body["source"]).to eq("dashboard")
      expect(body["action"]).to eq("mute")
      expect(body["events"].map { |event| event["action"] }).to eq(["mute"])
    end
  end

  describe "the rooms section" do
    it "reads the rooms of the community a community-scoped viewer may read" do
      get "/internal/communities/sample/rooms", {}, "rack.session" => community_viewer_session

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("rooms")
      expect(body["rooms"].map { |room| room["room_key"] }).to include("general")
    end

    it "puts every channel on one board, with its room state and the tab counts" do
      connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
      channel = models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "telegram", account: "telegram", route_key: "930",
        endpoint_key: "provisioned:telegram:telegram:930", label: nil,
        created_at: Time.now, updated_at: Time.now
      )
      get "/internal/communities/sample/rooms", {}, "rack.session" => community_viewer_session

      row = body.fetch("channels").find { |candidate| candidate["id"] == channel.id }
      expect(row).to include(
        "channel" => "Telegram channel 930", "room" => "Not in a room",
        "state" => "Needs a room", "state_tone" => "bad"
      )
      expect(body.fetch("counts")).to include("unroomed" => 1, "unnamed" => 1)
    end

    it "filters the board by an unfinished state" do
      connection = models.platform_connection.where(community_id: community.id, adapter: "telegram").first
      channel = models.channel.create(
        community_id: community.id, platform_connection_id: connection.id,
        adapter: "telegram", account: "telegram", route_key: "pending-name",
        endpoint_key: "provisioned:telegram:telegram:pending-name", label: "Proposed name", suggested: true,
        created_at: Time.now, updated_at: Time.now
      )
      get "/internal/communities/sample/rooms", { state: "suggested" }, "rack.session" => community_viewer_session

      expect(body.fetch("state")).to eq("suggested")
      expect(body.fetch("channels").map { |row| row.fetch("id") }).to eq([channel.id])
      expect(body.fetch("channels").first).to include("channel" => "Proposed name (proposed)",
                                                       "state" => "Needs a room")
    end

    it "reads a channel and a room through their themed detail surfaces" do
      channel = models.channel.where(community_id: community.id).order(:id).first
      room = models.room.where(community_id: community.id).order(:room_key).first

      get "/internal/communities/sample/rooms/channels/#{channel.id}", {}, "rack.session" => community_viewer_session
      expect(body).to include("section" => "room_channel")
      expect(body.fetch("channel")).to include("id" => channel.id, "endpoint_key" => channel.endpoint_key)

      get "/internal/communities/sample/rooms/#{room.room_key}", {}, "rack.session" => community_viewer_session
      expect(body).to include("section" => "room_detail")
      expect(body.fetch("room")).to include("room_key" => room.room_key)
    end

    # Both communities have a room keyed "general", so a room list that lost
    # its community scope comes back with two of them and reads as a duplicate
    # rather than as somebody else's data.
    it "lists this community's rooms and no others" do
      other_community
      get "/internal/communities/sample/rooms", {}, "rack.session" => community_viewer_session

      expect(body["rooms"].map { |room| room["room_key"] })
        .to eq(models.room.where(community_id: community.id).order(:room_key).select_map(:room_key))
    end

    # Deliberately corrupt data: room_channels carries no community of its own
    # and nothing in the schema stops a row from crossing one, so the channel
    # query names the community rather than trusting the join to have stayed
    # inside it.
    it "leaves out a channel that a stray join row hung on one of its rooms" do
      general = models.room.where(community_id: community.id, room_key: "general").first
      stray = models.channel.where(community_id: other_community.id).first
      models.room_channel.create(room_id: general.id, channel_id: stray.id, created_at: Time.now)

      get "/internal/communities/sample/rooms", {}, "rack.session" => community_viewer_session

      drawn = body["rooms"].flat_map { |room| room["channels"].map { |channel| channel["endpoint_key"] } }
      expect(drawn).not_to include(stray.endpoint_key)
    end

    # Both communities have a room keyed "general", which is what a query
    # keyed on room_key alone would answer with the wrong channels for while
    # looking entirely correct doing it.
    it "carries this community's channels and none of the other community's" do
      theirs = models.channel.where(community_id: other_community.id).select_map(:endpoint_key)
      mine = models.channel.where(community_id: community.id).select_map(:endpoint_key)

      get "/internal/communities/sample/rooms", {}, "rack.session" => community_viewer_session

      drawn = body["rooms"].flat_map { |room| room["channels"].map { |channel| channel["endpoint_key"] } }
      expect(drawn).not_to be_empty
      expect(theirs).not_to be_empty
      expect(drawn - mine).to be_empty
      expect(drawn & theirs).to be_empty
    end

    # rooms is an oversight read (Role::OVERSIGHT_READ_ACTIONS), which operating
    # a community does not carry on its own.
    it "answers 403 to an operator of that community who holds no viewer grant" do
      get "/internal/communities/sample/rooms", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(403)
      expect(body).to eq("error" => "forbidden")
    end

    # The order of the two refusals is the thing. If the section check ran
    # first, an out-of-reach community would answer 403 where an invented slug
    # answered 404, and the pair of them would say which slugs are real.
    it "answers 404, not 403, for a community out of reach, whichever refusal applies" do
      get "/internal/communities/#{other_community.slug}/rooms", {}, "rack.session" => operator_session
      out_of_reach = [last_response.status, last_response.body]

      get "/internal/communities/no-such-community/rooms", {}, "rack.session" => operator_session

      expect(out_of_reach).to eq([404, last_response.body])
    end

    it "reads any community for a deployment-wide viewer" do
      other_community
      get "/internal/communities/other-co/rooms", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(200)
      expect(body["community"]["slug"]).to eq("other-co")
    end
  end

  # The two deployment-wide sections. They belong to no community, so
  # the non-disclosure rule that governs the rest of this surface has
  # nothing to scope against: the whole section is administrator-only
  # instead, refused with a 404 like a community out of reach.
  describe "the onboarding queue" do
    it "lists a pending space and its blacklist to an administrator" do
      deps.pending_spaces.on_join!(
        adapter: :telegram, account: "telegram", external_id: "-100555", name: "Rando Group",
        inviter_native_id: "77", inviter_username: "rando"
      )
      admin!
      get "/internal/onboarding"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("onboarding")
      expect(body["pending"].map { |row| row["label"] }).to include("Rando Group")
      expect(body["may"]["manage_pending_spaces"]).to be(true)
    end

    it "answers 404 to an operator, saying nothing about the page being there" do
      get "/internal/onboarding", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    it "answers 404 to a deployment-wide viewer too, since a pending space is not oversight" do
      get "/internal/onboarding", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(404)
    end

    # A protected title is pended with no job behind it, so the payload has to
    # carry the difference rather than every card promising a departure.
    it "says whether a row has an auto-leave timer behind it at all" do
      deps.pending_spaces.on_join!(
        adapter: :telegram, account: "telegram", external_id: "-100556", name: "SECOND Lisbon"
      )
      admin!
      get "/internal/onboarding"

      expect(body["pending"].map { |row| row["auto_leaves"] }).to all(be(false).or(be(true)))
    end
  end

  describe "the operator login links" do
    it "lists an outstanding link to an administrator, by digest and never by raw token" do
      issued = deps.web_login.issue(
        identity_key: "telegram:telegram:80000012",
        operator: { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" },
        communities: [{ id: community.id, slug: community.slug, name: community.name }]
      )
      admin!
      get "/internal/operator-tokens"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("operator_tokens")
      expect(body["tokens"].map { |row| row["operator"] }).to include("Alex")
      expect(last_response.body).not_to include(issued.token)
    end

    it "answers 404 to an operator" do
      get "/internal/operator-tokens", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
      expect(body).to eq("error" => "not found")
    end

    # A live link is a path into somebody else's session, so oversight is not
    # enough to read one, matching what TOP_NAV already hides from a viewer.
    it "answers 404 to a deployment-wide viewer" do
      get "/internal/operator-tokens", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(404)
    end
  end

  describe "the administrators section" do
    it "lists the shipped floor, a granted row, a token and an audit line" do
      deps.dashboard_administrators.grant(adapter: "telegram", handle: "ada", native_id: dashboard_native_id("ada"), label: "Ada", granted_by: "seeded")
      minter = Rubotty::ControlPlane::AuthTokens::Minter.new(administrator: true, community_ids: [], label: "seed")
      deps.auth_tokens.mint(minter: minter, community_id: nil, administrator: true, label: "for Bea")
      admin!

      get "/internal/administrators"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("administrators")
      expect(body["administrators"].map { |row| row["handle"] }).to include("ada")
      expect(body["baked_in"]).to be_an(Array)
      expect(body["tokens"].map { |row| row["label"] }).to include("for Bea")
      expect(body["audit"].map { |row| row["subject"] }).to include("ada")
    end

    it "answers 404 to an operator" do
      get "/internal/administrators", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
    end

    it "answers 404 to a deployment-wide viewer" do
      get "/internal/administrators", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(404)
    end
  end

  describe "the accounts section" do
    # A second env var alongside the login secret, so one account's pill
    # reads "key present" and a second, unset one reads "not set in this
    # process" in the same render (#1415): ViewData cannot resolve this
    # on its own, since Deps carries no environment access.
    let(:env) { { "DASHBOARD_SECRET" => secret, "TELEGRAM_BOT_TOKEN" => "shh" } }

    it "lists every stored account with its own env pill" do
      deps.accounts.create(adapter: "telegram", name: "telegram_2", settings: { "token_env" => "TELEGRAM_BOT_TOKEN" })
      deps.accounts.create(adapter: "discord", name: "discord_2", settings: { "token_env" => "DISCORD_BOT_TOKEN" })
      admin!

      get "/internal/accounts"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("accounts")
      set_account = body["accounts"].find { |row| row["name"] == "telegram_2" }
      unset_account = body["accounts"].find { |row| row["name"] == "discord_2" }
      expect(set_account["token_env"]).to eq("TELEGRAM_BOT_TOKEN")
      expect(set_account["token_env_set"]).to eq(true)
      expect(unset_account["token_env"]).to eq("DISCORD_BOT_TOKEN")
      expect(unset_account["token_env_set"]).to eq(false)
    end

    it "carries every registered platform's schema fields for the two-step add form once one is chosen" do
      admin!

      get "/internal/accounts", adapter: "telegram"

      expect(body["new_adapter"]).to eq("telegram")
      expect(body["new_fields"].map { |field| field["name"] }).to include("token_env")
    end

    it "carries no new-account fields until a platform is chosen" do
      admin!

      get "/internal/accounts"

      expect(body["new_adapter"]).to be_nil
      expect(body["new_fields"]).to eq([])
    end

    it "answers 404 to an operator" do
      get "/internal/accounts", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
    end

    it "answers 404 to a deployment-wide viewer" do
      get "/internal/accounts", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(404)
    end

    it "carries the one grant every action on the page spends, true for an administrator" do
      admin!

      get "/internal/accounts"

      expect(body["may"]).to eq("manage_accounts" => true)
    end
  end

  describe "the integrations section" do
    it "lists both known integrations for an administrator" do
      admin!
      get "/internal/integrations"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("integrations")
      expect(body["integrations"].map { |row| row["name"] }).to eq(%w[libretranslate openarc])
      expect(body["may"]).to eq("manage_integrations" => true)
    end

    it "never carries a stored key, only whether one is set" do
      deps.integrations.save(name: "libretranslate", url: "https://libretranslate.example.org", api_key: "secret")
      admin!
      get "/internal/integrations"

      expect(last_response.body).not_to include("secret")
      row = body["integrations"].find { |entry| entry["name"] == "libretranslate" }
      expect(row["key_stored"]).to be(true)
      expect(row["configured"]).to be(true)
    end

    it "answers 404 to an operator" do
      get "/internal/integrations", {}, "rack.session" => operator_session

      expect(last_response.status).to eq(404)
    end

    it "answers 404 to a deployment-wide viewer" do
      get "/internal/integrations", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(404)
    end
  end

  describe "the backfill proposals section" do
    # Mirrors spec/dashboard/backfill_proposals_spec.rb's own create_proposal
    # helper: a proposal and its items, built with plain model inserts rather
    # than through the service, since nothing here is testing propose() itself.
    # Timestamps relative to Time.now rather than a fixed date: the service
    # has no injectable clock here (Deps builds it with the real one), and
    # #pending/#awaiting_relay/#expired all call expire_stale! first, so a
    # fixed past expires_at would auto-expire the fixture out from under
    # every example the moment real time passed it.
    def create_proposal(status: "pending", endpoint_id: "dc-general", fetched: 50, gaps: 3, ours: 40,
                        claimed: 7, below_floor: 0, community_id: community.id,
                        items: [["m1", "Alex@discord", "hello there", Time.now - 300]])
      id = models.backfill_proposal.insert(
        community_id: community_id, endpoint_id: endpoint_id, status: status,
        fetched: fetched, gaps: gaps, ours: ours, claimed: claimed, below_floor: below_floor,
        swept_since: Time.now - 3600, expires_at: Time.now + 86_400,
        created_at: Time.now - 600, updated_at: Time.now - 600
      )
      items.each do |native_id, author_label, preview, sent_at|
        models.backfill_proposal_item.insert(
          proposal_id: id, native_id: native_id, author_label: author_label, preview: preview,
          sent_at: sent_at, created_at: Time.now
        )
      end
      id
    end

    it "reads every pending proposal for an administrator, across every community" do
      create_proposal(endpoint_id: "dc-general")
      admin!
      get "/internal/backfill-proposals"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("backfill_proposals")
      expect(body["pending"].map { |row| row["endpoint_id"] }).to eq(["dc-general"])
    end

    it "carries the item previews: author, time and text, exactly as stored" do
      create_proposal(items: [["m1", "Alex@discord", "a very specific preview", Time.utc(2026, 7, 1, 11, 55)]])
      admin!
      get "/internal/backfill-proposals"

      item = body["pending"].first["items"].first
      expect(item["author_label"]).to eq("Alex@discord")
      expect(item["preview"]).to eq("a very specific preview")
    end

    # YAMLCamel has no representation for a raw Time (see ViewData#iso8601
    # and #relative), so this is a real regression check, not a style
    # preference: without one conversion or the other, this route raises
    # rather than answering.
    it "carries created_at as a relative distance and each item's sent_at as ISO 8601 text" do
      create_proposal
      admin!
      get "/internal/backfill-proposals"

      row = body["pending"].first
      expect(row["created_at"]).to match(/\A(just now|\d+ \w+s? ago)\z/)
      expect(row["items"].first["sent_at"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
    end

    it "sorts a proposal into pending, awaiting relay, or expired by its own status" do
      create_proposal(status: "pending", endpoint_id: "dc-pending")
      create_proposal(status: "approved", endpoint_id: "dc-awaiting")
      create_proposal(status: "expired", endpoint_id: "dc-expired")
      admin!
      get "/internal/backfill-proposals"

      expect(body["pending"].map { |row| row["endpoint_id"] }).to eq(["dc-pending"])
      expect(body["awaiting_relay"].map { |row| row["endpoint_id"] }).to eq(["dc-awaiting"])
      expect(body["expired"].map { |row| row["endpoint_id"] }).to eq(["dc-expired"])
    end

    # Administrator only, never authorize!, the same rule the ERB route holds
    # itself to: an operator gets refused even with no community scope at all
    # to be refused against, since this is not a community-scoped read.
    it "answers 403 for an operator, viewer status included" do
      get "/internal/backfill-proposals", {}, "rack.session" => dashboard_session(role: "operator", viewer: true)

      expect(last_response.status).to eq(403)
      expect(body).to eq("error" => "forbidden")
    end

    it "carries the one grant every action on the page spends, true for an administrator" do
      admin!
      get "/internal/backfill-proposals"

      expect(body["may"]).to eq("manage_backfill_proposals" => true)
    end
  end

  describe "the document sections" do
    around do |example|
      Dir.mktmpdir("rubotty-dashboard-documentation") do |directory|
        @scripting_path = File.join(directory, "scripting.md")
        example.run
      end
    end

    before do
      allow(Rubotty::Dashboard::ReadmeRenderer).to receive(:scripting_path).and_return(@scripting_path)
    end

    it "answers the scripting reference as markup, under its own section name" do
      File.write(@scripting_path, "# Scripting reference\n\nBuild a sample response.\n")
      admin!
      get "/internal/documentation"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("documentation")
      expect(body["document"]).to eq("scripting")
      expect(body["markup"]).to include("<h1", "Scripting reference", "<p>Build a sample response.</p>")
    end

    it "still serves the README when the scripting reference is absent" do
      admin!
      get "/internal/documentation"

      expect(last_response.status).to eq(200)
      expect(body["document"]).to eq("scripting")
      expect(body["markup"]).to be_nil
      expect(body["readme_markup"]).to include("Rubotty")
    end

    # The README rides alongside the scripting reference under its own key,
    # since Documentation now draws both.
    it "carries the README as a second document, on the same section" do
      admin!
      get "/internal/documentation"

      expect(body["readme_markup"])
        .to eq(Rubotty::Dashboard::Primitives::Prose.markup(:readme, app_root: ""))
    end

    # The markup goes over the wire as one long YAML scalar, and a fold or an
    # escape that did not survive would land on the page as broken markup
    # rather than as an error, so this compares it to the render itself.
    it "carries the document back byte for byte through YAML" do
      admin!
      get "/internal/licence"

      expect(body["markup"])
        .to eq(Rubotty::Dashboard::Primitives::Prose.markup(:licence, app_root: ""))
    end

    # The page is open, so the section behind it has to be: a themed page
    # whose read answers 401 falls back to a full page load, which starts the
    # runtime and reads again.
    it "answers the licence with no session, the way /licence itself does" do
      get "/internal/licence"

      expect(last_response.status).to eq(200)
      expect(body["section"]).to eq("licence")
    end

    it "still refuses the scripting reference signed out, since that page is gated too" do
      get "/internal/documentation"

      expect(last_response.status).to eq(401)
      expect(body).to eq("error" => "not signed in")
    end

    it "remains open with no opt-in setting" do
      default_app = Rubotty::Dashboard::App.assemble(deps: deps, env: { "DASHBOARD_SECRET" => secret })
      session = Rack::Test::Session.new(Rack::MockSession.new(default_app))
      session.get "/internal/licence"

      expect(session.last_response.status).to eq(200)
    end
  end

  # The surface is a read. Every write on the dashboard stays on the form post
  # beside it, which is where the CSRF protection and the bot nudge live.
  describe "what it will not do" do
    it "refuses a write to a section path" do
      admin!
      post "/internal/communities/sample/rooms", name: "invented"

      expect(last_response.status).to eq(404)
      expect(models.room.where(community_id: community.id, room_key: "invented").first).to be_nil
    end
  end
end
