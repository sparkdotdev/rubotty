# frozen_string_literal: true

require "spec_helper"
require "rubotty/dashboard"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "stringio"
require "cgi"

# rendered_vocabulary_spec.rb, screens_spec.rb and view_vocabulary_spec.rb
# all read server-rendered ERB, so hand-rolled markup is invisible to
# them. This file closes that gap: it compiles the real Civet source
# and runs the bundle through Node, the way a browser does.
module ThemedRenderedVocabularySupport
end

RSpec.describe "the themed dashboard vocabulary", :control_plane do
  ThemedRenderedVocabularySupport::ROOT = File.expand_path("../..", __dir__)
  ThemedRenderedVocabularySupport::SUPPORT_DIR = File.expand_path("../support", __dir__)
  ThemedRenderedVocabularySupport::RENDER_TOOLS = %w[node civet esbuild].freeze
  ThemedRenderedVocabularySupport::NODE_BIN = ThemeToolchain.path("node")
  ThemedRenderedVocabularySupport::CIVET_BIN = ThemeToolchain.path("civet")
  ThemedRenderedVocabularySupport::ESBUILD_BIN = ThemeToolchain.path("esbuild")

  def run!(*cmd)
    out, status = Open3.capture2e(*cmd)
    raise "#{cmd.join(' ')} failed:\n#{out}" unless status.success?

    out
  end

  # Compiles the runtime and every theme's own Civet fresh into a private directory on
  # every run (the same steps package.json's build:civet/build:theme-runtime scripts
  # run) rather than trusting whatever is or isn't sitting in the gitignored
  # lib/rubotty/dashboard/public, so a regression in the source is caught rather than
  # checked against yesterday's build. Must live under the project's own tmp/, not a
  # system temp directory: esbuild resolves a bare import like js-yaml by walking up
  # from the importing file looking for node_modules, and a system temp directory has
  # none of this project's above it to find.
  def compile_theme_bundles
    FileUtils.mkdir_p(File.join(ThemedRenderedVocabularySupport::ROOT, "tmp"))
    dir = Dir.mktmpdir("theme-spec", File.join(ThemedRenderedVocabularySupport::ROOT, "tmp"))
    %w[runtime series-a].each do |part|
      output = File.join(dir, part)
      FileUtils.mkdir_p(output)
      run!(ThemedRenderedVocabularySupport::CIVET_BIN, "--js", "-c",
           *Dir.glob(File.join(ThemedRenderedVocabularySupport::ROOT, "assets/themes/#{part}/*.civet")),
           "-o", "#{output}/.js")
    end
    runtime_js = File.join(dir, "theme-runtime.js")
    run!(ThemedRenderedVocabularySupport::ESBUILD_BIN, File.join(dir, "runtime", "index.js"), "--bundle", "--format=iife",
         "--global-name=rubottyTheme", "--outfile=#{runtime_js}")
    hydration_js = File.join(dir, "chart-engine.js")
    run!(ThemedRenderedVocabularySupport::ESBUILD_BIN, File.join(dir, "runtime", "chart-boot.js"), "--bundle", "--format=iife",
         "--outfile=#{hydration_js}")
    { dir: dir, runtime: runtime_js, hydration: hydration_js }
  end

  # The classes inside a Prose document, which kramdown puts on a fenced
  # block rather than any primitive drawing them: the same reason
  # the documents use Lua, YAML, shell and contribution-template examples.
  # No other emitter can produce one, and the scan refuses any other class.
  ThemedRenderedVocabularySupport::THEMED_DOCUMENT_CLASSES = %w[
    language-lua language-yaml language-sh language-markdown
  ].freeze

  def classes_in(html) = html.scan(/\bclass="([^"]*)"/).flatten.flat_map(&:split).uniq

  def inline_styles(html) = html.gsub(%r{<svg class="rb-chart-svg".*?</svg>}m, "").scan(/\sstyle="/).length

  def button_tags(html) = html.scan(/<(?:button|a)\b[^>]*class="rb-button[^>]*>/)

  def ungated_buttons(html) = button_tags(html).reject { |tag| tag.include?("data-grant") }

  if ThemeToolchain.ready?(ThemedRenderedVocabularySupport::RENDER_TOOLS)
    describe "driven through Node, the real compiled output" do
      before { install_dashboard_guide_fixture }
      after { remove_dashboard_guide_fixtures }

      before(:context) { @build = compile_theme_bundles }
      after(:context) { FileUtils.remove_entry(@build[:dir], true) }

      let(:seeded) { seeded_sample }
      let(:db) { seeded[0] }
      let(:file_store_root) { Dir.mktmpdir("theme-spec-files", File.join(ThemedRenderedVocabularySupport::ROOT, "tmp")) }
      let(:deps) do
        Rubotty::Dashboard::Deps.new(db: db, logger: Rubotty::Log.null, file_store_path: file_store_root)
      end
      let(:administrator) { Rubotty::Dashboard::Role.administrator }
      let(:view_data) { Rubotty::Dashboard::ViewData.new(deps: deps, role: administrator) }

      after { FileUtils.remove_entry(file_store_root, true) }

      # Every record seeded here gets real, non-default values, so the
      # client-side formatters and each screen's populated state have
      # something to actually render. Format.timestamp specifically needs a
      # real Date, decoded by js-yaml from the ISO 8601 text ViewData writes.
      before do
        community = deps.models.community.where(slug: "sample").first
        deps.script_endpoints.save(
          community: community, name: "weather", url: "https://api.example.com/forecast",
          http_method: "GET", timeout_seconds: 5, enabled: true, created_by: "administrator"
        )
        now = Time.now
        deps.models.redirection.create(
          community_id: community.id, source_endpoint_id: "tg-general", target_room_id: "right-room",
          operator: "sample_owner", message_count: 3, status: Rubotty::ControlPlane::Redirections::POSTING,
          step_index: 0, plan: "[]", created_at: now, updated_at: now
        )
        created = deps.webhooks.create(
          community_id: community.id, url: "https://example.invalid/hook",
          event_types: [Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED]
        )
        deps.webhooks.emit(community_id: community.id, event_type: Rubotty::ControlPlane::Webhooks::MESSAGE_RELAYED,
                           room_key: "general", data: { "body" => "hi" })
        row = deps.models.webhook_delivery.where(subscription_id: created.row.id).order(:id).last
        Rubotty::ControlPlane::Webhooks::MAX_ATTEMPTS.times do
          deps.webhooks.failed(row.refresh, error: "HTTP 500: down", response_status: 500)
        end
        greeter = deps.scripts.save(
          community: community, name: "greeter", kind: "processor", source: 'return { action = "allow" }',
          trigger_type: "always", trigger_config: {}, created_by: "administrator"
        )
        deps.scripts.record_error(greeter, "attempt to index a nil value")
        deps.scripts.record_run(greeter)
        deps.scripts.flush_runs
        deps.alerts.record(community_id: community.id, text: "greeter said hello", room_key: "general",
                           script: "greeter")
        deps.script_stats.increment(community: community, stat: "commands", row: "roll", step: 4)
        deps.script_stats.flush
        deps.feature_controls.set(
          community: community, selector: "all", feature: "bridge",
          key: "cross_platform_mentions", value: "false"
        )
        deps.feature_controls.set(
          community: community, selector: "all", feature: "backfill",
          key: "lookback_seconds", value: "7200"
        )
        deps.feature_controls.disable(community: community, selector: "all", feature: "backfill")
        # A real pending space and a real login link, so the two deployment
        # wide sections draw rows rather than their empty Notice.
        deps.pending_spaces.on_join!(
          adapter: :telegram, account: "telegram", external_id: "-100555", name: "Rando Group",
          inviter_native_id: "77", inviter_username: "rando"
        )
        deps.web_login.issue(
          identity_key: "telegram:telegram:80000012",
          operator: { adapter: "telegram", account: "telegram", native_id: "80000012", label: "Alex" },
          communities: [{ id: community.id, slug: community.slug, name: community.name }]
        )
        deps.participation.open_session(community: community, kind: "trivia", room_key: "general",
                                        label: "Friday trivia")
        deps.participation.open_round(community: community, room_key: "general",
                                      close_after: 300, on_close: "score_round")
        alert = deps.alerts.record(
          community_id: community.id, text: "disk usage high", mode: Rubotty::ControlPlane::Alerts::LOUD,
          room_key: "general", script: "diskwatch"
        )
        deps.alerts.delivered(alert, 1)
        deps.rehosted_files.store_file(
          community_id: community.id, source: StringIO.new("hello"), filename: "notes.txt",
          content_type: "text/plain", origin: "upload", created_by: "administrator"
        )
        deps.dashboard_administrators.grant(adapter: "telegram", handle: "ada", native_id: dashboard_native_id("ada"),
                                           label: "Ada", granted_by: "seeded")
        minter = Rubotty::ControlPlane::AuthTokens::Minter.new(administrator: true, community_ids: [], label: "seed")
        deps.auth_tokens.mint(minter: minter, community_id: nil, administrator: true, label: "for Bea")
        # A Fluxer instance and a scope's join links, so the connections screen
        # draws both of its own lists rather than their empty Notice.
        deps.fluxer_instances.create(
          community: community, label: "Flagship", kind: "flagship",
          endpoint_url: "", api_key_env: "FLUXER_FLAGSHIP_API_KEY"
        )
        deps.platform_links.replace(
          community: community, selector: "all",
          entries: [{ "platform" => "discord", "label" => "Our Discord", "url" => "https://discord.gg/abc" }]
        )

        # An open poll and a live guest invite, so both of those screens draw
        # rows rather than their empty Notice.
        room = deps.models.room.where(community_id: community.id).order(:room_key).first
        deps.polls.open(
          community: community, room: room, kind: Rubotty::Polls::Poll::KIND_POLL,
          question: "Which night suits everybody?", options: ["Thursday", "Friday"],
          created_by: "sample_owner"
        )
        deps.feature_controls.enable(community: community, selector: room.room_key, feature: "guest_portal")
        deps.guest_invites.issue(
          community: community, room: room, nickname: "Visiting Reviewer",
          ttl_seconds: 24 * 3600, created_by: "dashboard", as: :operator
        )

        # A second, dashboard-added account with its token env left unset, so
        # the very pill this screen exists to draw (see #1415) has both a good
        # and a bad row to render rather than only the seeded SAMPLE accounts,
        # whose env is always set in this suite by CONFIG_ENV.
        deps.accounts.create(adapter: "telegram", name: "telegram_2",
                             settings: { "token_env" => "TELEGRAM_BOT_TOKEN_2" })
        deps.identities.record(
          community_id: community.id, adapter: "telegram", native_id: "44556677",
          username: "ripley", display: "Ripley"
        )
        person = deps.bridged_nicknames.person_for(
          community_id: community.id, adapter: "telegram", native_id: "44556677",
          username: "ripley", display: "Ripley"
        )
        deps.bridged_nicknames.set(
          community_id: community.id, person_id: person.id, adapter: "discord", nickname: "Warrant Officer"
        )
        deps.feature_controls.set(
          community: community, selector: "all", feature: "nickname", key: "who_can_set", value: "everyone"
        )
        # entries starts empty on this feature now, so a real row for the
        # wrapping-textarea checks below has to be saved rather than read off
        # an unset default.
        deps.feature_controls.set(
          community: community, selector: "all", feature: "content_policy", key: "entries",
          value: [{ "name" => "Spam", "description" => "Promotional spam.", "action" => "delete" }]
        )
        deps.identities.record(
          community_id: community.id, adapter: "telegram", native_id: "77", username: "rando", display: "Rando"
        )
        deps.moderation.mute(
          community: community, adapter: "telegram", native_id: "77", username: "rando", display: "Rando",
          duration: "1h", reason: "testing", issued_by: "administrator"
        )
        general = deps.models.room.where(community_id: community.id, room_key: "general").first
        deps.feature_controls.enable(community: community, selector: "general", feature: "events")
        deps.event_scheduling.create(
          community: community, room: general, as: :operator, title: "Friday raid night",
          starts_at: Time.now + 3600, kind: "gaming", game_title: "Counter-Strike 2",
          server_address: "1.2.3.4:7777", rsvp_mode: "affirm", created_by: "administrator"
        )
        deps.integrations.save(
          name: "libretranslate", url: "https://libretranslate.example.org", api_key: "secret-key",
          config: { "allowed_pairs" => "en:pt,pt:en" }
        )
      end

      # A real pending proposal, ours: 0 included, so the client-drawn
      # danger notice has something other than a healthy count to prove
      # it ran. Relative to Time.now, not a fixed date, since #pending
      # calls expire_stale! first and a fixed past would auto-expire this.
      let(:proposal_created_at) { Time.now - 600 }

      before do
        community = deps.models.community.where(slug: "sample").first
        id = deps.models.backfill_proposal.insert(
          community_id: community.id, endpoint_id: "dc-general", status: "pending",
          fetched: 12, gaps: 4, ours: 0, claimed: 1, below_floor: 0,
          swept_since: proposal_created_at - 3600, expires_at: proposal_created_at + 86_400,
          created_at: proposal_created_at, updated_at: proposal_created_at
        )
        deps.models.backfill_proposal_item.insert(
          proposal_id: id, native_id: "m1", author_label: "Alex@discord", preview: "hello there",
          sent_at: proposal_created_at - 300, created_at: Time.now
        )
      end

      def cases
        community = deps.models.community.where(slug: "sample").first
        channel = deps.models.channel.where(community_id: community.id).order(:id).first
        room = deps.models.room.where(community_id: community.id).order(:room_key).first
        endpoint = deps.script_endpoints.list(community).first
        script = deps.scripts.list(community).first
        [
          { path: "/communities/sample", data_path: "/internal/communities/sample",
            data: view_data.overview("sample"), expected_section: "overview" },
          { path: "/communities/sample/rooms", data_path: "/internal/communities/sample/rooms",
            data: view_data.rooms("sample"), expected_section: "rooms" },
          { path: "/communities/sample/rooms/channels/#{channel.id}",
            data_path: "/internal/communities/sample/rooms/channels/#{channel.id}",
            data: view_data.room_channel("sample", channel.id), expected_section: "room_channel" },
          { path: "/communities/sample/rooms/#{room.room_key}",
            data_path: "/internal/communities/sample/rooms/#{room.room_key}",
            data: view_data.room_detail("sample", room.room_key), expected_section: "room_detail" },
          { path: "/communities/sample/rooms/automatic-mapping",
            data_path: "/internal/communities/sample/rooms/automatic-mapping",
            data: view_data.automatic_mapping("sample"), expected_section: "automatic_mapping" },
          { path: "/communities/sample/audit", data_path: "/internal/communities/sample/audit",
            data: view_data.audit(slug: "sample"), expected_section: "audit" },
          { path: "/communities/sample/endpoints", data_path: "/internal/communities/sample/endpoints",
            data: view_data.endpoints("sample"), expected_section: "endpoints" },
          { path: "/communities/sample/endpoints/#{endpoint.id}",
            data_path: "/internal/communities/sample/endpoints/#{endpoint.id}",
            data: view_data.endpoint_edit("sample", id: endpoint.id), expected_section: "endpoint_edit" },
          { path: "/communities/sample/redirections", data_path: "/internal/communities/sample/redirections",
            data: view_data.redirections("sample"), expected_section: "redirections" },
          { path: "/communities/sample/webhooks", data_path: "/internal/communities/sample/webhooks",
            data: view_data.webhooks("sample"), expected_section: "webhooks" },
          { path: "/communities/sample/scripts", data_path: "/internal/communities/sample/scripts",
            data: view_data.scripts("sample"), expected_section: "scripts" },
          { path: "/communities/sample/scripts/#{script.id}",
            data_path: "/internal/communities/sample/scripts/#{script.id}",
            data: view_data.script_edit("sample", id: script.id), expected_section: "script_edit" },
          { path: "/communities/sample/features", search: "?scope=all",
            data_path: "/internal/communities/sample/features",
            data: view_data.features("sample", scope: "all"), expected_section: "features" },
          { path: "/communities/sample/features/bridge/config", search: "?scope=all",
            data_path: "/internal/communities/sample/features/bridge/config",
            data: view_data.feature_config("sample", "bridge", scope: "all"), expected_section: "feature_config" },
          { path: "/communities/sample/features/content_policy/config", search: "?scope=all",
            data_path: "/internal/communities/sample/features/content_policy/config",
            data: view_data.feature_config("sample", "content_policy", scope: "all"),
            expected_section: "feature_config" },
          { path: "/onboarding", data_path: "/internal/onboarding",
            data: view_data.onboarding, expected_section: "onboarding" },
          { path: "/operator-tokens", data_path: "/internal/operator-tokens",
            data: view_data.operator_tokens, expected_section: "operator_tokens" },
          { path: "/administrators", data_path: "/internal/administrators",
            data: view_data.administrators, expected_section: "administrators" },
          { path: "/integrations", data_path: "/internal/integrations",
            data: view_data.integrations, expected_section: "integrations" },
          { path: "/communities/sample/participation", data_path: "/internal/communities/sample/participation",
            data: view_data.participation("sample"), expected_section: "participation" },
          { path: "/communities/sample/alerts", data_path: "/internal/communities/sample/alerts",
            data: view_data.alerts("sample"), expected_section: "alerts" },
          { path: "/communities/sample/files", data_path: "/internal/communities/sample/files",
            data: view_data.files("sample"), expected_section: "files" },
          { path: "/backfill-proposals", data_path: "/internal/backfill-proposals",
            data: view_data.backfill_proposals, expected_section: "backfill_proposals" },
          { path: "/audit", data_path: "/internal/audit",
            data: view_data.audit, expected_section: "audit" },
          { path: "/documentation", data_path: "/internal/documentation",
            data: view_data.documentation, expected_section: "documentation" },
          { path: "/licence", data_path: "/internal/licence",
            data: view_data.licence, expected_section: "licence" },
          { path: "/", data_path: "/internal/communities",
            data: view_data.communities, expected_section: "communities" },
          { path: "/analytics", data_path: "/internal/analytics",
            data: view_data.analytics_overview, expected_section: "analytics_overview" },
          { path: "/accounts", data_path: "/internal/accounts",
            data: view_data.accounts(token_env_set: { "TELEGRAM_BOT_TOKEN_2" => false }),
            expected_section: "accounts" },
          { path: "/api-keys", data_path: "/internal/api-keys",
            data: view_data.api_keys(issued_token: "rbk_seeded_once", issued_label: "for Bea"),
            expected_section: "api_keys" },
          { path: "/viewers", data_path: "/internal/viewers",
            data: view_data.viewers, expected_section: "viewers" },
          { path: "/communities/sample/people", data_path: "/internal/communities/sample/people",
            data: view_data.people("sample"), expected_section: "people" },
          { path: "/communities/sample/moderation", search: "?q=rando",
            data_path: "/internal/communities/sample/moderation",
            data: view_data.moderation("sample", query: "rando"), expected_section: "moderation" },
          { path: "/communities/sample/events", data_path: "/internal/communities/sample/events",
            data: view_data.events("sample"), expected_section: "events" },
          { path: "/communities/sample/word-filter", data_path: "/internal/communities/sample/word-filter",
            data: view_data.word_filter("sample"), expected_section: "word_filter" },
          { path: "/communities/sample/faq", data_path: "/internal/communities/sample/faq",
            data: view_data.faq("sample"), expected_section: "faq" },
          { path: "/communities/sample/platforms", data_path: "/internal/communities/sample/platforms",
            data: view_data.platforms("sample", token_env_set: { "TELEGRAM_BOT_TOKEN" => true }),
            expected_section: "platforms" },
          { path: "/communities/sample/operators", data_path: "/internal/communities/sample/operators",
            data: view_data.operators("sample", issued_token: "rba_seeded_once"),
            expected_section: "operators" },
          { path: "/communities/sample/analytics", search: "?window=7d&channel_view=room",
            data_path: "/internal/communities/sample/analytics",
            data: view_data.analytics("sample", window: "7d", channel_view: "room"),
            expected_section: "analytics" },
          { path: "/communities/sample/polls", data_path: "/internal/communities/sample/polls",
            data: view_data.polls("sample"), expected_section: "polls" },
          { path: "/communities/sample/guests", data_path: "/internal/communities/sample/guests",
            data: view_data.guests("sample", issued_link: "https://panel.invalid/guest/seeded-once",
                                            issued_nickname: "Visiting Reviewer"),
            expected_section: "guests" },
          { path: "/settings/datastore", data_path: "/internal/settings/datastore",
            data: view_data.datastore, expected_section: "datastore" }
        ]
      end

      def cases_file
        @cases_file ||= begin
          path = File.join(@build[:dir], "cases.json")
          payload = cases.map { |c| { path: c[:path], search: c[:search], dataPath: c[:data_path], data: c[:data] } }
          File.write(path, JSON.generate(payload))
          path
        end
      end

      def rendered
        @rendered ||= JSON.parse(
          run!(ThemedRenderedVocabularySupport::NODE_BIN, File.join(ThemedRenderedVocabularySupport::SUPPORT_DIR, "theme_render_harness.js"),
               @build[:runtime], cases_file)
        )
      end

      ThemedRenderedVocabularySupport::TABLE_SECTIONS = %w[
        endpoints scripts redirections webhooks features participation alerts files operator_tokens audit
        communities analytics_overview accounts api_keys
      ].freeze

      # Every section app.rb marks themed, read out of app.rb rather than
      # listed again here. The count below is a floor a newly themed section
      # slips straight past; this is the one that fails until a case exists for
      # it, which is what the screens no theme could draw needed and did not
      # have.
      def themed_sections
        source = File.read(File.join(ThemedRenderedVocabularySupport::ROOT, "lib/rubotty/dashboard/app.rb"), encoding: "UTF-8")
        source.scan(/@themed_section\s*=\s*"([a-z_]+)"/).flatten.uniq.sort
      end

      it "drives a real render for every ported screen, so nothing here passes vacuously" do
        expect(rendered.length).to eq(42)
        expect(rendered.flat_map { |r| classes_in(r["html"]) }.uniq.length).to be > 10
      end

      it "covers every section the server hands the runtime, so no themed screen goes unrendered here" do
        expect(cases.map { |c| c[:expected_section] }.uniq.sort).to eq(themed_sections)
      end

      it "draws every screen without falling through to a page load" do
        expect(rendered.map { |screen| screen["section"] }).to eq(cases.map { |entry| entry[:expected_section] })
        expect(rendered.map { |screen| screen["html"] }).to all(include("class="))
      end

      it "uses the wide Page variant for every primary table screen" do
        table_screens = rendered.select { |screen| ThemedRenderedVocabularySupport::TABLE_SECTIONS.include?(screen["section"]) }
        expected = cases.select { |entry| ThemedRenderedVocabularySupport::TABLE_SECTIONS.include?(entry[:expected_section]) }
                        .map { |entry| entry[:expected_section] }
        expect(table_screens.map { |screen| screen["section"] }).to match_array(expected)
        expect(table_screens.map { |screen| screen["html"] }).to all(include("rb-page--wide"))
      end

      it "routes each case to the section the internal surface itself names, proving the ROUTES table matches" do
        cases.each_with_index do |c, index|
          expect(rendered[index]["section"]).to eq(c[:expected_section]),
                                                "#{c[:path]} drew section #{rendered[index]['section'].inspect}, expected #{c[:expected_section].inspect}"
        end
      end

      it "emits nothing outside the primitive class vocabulary, unlike the ERB layer it draws over" do
        bespoke = rendered.flat_map { |r| classes_in(r["html"]) }.uniq -
                  Rubotty::Dashboard::Primitives::CLASSES - ThemedRenderedVocabularySupport::THEMED_DOCUMENT_CLASSES

        expect(bespoke).to be_empty, "class(es) outside Primitives::CLASSES: #{bespoke.join(', ')}"
      end

      it "keeps page layout styling in stylesheets, outside chart SVG drawings" do
        over = rendered.select { |r| inline_styles(r["html"]).positive? }

        expect(over).to be_empty, lambda {
          over.map { |r| "#{r['path']}: #{inline_styles(r['html'])} inline style(s)" }.join("\n")
        }
      end

      it "spends a grant on every button it draws" do
        offenders = rendered.flat_map { |r| ungated_buttons(r["html"]) }

        expect(offenders).to be_empty, "ungated button(s): #{offenders.join("\n")}"
      end

      # may and data-grant are the same string here (see button() in
      # primitives.civet), not two hand-maintained vocabularies, so this
      # can never observe drift between them. Checked over whatever grants
      # the render actually produced, so a third screen's new grant is covered.
      it "never draws a data-grant absent from the may map it was rendered from" do
        offenders = cases.each_with_index.flat_map do |c, index|
          html = rendered[index]["html"]
          grants = html.scan(/data-grant="([^"]*)"/).flatten.uniq
          may_keys = (c[:data]["may"] || {}).keys
          (grants - may_keys).map { |grant| "#{c[:path]}: data-grant=#{grant.inspect} not in #{may_keys.inspect}" }
        end

        expect(offenders).to be_empty, offenders.join("\n")
      end

      # TabLinks takes the current key positionally, so a call writing it as
      # current: hands over an object and marks nothing. Held on the markup
      # rather than on the call, since the call is where it looked correct.
      it "marks the showing tab on a filter, so the window in hand reads as chosen" do
        html = rendered.find { |r| r["section"] == "analytics_overview" }.fetch("html")
        marked = html.scan(%r{<a class="rb-tab rb-tab--current"[^>]*>([^<]*)</a>}).flatten

        expect(marked).to eq([Rubotty::ControlPlane::Analytics::DEFAULT_WINDOW])
        expect(html).to include('aria-current="page"')
      end

      it "formats the endpoint timeout through Format.duration rather than shipping the raw second count" do
        endpoints_html = rendered.find { |r| r["section"] == "endpoints" }.fetch("html")

        expect(endpoints_html).to include(">5s<")
        expect(endpoints_html).not_to match(%r{<td[^>]*>5</td>})
      end

      it "carries a data-confirm on the live destructive Delete button" do
        endpoints_html = rendered.find { |r| r["section"] == "endpoints" }.fetch("html")

        expect(endpoints_html).to match(/rb-button--destructive[^>]*data-confirm="[^"]+"/)
      end

      # A task flow is only one if every named step sits inside the one form,
      # so a single submit saves all of them. Sections reaching the page
      # beside the form rather than within it still draw and still read
      # correctly, and save nothing but the fields that stayed inside.
      it "puts the endpoint editor's named steps inside the one task form" do
        html = rendered.find { |r| r["section"] == "endpoint_edit" }.fetch("html")
        form = html[%r{<form[^>]*class="rb-form[^"]*".*?</form>}m]

        expect(form).to include("rb-form-body")

        expect(form).not_to be_nil
        expect(form).to include("rb-form-actions")
        %w[Name\ and\ method Target Optional\ request\ details Availability].each do |step|
          expect(form).to include(">#{step}<")
        end
        expect(form).to match(/<input[^>]+name="url"/)
      end

      # Collapsed rather than absent: the detail is reachable without being the
      # first thing an ordinary save has to read past.
      it "collapses the endpoint editor's optional detail and leaves the rest open" do
        html = rendered.find { |r| r["section"] == "endpoint_edit" }.fetch("html")

        expect(html).to match(%r{<details class="rb-section rb-section--collapsible"(?! open)})
        expect(html[%r{<details.*?</details>}m]).to include("Optional request details")
      end

      def page_title(html) = html[%r{<h1 class="rb-page-title">(.*?)</h1>}, 1]

      # Every screen said its own name three times: the breadcrumb, then an h1
      # re-prefixing the community the breadcrumb and the whole sidebar already
      # establish, then the section title. The prefix is the copy of the three
      # that carried no information at all.
      it "titles a page with the page's own name, never the community's as well" do
        offenders = rendered.filter_map do |screen|
          title = page_title(screen["html"])
          next nil unless title&.include?("SAMPLE: ")

          "#{screen['section']}: #{title.inspect}"
        end

        expect(offenders).to be_empty, "page title(s) still prefixed with the community:\n#{offenders.join("\n")}"
      end

      # Overview is the one page whose title IS the community, and its lede was
      # a field name stapled to its value.
      it "gives Overview the community's name and a lede of facts rather than a labelled slug" do
        overview_html = rendered.find { |r| r["section"] == "overview" }.fetch("html")

        expect(page_title(overview_html)).to eq("SAMPLE")
        expect(overview_html).to match(%r{<p class="rb-page-lede">sample, created })
        expect(overview_html).not_to include("Slug sample")
      end

      # The same idea was drawn four ways. Features already reached for the
      # Status pill; Endpoints printed Yes and No, Alerts printed Quiet and
      # Loud, and Overview set a word at the size a count is set at.
      it "draws an endpoint's enabled state as a Status pill rather than the bare word" do
        endpoints_html = rendered.find { |r| r["section"] == "endpoints" }.fetch("html")

        expect(endpoints_html).to match(%r{<td[^>]*><span class="rb-status rb-status--good">.*?Yes</span></td>})
        expect(endpoints_html).not_to match(%r{<td[^>]*>Yes</td>})
      end

      it "draws how an alert went out as a Status pill, toned by whether it reached anyone" do
        alerts_html = rendered.find { |r| r["section"] == "alerts" }.fetch("html")

        expect(alerts_html).to match(%r{<td[^>]*><span class="rb-status rb-status--good">.*?Loud, DMed 1</span></td>})
        expect(alerts_html).not_to match(%r{<td[^>]*>Loud, DMed 1</td>})
      end

      # A stat tile draws its value at the scale a number wants, so a word in
      # one reads as a number. The state belongs beside the control that
      # changes it, drawn as the pill every other state on every other screen
      # is drawn as.
      it "keeps the community's own state out of the stat row and draws it as a Status pill" do
        overview_html = rendered.find { |r| r["section"] == "overview" }.fetch("html")

        expect(overview_html).to include(%(<span class="rb-status rb-status--good">))
        expect(overview_html).to match(/rb-status--good">.*?Active</)
        expect(overview_html).not_to match(%r{<div class="rb-stat-value">Active</div>})
        expect(overview_html).not_to include(%(<div class="rb-stat-label">status</div>))
      end

      it "keeps the stat tiles' smaller detail line under their value and label" do
        overview_html = rendered.find { |r| r["section"] == "overview" }.fetch("html")

        expect(overview_html.scan('class="rb-stat-detail"').length).to eq(7)
        expect(overview_html).to match(
          %r{<div class="rb-stat-value">\d+</div><div class="rb-stat-label">platform connections</div><div class="rb-stat-detail">for this community</div>}
        )
      end

      # The mockup draws Features as a card of expandable rows rather than a
      # flat table of checklist glyphs; each row is its own collapsible
      # Section, its own name in the summary rather than the raw key some
      # other rendering used to draw in monospace. The nine categories add a
      # second kind of collapsible over them (chevron "start" rather than a
      # row's own "end"), so this still finds both.
      def feature_rows_in(html)
        html.split(%r{(?=<details class="rb-section rb-section--collapsible")})
      end

      it "names a feature by its display name rather than its raw key" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")

        expect(features_html).to include("<strong>Anti-Raid Lockdown</strong>")
        expect(features_html).not_to include(%(<code class="rb-code rb-code--inline">anti_raid</code>))
      end

      # Every category and its members, mirroring features_matrix_spec.rb's
      # own list so the plain and themed surfaces are checked against the
      # identical shape, each already written in alphabetical order.
      ThemedRenderedVocabularySupport::CATEGORY_MEMBERS = {
        "Bridging and Delivery" => ["Channel Management", "File Rehosting", "File Uploads", "Message Backfill",
                                     "Message Bridge", "Message Redirection"],
        "Community Tools" => ["Events & Scheduling", "FAQ Responses", "Keyword Watches", "Polls",
                               "Scheduled Announcements"],
        "Identity and Access" => ["Guest Portal", "Identity History", "Nicknames", "Operator Requests",
                                   "Operator Startup DM", "Restricted Room Access", "Room Topic Identification",
                                   "Telegram Avatar Sync"],
        "Semantic Message Redirection" => ["Topic Auto-Correction", "Topic Detection"],
        "Semantic Analysis" => ["Content Policy Filter", "Semantic FAQ Matching"],
        "Room Summaries" => ["Room Summaries"],
        "Moderation and Safety" => ["Anti-Raid Lockdown", "Anti-Spam Detection", "Link Filter",
                                     "Mass Mention Protection", "Member Reports", "Moderation Commands",
                                     "Multi-Post Prevention", "Warnings", "Word Blacklist"],
        "Platform and System" => ["Command Prefixes", "Disabled Command Notice", "Greetings",
                                   "Guided Command Builder", "Lua Scripting", "Startup Banner",
                                   "Utility Commands"],
        "Translation" => ["Foreign Link Translation", "LibreTranslate Message Translation"]
      }.freeze

      it "leaves nothing in the flat list below the nine categories" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
        listed = features_html.scan(%r{<span data-feature-heading><strong>([^<]+)</strong>})
                              .flatten.map { |label| CGI.unescape_html(label) }

        expect(listed.size).to eq(ThemedRenderedVocabularySupport::CATEGORY_MEMBERS.values.flatten.size)
      end

      describe "category grouping" do
        # A category's own collapsible carries the default chevron
        # (data-chevron="start"), which a single feature row never does; the
        # page's own "About scopes and defaults" disclosure carries it too,
        # so only a block whose title is a real category counts.
        ThemedRenderedVocabularySupport::CATEGORY_OPEN = '<details class="rb-section rb-section--collapsible" data-chevron="start">'

        def category_blocks(html)
          html.split(/(?=#{Regexp.escape(ThemedRenderedVocabularySupport::CATEGORY_OPEN)})/)
              .select { |chunk| chunk.start_with?(ThemedRenderedVocabularySupport::CATEGORY_OPEN) && ThemedRenderedVocabularySupport::CATEGORY_MEMBERS.key?(chunk[/rb-section-title">([^<]+)<\/summary>/, 1]) }
        end

        def category_block(html, title)
          category_blocks(html).find { |chunk| chunk.include?(%(rb-section-title">#{title}</summary>)) }
        end

        it "draws all nine categories, alphabetised top to bottom" do
          features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
          titles = category_blocks(features_html).map { |block| block[/rb-section-title">([^<]+)<\/summary>/, 1] }

          expect(titles).to eq(ThemedRenderedVocabularySupport::CATEGORY_MEMBERS.keys)
        end

        it "puts every feature into its own category, alphabetised inside it" do
          features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")

          ThemedRenderedVocabularySupport::CATEGORY_MEMBERS.each do |title, members|
            block = category_block(features_html, title)
            names = block.scan(%r{<span data-feature-heading><strong>([^<]+)</strong>})
                         .flatten.map { |label| CGI.unescape_html(label) }

            expect(names).to eq(members)
          end
        end
      end

      it "puts the Config link in the row summary for a feature with its own bespoke page" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
        row = feature_rows_in(features_html).find { |chunk| chunk.include?("<strong>Word Blacklist</strong>") }
        summary, body = row.split("</summary>", 2)

        expect(summary).to match(%r{<a href="[^"]*/communities/sample/word-filter"[^>]*>Config</a>})
        expect(body).not_to include(">Config<")
      end

      # The same rule for a feature using the generic per-feature form: only
      # where the link goes differs, never whether the row shows one. File
      # Rehosting is the row that was reported, twice, as looking like it had
      # no configuration at all until somebody expanded it.
      it "puts the Config link in the row summary for a feature on the generic config form too" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")

        ["Message Redirection", "File Rehosting"].each do |label|
          row = feature_rows_in(features_html).find { |chunk| chunk.include?("<strong>#{label}</strong>") }
          summary, body = row.split("</summary>", 2)

          expect(summary).to match(%r{<a href="[^"]*/features/[^"]*/config\?scope=all"[^>]*>Config</a>})
          expect(body).not_to include(">Config<")
        end
      end

      # Every row that can be configured, with no exceptions left to drift
      # back: the two earlier repairs each fixed a subset and the complaint
      # came back both times.
      it "leaves no configurable feature's Config link behind its own disclosure" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
        rows = feature_rows_in(features_html).select { |chunk| chunk.include?("data-feature-heading") }
        bodies_with_links = rows.count { |row| row.split("</summary>", 2).last.include?(">Config<") }

        expect(rows.length).to be >= 20
        expect(bodies_with_links).to eq(0)
      end

      it "renders file_rehosting as two independent rows instead of one" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
        rows = feature_rows_in(features_html)
        rehosting_row = rows.find { |row| row.include?("<strong>File Rehosting</strong>") }
        uploads_row = rows.find { |row| row.include?("<strong>File Uploads</strong>") }

        expect(rehosting_row).not_to be_nil
        expect(uploads_row).not_to be_nil
        expect(rehosting_row).not_to eq(uploads_row)
      end

      it "draws each feature as a toggle switch beside its title, on or off marked in the row" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
        rows = feature_rows_in(features_html)
        bridge_row = rows.find { |row| row.include?("<strong>Message Bridge</strong>") }
        backfill_row = rows.find { |row| row.include?("<strong>Message Backfill</strong>") }

        expect(features_html).not_to include("<th>State</th>")
        expect(bridge_row).to include('data-feature-toggle="on"')
        expect(backfill_row).to include('data-feature-toggle="off"')
      end

      it "shows a still-posting move's state as reposting, and offers to stop it" do
        redirections_html = rendered.find { |r| r["section"] == "redirections" }.fetch("html")

        expect(redirections_html).to include(">reposting<")
        expect(redirections_html).to match(/rb-button--primary[^>]*data-grant="manage_redirection"/)
      end

      # The real compiled client emitter, not the Ruby mirror of it: a
      # timestamp column carries its format for a stylesheet to target, and a
      # plain column carries its label with no format attribute at all.
      it "carries a redirection's column label and format on the client-rendered cell" do
        redirections_html = rendered.find { |r| r["section"] == "redirections" }.fetch("html")

        expect(redirections_html).to match(/<td data-l="When" data-format="timestamp"[^>]*>/)
        expect(redirections_html).to match(/<td data-l="By">[^<]/)
      end

      it "carries the real retention day count in the webhooks explainer, not a stale copy" do
        webhooks_html = rendered.find { |r| r["section"] == "webhooks" }.fetch("html")

        expect(webhooks_html).to include("kept for 14 days")
      end

      it "shows a dead-lettered delivery as given up on, with a live Send again button" do
        webhooks_html = rendered.find { |r| r["section"] == "webhooks" }.fetch("html")

        expect(webhooks_html).to include("given up")
        expect(webhooks_html).to match(/rb-button--secondary[^>]*data-grant="manage_webhooks"/)
      end

      it "renders the script's kind and trigger through Format rather than the raw stored token" do
        scripts_html = rendered.find { |r| r["section"] == "scripts" }.fetch("html")

        expect(scripts_html).to include(">Processor<")
        expect(scripts_html).to include('<code class="rb-code rb-code--inline">always</code>')
        expect(scripts_html).not_to match(%r{<td[^>]*>processor</td>})
      end

      # The numbers a script recorded for itself used to be drawn on the
      # analytics page. They belong with the scripts, and a themed deployment
      # draws this screen from the payload rather than from the ERB body, so
      # the section has to exist on both sides or it exists on neither.
      it "draws the numbers the scripts recorded for themselves" do
        scripts_html = rendered.find { |r| r["section"] == "scripts" }.fetch("html")

        expect(scripts_html).to include("What your scripts recorded")
        expect(scripts_html).to include(">commands<").and include(">roll<")
      end

      it "carries a data-confirm on the scripts screen's live destructive Delete button too" do
        scripts_html = rendered.find { |r| r["section"] == "scripts" }.fetch("html")

        expect(scripts_html).to match(/rb-button--destructive[^>]*data-confirm="[^"]+"/)
      end

      # What a script has been up to used to be missing from the themed page
      # entirely: the payload carried the form fields and nothing else, so a
      # themed reader could not see the failure counter, the run count or the
      # alerts an ERB reader already could.
      it "draws one script's own activity and alerts on its detail page" do
        script_edit_html = rendered.find { |r| r["section"] == "script_edit" }.fetch("html")

        expect(script_edit_html).to include(">runs<").and include("consecutive failures")
        expect(script_edit_html).to include("attempt to index a nil value")
        expect(script_edit_html).to include("greeter said hello")
        expect(script_edit_html).to include("What greeter raised with rubotty.alert")
      end

      # The ERB page's config_summary drew a feature's current settings
      # three different ways depending on the data shape it held. Bridge
      # has a real, non-default config here, so this proves the one
      # KeyValues rendering actually draws instead of any of the three old shapes.
      it "draws a feature's current settings through KeyValues, not the bare Defaults label" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")

        expect(features_html).to include("rb-kv--stacked")
        expect(features_html).to include("Cross platform mentions")
        expect(features_html).not_to include("Defaults")
      end

      it "carries no config summary at all for a feature still at its untouched default" do
        features_html = rendered.find { |r| r["section"] == "features" }.fetch("html")
        word_filter_row = feature_rows_in(features_html).find { |row| row.include?("<strong>Word Blacklist</strong>") }

        expect(word_filter_row).not_to be_nil
        expect(word_filter_row).not_to include("rb-kv")
      end

      # The checkbox pile-up: the ERB config form drew a boolean field as
      # its own hidden+checkbox pair, several in a row on a feature like
      # bridge. The Field primitive's :toggle type has no checkbox at all
      # (a select offering Yes/No instead), proving the fix, not a reproduction.
      it "draws every boolean config field as a toggle select, never a checkbox" do
        config_html = rendered.find { |r| r["section"] == "feature_config" }.fetch("html")

        expect(config_html).to include("rb-field--short")
        expect(config_html).not_to match(/type="checkbox"/)
      end

      it "draws mapping-list entries as labelled controls, not JSON textareas" do
        config_html = rendered.find { |r| r["section"] == "feature_config" }.fetch("html")

        expect(config_html).to include("data-mapping-list")
        expect(config_html).to include('name="timestamp_timezones[0][label]"')
        expect(config_html).to include('name="timestamp_timezones[0][iana_timezone]"')
        expect(config_html).not_to include('textarea name="timestamp_timezones"')
      end

      # content_policy's own feature_config case sits right after bridge's in
      # cases (both section "feature_config"), so this reaches it by index
      # rather than the ambiguous rendered.find every other test here uses.
      it "draws content policy's long description sub-field as a wrapping textarea, not a one-line input" do
        index = cases.index { |c| c[:path].include?("content_policy") }
        config_html = rendered[index].fetch("html")

        expect(config_html).to match(%r{<textarea[^>]*name="entries\[0\]\[description\]"})
        expect(config_html).to match(%r{<input[^>]*name="entries\[0\]\[name\]"})
      end

      # entry_presets travels from ContentPolicy::Service through view_data.rb
      # to primitives.civet, which draws it as a select beside one Add preset
      # button rather than a button per preset: a button's own label is a
      # verb from the shared lexicon, never a raw value.
      it "offers every one of content policy's named presets in a select beside one Add preset button" do
        index = cases.index { |c| c[:path].include?("content_policy") }
        config_html = rendered[index].fetch("html")

        expect(config_html).to include("data-mapping-list-preset-select")
        expect(config_html).to match(/data-mapping-list-preset-add[^>]*>Add preset</)
        expect(config_html.scan("data-preset-name=").length)
          .to eq(Rubotty::ContentPolicy::Service::PRESETS.length)
        Rubotty::ContentPolicy::Service::PRESETS.each do |preset|
          expect(config_html).to include(">#{CGI.escapeHTML(preset.fetch("name"))}</option>")
        end
      end

      # The hint is the only account this page gives of what a setting does,
      # so the Field primitive's own 140 character cut is asked off here.
      # Nothing carries the cut's markers, a title holding the rest and a
      # tabindex to reach it, because nothing is held back.
      it "asks the cut off for every field hint on the config page" do
        config_html = rendered.find { |r| r["section"] == "feature_config" }.fetch("html")

        expect(config_html).to include(%(<p class="rb-field-hint">))
        expect(config_html).not_to include(%(<p class="rb-field-hint" title=))
      end

      # What the cut used to eat: the example naming the format this field
      # wants sat past the limit, so the sentence stopped in the middle and
      # hover was the only way to the rest of it, which a phone does not
      # have.
      it "draws a long hint whole, example and all, rather than on hover" do
        config_html = rendered.find { |r| r["section"] == "feature_config" }.fetch("html")
        hints = config_html.scan(%r{<p class="rb-field-hint"[^>]*>(.*?)</p>}).flatten
                           .map { |hint| CGI.unescape_html(hint) }

        expect(hints).to include(a_string_including("iana_timezone: \"America/Los_Angeles\""))
        expect(hints.count { |hint| hint.length > 140 }).to be >= 5
      end

      # Above the control, a two-line hint and a three-line hint start their
      # controls at different heights, so no two fields in a row line up. Every
      # control on this screen is preceded by its label and nothing else, which
      # is what makes a row of them level.
      it "draws every hint under the control it explains, never above it" do
        config_html = rendered.find { |r| r["section"] == "feature_config" }.fetch("html")
        fields = config_html.split(/(?=<div class="rb-field rb-field--)/)
                            .select { |part| part.start_with?(%(<div class="rb-field )) }

        expect(fields.length).to be >= 6
        fields.each do |markup|
          next unless markup.include?("rb-field-hint")

          expect(markup.index("rb-field-control")).to be < markup.index("rb-field-hint")
          expect(markup.index("rb-field-label")).to be < markup.index("rb-field-control")
        end
      end

      # ViewData#participation_row resolves opened_at to relative text
      # already, and closes_at to ISO 8601 text js-yaml decodes into a Date
      # before Format.timestamp ever sees it, the same client-side path
      # Format.duration takes for endpoints above.
      it "reads the round's opened time as relative text and its close time through Format.timestamp" do
        participation_html = rendered.find { |r| r["section"] == "participation" }.fetch("html")

        expect(participation_html).to match(%r{<td[^>]*>(just now|\d+ \w+s? ago)</td>})
        expect(participation_html).to match(/<td[^>]*>\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC<\/td>/)
        expect(participation_html).not_to match(/<td[^>]*>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z<\/td>/)
      end

      it "carries a data-confirm on the live destructive Close session button" do
        participation_html = rendered.find { |r| r["section"] == "participation" }.fetch("html")

        expect(participation_html).to match(/rb-button--destructive[^>]*data-confirm="[^"]+"/)
      end

      # How is folded into text by ViewData#alerts, its tone traveling
      # beside it as how_tone rather than parsed back out of the client's
      # words: "Loud, DMed 2" and "Loud, reached nobody" share a column
      # but mean opposite things. This proves the server's wording reaches the page.
      it "reads a loud alert's delivery count as the server's own wording" do
        alerts_html = rendered.find { |r| r["section"] == "alerts" }.fetch("html")

        expect(alerts_html).to include(">Loud, DMed 1<")
        expect(alerts_html).not_to include("delivered_to")
      end

      it "carries a data-confirm on the files section's live destructive Delete button too" do
        files_html = rendered.find { |r| r["section"] == "files" }.fetch("html")

        expect(files_html).to match(/rb-button--destructive[^>]*data-confirm="[^"]+"/)
      end

      it "formats a rehosted file's size through Format.bytes rather than shipping the raw byte count" do
        files_html = rendered.find { |r| r["section"] == "files" }.fetch("html")

        expect(files_html).to include(">5 B<")
      end

      it "reads a backfill proposal's proposed time as relative text and its expiry through Format.timestamp" do
        html = rendered.find { |r| r["section"] == "backfill_proposals" }.fetch("html")

        expect(html).to match(/Proposed (just now|\d+ \w+s? ago)/)
        expect(html).to include((proposal_created_at + 86_400).utc.strftime("%Y-%m-%d %H:%M UTC"))
        expect(html).not_to include(proposal_created_at.utc.iso8601)
      end

      it "warns loudly on the client when a proposal's own ours count is zero" do
        html = rendered.find { |r| r["section"] == "backfill_proposals" }.fetch("html")

        expect(html).to include("Ours is zero")
      end

      it "keeps proposal groups and headings unboxed, with one messages disclosure" do
        html = rendered.find { |r| r["section"] == "backfill_proposals" }.fetch("html")

        expect(html.scan(/<section class="rb-section rb-section--default"/)).to be_empty
        expect(html.scan(/<section class="rb-section rb-section--plain"/).length).to eq(3)
        expect(html.scan(/<details class="rb-section rb-section--collapsible"/).length).to eq(1)
      end

      # The same split the ERB screens are held to in contextual_help_spec.rb:
      # consequence beside the control, background folded shut behind one
      # summary a reader opens once.
      it "folds background into one shut Help disclosure per screen, keeping the consequence outside it" do
        {
          "scripts" => ["About scripts", "runs on real messages"],
          "features" => ["About scopes and defaults", "community-wide default every room inherits"],
          "endpoint_edit" => ["How a script calls this", "{braces}"]
        }.each do |section, (title, kept)|
          html = rendered.find { |r| r["section"] == section }.fetch("html")
          folded = html.scan(%r{<details class="rb-section rb-section--collapsible"[^>]*>.*?</details>}m)
          help = folded.find { |one| one.include?(">#{title}</summary>") }
          outside = folded.reduce(html) { |left, one| left.sub(one, "") }

          expect(help).not_to be_nil, "#{section} drew no #{title.inspect} disclosure"
          expect(help).not_to match(/<details[^>]*\bopen\b/), "#{section} opened its Help by default"
          expect(outside).to include(kept), "#{section} folded away what a reader needs beside the control"
        end
      end

      it "links the reference from the Help disclosure it folded the reference prose into" do
        { "scripts" => "About scripts", "endpoint_edit" => "How a script calls this" }.each do |section, title|
          html = rendered.find { |r| r["section"] == section }.fetch("html")
          help = html.scan(%r{<details class="rb-section rb-section--collapsible"[^>]*>.*?</details>}m)
                     .find { |one| one.include?(">#{title}</summary>") }

          expect(help).to match(%r{<a href="[^"]*/documentation"[^>]*class="rb-button}),
                          "#{section} folded the reference prose away without linking the reference"
        end
      end

      # The same hierarchy the ERB editors are held to in
      # form_action_hierarchy_spec.rb, on the two editors a theme draws itself.
      it "ends a themed editor on one action footer: validation, then back, then the submit" do
        %w[endpoint_edit feature_config].each do |section|
          html = rendered.find { |r| r["section"] == section }.fetch("html")
          footer = html[%r{<div class="rb-form-actions">.*?</form>}m].to_s

          expect(footer).to include("rb-notice--info"), "#{section} drew no validation beside its submit"
          expect(footer.index("rb-notice")).to be < footer.index("rb-button--secondary"),
                                                "#{section} drew its validation after the subordinate control"
          expect(footer.index("rb-button--secondary")).to be < footer.index("rb-form-submit"),
                                                          "#{section} drew a subordinate control after the submit"
          expect(footer.scan("rb-button--primary").length).to eq(1),
                                                             "#{section} drew more than one primary action"
          expect(footer).not_to include(%(data-destructive="true"))
        end
      end

      it "draws Accept and Reject as ordinary buttons, neither one destructive" do
        html = rendered.find { |r| r["section"] == "backfill_proposals" }.fetch("html")

        expect(html).to include(">Accept<")
        expect(html).to include(">Reject<")
        expect(html).not_to include("rb-button--destructive")
      end

      # The route zips platform, label and url by index, so the parallel array
      # names have to survive the port, and the blank row on the end is the
      # only way to add a link at all.
      it "keeps the join link editor's parallel array names and its trailing blank row" do
        html = rendered.find { |r| r["section"] == "platforms" }.fetch("html")

        expect(html).to include(%(name="platform[]"))
        expect(html).to include(%(name="label[]"))
        expect(html).to include(%(name="url[]"))
        expect(html).to include("https://discord.gg/abc")
        expect(html).to include(">New link<")
      end

      # Every row in every scope shares platform[]/label[]/url[], so
      # nothing here would catch a Field id collision without checking
      # the ids themselves rather than just the shared names. Cut before
      # the Fluxer section, which carries this same shape but is a separate fix.
      it "gives every join link row and connection its own id, despite the shared field names" do
        html = rendered.find { |r| r["section"] == "platforms" }.fetch("html")
        html = html[0...(html.index("Add a Fluxer instance") || html.length)]
        ids = html.scan(/\sid="([^"]+)"/).flatten

        expect(ids.length).to be > 3
        expect(ids.uniq.length).to eq(ids.length), "duplicate id(s): #{ids.tally.select { |_, n| n > 1 }.keys.join(', ')}"
      end

      # This fixture has no boot-time bridge config, so every connection lands
      # on the same branch the ERB page lands on: the settings say why they are
      # absent rather than drawing an empty form.
      it "shows each connection's key state and channels, and why behaviour settings are absent" do
        html = rendered.find { |r| r["section"] == "platforms" }.fetch("html")

        expect(html).to include(">Channels<")
        expect(html).to include("Behaviour settings need an account configured for this adapter first.")
        expect(html).to include("FLUXER_FLAGSHIP_API_KEY")
        expect(html).to include("rb-status--")
      end

      # The route reads these back as params[:setting][<name>], so the control
      # a behaviour setting draws through has to keep that name and pick the
      # Field type its schema declares.
      it "names each behaviour setting the way the route reads it back" do
        account = Struct.new(:settings, :adapter_class).new({ token_env: "TELEGRAM_BOT_TOKEN" }, nil)
        connection = deps.models.platform_connection.where(adapter: "telegram").first
        settings = view_data.send(:behavior_settings, connection, account)

        expect(settings.map { |row| row["name"] }).to include("reaction_policy", "album_window")
        expect(settings.map { |row| row["type"] }).to all(satisfy { |type| !type.to_s.empty? })
      end

      # The route behind this form decides on the key being present at all, so
      # each grant is a checkbox and never a select: a select would send a key
      # for every grant on the page and turn all of them on at once.
      it "draws each operator grant as its own checkbox, keyed by the action it spends" do
        html = rendered.find { |r| r["section"] == "operators" }.fetch("html")

        Rubotty::Dashboard::ActionPermissions::ACTIONS.each_key do |action|
          expect(html).to include(%(name="permissions[#{action}][]")), "no checkbox for #{action}"
        end
        expect(html).not_to include(%(<select class="rb-field-control" id="rb-field-permissions))
      end

      # Both roles read as the literal "1" on the route behind the mint form.
      it "draws the operators screen's five sections, with the minted token shown once" do
        html = rendered.find { |r| r["section"] == "operators" }.fetch("html")

        ["What operators may change", "Pending requests", "Viewers of this community",
         "Hand a role over with a token", "Operators"].each { |title| expect(html).to include(">#{title}<") }
        expect(html).to include("rba_seeded_once")
        expect(html).to include(%(<option value="1">Yes</option>))
      end

      # Eleven reports, each one either its figures or the reason this datastore
      # cannot answer it, and a chart drawn through the shared emitter rather
      # than left to the ERB layer's own boot script.
      it "draws every analytics report, with its charts through the shared emitter" do
        html = rendered.find { |r| r["section"] == "analytics" }.fetch("html")
        reports = view_data.analytics("sample", window: "7d", channel_view: "room").fetch("reports")

        expect(reports.length).to eq(11)
        reports.each { |report| expect(html).to include(">#{report['title']}<") }
        expect(html).to include(%(<figure class="rb-chart">))
        expect(html).to include("rb-stats")
      end

      # Switching the grouping keeps the chosen window, and switching the
      # window keeps the grouping, so neither control resets the other.
      it "keeps the window and the grouping on each other's analytics tab links" do
        html = rendered.find { |r| r["section"] == "analytics" }.fetch("html")

        expect(html).to include("analytics?window=7d&amp;channel_view=channel")
        expect(html).to include("channel_view=room")
        expect(html.scan(%(<nav class="rb-tabs">)).length).to eq(2)
      end

      # A poll's deadline goes over the wire as an ISO 8601 string and reaches
      # the page through Format.timestamp, never as a raw stored value.
      it "draws an open poll with its kind, counts and deadline, and a destructive Cancel" do
        html = rendered.find { |r| r["section"] == "polls" }.fetch("html")

        expect(html).to include("Which night suits everybody?")
        expect(html).to include(">Poll<")
        expect(html).to include(%(data-format="timestamp"))
        expect(html).to include("rb-button--destructive")
      end

      # Shown once and never stored whole, so it reaches the page through Code
      # rather than a readonly input nothing can style.
      it "draws a freshly issued guest link once, through Code, with its own warning" do
        html = rendered.find { |r| r["section"] == "guests" }.fetch("html")

        expect(html).to include("https://panel.invalid/guest/seeded-once")
        expect(html).to include(%(<pre class="rb-code rb-code--block">))
        expect(html).to include("shown once")
      end

      # Only a live invite can be revoked, so a revoked or expired row draws no
      # control at all rather than a dead one.
      it "offers Revoke on a live guest invite and marks the guest with the guest domain" do
        html = rendered.find { |r| r["section"] == "guests" }.fetch("html")

        expect(html).to include("Visiting Reviewer@guest-user")
        expect(html).to include(">Revoke<")
        expect(html).to include("rb-status--good")
      end

      # The route this form posts to falls back to the off mode for a save it
      # was not sent one on, so saving a word list alone has to carry the mode
      # already stored or it quietly turns the filter off.
      it "carries the stored mode and action through the word list's own save" do
        html = rendered.find { |r| r["section"] == "word_filter" }.fetch("html")

        expect(html).to include(%(<input type="hidden" name="op" value="save">))
        expect(html).to match(/name="op" value="save"><input type="hidden" name="selector"[^>]*><input type="hidden" name="mode"/)
        expect(html).to include(%(name="action"))
      end

      # A room with no row of its own is still listed, reading the state it
      # actually inherits, and only a room is offered the third state.
      it "lists every word filter scope, offering follows-all to rooms and not to the default" do
        html = rendered.find { |r| r["section"] == "word_filter" }.fetch("html")
        scopes = view_data.word_filter("sample").fetch("scopes")

        expect(scopes.length).to be > 1
        expect(html.scan(%(<option value="inherit">)).length).to eq(scopes.count { |s| !s["community"] })
        expect(html).to include(">all<")
      end

      it "counts each FAQ scope's entries and offers a scope to add one at" do
        html = rendered.find { |r| r["section"] == "faq" }.fetch("html")

        expect(html).to include(%(<input type="hidden" name="op" value="add">))
        expect(html).to include(%(name="trigger_type"))
        expect(html).to include(">Entries<")
      end

      # An upload posted without this encoding arrives as a bare filename
      # string, which restores nothing and reports no error worth reading.
      it "encodes the datastore restore form for an upload and draws the export as a link" do
        html = rendered.find { |r| r["section"] == "datastore" }.fetch("html")

        expect(html).to include(%(enctype="multipart/form-data"))
        expect(html).to include(%(type="file"))
        expect(html).to include(%(href="/settings/datastore/export"))
      end

      # A whole rendered document reaching the page through the client Prose
      # emitter: the render itself is the proof the scan let the real bytes
      # through, since an element or attribute it refuses throws instead.
      it "draws the scripting reference as one Prose block, headings and tables and all" do
        html = rendered.find { |r| r["section"] == "documentation" }.fetch("html")

        expect(html).to include(%(<div class="rb-prose">))
        expect(html).to include("Scripting reference")
        expect(html).to include("<table>")
        expect(html).to include("language-lua")
      end

      it "draws each document once, on its own screen, rather than one of them twice" do
        licence_html = rendered.find { |r| r["section"] == "licence" }.fetch("html")

        expect(licence_html).to include("PolyForm Strict License 1.0.0")
        expect(licence_html).not_to include("Scripting reference")
      end

      # The README moved here from the index, as a second document under the
      # scripting reference rather than replacing it.
      it "draws the README on Documentation too, one Prose block per document" do
        html = rendered.find { |r| r["section"] == "documentation" }.fetch("html")

        expect(html.scan(%(<div class="rb-prose">)).length).to eq(2)
        expect(html).to include("Scripting reference")
      end

      it "draws an absent-guide notice while keeping the README when the guide is not shipped" do
        with_dashboard_guide_fixture(present: false) do
          html = rendered.find { |r| r["section"] == "documentation" }.fetch("html")

          expect(html).to include("The scripting reference is not shipped alongside this build")
          expect(html).to include("Forking and Contributions")
          expect(html.scan(%(<div class="rb-prose">)).length).to eq(1)
          expect(html).not_to include(%(<h1 id="scripting-reference">))
        end
      end

      # The client emitter would throw on any of these rather than draw them,
      # so finding one here would mean the wire had carried something the scan
      # let past.
      it "carries no script, style attribute or inline handler out of a document" do
        %w[documentation licence].each do |section|
          html = rendered.find { |r| r["section"] == section }.fetch("html")

          expect(html).not_to include("<script")
          expect(html).not_to match(/\son[a-z]+="/)
        end
      end

      # The seeded LibreTranslate row has a URL and a key; the never-configured
      # OpenArc row does not, so this proves the payload's configured/key_stored
      # facts reach the two cards as distinct pills rather than one static pair,
      # and that the saved allowed_pairs text round-trips into its own field.
      it "shows each integration's own connected and key-stored state, not a shared default" do
        html = rendered.find { |r| r["section"] == "integrations" }.fetch("html")

        expect(html).to match(/rb-status--good">.*?Connected/)
        expect(html).to match(/rb-status--good">.*?Key stored/)
        expect(html).to match(/rb-status--neutral">.*?Not configured/)
        expect(html).to match(/rb-status--neutral">.*?No key stored/)
        expect(html).to match(%r{<textarea[^>]*name="allowed_pairs"[^>]*>en:pt,pt:en</textarea>})
        expect(html).to match(%r{formaction="[^"]*/integrations/libretranslate/test"})
      end

      # LibreTranslate and OpenArc both post "url" and "api_key", so nothing
      # here would catch a Field id collision without checking the ids
      # themselves rather than just the shared names.
      it "gives every integration card's fields their own id, despite the shared url/api_key names" do
        html = rendered.find { |r| r["section"] == "integrations" }.fetch("html")
        ids = html.scan(/\sid="([^"]+)"/).flatten

        expect(ids).not_to be_empty
        expect(ids.uniq.length).to eq(ids.length), "duplicate id(s): #{ids.tally.select { |_, n| n > 1 }.keys.join(', ')}"
      end
    end

    describe "the shared emitters' own contract" do
      before(:context) { @build = compile_theme_bundles }
      after(:context) { FileUtils.remove_entry(@build[:dir], true) }

      # The name a Ruby helper goes by on the client, derived from the helper
      # itself rather than listed out, so a fifteenth primitive cannot be added
      # on one side and quietly forgotten on the other.
      def client_name(helper) = helper.to_s.gsub(/_(.)/) { Regexp.last_match(1).upcase }

      def report
        @report ||= begin
          out = run!(ThemedRenderedVocabularySupport::NODE_BIN, File.join(ThemedRenderedVocabularySupport::SUPPORT_DIR, "theme_primitive_checks.js"),
                     @build[:runtime])
          JSON.parse(out)
        end
      end

      it "hydrates all server chart shapes while retaining their titles and accessible values" do
        surface = Object.new.extend(Rubotty::Dashboard::Primitives::Identity)
        rows = (1..12).map { |index| { label: "Room <#{index}>", count: index * 3 } }
        title = "Activity & rooms"
        cases = %i[categorical_distribution time_series share_of_total].map do |shape|
          original = surface.chart(rows, shape: shape, title: title, limit: 12)
          { original: original, title: title, shape: shape,
            rows: CGI.unescapeHTML(original[/data-chart="([^"]+)"/, 1]) }
        end
        path = File.join(@build[:dir], "chart-hydration.json")
        File.write(path, JSON.generate(cases))
        output = run!(ThemedRenderedVocabularySupport::NODE_BIN,
                      File.join(ThemedRenderedVocabularySupport::SUPPORT_DIR, "chart_hydration_checks.js"),
                      @build[:hydration], path)
        hydrated = JSON.parse(output)

        expect(hydrated.fetch("warnings").length).to eq(1)
        hydrated.fetch("html").zip(cases).each do |html, original|
          expect(html).to include("<svg", 'aria-hidden="true"', "Activity &amp; rooms")
          expect(html[%r{<table.*?</table>}m]).to eq(original.fetch(:original)[%r{<table.*?</table>}m])
          expect(html).not_to include("<12>", "NaN", "undefined")
        end
      end

      def checks = report.fetch("checks")

      it "runs a real battery of checks, so nothing here passes vacuously" do
        expect(checks.length).to be >= 40
      end

      it "holds every one of them" do
        failed = checks.reject { |c| c["ok"] }

        expect(failed).to be_empty, lambda {
          failed.map { |c| "#{c['name']}: #{c['detail']}" }.join("\n")
        }
      end

      # Six of the fourteen existed client side for a while, which meant a
      # screen needing any of the other eight could not be themed at all: the
      # gap blocked three separate porting batches before it was closed. Chart
      # was the last one, and it blocked both analytics screens.
      it "carries a client emitter for every primitive the Ruby side declares" do
        wanted = Rubotty::Dashboard::Primitives::NAMES.values.map { |helper| client_name(helper) }
        missing = wanted - report.fetch("exports")

        expect(missing).to be_empty, "primitive(s) with no client emitter: #{missing.join(', ')}"
      end

      it "exposes the chart primitive and the shape list the server names" do
        expect(report.fetch("exports")).to include("chart", "CHART_SHAPES")
      end

      # The render checks above only see the classes the ported screens happen
      # to draw, so an emitter no screen uses yet could invent a class name
      # unnoticed. These are one render per emitter instead.
      it "draws no class outside Primitives::CLASSES from any emitter, ported screen or not" do
        drawn = report.fetch("samples").values.flat_map { |html| classes_in(html) }.uniq
        bespoke = drawn - Rubotty::Dashboard::Primitives::CLASSES

        expect(bespoke).to be_empty, "class(es) outside Primitives::CLASSES: #{bespoke.join(', ')}"
      end

      it "renders every emitter for that check, so it cannot pass on an empty sample" do
        expect(report.fetch("samples").length).to be >= 13
        expect(report.fetch("samples").values).to all(include("class="))
      end
    end
  else
    it "has no toolchain installed to render the themes with" do
      ThemeToolchain.report_gap!(self, ThemedRenderedVocabularySupport::RENDER_TOOLS, "the themed render checks")
    end
  end
end
