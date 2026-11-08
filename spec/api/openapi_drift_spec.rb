# frozen_string_literal: true

require "spec_helper"
require "rubotty/api"
require "rack/test"
require "json_schemer"
require "tmpdir"

# The published contract, checked against the running app both ways: an undocumented
# route fails, and so does a documented route the app does not serve. Every documented
# operation is driven and its response body validated against the schema written for
# it, so adding a route means documenting it in the same change.
RSpec.describe "docs/api/openapi.yaml against the real API", :control_plane, :api_spec_document do
  include Rack::Test::Methods

  SPEC_PATH = ApiSpecDocument::PATH

  # HTTP verbs an OpenAPI path item may carry. HEAD is excluded on both sides, since
  # Sinatra registers one for free alongside every GET.
  HTTP_VERBS = %w[get post put patch delete options].freeze

  # The wire format promise, as content type keys. Anything outside these sets is
  # drift even when the routes line up, application/json above all.
  RESPONSE_TYPES = %w[application/yaml text/plain text/event-stream].freeze
  # multipart/form-data is here for the file upload alone: bytes cannot ride a YAML
  # mapping without base64, which would inflate the request and hold the whole file in
  # memory at both ends.
  REQUEST_TYPES = %w[application/yaml application/x-www-form-urlencoded multipart/form-data].freeze

  let(:document) { YAMLCamel.load(File.read(SPEC_PATH)) }

  # The node a JSON pointer names, with "~1" and "~0" decoded back to "/" and "~".
  def at_pointer(pointer)
    tokens = pointer.delete_prefix("#/").split("/").map { |token| token.gsub("~1", "/").gsub("~0", "~") }
    tokens.empty? ? document : document.dig(*tokens)
  end

  # Follow "$ref" until something concrete, returning the node and the pointer it
  # really lives at, since a response written as a reference has its schema under
  # /components rather than under /paths.
  def follow(pointer)
    node = at_pointer(pointer)
    while node.is_a?(Hash) && node.key?("$ref")
      pointer = node["$ref"]
      node = at_pointer(pointer)
    end
    [node, pointer]
  end

  def escape(token) = token.gsub("~", "~0").gsub("/", "~1")

  # Sinatra keeps the compiled patterns, so this reads what the app will actually
  # serve, with ":slug" translated into OpenAPI's "{slug}" for the comparison.
  def app_routes
    Rubotty::Api::App.routes.flat_map do |verb, defined|
      next [] if verb == "HEAD"

      defined.map { |pattern| "#{verb} #{pattern[0].to_s.gsub(/:(\w+)/, '{\1}')}" }
    end.sort
  end

  def documented_routes
    document["paths"].flat_map do |path, item|
      item.keys.select { |key| HTTP_VERBS.include?(key) }.map { |verb| "#{verb.upcase} #{path}" }
    end.sort
  end

  describe "the route table" do
    it "documents every route the app serves" do
      missing = app_routes - documented_routes

      expect(missing).to be_empty, lambda {
        "#{missing.length} route(s) the app serves are absent from docs/api/openapi.yaml:\n" \
          "  #{missing.join("\n  ")}"
      }
    end

    it "serves every route the spec documents" do
      invented = documented_routes - app_routes

      expect(invented).to be_empty, lambda {
        "#{invented.length} route(s) documented in docs/api/openapi.yaml do not exist:\n" \
          "  #{invented.join("\n  ")}"
      }
    end

    # Both sets going empty would make the two assertions above pass while proving
    # nothing at all.
    it "reads a real route table on both sides" do
      expect(app_routes.length).to be > 50
      expect(documented_routes.length).to eq(app_routes.length)
    end
  end

  describe "the wire format" do
    def operations
      document["paths"].flat_map do |path, item|
        item.filter_map { |verb, op| [path, verb, op] if HTTP_VERBS.include?(verb) }
      end
    end

    it "never mentions JSON as a content type anywhere in the document" do
      offenders = []
      walk = lambda do |node, trail|
        case node
        when Hash
          node.each do |key, value|
            offenders << trail.join("/") if key.to_s.start_with?("application/json")
            walk.call(value, trail + [key.to_s])
          end
        when Array
          node.each_with_index { |item, index| walk.call(item, trail + [index.to_s]) }
        end
      end
      walk.call(document, [])

      expect(offenders).to be_empty, "application/json appears at: #{offenders.join(', ')}"
    end

    it "answers only YAML, plain text or an event stream" do
      offenders = operations.flat_map do |path, verb, op|
        op.fetch("responses", {}).flat_map do |status, response|
          types = response.fetch("content", {}).keys - RESPONSE_TYPES
          types.map { |type| "#{verb.upcase} #{path} #{status}: #{type}" }
        end
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    it "declares the shared body-limit error for every operation accepting a body" do
      body_operations = operations.select { |_, _, operation| operation.key?("requestBody") }
      expect(body_operations.size).to eq(50)
      offenders = body_operations.filter_map do |path, verb, operation|
        component = operation["operationId"] == "uploadFileAdmin" ? "TooLarge" : "RequestTooLarge"
        expected = "#/components/responses/#{component}"
        "#{verb.upcase} #{path}: missing #{expected}" unless operation.dig("responses", "413", "$ref") == expected
      end
      expect(offenders).to be_empty, offenders.join("\n")
    end

    it "accepts only YAML or form encoding on a request body" do
      offenders = operations.filter_map do |path, verb, op|
        next nil if op["requestBody"].nil?

        body, = follow("#/paths/#{escape(path)}/#{verb}/requestBody")
        types = body.fetch("content", {}).keys - REQUEST_TYPES
        "#{verb.upcase} #{path}: #{types.join(', ')}" if types.any?
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end
  end

  # What the document promises; the app's real 401/403/404 answers are driven by
  # spec/api/app_spec.rb. A route added with a copied and trimmed responses block is
  # how a documented security model quietly stops being documented.
  describe "the documented authorization model" do
    def authenticated_operations
      document["paths"].reject { |path, _| path == "/healthz" }.flat_map do |path, item|
        item.filter_map { |verb, op| [path, verb, op] if HTTP_VERBS.include?(verb) }
      end
    end

    it "declares 401 and 429 on every authenticated operation" do
      offenders = authenticated_operations.filter_map do |path, verb, op|
        missing = %w[401 429] - op.fetch("responses", {}).keys
        "#{verb.upcase} #{path}: missing #{missing.join(' and ')}" if missing.any?
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    it "declares 403 on every /admin/ operation and on no other" do
      wrong = authenticated_operations.filter_map do |path, verb, op|
        admin = path.start_with?("/admin/")
        declared = op.fetch("responses", {}).key?("403")
        next "#{verb.upcase} #{path}: admin route with no 403" if admin && !declared

        "#{verb.upcase} #{path}: 403 on a developer-reachable route" if !admin && declared
      end

      expect(wrong).to be_empty, wrong.join("\n")
    end
  end

  # The feature line rather than the exact version, because every pull request bumps
  # rubotty's patch: exact equality would need a rubotty-api-spec commit and a pointer
  # move on every one of them, stale again the moment a second one merged ahead of it.
  # The route table and body checks above are what catch a spec behind the routes.
  it "carries the feature line of the service it describes" do
    feature_line = ->(version) { version.to_s.split(".").first(2).join(".") }
    published = document.dig("info", "version")

    expect(feature_line[published]).to eq(feature_line[Rubotty::VERSION]),
                                       "openapi.yaml is published as #{published}, rubotty is #{Rubotty::VERSION}: " \
                                       "bump info.version in rubotty-api-spec and move the docs/api pointer to it"
  end

  # A feature's config is documented as an open mapping with the per-feature
  # keys served live by GET /features/schema, rather than copied into this file
  # (see the FeatureConfig schema for why). That leaves the runtime endpoint's
  # own contract as the thing worth holding to account, which is what these do.
  describe "the feature config contract" do
    def declared_fields
      Rubotty::Features::Catalog.names.uniq.flat_map do |name|
        schema = Rubotty::Features::Catalog.config_schema(name)
        schema ? schema.fields.values.map { |field| [name, field] } : []
      end
    end

    # A Symbol at the top of a default is turned into a string on the way out.
    # One buried in a list or a mapping is not, and would reach a client as a
    # value only Ruby can read.
    def nested_symbol?(value)
      case value
      when Array then value.any? { |item| item.is_a?(Symbol) || nested_symbol?(item) }
      when Hash then value.any? { |key, held| key.is_a?(Symbol) || held.is_a?(Symbol) || nested_symbol?(held) }
      else false
      end
    end

    it "documents every type a config key can declare" do
      documented = document.dig("components", "schemas", "ConfigField", "properties", "type", "enum")

      expect(documented.map(&:to_s).sort).to eq(Rubotty::Config::Schema::TYPES.map(&:to_s).sort)
    end

    it "declares no default or permitted value that would reach a client as a Ruby value" do
      offenders = declared_fields.filter_map do |name, field|
        odd = [field.default, *Array(field.one_of)].select { |value| nested_symbol?(value) }
        "#{name}.#{field.name}: #{odd.map(&:inspect).join(', ')}" if odd.any?
      end

      expect(offenders).to be_empty, offenders.join("\n")
    end

    # Both halves point a reader at the live answer. Without this the pointer
    # could be dropped from either while the document still claimed to describe
    # what a feature accepts.
    it "sends a reader to the live schema from both the read and the write" do
      config = document.dig("components", "schemas", "FeatureConfig", "description")
      write = document.dig("components", "schemas", "FeatureWriteBody", "properties", "config", "allOf")

      expect(config).to include("GET /features/schema")
      expect(write.map { |part| part["description"] }.compact.join(" ")).to include("GET /features/schema")
    end
  end

  # This file's real home is rubotty-api-spec, a repository other people can read, so a
  # Ruby module path, a table name or a migration number in a description hands out the
  # shape of the private code. Checked here, so it fails in the pull request that wrote
  # the line rather than after it reaches that repository.
  describe "the file as something published" do
    # Table names a client never sees on the wire. A list rather than a scan of the
    # whole schema, because "operators" and "events" are resources the API exposes.
    INTERNAL_TABLES = %w[
      feature_settings room_channels person_identities platform_connections_map
      api_keys_log script_stats_rows message_map guest_sessions
      script_endpoints token_hash key_hash
    ].freeze

    let(:text) { File.read(SPEC_PATH) }

    it "names no Ruby module or class path" do
      # Two capitalised words joined by ::, which is a Ruby constant path.
      offenders = text.scan(/\b[A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)+\b/).uniq

      expect(offenders).to be_empty, "internal constant path(s): #{offenders.join(', ')}"
    end

    it "names no file inside this repository" do
      offenders = text.scan(%r{\b(?:lib|spec|db|config)/[a-z0-9_/]+\.rb\b}).uniq

      expect(offenders).to be_empty, "internal file path(s): #{offenders.join(', ')}"
    end

    it "cites no migration" do
      offenders = text.scan(/migration \d+/i).uniq

      expect(offenders).to be_empty, "migration reference(s): #{offenders.join(', ')}"
    end

    it "names no storage-only table or column" do
      offenders = INTERNAL_TABLES.select { |name| text.include?(name) }

      expect(offenders).to be_empty, "internal storage name(s): #{offenders.join(', ')}"
    end

    # Anything long and random enough to be a token. The spec's examples are all short
    # readable identifiers, so nothing legitimate trips this.
    it "carries nothing that looks like a credential" do
      offenders = text.scan(/\b(?:Bearer\s+\S{16,}|[A-Za-z0-9_-]{32,})\b/).uniq

      expect(offenders).to be_empty, "possible secret(s): #{offenders.join(', ')}"
    end
  end

  describe "response bodies" do
    # A real object store in a directory that goes away with the example, since the
    # file routes need one and the packaged default would leave an initialised store
    # beside the checkout.
    around do |example|
      Dir.mktmpdir("rubotty-drift") do |dir|
        @store_root = File.join(dir, "objects")
        example.run
      end
    end

    let(:seeded) { seeded_sample }
    let(:db) { seeded[0] }
    let(:models) { seeded[1] }
    let(:community) { models.community.where(slug: "sample").first }
    let(:storage) { Rubotty::Storage::SequelStore.new(db: db, logger: Rubotty::Log.null).tap(&:migrate!) }
    let(:deps) do
      Rubotty::Api::Deps.new(db: db, logger: Rubotty::Log.null, rate_max: 100_000,
                             file_store_path: @store_root, storage: storage)
    end
    # One pass and the stream closes, so this terminates instead of holding the
    # connection open.
    let(:app) { Rubotty::Api::App.assemble(deps: deps, env: { "API_SSE_MAX_PASSES" => "1" }) }
    let(:keys) { Rubotty::ControlPlane::ApiKeys.new(models: models) }
    let(:admin) { { "HTTP_AUTHORIZATION" => "Bearer #{keys.issue(scope: 'administrator', label: 'drift').token}" } }
    let(:validator) { JSONSchemer.openapi(document) }

    # The rows the shipped example configuration does not seed. Without them every
    # single-resource read answers 404 and no item schema below is exercised.
    let(:fixtures) { build_fixtures }

    def build_fixtures
      now = Time.now
      room = community.rooms_dataset.where(room_key: "general").first
      channel = community.channels_dataset.order(:id).first
      account = models.account.create(adapter: "telegram", name: "telegram", settings: '{"token_env":"TELEGRAM_BOT_TOKEN"}',
                                      source: "yaml_seed", created_at: now, updated_at: now)
      network = models.irc_network.create(community_id: community.id, name: "libera", host: "irc.libera.chat",
                                          port: 6697, tls: true, nick: "rubotty", channels: '["#sample"]',
                                          mode: "per_room", channel_keys: "{}", created_at: now, updated_at: now)
      fluxer = models.fluxer_instance.create(community_id: community.id, label: "flagship", kind: "flagship",
                                             api_key_env: "FLUXER_API_KEY", created_at: now, updated_at: now)
      invite = models.guest_invite.create(community_id: community.id, room_id: room.id, nickname: "visitor",
                                          token_hash: "0" * 64, created_by: "drift", expires_at: now + 3600,
                                          created_at: now, updated_at: now)
      event = models.event.create(community_id: community.id, room_id: room.id, title: "Launch night",
                                  starts_at: now + 86_400, kind: "gaming", rsvp_mode: "affirm",
                                  status: "scheduled", native_refs: "{}", created_at: now, updated_at: now)
      request = models.operator_request.create(community_id: community.id, adapter: "telegram",
                                               requester_native_id: "9001", requester_username: "hopeful",
                                               requester_display: "Hopeful", state: "pending", requested_at: now)
      # A granted viewer, plus two open asks, or the viewer routes answer with
      # empty lists and 404s and no item schema below is ever reached.
      db[:dashboard_viewers].insert(adapter: "telegram", handle: "onlooker", label: "Onlooker",
                                    granted_at: now, granted_by: "drift")
      viewer_request = db[:dashboard_viewer_requests].insert(
        adapter: "telegram", requester_native_id: "9101", requester_username: "peeker",
        requester_display: "Peeker", state: "pending", requested_at: now
      )
      denied_viewer_request = db[:dashboard_viewer_requests].insert(
        adapter: "telegram", requester_native_id: "9102", requester_username: "spectator",
        requester_display: "Spectator", state: "pending", requested_at: now
      )
      # The community-scoped half of the same thing, for the routes on the
      # ordinary community path.
      db[:community_viewers].insert(community_id: community.id, adapter: "telegram", handle: "bystander",
                                    label: "Bystander", granted_at: now, granted_by: "drift")
      community_viewer_request = db[:community_viewer_requests].insert(
        community_id: community.id, adapter: "telegram", requester_native_id: "9201",
        requester_username: "watcher", requester_display: "Watcher", state: "pending", requested_at: now
      )
      denied_community_viewer_request = db[:community_viewer_requests].insert(
        community_id: community.id, adapter: "telegram", requester_native_id: "9202",
        requester_username: "gazer", requester_display: "Gazer", state: "pending", requested_at: now
      )
      # One token of each scope, or both list routes answer with an empty array
      # and the item schema below is never reached.
      minter = Rubotty::ControlPlane::AuthTokens::Minter.new(
        administrator: true, community_ids: [], may_grant_operator: true, label: "drift"
      )
      deps.auth_tokens.mint(minter: minter, community_id: community.id, operator: true, label: "drift here")
      deps.auth_tokens.mint(minter: minter, community_id: nil, viewer: true, label: "drift everywhere")
      person = community.people.first
      # A channel that belongs to no room, which is what "discovered" means; without
      # one both discovery routes answer with an empty list.
      discovered = models.channel.create(
        community_id: community.id, platform_connection_id: models.platform_connection.first.id,
        adapter: "telegram", account: "telegram", route_key: "-100999", endpoint_key: "discovered:telegram:-100999",
        label: "gaming", receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
        created_at: now, updated_at: now
      )
      # A second one, so the single-channel map route has something left to map
      # after the bulk apply above has consumed the first.
      lone = models.channel.create(
        community_id: community.id, platform_connection_id: models.platform_connection.first.id,
        adapter: "telegram", account: "telegram", route_key: "-100998", endpoint_key: "discovered:telegram:-100998",
        label: "bookclub", receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
        created_at: now, updated_at: now
      )
      # Two channels a non-operator named, so the list has rows on it and each
      # decision below has its own to work on.
      kept = suggested_channel(route_key: "-100997", label: "recipes", now: now)
      dropped = suggested_channel(route_key: "-100996", label: "spoilers", now: now)

      # Two spaces awaiting a decision: one named after the community, so the
      # suggestion route has a match to report, and one named after nothing, so
      # a reject and the clear that follows it have their own row to work on.
      space = pending_space(name: "SAMPLE Chat", external_id: "-100111", now: now)
      stranger = pending_space(name: "Wandering Albatross", external_id: "-100222", now: now)

      # One raised alert and one held file, or both families answer with empty lists.
      alert = deps.alerts.record(community_id: community.id, text: "a drift check alert",
                                 mode: "loud", room_key: "general", script: "guard")
      # The upload route honours the community's own setting, so the feature has to be
      # on for it to answer anything but a refusal.
      deps.feature_controls.enable(community: community, selector: "all", feature: "file_rehosting")
      held = deps.rehosted_files.store_file(
        community_id: community.id, room_key: "general", source: StringIO.new("held bytes"),
        filename: "held.txt", content_type: "text/plain"
      )

      # Two channels a sweep held back, so the list has rows with counts on it
      # and each decision below has its own to work on.
      proposal = backfill_proposal(endpoint_id: "tg-general", now: now)
      spare_proposal = backfill_proposal(endpoint_id: "tg-random", now: now)

      # An open session with an open round, so the room-games read has
      # something other than null to answer with, and the write example has
      # something open to close.
      session = models.script_session.create(
        community_id: community.id, room_key: "general", kind: "trivia", label: "Friday quiz",
        state: "open", opened_at: now, created_at: now, updated_at: now
      )
      models.script_round.create(
        community_id: community.id, session_id: session.id, position: 1, state: "open",
        opened_at: now, created_at: now, updated_at: now
      )

      # A channel of the api_wrapper adapter, and a developer key scoped to its
      # own account, so the /bridge routes have something real to address. The
      # channel needs no room mapping for these HTTP-level checks: that only
      # matters once the bot's receive loop drains what gets queued here.
      bridge_key = deps.api_keys.issue(
        scope: "developer", community: community, platform_account: "drift-bridge", label: "drift bridge account"
      ).token
      bridge_channel = models.channel.create(
        community_id: community.id, platform_connection_id: models.platform_connection.first.id,
        adapter: "api_wrapper", account: "drift-bridge", route_key: "chan-1",
        endpoint_key: "api_wrapper:drift-bridge:chan-1", label: "drift bridge channel",
        receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
        created_at: now, updated_at: now
      )

      { room: room, channel: channel, account: account, network: network, fluxer: fluxer,
        invite: invite, event: event, request: request, person: person, discovered: discovered,
        lone: lone, kept: kept, dropped: dropped, space: space, stranger: stranger,
        alert: alert, held: held,
        proposal: proposal, spare_proposal: spare_proposal,
        viewer_request: viewer_request, denied_viewer_request: denied_viewer_request,
        community_viewer_request: community_viewer_request,
        denied_community_viewer_request: denied_community_viewer_request,
        session: session, bridge_key: bridge_key, bridge_channel: bridge_channel }
    end

    # One channel a non-operator's topic command named, still waiting on a
    # decision. Written directly, since no adapter is connected in this process
    # for anybody to run that command on.
    def suggested_channel(route_key:, label:, now:)
      models.channel.create(
        community_id: community.id, platform_connection_id: models.platform_connection.first.id,
        adapter: "telegram", account: "telegram", route_key: route_key,
        endpoint_key: "discovered:telegram:#{route_key}", label: label, suggested: true,
        receives: true, sends: true, relay: "{}", display_name: "{}", settings: "{}",
        created_at: now, updated_at: now
      )
    end

    # One row in the review queue. Written directly rather than through a join,
    # since no adapter is connected in this process to raise one.
    def pending_space(name:, external_id:, now:)
      models.pending_space.create(
        adapter: "telegram", account: "telegram", external_id: external_id, name: name,
        inviter_native_id: "4242", inviter_username: "founder", inviter_display: "Founder",
        member_count: 12, sample_channels: '["general","random"]', state: "pending",
        expires_at: now + 1800, created_at: now, updated_at: now
      )
    end

    # One channel's held-back list, with a preview to read. Written directly, since
    # no adapter is connected in this process for a sweep to find a gap on.
    def backfill_proposal(endpoint_id:, now:)
      id = models.backfill_proposal.insert(
        community_id: community.id, endpoint_id: endpoint_id, status: "pending",
        fetched: 50, gaps: 3, ours: 40, claimed: 7, below_floor: 0,
        swept_since: now - 3600, expires_at: now + 3600, created_at: now, updated_at: now
      )
      models.backfill_proposal_item.insert(
        proposal_id: id, native_id: "m1", author_label: "Alex@discord",
        preview: "drifted into the gap", sent_at: now - 60, created_at: now
      )
      id
    end

    # A script and an endpoint are created through the API itself, since the ids they
    # hand back are what every other script route is addressed by.
    def create_script
      params = { name: "drift", kind: "processor", language: "lua",
                 source: 'return { action = "allow" }', trigger_type: "always" }
      expect_valid_request("/admin/communities/{slug}/scripts", "post", params)
      post "/admin/communities/sample/scripts", params, admin
      YAMLCamel.load(last_response.body)
    end

    def create_endpoint
      params = { name: "drift", url: "https://example.invalid/hook", http_method: "GET" }
      expect_valid_request("/admin/communities/{slug}/endpoints", "post", params)
      post "/admin/communities/sample/endpoints", params, admin
      YAMLCamel.load(last_response.body)
    end

    # A subscription has to exist before the routes addressed by its public id can
    # answer anything but a 404.
    def create_webhook
      params = { url: "https://example.invalid/events", event_types: "message.relayed", label: "drift" }
      expect_valid_request("/admin/communities/{slug}/webhooks", "post", params)
      post "/admin/communities/sample/webhooks", params, admin
      YAMLCamel.load(last_response.body)
    end

    # The documented schema for one operation's response, as a validator. A JSON
    # pointer travels inside a URI fragment where a brace is not legal, so the path
    # template's braces are percent encoded or every parameterised path raises.
    def schema_for(path, verb, status)
      response, pointer = follow(["#/paths", escape(path), verb, "responses", status].join("/"))
      content = response && response["content"]
      raise "no content documented for #{verb.upcase} #{path} #{status}" if content.nil?

      type = (content.keys & RESPONSE_TYPES).first
      raise "#{verb.upcase} #{path} #{status} answers an undeclared content type" if type.nil?

      validator.ref("#{pointer}/content/#{escape(type)}/schema".gsub("{", "%7B").gsub("}", "%7D"))
    end

    # The submitted form is an ordinary Ruby object in rack-test, before Rack
    # serializes it. Validate that object against the documented request body
    # before sending it, which keeps the contract check independent of the
    # particular form or YAML encoder a client chooses.
    def request_schema_for(path, verb)
      body, pointer = follow(["#/paths", escape(path), verb, "requestBody"].join("/"))
      return nil if body.nil?

      content = body.fetch("content", {})
      type = (content.keys & REQUEST_TYPES).first
      raise "#{verb.upcase} #{path} accepts no documented request content type" if type.nil?

      validator.ref("#{pointer}/content/#{escape(type)}/schema".gsub("{", "%7B").gsub("}", "%7D"))
    end

    # An upload's rack-test wrapper is a local IO object, while an OpenAPI
    # binary field is represented as a string. The schema is concerned with the
    # field being present, not the temporary file implementation behind it.
    def request_value(value)
      case value
      when Rack::Test::UploadedFile then value.original_filename.b
      when Hash then value.transform_values { |item| request_value(item) }
      when Array then value.map { |item| request_value(item) }
      else value
      end
    end

    def expect_valid_request(path, verb, params)
      schema = request_schema_for(path, verb)
      return if schema.nil?

      body = request_value(params)
      errors = schema.validate(body).map do |error|
        "  #{error['data_pointer'].empty? ? '(root)' : error['data_pointer']}: #{error['type']}" \
          " (#{error['schema_pointer']})"
      end
      expect(errors).to be_empty, lambda {
        "#{verb.upcase} #{path} sends a body the spec does not describe:\n" \
          "#{errors.join("\n")}\n\nbody was:\n#{body.inspect[0, 1500]}"
      }
    end

    def expect_valid(path, verb, status, body)
      errors = schema_for(path, verb, status).validate(body).map do |error|
        "  #{error['data_pointer'].empty? ? '(root)' : error['data_pointer']}: #{error['type']}" \
          " (#{error['schema_pointer']})"
      end
      expect(errors).to be_empty, lambda {
        "#{verb.upcase} #{path} answered #{status} with a body the spec does not describe:\n" \
          "#{errors.join("\n")}\n\nbody was:\n#{body.inspect[0, 1500]}"
      }
    end

    # Drive one documented operation and check the answer against what was promised.
    def check(path, verb, concrete, params = {}, headers: admin, expect_status:)
      expect_valid_request(path, verb.to_s, params)
      public_send(verb, concrete, params, headers)
      expect(last_response.status).to eq(expect_status),
                                     "#{verb.upcase} #{concrete} answered #{last_response.status}, " \
                                     "not the #{expect_status} this check drives it for: #{last_response.body[0, 300]}"
      @exercised << "#{verb.upcase} #{path}"
      return if expect_status == 204

      expect_valid(path, verb.to_s, expect_status.to_s, YAMLCamel.load(last_response.body))
    end

    before { @exercised = [] }

    # The app must not reveal whether a route, room, person or other resource
    # exists in a community outside a developer key's scope. Substitute harmless
    # path values for every documented community route, because scope resolution
    # happens before the route looks any resource up.
    FOREIGN_PATH_VALUES = {
      "slug" => "other-co",
      "room_key" => "not-your-room",
      "message_id" => "not-your-message",
      "channel_id" => "not-your-channel",
      "id" => "999999",
      "feature" => "moderation",
      "endpoint_key" => "not-your-endpoint",
      "adapter" => "discord",
      "name" => "not-your-network",
      "label" => "not-your-instance",
      "public_id" => "not-your-webhook"
    }.freeze

    def community_operations
      document["paths"].flat_map do |path, item|
        next [] unless path.start_with?("/communities/{slug}")

        item.filter_map { |verb, _operation| [path, verb] if HTTP_VERBS.include?(verb) }
      end
    end

    def foreign_path(path)
      missing = []
      concrete = path.gsub(/\{([^}]+)\}/) do
        name = Regexp.last_match(1)
        missing << name unless FOREIGN_PATH_VALUES.key?(name)
        FOREIGN_PATH_VALUES.fetch(name, "missing")
      end
      raise "no foreign-community value for #{missing.uniq.join(', ')}" if missing.any?

      concrete
    end

    # Every read in one example, since they share the fixture set and standing it up
    # sixty times over would dominate the suite's runtime.
    it "answers every documented read with a body the spec describes" do
      f = fixtures
      script = create_script
      endpoint = create_endpoint
      webhook = create_webhook

      check("/communities/{slug}", :get, "/communities/sample", expect_status: 200)
      check("/admin/communities", :get, "/admin/communities", expect_status: 200)
      check("/admin/accounts", :get, "/admin/accounts", expect_status: 200)
      check("/admin/accounts/{adapter}/{name}", :get, "/admin/accounts/telegram/telegram", expect_status: 200)
      check("/admin/api-keys", :get, "/admin/api-keys", expect_status: 200)
      check("/admin/integrations", :get, "/admin/integrations", expect_status: 200)
      check("/admin/integrations/{name}", :get, "/admin/integrations/libretranslate", expect_status: 200)
      check("/admin/viewers", :get, "/admin/viewers", expect_status: 200)
      check("/admin/viewer-requests", :get, "/admin/viewer-requests", expect_status: 200)
      check("/admin/administrators", :get, "/admin/administrators", expect_status: 200)
      check("/admin/auth-tokens", :get, "/admin/auth-tokens", expect_status: 200)
      check("/admin/action-permissions", :get, "/admin/action-permissions", expect_status: 200)

      check("/communities/{slug}/rooms", :get, "/communities/sample/rooms", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}", :get, "/communities/sample/rooms/general", expect_status: 200)

      check("/communities/{slug}/channels", :get, "/communities/sample/channels", expect_status: 200)
      check("/communities/{slug}/channels/{endpoint_key}", :get,
            "/communities/sample/channels/#{f[:channel].endpoint_key}", expect_status: 200)

      check("/communities/{slug}/people", :get, "/communities/sample/people", expect_status: 200)
      check("/communities/{slug}/people/{id}", :get, "/communities/sample/people/#{f[:person].id}", expect_status: 200)

      check("/communities/{slug}/viewers", :get, "/communities/sample/viewers", expect_status: 200)
      check("/communities/{slug}/viewer-requests", :get, "/communities/sample/viewer-requests",
            expect_status: 200)
      check("/communities/{slug}/auth-tokens", :get, "/communities/sample/auth-tokens", expect_status: 200)

      check("/communities/{slug}/operators", :get, "/communities/sample/operators", expect_status: 200)
      operators = YAMLCamel.load(last_response.body)["operators"]
      check("/communities/{slug}/operator-requests", :get, "/communities/sample/operator-requests", expect_status: 200)
      check("/communities/{slug}/operator-requests/{id}", :get,
            "/communities/sample/operator-requests/#{f[:request].id}", expect_status: 200)

      check("/communities/{slug}/discovered-channels", :get,
            "/communities/sample/discovered-channels", expect_status: 200)
      check("/communities/{slug}/discovered-channels/mapping-proposals", :get,
            "/communities/sample/discovered-channels/mapping-proposals", expect_status: 200)
      check("/communities/{slug}/suggested-channels", :get,
            "/communities/sample/suggested-channels", expect_status: 200)

      check("/admin/pending-spaces", :get, "/admin/pending-spaces", expect_status: 200)
      check("/admin/pending-spaces/{id}", :get, "/admin/pending-spaces/#{f[:space].id}", expect_status: 200)
      check("/admin/communities/{slug}/space-suggestions", :get,
            "/admin/communities/sample/space-suggestions", expect_status: 200)

      check("/features/schema", :get, "/features/schema", expect_status: 200)

      check("/communities/{slug}/features", :get, "/communities/sample/features", expect_status: 200)
      check("/communities/{slug}/features/{feature}", :get,
            "/communities/sample/features/moderation", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/features", :get,
            "/communities/sample/rooms/general/features", expect_status: 200)
      # No override on this room, so this is the inherited answer. The override
      # case is driven in the writes example, after a PATCH creates one.
      check("/communities/{slug}/rooms/{room_key}/features/{feature}", :get,
            "/communities/sample/rooms/general/features/moderation", expect_status: 200)

      check("/communities/{slug}/content-policy/misfires", :get,
            "/communities/sample/content-policy/misfires", expect_status: 200)
      check("/communities/{slug}/word-filter/entries", :get,
            "/communities/sample/word-filter/entries", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/word-filter/entries", :get,
            "/communities/sample/rooms/general/word-filter/entries", expect_status: 200)
      check("/communities/{slug}/faq/entries", :get, "/communities/sample/faq/entries", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/faq/entries", :get,
            "/communities/sample/rooms/general/faq/entries", expect_status: 200)
      check("/communities/{slug}/join-links", :get, "/communities/sample/join-links", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/join-links", :get,
            "/communities/sample/rooms/general/join-links", expect_status: 200)

      check("/communities/{slug}/platform-connections", :get,
            "/communities/sample/platform-connections", expect_status: 200)
      check("/communities/{slug}/irc-networks", :get, "/communities/sample/irc-networks", expect_status: 200)
      check("/communities/{slug}/irc-networks/{name}", :get,
            "/communities/sample/irc-networks/#{f[:network].name}", expect_status: 200)
      check("/communities/{slug}/fluxer-instances", :get, "/communities/sample/fluxer-instances", expect_status: 200)
      check("/communities/{slug}/fluxer-instances/{label}", :get,
            "/communities/sample/fluxer-instances/#{f[:fluxer].label}", expect_status: 200)

      check("/communities/{slug}/guest-invites", :get, "/communities/sample/guest-invites", expect_status: 200)
      check("/communities/{slug}/guest-invites/{id}", :get,
            "/communities/sample/guest-invites/#{f[:invite].id}", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/events", :get,
            "/communities/sample/rooms/general/events", expect_status: 200)
      check("/communities/{slug}/events/{id}", :get, "/communities/sample/events/#{f[:event].id}", expect_status: 200)
      check("/admin/communities/{slug}/mutes", :get, "/admin/communities/sample/mutes", expect_status: 200)

      check("/admin/communities/{slug}/scripts", :get, "/admin/communities/sample/scripts", expect_status: 200)
      check("/admin/communities/{slug}/scripts/archived", :get,
            "/admin/communities/sample/scripts/archived", expect_status: 200)
      check("/admin/communities/{slug}/scripts/{id}", :get,
            "/admin/communities/sample/scripts/#{script['id']}", expect_status: 200)
      check("/admin/scripting/capabilities", :get, "/admin/scripting/capabilities", expect_status: 200)
      check("/admin/communities/{slug}/endpoints", :get, "/admin/communities/sample/endpoints", expect_status: 200)
      check("/admin/communities/{slug}/endpoints/{id}", :get,
            "/admin/communities/sample/endpoints/#{endpoint['id']}", expect_status: 200)
      check("/admin/communities/{slug}/webhooks", :get, "/admin/communities/sample/webhooks", expect_status: 200)
      check("/admin/communities/{slug}/webhooks/{public_id}", :get,
            "/admin/communities/sample/webhooks/#{webhook['public_id']}", expect_status: 200)
      check("/admin/communities/{slug}/webhook-deliveries", :get,
            "/admin/communities/sample/webhook-deliveries", expect_status: 200)

      check("/admin/communities/{slug}/scripts/{id}/errors", :get,
            "/admin/communities/sample/scripts/#{script['id']}/errors", expect_status: 200)

      check("/communities/{slug}/alerts", :get, "/communities/sample/alerts", expect_status: 200)

      check("/communities/{slug}/rooms/{room_key}/participation", :get,
            "/communities/sample/rooms/general/participation", expect_status: 200)

      check("/admin/communities/{slug}/files", :get, "/admin/communities/sample/files", expect_status: 200)
      check("/admin/communities/{slug}/files/{id}", :get,
            "/admin/communities/sample/files/#{f[:held].file.id}", expect_status: 200)

      check("/admin/communities/{slug}/script-stats", :get,
            "/admin/communities/sample/script-stats", expect_status: 200)
      check("/admin/communities/{slug}/stats", :get, "/admin/communities/sample/stats", expect_status: 200)
      check("/admin/debug/info", :get, "/admin/debug/info", expect_status: 200)
      check("/admin/debug/logs", :get, "/admin/debug/logs", expect_status: 200)
      check("/admin/debug/backfill-gaps", :get, "/admin/debug/backfill-gaps", expect_status: 200)
      check("/admin/backfill-proposals", :get, "/admin/backfill-proposals", expect_status: 200)
      check("/admin/backfill-proposals/{id}", :get,
            "/admin/backfill-proposals/#{f[:proposal]}", expect_status: 200)

      # Both shapes the operators list can carry are reached here: the shipped
      # owner floor is never empty, and the seeded configuration grants one
      # record of its own.
      expect(operators.select { |entry| entry["baked_in"] }).not_to be_empty
      expect(operators.reject { |entry| entry["baked_in"] }).not_to be_empty

      expect(@exercised.length).to eq(73)
    end

    it "answers every documented write with a body the spec describes" do
      f = fixtures

      # Created through the API, so the 201 bodies are checked and then reused as the
      # ids the rest address.
      script_params = { name: "drift", kind: "processor", language: "lua",
                        source: 'return { action = "allow" }', trigger_type: "always" }
      expect_valid_request("/admin/communities/{slug}/scripts", "post", script_params)
      post "/admin/communities/sample/scripts", script_params, admin
      expect(last_response.status).to eq(201)
      script = YAMLCamel.load(last_response.body)
      expect_valid("/admin/communities/{slug}/scripts", "post", "201", script)
      @exercised << "POST /admin/communities/{slug}/scripts"

      endpoint_params = { name: "drift", url: "https://example.invalid/hook", http_method: "GET" }
      expect_valid_request("/admin/communities/{slug}/endpoints", "post", endpoint_params)
      post "/admin/communities/sample/endpoints", endpoint_params, admin
      expect(last_response.status).to eq(201)
      endpoint = YAMLCamel.load(last_response.body)
      expect_valid("/admin/communities/{slug}/endpoints", "post", "201", endpoint)
      @exercised << "POST /admin/communities/{slug}/endpoints"

      check("/admin/communities/{slug}/rooms", :post, "/admin/communities/sample/rooms",
            { "name" => "Drift room", "platforms" => [{ "adapter" => "telegram", "account" => "telegram" }] },
            expect_status: 202)
      check("/admin/communities/{slug}/rooms/{room_key}", :delete, "/admin/communities/sample/rooms/general",
            { "confirmed_name" => f[:room].label || f[:room].room_key }, expect_status: 202)
      check("/admin/communities/{slug}/status", :put, "/admin/communities/sample/status",
            { "status" => "active" }, expect_status: 200)

      check("/admin/action-permissions", :patch, "/admin/action-permissions",
            { "permissions" => { "moderate_user" => true } }, expect_status: 200)

      check("/admin/integrations/{name}", :patch, "/admin/integrations/openarc",
            { "url" => "http://openarc:8000/v1", "api_key" => "drift-key", "config" => { "model" => "drift-model" } },
            expect_status: 200)

      # Written straight into the store rather than over the API: a misfire row
      # exists only because an operator reversed something in chat, so there is
      # no create route for one to be driven through.
      misfire = models.content_policy_misfire.create(
        community_id: community.id, adapter: "telegram", endpoint_id: "tg-general",
        policy: "Drift policy", action: "flag_notify", body: "drift sample",
        reasoning: "matched", confidence: 0.5, statement: "wrong call",
        reversed_by: "telegram:drift", acted_at: Time.now, created_at: Time.now
      )
      check("/communities/{slug}/content-policy/misfires/{id}", :delete,
            "/communities/sample/content-policy/misfires/#{misfire.id}", expect_status: 204)

      check("/admin/communities/{slug}/mutes", :post, "/admin/communities/sample/mutes",
            { "adapter" => "telegram", "native_id" => "drift-mute", "duration" => "1h" }, expect_status: 201)
      mute = YAMLCamel.load(last_response.body)
      check("/admin/communities/{slug}/mutes/{id}", :delete,
            "/admin/communities/sample/mutes/#{mute["id"]}", expect_status: 200)

      deps.feature_controls.enable(community: community, selector: f[:room].room_key, feature: "events")
      check("/communities/{slug}/rooms/{room_key}/events", :post, "/communities/sample/rooms/general/events",
            { "title" => "Drift event", "starts_at" => "2030-01-01 20:00", "timezone" => "Europe/Lisbon",
              "kind" => "general" }, expect_status: 201)
      event = YAMLCamel.load(last_response.body)
      check("/communities/{slug}/events/{id}", :patch, "/communities/sample/events/#{event["id"]}",
            { "title" => "Drift event revised" }, expect_status: 200)
      check("/communities/{slug}/events/{id}", :delete, "/communities/sample/events/#{event["id"]}",
            expect_status: 200)

      check("/communities/{slug}/rooms/{room_key}/messages", :post,
            "/communities/sample/rooms/general/messages", { body: "a drift check post" }, expect_status: 201)
      meta_message_id = YAMLCamel.load(last_response.body)["id"]

      # The meta-level surface, addressing the message the room-level POST
      # just minted. No bot process runs here to actually relay it, so the
      # map row a real relay would have left behind is written directly,
      # standing in for that relay.
      storage.record(
        source: Rubotty::Core::MessageRef.new(Rubotty::Adapters::Api.endpoint_key_for(f[:room].id),
                                              meta_message_id.to_s),
        destination: Rubotty::Core::MessageRef.new("tg-general", "drift-900"), room_id: f[:room].id
      )
      meta_message_path = "/communities/sample/rooms/general/messages/#{meta_message_id}"
      check("/communities/{slug}/rooms/{room_key}/messages/{message_id}", :patch,
            meta_message_path, { "body" => "edited from the meta surface" }, expect_status: 202)
      check("/communities/{slug}/rooms/{room_key}/messages/{message_id}/reactions", :put,
            "#{meta_message_path}/reactions", { "reaction" => { "emoji" => "\u{1F44D}" } }, expect_status: 202)
      check("/communities/{slug}/rooms/{room_key}/messages/{message_id}/reactions", :delete,
            "#{meta_message_path}/reactions", { "reaction" => { "emoji" => "\u{1F44D}" } }, expect_status: 202)
      check("/communities/{slug}/rooms/{room_key}/messages/{message_id}", :delete,
            meta_message_path, expect_status: 202)

      # The api_wrapper bridge surface, driven with the platform-account
      # scoped key {#build_fixtures} minted rather than the admin key every
      # other check above uses.
      as_bridge = { "HTTP_AUTHORIZATION" => "Bearer #{f[:bridge_key]}" }
      bridge_channel_id = f[:bridge_channel].route_key
      check("/communities/{slug}/bridge/channels/{channel_id}/messages", :post,
            "/communities/sample/bridge/channels/#{bridge_channel_id}/messages",
            { "body" => "hello from the other side", "author" => { "id" => "u1", "name" => "Remote Ada" } },
            headers: as_bridge, expect_status: 201)
      bridge_message = YAMLCamel.load(last_response.body)
      bridge_message_path = "/communities/sample/bridge/channels/#{bridge_channel_id}/messages/#{bridge_message['message_id']}"

      check("/communities/{slug}/bridge/channels/{channel_id}/messages/{message_id}", :patch,
            bridge_message_path, { "body" => "edited from the other side" }, headers: as_bridge, expect_status: 202)
      check("/communities/{slug}/bridge/channels/{channel_id}/messages/{message_id}/reactions", :put,
            "#{bridge_message_path}/reactions",
            { "author" => { "id" => "u1" }, "reaction" => { "emoji" => "\u{1F44D}" } },
            headers: as_bridge, expect_status: 202)
      check("/communities/{slug}/bridge/channels/{channel_id}/messages/{message_id}/reactions", :delete,
            "#{bridge_message_path}/reactions",
            { "author" => { "id" => "u1" }, "reaction" => { "emoji" => "\u{1F44D}" } },
            headers: as_bridge, expect_status: 202)
      check("/communities/{slug}/bridge/channels/{channel_id}/messages/{message_id}", :delete,
            bridge_message_path, { "author" => { "id" => "u1" } }, headers: as_bridge, expect_status: 202)

      bridge_members_path = "/communities/sample/bridge/channels/#{bridge_channel_id}/members"
      check("/communities/{slug}/bridge/channels/{channel_id}/members", :post, bridge_members_path,
            { "author" => { "id" => "u1", "name" => "Remote Ada" } }, headers: as_bridge, expect_status: 202)
      check("/communities/{slug}/bridge/channels/{channel_id}/members", :delete, bridge_members_path,
            { "author" => { "id" => "u1", "name" => "Remote Ada" } }, headers: as_bridge, expect_status: 202)

      check("/communities/{slug}/discovered-channels/mapping-proposals/apply", :post,
            "/communities/sample/discovered-channels/mapping-proposals/apply",
            { "mappings" => [{ "endpoint_key" => f[:discovered].endpoint_key, "room_key" => "gaming" }] },
            expect_status: 200)
      check("/communities/{slug}/discovered-channels/{endpoint_key}/map", :post,
            "/communities/sample/discovered-channels/#{f[:lone].endpoint_key}/map",
            { "solo" => true, "label" => "Book club" }, expect_status: 200)

      # Keep one suggestion and drop the other, so each decision runs on a row
      # that is still open to it.
      check("/communities/{slug}/suggested-channels/{id}/approve", :post,
            "/communities/sample/suggested-channels/#{f[:kept].id}/approve", expect_status: 200)
      check("/communities/{slug}/suggested-channels/{id}/reject", :post,
            "/communities/sample/suggested-channels/#{f[:dropped].id}/reject", expect_status: 204)

      # Approve one space, refuse the other, then clear the refusal, so each
      # decision runs on a row that is still open to it.
      check("/admin/pending-spaces/{id}/approve", :post,
            "/admin/pending-spaces/#{f[:space].id}/approve",
            { "community" => "sample", "make_operator" => true }, expect_status: 200)
      check("/admin/pending-spaces/{id}/reject", :post,
            "/admin/pending-spaces/#{f[:stranger].id}/reject", expect_status: 200)
      check("/admin/pending-spaces/{id}", :delete,
            "/admin/pending-spaces/#{f[:stranger].id}", expect_status: 204)

      check("/communities/{slug}/word-filter/entries", :put,
            "/communities/sample/word-filter/entries", { "entries" => %w[badword] }, expect_status: 200)
      check("/communities/{slug}/word-filter/entries", :delete,
            "/communities/sample/word-filter/entries", { "value" => "badword" }, expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/word-filter/entries", :put,
            "/communities/sample/rooms/general/word-filter/entries", { "entries" => %w[roomword] }, expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/word-filter/entries", :delete,
            "/communities/sample/rooms/general/word-filter/entries", { "value" => "roomword" }, expect_status: 200)

      # Driven directly so the 201 body, which carries the id the delete below
      # addresses, is checked against its own schema.
      faq_params = { trigger: "help", response: "See the docs.", trigger_type: "command" }
      expect_valid_request("/communities/{slug}/faq/entries", "post", faq_params)
      post "/communities/sample/faq/entries", faq_params, admin
      expect(last_response.status).to eq(201)
      faq_entry = YAMLCamel.load(last_response.body)
      expect_valid("/communities/{slug}/faq/entries", "post", "201", faq_entry)
      @exercised << "POST /communities/{slug}/faq/entries"
      check("/communities/{slug}/faq/entries/{id}", :delete,
            "/communities/sample/faq/entries/#{faq_entry["id"]}", expect_status: 200)

      room_faq_params = { trigger: "rules", response: "Be nice.", trigger_type: "keyword" }
      expect_valid_request("/communities/{slug}/rooms/{room_key}/faq/entries", "post", room_faq_params)
      post "/communities/sample/rooms/general/faq/entries", room_faq_params, admin
      expect(last_response.status).to eq(201)
      room_faq_entry = YAMLCamel.load(last_response.body)
      expect_valid("/communities/{slug}/rooms/{room_key}/faq/entries", "post", "201", room_faq_entry)
      @exercised << "POST /communities/{slug}/rooms/{room_key}/faq/entries"
      check("/communities/{slug}/rooms/{room_key}/faq/entries/{id}", :delete,
            "/communities/sample/rooms/general/faq/entries/#{room_faq_entry["id"]}", expect_status: 200)

      check("/communities/{slug}/join-links", :put, "/communities/sample/join-links",
            { "join_links" => [{ "platform" => "discord", "label" => "Discord", "url" => "https://discord.example/invite" }] },
            expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/join-links", :put, "/communities/sample/rooms/general/join-links",
            { "join_links" => [{ "platform" => "discord", "url" => "https://discord.example/invite" }] },
            expect_status: 200)

      # A real config key rather than only the on switch, so a config value the
      # spec does not describe fails here. The key is one the feature actually
      # declares, read back through the same row the read routes serve.
      check("/communities/{slug}/features/{feature}", :patch,
            "/communities/sample/features/moderation",
            { enabled: true, config: { ack_ttl_seconds: 45 } }, expect_status: 200)
      expect(YAMLCamel.load(last_response.body).dig("config", "ack_ttl_seconds")).to eq(45)
      check("/communities/{slug}/rooms/{room_key}/features/{feature}", :patch,
            "/communities/sample/rooms/general/features/moderation", { enabled: true }, expect_status: 200)
      # Only reachable after the PATCH above created an override to reset.
      check("/communities/{slug}/rooms/{room_key}/features/{feature}", :get,
            "/communities/sample/rooms/general/features/moderation", expect_status: 200)
      check("/communities/{slug}/rooms/{room_key}/features/{feature}", :delete,
            "/communities/sample/rooms/general/features/moderation", expect_status: 204)

      check("/admin/communities/{slug}/scripts/{id}", :patch,
            "/admin/communities/sample/scripts/#{script['id']}", { name: "drift renamed" }, expect_status: 200)
      check("/admin/communities/{slug}/scripts/{id}/verify", :post,
            "/admin/communities/sample/scripts/#{script['id']}/verify", expect_status: 200)
      check("/admin/communities/{slug}/scripts/{id}/disable", :post,
            "/admin/communities/sample/scripts/#{script['id']}/disable", expect_status: 200)
      check("/admin/communities/{slug}/scripts/{id}", :delete,
            "/admin/communities/sample/scripts/#{script['id']}", expect_status: 204)
      check("/admin/communities/{slug}/scripts/{id}/restore", :post,
            "/admin/communities/sample/scripts/#{script['id']}/restore", expect_status: 200)

      check("/admin/communities/{slug}/endpoints/{id}", :patch,
            "/admin/communities/sample/endpoints/#{endpoint['id']}", { cache_seconds: 60 }, expect_status: 200)
      check("/admin/communities/{slug}/endpoints/{id}", :delete,
            "/admin/communities/sample/endpoints/#{endpoint['id']}", expect_status: 204)

      network_params = { name: "drift", host: "irc.drift.example", nick: "driftbot" }
      expect_valid_request("/admin/communities/{slug}/irc-networks", "post", network_params)
      post "/admin/communities/sample/irc-networks", network_params, admin
      expect(last_response.status).to eq(201)
      network = YAMLCamel.load(last_response.body)
      expect_valid("/admin/communities/{slug}/irc-networks", "post", "201", network)
      @exercised << "POST /admin/communities/{slug}/irc-networks"

      check("/admin/communities/{slug}/irc-networks/{name}", :patch,
            "/admin/communities/sample/irc-networks/#{network['name']}", { mode: "hub", hub_channel: "#sample" },
            expect_status: 200)
      check("/admin/communities/{slug}/irc-networks/{name}", :delete,
            "/admin/communities/sample/irc-networks/#{network['name']}", expect_status: 204)

      # Driven here rather than through the helper, so the 201 body carrying the
      # signing secret is checked against its own schema.
      webhook_params = { url: "https://example.invalid/events", event_types: "message.relayed" }
      expect_valid_request("/admin/communities/{slug}/webhooks", "post", webhook_params)
      post "/admin/communities/sample/webhooks", webhook_params, admin
      expect(last_response.status).to eq(201)
      webhook = YAMLCamel.load(last_response.body)
      expect_valid("/admin/communities/{slug}/webhooks", "post", "201", webhook)
      @exercised << "POST /admin/communities/{slug}/webhooks"

      check("/admin/communities/{slug}/webhooks/{public_id}/rotate", :post,
            "/admin/communities/sample/webhooks/#{webhook['public_id']}/rotate",
            { overlap: 3600 }, expect_status: 200)
      check("/admin/communities/{slug}/webhooks/{public_id}", :delete,
            "/admin/communities/sample/webhooks/#{webhook['public_id']}", expect_status: 204)

      check("/admin/viewers", :post, "/admin/viewers",
            { adapter: "telegram", handle: "ada", native_id: "9301", label: "Ada" }, expect_status: 201)
      granted_viewer = YAMLCamel.load(last_response.body)
      check("/admin/viewer-requests/{id}/approve", :post,
            "/admin/viewer-requests/#{f[:viewer_request]}/approve", expect_status: 200)
      check("/admin/viewer-requests/{id}/deny", :post,
            "/admin/viewer-requests/#{f[:denied_viewer_request]}/deny", expect_status: 200)
      check("/admin/viewers/{id}", :delete, "/admin/viewers/#{granted_viewer["id"]}", expect_status: 204)

      check("/admin/administrators", :post, "/admin/administrators",
            { adapter: "telegram", handle: "baker", native_id: "9302", label: "Baker" }, expect_status: 201)
      granted_administrator = YAMLCamel.load(last_response.body)
      check("/admin/administrators/{id}", :delete,
            "/admin/administrators/#{granted_administrator["id"]}", expect_status: 204)

      check("/communities/{slug}/viewers", :post, "/communities/sample/viewers",
            { adapter: "telegram", handle: "bea", native_id: "9303", label: "Bea" }, expect_status: 201)
      granted_community_viewer = YAMLCamel.load(last_response.body)
      check("/communities/{slug}/viewer-requests/{id}/approve", :post,
            "/communities/sample/viewer-requests/#{f[:community_viewer_request]}/approve", expect_status: 200)
      check("/communities/{slug}/viewer-requests/{id}/deny", :post,
            "/communities/sample/viewer-requests/#{f[:denied_community_viewer_request]}/deny", expect_status: 200)
      check("/communities/{slug}/viewers/{id}", :delete,
            "/communities/sample/viewers/#{granted_community_viewer["id"]}", expect_status: 204)

      check("/admin/auth-tokens", :post, "/admin/auth-tokens", { label: "drift wide" }, expect_status: 201)
      wide_token = YAMLCamel.load(last_response.body)
      check("/admin/auth-tokens/{public_id}", :delete,
            "/admin/auth-tokens/#{wide_token["public_id"]}", expect_status: 204)

      check("/communities/{slug}/auth-tokens", :post, "/communities/sample/auth-tokens",
            { operator: true, viewer: true, label: "drift scoped" }, expect_status: 201)
      scoped_token = YAMLCamel.load(last_response.body)
      check("/communities/{slug}/auth-tokens/{public_id}", :delete,
            "/communities/sample/auth-tokens/#{scoped_token["public_id"]}", expect_status: 204)

      # Granted here rather than seeded, because the one operator the shipped
      # configuration seeds is also a deployment-configured owner and so cannot be revoked.
      check("/admin/communities/{slug}/operators", :post, "/admin/communities/sample/operators",
            { adapter: "telegram", native_id: "7788", username: "deputy", display: "Deputy" },
            expect_status: 201)
      granted_operator = YAMLCamel.load(last_response.body)
      expect(granted_operator["baked_in"]).to be(false)
      check("/admin/communities/{slug}/operators/{id}", :delete,
            "/admin/communities/sample/operators/#{granted_operator["id"]}", expect_status: 204)

      check("/communities/{slug}/people/{id}/nicknames/{adapter}", :put,
            "/communities/sample/people/#{f[:person].id}/nicknames/discord",
            { nickname: "Drifter" }, expect_status: 200)
      expect(YAMLCamel.load(last_response.body).dig("nicknames", "discord")).to eq("Drifter")
      check("/communities/{slug}/people/{id}/nicknames/{adapter}", :delete,
            "/communities/sample/people/#{f[:person].id}/nicknames/discord", expect_status: 204)

      check("/communities/{slug}/alerts/{id}/seen", :post,
            "/communities/sample/alerts/#{f[:alert].id}/seen", expect_status: 200)
      check("/communities/{slug}/alerts/seen", :post, "/communities/sample/alerts/seen", expect_status: 200)

      check("/communities/{slug}/rooms/{room_key}/participation/close", :post,
            "/communities/sample/rooms/general/participation/close", expect_status: 200)

      # Driven directly, since it is the one multipart request in the whole surface and
      # its 201 is what carries the UUID.
      upload_params = {
        file: Rack::Test::UploadedFile.new(StringIO.new("drifted bytes"), "text/plain", original_filename: "drift.txt")
      }
      expect_valid_request("/admin/communities/{slug}/files", "post", upload_params)
      post "/admin/communities/sample/files", upload_params, admin
      expect(last_response.status).to eq(201)
      uploaded = YAMLCamel.load(last_response.body)
      expect_valid("/admin/communities/{slug}/files", "post", "201", uploaded)
      @exercised << "POST /admin/communities/{slug}/files"

      check("/admin/communities/{slug}/files/rotate", :post, "/admin/communities/sample/files/rotate",
            { uuid: uploaded["uuid"] }, expect_status: 200)
      rotated = YAMLCamel.load(last_response.body)
      check("/admin/communities/{slug}/files/expire", :post, "/admin/communities/sample/files/expire",
            { uuid: rotated["uuid"] }, expect_status: 200)
      # By id rather than UUID, and on a file already expired above, which is the
      # no-op the route promises.
      check("/admin/communities/{slug}/files/{id}", :delete,
            "/admin/communities/sample/files/#{rotated["id"]}", expect_status: 200)

      # No bot process is reachable from here, so the accept records the decision
      # and reports plainly that nothing is being sent, which is the shape the
      # spec describes for it.
      check("/admin/backfill-proposals/{id}/approve", :post,
            "/admin/backfill-proposals/#{f[:proposal]}/approve", expect_status: 200)
      check("/admin/backfill-proposals/{id}/reject", :post,
            "/admin/backfill-proposals/#{f[:spare_proposal]}/reject", expect_status: 200)

      expect(@exercised.length).to eq(86)
    end

    it "answers an oversized text request with the documented YAML 413 shape" do
      payload = "enabled: true\n#" + ("x" * Rubotty::Api::App::TEXT_BODY_BYTES)
      patch "/communities/sample/features/faq", payload, admin.merge("CONTENT_TYPE" => "application/yaml")
      expect(last_response.status).to eq(413)
      expect(last_response.content_type).to start_with("application/yaml")
      body = YAMLCamel.load(last_response.body)
      expect(body.fetch("error")).to include("larger")
      expect_valid("/communities/{slug}/features/{feature}", "patch", "413", body)
    end

    # Switching a script on needs a Lua interpreter on the host, so it is kept apart
    # from the writes above and a machine without one skips this example alone.
    it "answers the on switch with a body the spec describes", if: Rubotty::Scripting::Child.find_binary do
      fixtures
      script = create_script
      post "/admin/communities/sample/scripts/#{script['id']}/verify", {}, admin
      expect(YAMLCamel.load(last_response.body)["ok"]).to be(true)

      post "/admin/communities/sample/scripts/#{script['id']}/enable", {}, admin

      expect(last_response.status).to eq(200)
      expect_valid("/admin/communities/{slug}/scripts/{id}/enable", "post", "200", YAMLCamel.load(last_response.body))
    end

    # The one route whose body is a frame stream, so each frame is checked against the
    # schema the response declares.
    it "sends stream frames the spec describes" do
      fixtures
      Rubotty::ControlPlane::LiveRoomFeed.new(models: models)
                                         .record(community_id: community.id, room_key: "general",
                                                 body: "watched live", origin_key: "tg-general",
                                                 author_label: "ada", kind: "chat")

      # since=0 rather than the default head, because a stream opened inside one
      # in-process request has no "afterwards" to carry a message.
      get "/communities/sample/rooms/general/stream", { since: 0 }, admin

      expect(last_response.status).to eq(200)
      expect(last_response.content_type).to start_with("text/event-stream")

      frames = last_response.body.split("\n\n").reject { |frame| frame.strip.start_with?(":") }
      documents = frames.filter_map do |frame|
        payload = frame.lines.filter_map { |line| line.delete_prefix("data: ").chomp if line.start_with?("data: ") }
        YAMLCamel.load(payload.join("\n")) unless payload.empty?
      end

      expect(documents).not_to be_empty
      documents.each do |frame|
        expect_valid("/communities/{slug}/rooms/{room_key}/stream", "get", "200", frame)
      end
      # The opening frame pins the cursor and carries nothing, so the message has to
      # appear in a later one or the item schema was never reached.
      expect(documents.flat_map { |frame| frame["messages"] }.map { |m| m["body"] }).to include("watched live")
    end

    # Checked against the spec's own 401/403/404 nodes, so those cannot be trimmed off
    # an operation while the app still answers with them.
    it "answers the documented error shapes" do
      fixtures
      developer = keys.issue(scope: "developer", community: community, label: "drift dev").token
      as_developer = { "HTTP_AUTHORIZATION" => "Bearer #{developer}" }
      now = Time.now
      models.community.create(slug: "other-co", name: "Other Co", status: "active", settings: "{}",
                              created_at: now, updated_at: now)

      get "/communities/sample"
      expect(last_response.status).to eq(401)
      expect_valid("/communities/{slug}", "get", "401", YAMLCamel.load(last_response.body))

      get "/admin/communities", {}, as_developer
      expect(last_response.status).to eq(403)
      expect_valid("/admin/communities", "get", "403", YAMLCamel.load(last_response.body))

      get "/communities/other-co", {}, as_developer
      expect(last_response.status).to eq(404)
      expect_valid("/communities/{slug}", "get", "404", YAMLCamel.load(last_response.body))
    end

    it "keeps every community route opaque to a key from another community" do
      fixtures
      developer = keys.issue(scope: "developer", community: community, label: "drift dev").token
      as_developer = { "HTTP_AUTHORIZATION" => "Bearer #{developer}" }
      now = Time.now
      models.community.create(slug: "other-co", name: "Other Co", status: "active", settings: "{}",
                              created_at: now, updated_at: now)

      checked = community_operations.map do |path, verb|
        public_send(verb, foreign_path(path), {}, as_developer)

        expect(last_response.status).to eq(404), "#{verb.upcase} #{path} exposed another community"
        expect_valid(path, verb, "404", YAMLCamel.load(last_response.body))
        "#{verb.upcase} #{path}"
      end

      expect(checked.length).to be > 40
    end
  end

  # Without this, a new route could be documented, satisfy the route table comparison
  # and never have its body checked against the schema somebody wrote for it.
  describe "which operations the body checks cover" do
    # Operation to why it is not driven. An entry here is a schema nobody is holding
    # to account.
    UNEXERCISED = {
      "GET /healthz" =>
        "answers plain text, not a schema, and spec/api/app_spec.rb already asserts the body",
      "POST /admin/communities/{slug}/scripts/{id}/enable" =>
        "driven in its own example, which skips without a Lua interpreter on the host",
      "GET /communities/{slug}/rooms/{room_key}/stream" =>
        "driven in its own example, since its body is a frame stream rather than one document"
    }.freeze

    it "leaves nothing undriven without saying why" do
      driven = File.read(File.expand_path("openapi_drift_spec.rb", __dir__))
      documented = document["paths"].flat_map do |path, item|
        item.keys.select { |key| HTTP_VERBS.include?(key) }.map { |verb| ["#{verb.upcase} #{path}", path, verb] }
      end

      unaccounted = documented.filter_map do |label, path, verb|
        next nil if UNEXERCISED.key?(label)
        # The check helper takes the path template first, so the template sitting next
        # to the verb is what proves the operation is driven.
        next nil if driven.include?(%("#{path}", :#{verb}))
        next nil if driven.include?(%("#{path}", "#{verb}"))

        label
      end

      expect(unaccounted).to be_empty, lambda {
        "#{unaccounted.length} documented operation(s) have no response-body check and no stated reason:\n" \
          "  #{unaccounted.join("\n  ")}"
      }
    end

    it "keeps the stated exceptions to operations that exist" do
      documented = document["paths"].flat_map do |path, item|
        item.keys.select { |key| HTTP_VERBS.include?(key) }.map { |verb| "#{verb.upcase} #{path}" }
      end

      expect(UNEXERCISED.keys - documented).to be_empty
    end
  end
end
