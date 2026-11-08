# frozen_string_literal: true

require "rack/utils"
require "time"

require "rubotty/dashboard/nav"

module Rubotty
  module Dashboard
    # The internal YAML surface: what one themed section of the dashboard is
    # drawn from, as plain string-keyed Ruby ready to be dumped as YAML.
    # Separate from the REST admin API on purpose: that one authenticates a
    # bearer key (developer or administrator scope), this one rides the
    # dashboard session and its per-community grants, so a scope can never be
    # widened by accident through one surface answering to both auth models.
    # It holds no state between calls and reads only; every write stays on
    # the existing form posts.
    class ViewData
      # A slug this session may not read, and a slug that names nothing, both
      # raise this. One refusal for both, so an answer never tells a reader
      # that another community exists. Same rule the API follows, and for the
      # same reason.
      class NotFound < Rubotty::Error; end

      # A section this session may not read inside a community it CAN read.
      # Distinct from {NotFound} because the reader already knows that
      # community is there, so there is nothing left for a refusal to give
      # away.
      class Forbidden < Rubotty::Error; end

      # Said on the model-backed panel, because all three caveats would
      # otherwise be invisible in the numbers themselves.
      MODEL_CALL_NOTE = "Counted by day, so the shortest window rounds out to whole days. Response " \
                        "times are kept as a histogram, so a percentile lands on a bucket boundary " \
                        "rather than an exact value. Measurements only: no prompt, answer or message " \
                        "text is recorded here."

      # @param deps [Deps] the same control-plane bundle every dashboard route uses
      # @param role [Role] the role behind the current session
      def initialize(deps:, role:)
        @deps = deps
        @role = role
      end

      # The shell document: everything a theme needs to draw the chrome
      # around a page rather than only the page. Navigation is data here
      # (see {Nav}), which supplies the dashboard's navigation catalogue.
      #
      # @param path [String] the page path, prefix free, never reflected
      #   back: every path in the answer is one this process built
      # @param prefix [String] the mount point, "" standalone
      def shell(path:, prefix: "")
        page = normalise_path(path)
        community = community_in(page)
        here = page == "/" ? Nav.root_path(prefix) : "#{prefix}#{page}"
        {
          "section" => "shell",
          "scopes" => Nav.scopes(role: @role, community: community, prefix: prefix, path: here,
                                 badges: badges(community), counts: counts(community)),
          "communities" => Nav.switcher(switchable_communities, community: community,
                                        prefix: prefix),
          "crumbs" => Nav.crumbs(community: community, prefix: prefix,
                                 title: Nav.title_for(path: here, community: community,
                                                      prefix: prefix)),
          "operator" => {
            "label" => @role.administrator? ? "Administrator" : "Operator",
            "administrator" => @role.administrator?,
            "read_only" => !@role.administrator? && @role.write_actions.empty?
          },
          "search" => {
            "path" => "#{prefix}/search.json",
            "placeholder" => community ? "Search #{community.slug}" : "Search this deployment"
          },
          "logout_path" => "#{prefix}/logout",
          "help_path" => "#{prefix}/documentation",
          # The current community's own figures, the same ones the overview
          # page's stat row draws, for a chrome that sits on every one of its
          # pages rather than only the landing one.
          "stats" => community ? community_stats(community) : {},
          "may" => {
            "manage_lifecycle" => community ? @role.can?(:manage_community_lifecycle, community: community) : false
          }
        }
      end

      # The community index, deliberately the whole deployment (matching the
      # HTML index and {Role::GLOBAL_READ_ACTIONS}): an operator has to see
      # that a community exists to ask for access, and this carries only
      # names and counts, nothing said inside one. +readable+ separates the
      # two, so a theme can link what this session can open and offer the
      # rest as a request instead of a 404.
      def communities
        rows = @deps.communities.map do |community|
          community_payload(community).merge(
            "readable" => @role.can?(:view_community, community: community),
            "status_tone" => community.status == "active" ? "good" : "neutral",
            "channels" => models.channel.where(community_id: community.id).count,
            "operators" => operator_count(community.id),
            "pending_operator_requests" =>
              models.operator_request.where(community_id: community.id, state: "pending").count
          )
        end
        {
          "section" => "communities",
          "communities" => rows,
          # A count and a link, never the queue itself, the same split the ERB
          # index draws: the rows live on Onboarding and belong to nobody else.
          "waiting_spaces" => @role.administrator? ? @deps.pending_spaces.pending.length : 0,
          "may" => {
            "view_community" => true,
            "manage_pending_spaces" => @role.administrator?
          }
        }
      end

      # The deployment-wide activity table, one row per community this session
      # may already open, over the selected window. The per-community report
      # behind each row is its own section; this one only totals.
      def analytics_overview(window: nil)
        authorize!(:view_analytics, Role::DEPLOYMENT)
        selected = ControlPlane::Analytics.window_key(window)
        rows = @deps.analytics.community_rows(window: selected, only: readable_communities)
        {
          "section" => "analytics_overview",
          "window" => selected,
          "windows" => ControlPlane::Analytics::WINDOWS.keys,
          "rows" => rows.map { |row| analytics_overview_payload(row) },
          "may" => { "view_analytics" => true }
        }
      end

      # The deployment-wide credentialed gateway connections: every stored
      # account, plus the two-step add form (adapter first, then that
      # adapter's own account_schema). Administrator only, the same
      # reconnaissance reasoning {#api_keys} carries. +token_env_set+ is a
      # request-time fact of this process, resolved against the environment
      # rather than read from {Deps} directly.
      def accounts(adapter: nil, token_env_set: {})
        administrator!
        chosen_adapter = presence(adapter)
        schema = chosen_adapter && account_schema_or_nil(chosen_adapter)
        {
          "section" => "accounts",
          "accounts" => @deps.accounts.list.map { |row| account_payload(row, token_env_set) },
          "adapters" => ControlPlane::Accounts.adapter_names,
          "new_adapter" => schema ? chosen_adapter : nil,
          "new_fields" => schema ? schema_field_payloads(schema, {}) : [],
          "may" => { "manage_accounts" => true }
        }
      end

      # The REST admin API's bearer credentials. Administrator only for the
      # reason the ERB route is: the list names who holds one and what it
      # reaches, which is reconnaissance rather than oversight. +issued+ is
      # the raw token of a key minted a moment ago, which exists for one
      # render and is never stored in full.
      def api_keys(issued_token: nil, issued_label: nil, platform_accounts: [])
        administrator!
        communities = models.community.order(:slug).all
        named = communities.each_with_object({}) { |row, index| index[row.id] = row }
        {
          "section" => "api_keys",
          "keys" => @deps.api_keys.list.map { |key| api_key_payload(key, named) },
          "communities" => communities.map { |row| [row.slug, row.slug] },
          "platform_accounts" => Array(platform_accounts),
          "issued_token" => presence(issued_token),
          "issued_label" => presence(issued_label),
          "may" => { "manage_api_keys" => true }
        }
      end

      # Who reads every community, who has asked to, and the tokens that hand
      # the dimension over. Administrator only, since viewer spans the whole
      # deployment and an operator of one community must not hand out
      # oversight of the others.
      def viewers(issued_token: nil)
        administrator!
        {
          "section" => "viewers",
          "issued_token" => presence(issued_token),
          "requests" => @deps.dashboard_viewers.pending.map { |row| viewer_request_payload(row) },
          "baked_in" => @deps.dashboard_viewers.baked_in.map { |entry| baked_in_viewer_payload(entry) },
          "granted" => @deps.dashboard_viewers.granted.map { |row| viewer_payload(row) },
          "adapters" => ControlPlane::DashboardViewers::ADAPTERS,
          "tokens" => viewer_tokens.map { |row| administrator_token_payload(row) },
          "audit" => @deps.dashboard_viewers.audit_trail.map { |event| audit_event_payload(event) },
          "may" => { "manage_viewers" => true }
        }
      end

      # One community's landing section: the counts the overview page draws,
      # plus the one grant its button spends. manage_lifecycle mirrors what
      # act_button already answers for the ERB start/stop form: nobody
      # outside Role::ADMINISTRATOR holds :manage_community_lifecycle, so a
      # themed page has no other way to know whether to draw that button live.
      def overview(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        {
          "section" => "overview",
          "community" => community_payload(community),
          "counts" => {
            "connections" => models.platform_connection.where(community_id: community.id).count,
            "channels" => models.channel.where(community_id: community.id).count,
            "rooms" => community.rooms_dataset.count,
            "endpoints" => models.script_endpoint.where(community_id: community.id).count,
            "operators" => operator_count(community.id),
            "pending_operator_requests" => @deps.operators.pending(community_id: community.id).length,
            "features" => models.feature_setting.where(community_id: community.id).count
          },
          "may" => {
            "manage_lifecycle" => @role.can?(:manage_community_lifecycle, community: community)
          }
        }
      end

      # The endpoints section: the outbound addresses this community's
      # scripts may call by name. Two grants ride in "may": view_endpoints
      # (true by construction, so a themed Open button still spends a real
      # grant) and manage_endpoints, which nobody outside
      # Role::ADMINISTRATOR ever holds since it is not in
      # ActionPermissions::ACTIONS, a themed page having no other way to know.
      def endpoints(slug)
        community = community!(slug)
        authorize!(:view_endpoints, community)
        {
          "section" => "endpoints",
          "community" => community_payload(community),
          "endpoints" => @deps.script_endpoints.list(community).map { |row| endpoint_payload(row) },
          "may" => {
            "view_endpoints" => true,
            "manage_endpoints" => @role.can?(:manage_endpoints, community: community)
          }
        }
      end

      # One endpoint's task form. The list needs only display facts; this is
      # deliberately separate because an administrator may edit header values
      # while an oversight reader may see only that an endpoint exists.
      def endpoint_edit(slug, id: nil)
        community = community!(slug)
        authorize!(:view_endpoints, community)
        endpoint = id.nil? ? nil : @deps.script_endpoints.find(community, id)
        raise NotFound if !id.nil? && endpoint.nil?

        {
          "section" => "endpoint_edit",
          "community" => community_payload(community),
          "endpoint" => endpoint_form_payload(endpoint),
          "http_methods" => ControlPlane::ScriptEndpoints::METHODS,
          "max_timeout" => ControlPlane::ScriptEndpoints::MAX_TIMEOUT,
          "may" => {
            "view_endpoints" => true,
            "manage_endpoints" => @role.can?(:manage_endpoints, community: community)
          }
        }
      end

      # The scripts section: this community's operator-authored rules, both
      # live and archived, plus the one grant a themed enable/disable/delete
      # button spends. manage_scripts mirrors the ERB view's own act_button
      # call: like manage_endpoints, it is not in ActionPermissions::ACTIONS,
      # so nobody outside Role::ADMINISTRATOR ever holds it and a themed page
      # has no other way to know that than being told.
      def scripts(slug)
        community = community!(slug)
        authorize!(:view_scripts, community)
        {
          "section" => "scripts",
          "community" => community_payload(community),
          "scripts" => @deps.scripts.list(community).map { |row| script_payload(row) },
          "archived" => @deps.scripts.list(community, archived: true).map { |row| script_payload(row) },
          "runtime_available" => @deps.script_pool.available?,
          # What the scripts here recorded for themselves. A stat row carries
          # no script name, so it belongs to the community rather than to any
          # one of them.
          "recorded" => script_stat_payload(community),
          "may" => {
            "view_scripts" => true,
            "manage_scripts" => @role.can?(:manage_scripts, community: community)
          }
        }
      end

      # One script's authoring flow: when it runs, its code and data, then the
      # check and the switch. Every trigger describes itself here (its summary,
      # the fields it reads, what it hands over) so the client shows only the
      # boxes the chosen condition actually reads without a second copy of that
      # knowledge living in a script tag.
      def script_edit(slug, id: nil)
        community = community!(slug)
        authorize!(:view_scripts, community)
        script = id.nil? ? nil : @deps.scripts.find(community, id)
        raise NotFound if !id.nil? && script.nil?

        {
          "section" => "script_edit",
          "community" => community_payload(community),
          "script" => script_form_payload(script),
          "activity" => script.nil? ? nil : script_activity_payload(script),
          "kinds" => ControlPlane::Scripts::KINDS.map { |kind| [kind, ControlPlane::Scripts::KIND_LABELS[kind]] },
          "languages" => Scripting::Dialects.available.map { |dialect| [dialect.name, dialect.label] },
          "triggers" => trigger_catalogue,
          "max_conditions" => Scripting::Triggers::MAX,
          "runtime_available" => @deps.script_pool.available?,
          "may" => {
            "view_scripts" => true,
            "manage_scripts" => @role.can?(:manage_scripts, community: community)
          }
        }
      end

      # The redirections section: every run of messages an operator has moved
      # out of one of this community's rooms and into another, newest first.
      # manage_redirection is a real operator grant (ActionPermissions::ACTIONS),
      # unlike manage_endpoints above, so this one can actually be false for
      # an operator who was never handed it.
      def redirections(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        {
          "section" => "redirections",
          "community" => community_payload(community),
          "redirections" => @deps.redirections.recent(community_id: community.id).map do |row|
            redirection_payload(row)
          end,
          "may" => {
            "manage_redirection" => @role.can?(:manage_redirection, community: community)
          }
        }
      end

      # The webhooks section: where this community's events are sent, and
      # what happened to every attempt at sending one. Subscriptions
      # themselves are created over the REST API rather than here (creating
      # one hands out a signing secret), so this is read-only besides the
      # retry.
      def webhooks(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        {
          "section" => "webhooks",
          "community" => community_payload(community),
          "subscriptions" => @deps.webhooks.list(community_id: community.id).map do |row|
            webhook_subscription_payload(row)
          end,
          "deliveries" => @deps.webhooks.deliveries(community_id: community.id, limit: 200).map do |row|
            webhook_delivery_payload(row)
          end,
          # The deployment-wide count, not a tally of the 200 most recent
          # rows above: a community with more dead-lettered deliveries than
          # that window would otherwise read the flash notice's own number
          # as wrong.
          "failed_count" => @deps.webhooks.failed_count(community_id: community.id),
          "retention_days" => Rubotty::ControlPlane::Webhooks::RETENTION / (24 * 60 * 60),
          "may" => {
            "manage_webhooks" => @role.can?(:manage_webhooks, community: community)
          }
        }
      end

      # The audit history at either dashboard scope. The deployment view reads
      # only communities this session may already open; the community view
      # keeps the same narrower query without needing a separate renderer.
      def audit(slug: nil, source: nil, action: nil)
        community = slug.nil? ? nil : community!(slug)
        authorize!(:view_audit_log, community)
        selected_source = presence(source)
        selected_action = presence(action)
        communities = community ? [community.slug] : readable_communities.select_map(:slug)
        events = @deps.audit.query(
          communities: communities, source: selected_source, action: selected_action, limit: 200
        )
        {
          "section" => "audit",
          "community" => community && community_payload(community),
          "events" => events.map { |event| audit_log_event_payload(event) },
          "source" => selected_source,
          "action" => selected_action,
          "may" => { "view_audit_log" => true }
        }
      end

      # Both processes' recent log lines. Administrator only, never authorize!,
      # the rule the ERB route holds itself to for the same reason: a log line
      # carries whatever the code that wrote it put there, which belongs to no
      # one community for an operator to be given a window on.
      def logs(source: nil, level: nil, limit: nil)
        raise Forbidden, "forbidden" unless @role.administrator?

        chosen = DebugLogs.source_of(source)
        chosen_level = DebugLogs.level_of(level)
        chosen_limit = DebugLogs.limit_of(limit)
        view = @deps.debug_logs.fetch(source: chosen, level: chosen_level, limit: chosen_limit)
        {
          "section" => "logs",
          "source" => chosen,
          "level" => chosen_level,
          "limit" => chosen_limit,
          "entries" => view["entries"],
          "errors" => view["errors"],
          "may" => { "view_logs" => true }
        }
      end

      # Every backfill proposal a sweep has made, grouped by where it stands.
      # Administrator only, never authorize!, the same rule the ERB route
      # holds itself to: a proposal's items carry real message content, and
      # PRIVACY.md's narrow exception for that reaches only the audience that
      # can already read everything else here.
      def backfill_proposals
        raise Forbidden, "forbidden" unless @role.administrator?

        every = ControlPlane::BackfillProposals::EVERY_COMMUNITY
        pending = @deps.backfill_proposals.pending(community: every)
        awaiting_relay = @deps.backfill_proposals.awaiting_relay(community: every)
        expired = @deps.backfill_proposals.expired(community: every)
        communities = communities_by_id(pending + awaiting_relay + expired)
        {
          "section" => "backfill_proposals",
          "pending" => pending.map { |row| backfill_proposal_payload(row, communities) },
          "awaiting_relay" => awaiting_relay.map { |row| backfill_proposal_payload(row, communities) },
          "expired" => expired.map { |row| backfill_proposal_payload(row, communities) },
          # One grant, since every action on this page (accept, reject, retry)
          # is gated the same way the ERB route gates it: require_admin!, not
          # authorize!, so reaching this method at all already answered it.
          "may" => { "manage_backfill_proposals" => true }
        }
      end

      # The onboarding queue: every space the bot sits in that no community
      # owns yet, plus the spaces a previous decision blacklisted, deployment
      # wide and administrator only. manage_pending_spaces is carried in
      # "may" rather than assumed, since the route behind accept/reject is
      # require_admin! and a themed Button has no other way to learn that.
      def onboarding
        administrator!
        {
          "section" => "onboarding",
          "pending" => @deps.pending_spaces.pending.map { |row| pending_payload(row) },
          "denied" => @deps.pending_spaces.denied.map { |row| denied_payload(row) },
          "communities" => @deps.communities.map { |row| { "id" => row.id, "slug" => row.slug, "name" => row.name } },
          "may" => { "manage_pending_spaces" => true }
        }
      end

      # The outstanding /web-login links, so an administrator can see who holds
      # one and end it early. Administrator only for the same reason the ERB
      # route is: a live link is a path into somebody else's session, which is
      # reconnaissance rather than oversight, so a viewer is refused here too.
      def operator_tokens
        administrator!
        {
          "section" => "operator_tokens",
          "tokens" => @deps.web_login.active_tokens.map { |token| operator_token_payload(token) },
          "may" => { "manage_operator_tokens" => true }
        }
      end

      def administrators
        administrator!
        {
          "section" => "administrators",
          "administrators" => @deps.dashboard_administrators.granted.map { |row| administrator_payload(row) },
          "baked_in" => @deps.dashboard_administrators.baked_in.map { |entry| baked_in_administrator_payload(entry) },
          "adapters" => ControlPlane::DashboardAdministrators::ADAPTERS,
          "tokens" => administrator_tokens.map { |row| administrator_token_payload(row) },
          "audit" => @deps.dashboard_administrators.audit_trail.map { |event| audit_event_payload(event) },
          "may" => { "manage_administrators" => true }
        }
      end

      # Deployment-wide connections to outside services, one row per known
      # integration (see {ControlPlane::Integrations::KNOWN}). Administrator
      # only, the same rule the ERB route holds itself to: a stored key here
      # is shared by every community. Whether a community actually uses the
      # connection is a separate per-community toggle on its own Features
      # page, not drawn here.
      def integrations
        administrator!
        openarc = openarc_models
        {
          "section" => "integrations",
          "integrations" => @deps.integrations.list.map { |row| integration_payload(row, openarc) },
          "may" => { "manage_integrations" => true }
        }
      end

      # What the configured OpenArc server reports it has loaded, so the model
      # choice is drawn from the server rather than from a constant. A server
      # that cannot be reached carries its reason instead of an empty list that
      # would read as "no models". Whether that read got an answer at all is
      # the card's reachability too, so the page waits on one listing rather
      # than two: bounded by the client's own connect and read ceilings, which
      # is what keeps a dead endpoint from holding the render open.
      def openarc_models
        settings = OpenArc::Settings.new(
          store: ControlPlane::Integrations::OpenArcSettings.new(@deps.integrations)
        )
        return { available: [], error: nil, reachable: nil, settings: settings } unless settings.configured?

        { available: OpenArc::Client.new(settings: settings).models, error: nil, reachable: true,
          settings: settings }
      rescue OpenArc::Client::Error => e
        { available: [], error: e.message, reachable: false, settings: settings }
      end

      # The datastore snapshot screen, which is two controls and the warnings
      # that belong beside them. It carries no datastore contents: the export
      # is a streamed download on its own route, and reading a row count here
      # would say more about the deployment than the page needs to.
      def datastore
        administrator!
        {
          "section" => "datastore",
          "may" => { "export_datastore" => true, "import_datastore" => true }
        }
      end

      # The scripting reference and the README, both rendered as markup since
      # nothing on the client renders markdown itself. +prefix+ is the mount
      # point, so a link either document carries to a page this server serves
      # points here rather than at the private repository.
      def documentation(prefix: "")
        data = prose("documentation", :scripting, prefix)
        data["readme_markup"] = Primitives::Prose.markup(:readme, app_root: prefix.to_s)
        data
      end

      # The licence, the same way. No grant is checked, matching the page:
      # /licence answers signed out, because the base licence conditions every
      # right on agreeing to it and whoever is weighing that up has no session.
      def licence(prefix: "") = prose("licence", :licence, prefix)

      # The features section: every known feature at one scope, toggled in
      # place, its current config carried as config_pairs so a themed
      # KeyValues call draws every shape (boolean, duration, list) one way.
      # feature_categories carries every category in FeatureDisplay's own
      # order, so a theme never hardcodes a category title of its own.
      # A toggle_<feature> grant rides per known feature, not just the ones
      # with a feature_settings row; view_community rides too, spent by
      # every themed Config link.
      def features(slug, scope: nil)
        community = community!(slug)
        authorize!(:view_community, community)
        scope = presence(scope) || "all"
        {
          "section" => "features",
          "community" => community_payload(community),
          "scope" => scope,
          "scopes" => scope_options(community),
          "feature_rows" => feature_rows(community, scope),
          "feature_categories" => FeatureDisplay::CATEGORIES.map { |key, title| { "key" => key.to_s, "title" => title } },
          "may" => Features::Catalog.names.each_with_object("view_community" => true) do |name, may|
            may["toggle_#{name}"] = @role.can?(:"toggle_#{name}", community: community)
          end
        }
      end

      # One feature's config editor: every field its config_schema declares,
      # at one scope. {NotFound} for a feature with no schema at all, the
      # same refusal an invented slug gets: there is no config page behind
      # either, and telling the two apart would say more than a 404 should.
      def feature_config(slug, feature, scope: nil)
        community = community!(slug)
        authorize!(:view_community, community)
        feature = feature.to_s
        schema = Features::Catalog.config_schema(feature)
        raise NotFound, "not found" if schema.nil?

        scope = presence(scope) || "all"
        config = @deps.feature_controls.list(community, selector: scope)
                      .find { |entry| entry[:feature] == feature }&.dig(:config) || {}
        {
          "section" => "feature_config",
          "community" => community_payload(community),
          "feature" => feature,
          "feature_label" => ConfigHumanizer.humanize_key(feature),
          "scope" => scope,
          "scopes" => scope_options(community),
          "retention_notice" => Features::Catalog.retention_notice(feature),
          "fields" => schema.fields.each_value.map { |field| field_payload(field, config, feature) },
          "may" => { "view_community" => true, "configure_#{feature}" => @role.can?(:"configure_#{feature}", community: community) }
        }
      end

      # The word filter's own page: one row per scope, carrying what the bot
      # actually applies there rather than only what has a row of its own, and
      # the supplemental word list each configured scope adds on top of its
      # mode. Two writes reach the existing route from here, matching the two
      # the ERB page posts: the behaviour at a scope (mode, action, operator
      # exemption, enablement) and that scope's own extra words.
      def word_filter(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        {
          "section" => "word_filter",
          "community" => community_payload(community),
          "scopes" => feature_matrix(community, "word_filter").map { |entry| word_filter_scope(entry) },
          "modes" => WORD_FILTER_MODES,
          "actions" => Features::WordFilter::ACTIONS,
          "may" => {
            "view_community" => true,
            "configure_word_filter" => @role.can?(:configure_word_filter, community: community),
            "toggle_word_filter" => @role.can?(:toggle_word_filter, community: community)
          }
        }
      end

      # The FAQ page: the same per-scope shape as the word filter, with each
      # scope's canned answers as rows rather than a word list. A trigger is
      # folded into one string here, the way {#alerts} folds delivery, since a
      # Table cell draws one value.
      def faq(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        {
          "section" => "faq",
          "community" => community_payload(community),
          "scopes" => feature_matrix(community, "faq").map { |entry| faq_scope(entry) },
          "scope_options" => scope_options(community),
          "trigger_types" => %w[command keyword],
          "may" => {
            "view_community" => true,
            "configure_faq" => @role.can?(:configure_faq, community: community),
            "toggle_faq" => @role.can?(:toggle_faq, community: community)
          }
        }
      end

      # What this community is wired to: the join links the /platforms command
      # advertises, the credentialed connections behind its channels, and its
      # Fluxer instances. +token_env_set+ is the set/unset map the route
      # resolves against the process environment, handed in for the same
      # reason {#accounts} takes its own.
      def platforms(slug, token_env_set: {})
        community = community!(slug)
        authorize!(:view_platforms, community)
        {
          "section" => "platforms",
          "community" => community_payload(community),
          "known_adapters" => ControlPlane::PlatformConnections::KNOWN_ADAPTERS,
          "scope_options" => scope_options(community),
          "link_scopes" => feature_matrix(community, "utility_commands")
                             .map { |entry| platform_link_scope(entry) },
          "connections" => platform_connection_rows(community, token_env_set),
          "fluxer_kinds" => ControlPlane::FluxerInstances::KINDS.map do |kind|
            [kind, kind == "flagship" ? "Flagship" : "Self-hosted"]
          end,
          "fluxer_instances" => @deps.fluxer_instances.list(community: community).map do |instance|
            fluxer_instance_payload(instance, token_env_set)
          end,
          "may" => {
            "view_platforms" => true,
            "manage_platforms" => @role.can?(:manage_platforms, community: community)
          }
        }
      end

      # Who runs this community and who only reads it, plus the tokens that
      # hand either role to somebody nobody has met yet. The grant matrix is
      # deployment-wide (each grant applies in every community), so it rides
      # only for a reader whose sight is the whole deployment, matching what
      # the ERB page shows. +issued_token+ is relayed the way {#api_keys}
      # relays a raw key.
      def operators(slug, issued_token: nil)
        community = community!(slug)
        authorize!(:view_operators, community)
        deployment_wide = @role.administrator? || @role.viewer?
        {
          "section" => "operators",
          "community" => community_payload(community),
          "deployment_wide" => deployment_wide,
          "back" => "/communities/#{community.slug}/operators",
          "permission_groups" => deployment_wide ? permission_groups : [],
          "pending" => @deps.operators.pending(community_id: community.id)
                            .map { |row| operator_request_payload(row) },
          "has_approver" => !models.operator.where(community_id: community.id).order(:id).first.nil?,
          "viewer_requests" => @deps.community_viewers.pending(community_id: community.id)
                                    .map { |row| community_viewer_request_payload(row) },
          "viewers" => community_viewer_rows(community),
          "viewer_adapters" => ControlPlane::CommunityViewers::ADAPTERS,
          "issued_auth_token" => presence(issued_token),
          "auth_tokens" => @deps.auth_tokens.list(community_id: community.id)
                                .map { |row| auth_token_row_payload(row) },
          "operators" => operator_rows(community),
          "unreachable" => unreachable_operator_rows(community),
          "may" => {
            "view_operators" => true,
            "manage_action_permissions" => @role.can?(:manage_action_permissions, community: community),
            "manage_operator_requests" => @role.can?(:manage_operator_requests, community: community),
            "manage_community_viewers" => @role.can?(:manage_community_viewers, community: community),
            "manage_operators" => @role.can?(:manage_operators, community: community)
          }
        }
      end

      # One community's detailed activity report. Every figure the report
      # carries is folded here into the shape the two emitters that draw it
      # take: StatRow triples and Chart's own label and count rows. Doing it
      # here rather than on the client is what keeps a raw bucket timestamp or
      # a bare rate off the page, and it means one report structure the screen
      # walks rather than ten hand-written blocks.
      def analytics(slug, window: nil, channel_view: nil)
        community = community!(slug)
        authorize!(:view_analytics, community)
        selected = ControlPlane::Analytics.window_key(window)
        view = ControlPlane::Analytics.channel_view_key(channel_view)
        report = @deps.analytics.overview(community: community, window: selected)
        {
          "section" => "analytics",
          "community" => community_payload(community),
          "window" => selected,
          "windows" => ControlPlane::Analytics::WINDOWS.keys,
          "channel_view" => view,
          "channel_views" => [["channel", "By platform channel"], ["room", "By room"]],
          "reports" => analytics_reports(report, view),
          "recently_active" => report[:members][:recently_active].map { |row| sender_row_payload(row) },
          "may" => { "view_analytics" => true }
        }
      end

      # The polls page: every open poll and open scheduling session across
      # this community's rooms, soonest deadline first. Read and cancel only,
      # matching the route: creating one is a chat action.
      def polls(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        rooms_by_id = models.room.where(community_id: community.id).all.to_h { |room| [room.id, room] }
        {
          "section" => "polls",
          "community" => community_payload(community),
          "polls" => @deps.polls.open_polls(community: community).map do |poll|
            poll_payload(poll, rooms_by_id[poll.room_id])
          end,
          "may" => {
            "view_community" => true,
            "configure_poll" => @role.can?(:configure_poll, community: community)
          }
        }
      end

      # The guest portal: which rooms allow a guest at all, the link issue
      # form for those that do, and every invite issued so far. +issued_link+
      # is the one-time link the create route just minted, relayed here the
      # way {#api_keys} relays a raw key: the themed draw replaces the body
      # that would otherwise have spent the flash itself.
      def guests(slug, issued_link: nil, issued_nickname: nil)
        community = community!(slug)
        authorize!(:view_guests, community)
        rooms = models.room.where(community_id: community.id).order(:room_key).all
        access = rooms.map { |room| guest_room_access_payload(community, room) }
        {
          "section" => "guests",
          "community" => community_payload(community),
          "issued_link" => presence(issued_link),
          "issued_nickname" => presence(issued_nickname),
          "guest_domain" => Core::SenderLabel::GUEST_DOMAIN,
          "room_access" => access,
          "allowed_rooms" => access.select { |entry| entry["allowed"] }
                                   .map { |entry| [entry["room_key"], entry["label"]] },
          "who_can_invite_options" => Features::GuestPortal::WHO_CAN_INVITE,
          "invites" => @deps.guest_invites.list(community: community).map do |invite|
            guest_invite_payload(invite, models.room[invite.room_id])
          end,
          "may" => {
            "view_guests" => true,
            "manage_guests" => @role.can?(:manage_guests, community: community)
          }
        }
      end

      # The alerts section: what this community's scripts have raised with
      # rubotty.alert, newest first. "how" is folded into text here rather
      # than left as mode/delivered_to for the client to re-derive, since
      # Table draws a cell as formatted text and has nowhere to put a status
      # pill inside a row.
      def alerts(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        rows = @deps.alerts.recent(community_id: community.id)
        {
          "section" => "alerts",
          "community" => community_payload(community),
          "retention_days" => Rubotty::ControlPlane::Alerts::RETENTION / (24 * 60 * 60),
          "unseen" => rows.count { |row| row.seen_at.nil? },
          "alerts" => rows.map { |row| alert_payload(row) },
          "may" => {
            "manage_alerts" => @role.can?(:manage_alerts, community: community)
          }
        }
      end

      # The files section: what rubotty is currently rehosting for this
      # community. Admin-only (mirrors the ERB route's require_admin!):
      # nothing in Role::WRITE_ACTIONS ever names a files grant, so an
      # operator never reaches this section at all.
      def files(slug)
        community = community!(slug)
        raise Forbidden, "forbidden" unless @role.administrator?

        store = @deps.rehosted_files
        {
          "section" => "files",
          "community" => community_payload(community),
          "configured" => !store.nil?,
          "usage_bytes" => store&.sealed_bytes_for(community_id: community.id),
          "quota_bytes" => store&.policy_for(community_id: community.id)&.dig(:quota_bytes),
          "files" => (store&.list(community_id: community.id) || []).map { |row| file_payload(row) },
          "may" => {
            "manage_files" => @role.administrator?
          }
        }
      end

      # The Rooms board is one row per channel. Whether a channel has a room,
      # whether it has a name, and whether that name awaits approval are facts
      # on that row, not three separate queues.
      def rooms(slug, state: nil)
        community = community!(slug)
        authorize!(:view_rooms, community)
        rooms = community.rooms_dataset.order(:room_key).all
        channels = community.channels_dataset.order(:adapter, :account, :route_key).all
        rooms_by_id = rooms.to_h { |room| [room.id, room] }
        channel_rooms = Hash.new { |index, id| index[id] = [] }
        unless rooms.empty?
          models.room_channel.where(room_id: rooms.map(&:id)).all.each do |row|
            room = rooms_by_id[row.room_id]
            channel_rooms[row.channel_id] << room if room
          end
        end

        rows = channels.map { |channel| room_board_channel_payload(channel, channel_rooms[channel.id]) }
        active_state = room_board_state(state)
        counts = room_board_counts(rows)
        {
          "section" => "rooms",
          "community" => community_payload(community),
          "channel_management_enabled" => channel_management_enabled?(community),
          "state" => active_state,
          "counts" => counts,
          "pending_spaces" => @role.administrator? ? @deps.pending_spaces.pending.length : 0,
          "channels" => rows.select { |row| active_state == "all" || row["filter_states"].include?(active_state) },
          "rooms" => rooms.map { |room| room_board_payload(community, room) },
          "connections" => community.platform_connections_dataset.order(:adapter, :account).all.map do |row|
            { "adapter" => row.adapter, "account" => row.account, "label" => row.label }
          end,
          "may" => {
            "view_rooms" => @role.can?(:view_rooms, community: community),
            "manage_discovered" => @role.can?(:manage_discovered, community: community),
            "manage_rooms" => @role.can?(:manage_rooms, community: community)
          }
        }
      end

      # One channel's mapping and naming controls. The board deliberately
      # contains no mapping fields: a state column tells the operator what is
      # unfinished, while this page owns the fields needed to change it.
      def room_channel(slug, id)
        community = community!(slug)
        authorize!(:view_rooms, community)
        channel = models.channel.where(community_id: community.id, id: id.to_i).first
        raise NotFound, "not found" if channel.nil?

        rooms = room_memberships(community, channel)
        primary_room = rooms.first
        candidates = @deps.channel_discovery.unmapped(community).reject { |row| row.id == channel.id }
        {
          "section" => "room_channel",
          "community" => community_payload(community),
          "channel" => room_board_channel_payload(channel, rooms),
          "details" => [
            ["Endpoint key", channel.endpoint_key, "code"],
            ["Route key", channel.route_key, "code"],
            ["Platform", "#{channel.adapter} / #{channel.account}"],
            ["First seen", channel.created_at&.iso8601, "timestamp"],
            ["Room", rooms.empty? ? "Not in a room" : rooms.map { |room| room_name(room) }.join(", ")]
          ],
          "endpoint_notice" => "This fixed endpoint key is the address other tables use for this channel. " \
                               "Its prefix records how the bot first saw it, not its current state.",
          "name" => channel.label.to_s,
          "suggested" => truthy?(channel.suggested),
          "rooms" => rooms.map { |room| room_board_payload(community, room) },
          "room_options" => community.rooms_dataset.order(:room_key).all.map do |room|
            [room.room_key, room_name(room)]
          end,
          "partner_options" => candidates.map { |row| [row.endpoint_key, room_board_channel_name(row, proposed: false)] },
          "members" => primary_room ? room_member_rows(community, primary_room) : [],
          "may" => {
            "view_rooms" => @role.can?(:view_rooms, community: community),
            "manage_discovered" => @role.can?(:manage_discovered, community: community)
          }
        }
      end

      # One room's membership and provisioning controls. A room's key stays
      # stable because feature configuration scopes to it; the human label is
      # the value an operator may rename.
      def room_detail(slug, room_key)
        community = community!(slug)
        authorize!(:view_rooms, community)
        room = community.rooms_dataset.where(room_key: room_key.to_s).first
        raise NotFound, "not found" if room.nil?

        {
          "section" => "room_detail",
          "community" => community_payload(community),
          "room" => room_board_payload(community, room),
          "details" => [
            ["Room key", room.room_key, "code"],
            ["Channels", room.channels_dataset.where(community_id: community.id).count],
            ["Platforms", room.channels_dataset.where(community_id: community.id).select_map(:adapter).uniq.sort.join(", ")]
          ],
          "members" => room_member_rows(community, room),
          "channel_management_enabled" => channel_management_enabled?(community),
          "may" => {
            "view_rooms" => @role.can?(:view_rooms, community: community),
            "manage_rooms" => @role.can?(:manage_rooms, community: community)
          }
        }
      end

      # Automatic mapping is a proposal-only view. Saving the ticked rows
      # still goes through ChannelMapper, just as a manual channel form does.
      def automatic_mapping(slug)
        community = community!(slug)
        authorize!(:manage_discovered, community)
        rooms = community.rooms_dataset.order(:room_key).all
        proposals = @deps.auto_mapper.propose(channels: @deps.channel_discovery.unmapped(community), rooms: rooms)
        {
          "section" => "automatic_mapping",
          "community" => community_payload(community),
          "proposals" => proposals.reject(&:skip?).map { |proposal| automatic_mapping_payload(proposal) },
          "skipped" => proposals.select(&:skip?).map { |proposal| automatic_mapping_payload(proposal) },
          "may" => {
            "manage_discovered" => @role.can?(:manage_discovered, community: community)
          }
        }
      end

      # The room games section: what a script has running in each room
      # through rubotty.open_session, one row per room with something open.
      # A room with nothing running is left out rather than drawn as a row of
      # dashes, the same way {#endpoints} leaves an empty community with no
      # row at all; the themed Table's own empty state already says so.
      def participation(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        rooms = community.rooms_dataset.order(:room_key).all.filter_map { |room| participation_row(community, room) }
        {
          "section" => "participation",
          "community" => community_payload(community),
          "rooms" => rooms,
          "may" => {
            "manage_participation" => @role.can?(:manage_participation, community: community)
          }
        }
      end

      # The people page: this community's directory, most recently seen first
      # and capped the same way the ERB route caps it (PEOPLE_CAP), plus one
      # bridged nickname field per other platform this community bridges. The
      # write stays on the existing form post, one target platform per submit,
      # so this carries exactly the fields that post already reads.
      PEOPLE_CAP = 50

      def people(slug, query: nil)
        community = community!(slug)
        authorize!(:view_community, community)
        query = presence(query)
        identities = @deps.identities.recent(community_id: community.id, query: query, limit: PEOPLE_CAP)
        {
          "section" => "people",
          "community" => community_payload(community),
          "query" => query,
          "cap" => PEOPLE_CAP,
          "who_can_set" => nickname_who_can_set(community),
          "who_can_set_options" => Features::Nickname::WHO_CAN_SET,
          "identities" => identities.map { |identity| person_row_payload(community, identity) },
          "may" => {
            "view_community" => true,
            "configure_nickname" => @role.can?(:configure_nickname, community: community)
          }
        }
      end

      # The moderation page: search plus the mutes already active. The manual
      # mute form (platform, user id, duration, reason) stays a themed Form
      # posting to the existing route; a found identity's own row offers a
      # quicker indefinite mute, so a duration or a reason is still typed on
      # the manual form beneath it rather than lost.
      def moderation(slug, query: nil)
        community = community!(slug)
        authorize!(:view_community, community)
        query = presence(query)
        identities = query ? @deps.identities.search(community_id: community.id, query: query, limit: 25) : []
        {
          "section" => "moderation",
          "community" => community_payload(community),
          "query" => query,
          "identities" => identities.map { |identity| identity_row_payload(identity) },
          "active_mutes" => @deps.moderation.active_mutes(community: community).map { |row| mute_row_payload(row) },
          "may" => {
            "view_community" => true,
            "moderate_user" => @role.can?(:moderate_user, community: community)
          }
        }
      end

      # The events page: which rooms may schedule one, the create form's own
      # room options, and every event not yet started. Detail folds the
      # gaming/general specifics into one column, the same reason alerts folds
      # mode into text: Table draws one column as one string.
      def events(slug)
        community = community!(slug)
        authorize!(:view_community, community)
        rooms = models.room.where(community_id: community.id).order(:room_key).all
        room_access = rooms.map { |room| event_room_access_payload(community, room) }
        upcoming = @deps.event_scheduling.upcoming(community: community)
        rooms_by_id = rooms.to_h { |room| [room.id, room] }
        {
          "section" => "events",
          "community" => community_payload(community),
          "room_access" => room_access,
          "enabled_rooms" => room_access.select { |entry| entry["enabled"] }
                                        .map { |entry| [entry["room_key"], entry["label"]] },
          "events" => upcoming.map { |event| event_row_payload(event, rooms_by_id[event.room_id]) },
          "may" => {
            "configure_events" => @role.can?(:configure_events, community: community)
          }
        }
      end

      private

      def models = @deps.models

      # DB rows plus the deployment-configured floor, which is owner-level in every community
      # and so counts once per community rather than once per deployment.
      def operator_count(community_id)
        models.operator.where(community_id: community_id).count + Security::ProtectedOperators.default.entries.size
      end

      # Administrator or nothing, matching require_admin! on the ERB route.
      # NotFound rather than Forbidden, the same non-disclosure the API
      # follows: a deployment-wide admin page must not confirm it is there to
      # a session that may not open it.
      def administrator!
        raise NotFound, "not found" unless @role.administrator?
      end

      # One prose section. The document is named here rather than anywhere a
      # request can reach, which is the whole of {Primitives::Prose}'s trust
      # model: nothing a caller sends decides which file is rendered.
      def prose(section, document, prefix)
        {
          "section" => section,
          "document" => document.to_s,
          "markup" => Primitives::Prose.markup(document, app_root: prefix.to_s)
        }
      end

      # A page path as the rest of this method expects it: leading slash, and
      # "/" for an empty one, so a caller that sends "" and one that sends "/"
      # get the same chrome.
      def normalise_path(path)
        given = path.to_s
        return "/" if given.empty?

        given.start_with?("/") ? given : "/#{given}"
      end

      # Which community a page path is about, resolved through the same scoped
      # lookup every section uses, so a slug outside this session's reach
      # gives chrome with no community in it rather than a name it may not
      # read. Only the slug segment of the path is ever read.
      def community_in(path)
        slug = path.to_s[%r{\A/communities/([^/]+)}, 1]
        return nil if slug.nil?

        readable_communities.where(slug: Rack::Utils.unescape(slug)).first
      end

      # The communities a scope switcher may offer, which is exactly the set
      # this session may open. A picker carrying the rest is a way into a
      # community the reader was just told they cannot read.
      def switchable_communities
        readable_communities.order(:slug).all
      end

      # The counts the nav catalogue attaches to an entry, keyed by the badge
      # name the entry declares. A count of zero is dropped by {Nav}, so a
      # quiet section carries no number at all.
      def badges(community)
        rows = { "pending_spaces" => @role.administrator? ? @deps.pending_spaces.pending.length : 0 }
        return rows if community.nil?

        rows.merge(
          "alerts" => models.alert.where(community_id: community.id, seen_at: nil).count,
          "webhook_failures" => @deps.webhooks.failed_count(community_id: community.id),
          "rooms" => (@deps.channel_discovery.unmapped(community).map(&:id) +
                      models.channel.where(community_id: community.id, suggested: true).select_map(:id)).uniq.length,
          "operator_requests" =>
            models.operator_request.where(community_id: community.id, state: "pending").count
        )
      end

      # The ordinary total each nav entry carries, keyed by the item's own
      # key rather than by a badge name: unlike {#badges} this is not an
      # attention flag, so a quiet section still gets a real zero instead of
      # nothing. Only the entries with a cheap, unambiguous count are here;
      # a section with no themed page of its own yet (Moderation, Platforms)
      # has nothing this can total honestly.
      def counts(community)
        return {} if community.nil?

        {
          "rooms" => community.rooms_dataset.count,
          "endpoints" => models.script_endpoint.where(community_id: community.id).count,
          "features" => models.feature_setting.where(community_id: community.id).count,
          "redirections" => community.redirections_dataset.count,
          "webhooks" => community.webhook_subscriptions_dataset.count,
          "files" => community.rehosted_files_dataset.count,
          "alerts" => models.alert.where(community_id: community.id).count,
          "operators" => operator_count(community.id)
        }
      end

      # The small figure block a chrome's context bar draws beside the
      # community it is currently open to: distinct platforms bridged in,
      # channels bridged, and operators, the same three the mockup's own
      # strip names.
      def community_stats(community)
        channels = models.channel.where(community_id: community.id)
        {
          "platforms" => channels.select_map(:adapter).uniq.length,
          "channels" => channels.count,
          "operators" => operator_count(community.id)
        }
      end

      # The community row for a slug, resolved against the communities this
      # session may read rather than against all of them. The scope is in the
      # query, so a slug outside it resolves to nothing and takes the same
      # {NotFound} path an invented slug takes.
      def community!(slug)
        row = readable_communities.where(slug: slug.to_s).first
        raise NotFound, "not found" if row.nil?

        row
      end

      # Every community this session may open, as a dataset to scope by. nil
      # from {Role#readable_community_ids} means the whole deployment, which is
      # an administrator or a deployment-wide viewer.
      def readable_communities
        ids = @role.readable_community_ids
        ids.nil? ? models.community : models.community.where(id: ids)
      end

      def authorize!(action, community)
        raise Forbidden, "forbidden" unless @role.can?(action, community: community)
      end

      def community_payload(community)
        {
          "slug" => community.slug,
          "name" => community.name,
          "status" => community.status,
          "created_at" => iso8601(community.created_at)
        }
      end

      # The community-wide who_can_set the nickname feature is configured
      # with, read the exact way Features::Nickname itself falls back, so the
      # people page never shows or enforces a policy the command would not.
      def nickname_who_can_set(community)
        entry = @deps.feature_controls.list(community, selector: "all").find { |row| row[:feature] == "nickname" }
        Features::Nickname.who_can_set(entry ? entry[:config] : {})
      end

      # The platforms a nickname could ever be shown on here: every adapter
      # this community actually bridges, the same set Features::Nickname's
      # own platform? check reads against.
      def bridged_platforms(community)
        community.channels_dataset.select_map(:adapter).uniq.sort
      end

      # One identity row plus one entry per other platform this community
      # bridges, each carrying whatever that person already holds there. Read
      # through the same ControlPlane::BridgedNicknames the write goes
      # through, so the page can never show a value it did not actually get
      # from that store.
      def person_row_payload(community, identity)
        person = @deps.bridged_nicknames.person_for_identity(
          community_id: community.id, adapter: identity.adapter, native_id: identity.native_id
        )
        held = person ? @deps.bridged_nicknames.for_person(community_id: community.id, person_id: person.id) : {}
        targets = (bridged_platforms(community) - [identity.adapter.to_s]).map do |adapter|
          { "adapter" => adapter, "nickname" => held[adapter] }
        end
        {
          "adapter" => identity.adapter,
          "native_id" => identity.native_id,
          "username" => identity.username,
          "display_name" => identity.display_name,
          "last_seen_at" => relative(identity.last_seen_at),
          "targets" => targets
        }
      end

      # One search result on the moderation page: no target platforms, since
      # this page never edits a nickname.
      def identity_row_payload(identity)
        {
          "adapter" => identity.adapter,
          "native_id" => identity.native_id,
          "username" => identity.username,
          "display_name" => identity.display_name
        }
      end

      # One active mute. Subject folds handle and native id into one string
      # and until folds a nil-or-Time into "permanent" or a formatted
      # timestamp, the same reason alerts folds mode into text: Table draws
      # one column as one string.
      def mute_row_payload(sanction)
        handle = sanction.subject_username.to_s.empty? ? nil : "@#{sanction.subject_username}"
        {
          "id" => sanction.id,
          "adapter" => sanction.adapter,
          "subject" => [handle, sanction.subject_native_id].compact.join(" · "),
          "until" => sanction.until_at ? Primitives::Format.timestamp(sanction.until_at) : "permanent"
        }
      end

      # One room's event policy row for the access table: whether the events
      # feature is on there and who may create one, the same read the events
      # ERB route already does through EventPolicy.
      # One open poll or scheduling session. The two are the same underlying
      # row told apart by its kind, which is why kind is a column rather than
      # two lists.
      def poll_payload(poll, room)
        {
          "id" => poll.id,
          "kind" => poll.schedule? ? "Scheduling" : "Poll",
          "question" => poll.question,
          "room" => room ? (room.label.to_s.empty? ? room.room_key : room.label) : nil,
          "closes_at" => iso8601(poll.closes_at),
          "options" => @deps.polls.options(poll).size,
          "votes" => models.poll_vote.where(poll_id: poll.id).count,
          "created_by" => poll.created_by
        }
      end

      def guest_room_access_payload(community, room)
        policy = @deps.guest_invites.room_policy(community: community, room: room)
        {
          "room_key" => room.room_key,
          "label" => room.label.to_s.empty? ? room.room_key : room.label,
          "allowed" => policy[:allowed],
          "status" => policy[:allowed] ? "allowed" : "not allowed",
          "status_tone" => policy[:allowed] ? "good" : "neutral",
          "who_can_invite" => policy[:who_can_invite]
        }
      end

      # One issued invite. The token itself never rides here: only the link the
      # create route just minted does, and only on the render right after it.
      def guest_invite_payload(invite, room)
        state = @deps.guest_invites.state_of(invite)
        {
          "id" => invite.id,
          "guest" => "#{invite.nickname}@#{Core::SenderLabel::GUEST_DOMAIN}",
          "room" => room ? (room.label.to_s.empty? ? room.room_key : room.label) : nil,
          "state" => state,
          "state_tone" => state == "live" ? "good" : "neutral",
          "live" => state == "live",
          "expires_at" => iso8601(invite.expires_at),
          "created_by" => invite.created_by
        }
      end

      def event_room_access_payload(community, room)
        policy = @deps.event_policy.room_policy(community: community, room: room)
        {
          "room_key" => room.room_key,
          "label" => room.label.to_s.empty? ? room.room_key : room.label,
          "enabled" => policy[:enabled],
          "who_can_create" => policy[:who_can_create]
        }
      end

      # One upcoming event. starts_at is pre-formatted with its timezone label
      # alongside it, and detail folds gaming's game/server pair or general's
      # link into the one column a Table cell can draw.
      def event_row_payload(event, room)
        starts = Primitives::Format.timestamp(event.starts_at)
        starts += " (#{event.timezone})" if presence(event.timezone)
        detail = if event.gaming?
                   [event.game_title, event.server_address].reject { |part| part.to_s.empty? }.join(" @ ")
                 else
                   event.url.to_s
                 end
        {
          "id" => event.id,
          "title" => event.title,
          "room" => room ? (room.label.to_s.empty? ? room.room_key : room.label) : nil,
          "starts_at" => starts,
          "kind" => event.kind,
          "detail" => detail,
          "rsvp_mode" => event.rsvp_mode
        }
      end

      # nil for a blank or absent value, mirroring App#presence: a query
      # parameter arrives as "" as often as it arrives absent, and both mean
      # the caller did not actually choose one.
      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # The scope selector options for a community: the community-wide
      # default plus every room, as {value:, label:} pairs, the same shape
      # App#scope_options builds for the ERB route this section is standing
      # in for.
      # One scope's join links, with a blank row on the end: the route zips
      # platform, label and url by index and drops any row with no url, so the
      # blank one is how a link is added and clearing a url is how one goes.
      def platform_link_scope(entry)
        rows = entry[:config]["platforms"]
        rows = [] unless rows.is_a?(Array)
        {
          "key" => entry[:key],
          "label" => entry[:label],
          "enabled" => entry[:enabled],
          "status" => entry[:enabled] ? "on" : "off",
          "status_tone" => entry[:enabled] ? "good" : "neutral",
          "rows" => rows.map { |row| platform_link_row(row) } + [platform_link_row({})]
        }
      end

      def platform_link_row(row)
        {
          "platform" => row["platform"].to_s,
          "label" => row["label"].to_s,
          "url" => redact_secret(row["url"])
        }
      end

      # A join URL is a credential of sorts, so only an administrator reads one
      # back off the page, matching the ERB view's own redaction.
      def redact_secret(value)
        return value.to_s if @role.administrator? || value.to_s.empty?

        "[redacted]"
      end

      # Each connection with its adapter and account, whether the key behind it
      # is present, the behaviour settings that adapter exposes, and the
      # channels riding on it.
      def platform_connection_rows(community, token_env_set)
        channels = models.channel.where(community_id: community.id).all.group_by(&:platform_connection_id)
        roomed = roomed_channel_ids(community)
        @deps.platform_connections.list(community: community).map do |connection|
          account = @deps.accounts.resolved(adapter: connection.adapter, name: connection.account)
          token_env = account && account.settings[:token_env]
          {
            "id" => connection.id,
            "adapter" => connection.adapter.to_s,
            "account" => connection.account.to_s,
            "external_id" => connection.external_id.to_s,
            "label" => connection.label.to_s,
            "token_env" => token_env.to_s,
            "token_known" => !account.nil?,
            "token_status" => token_env_set[token_env.to_s] ? "key present" : "dormant, waiting for key",
            "token_tone" => token_env_set[token_env.to_s] ? "good" : "warn",
            "behavior" => behavior_settings(connection, account),
            "behavior_note" => behavior_note(connection, account),
            "fetch_ceiling" => fetch_ceiling_for(connection, account),
            "channels" => (channels[connection.id] || []).sort_by { |row| row.endpoint_key.to_s }
                                                        .map { |row| channel_row_payload(row, roomed) }
          }
        end
      end

      # The largest file this connection's adapter can pull back off its own
      # platform, in bytes, or nil where the adapter draws no such distinction.
      # Mirrors the ERB dashboard's own helper of the same name; see
      # {Adapters::Base.max_fetch_bytes_for}.
      def fetch_ceiling_for(connection, account)
        adapter_class = account&.adapter_class || Adapters::Registry[connection.adapter]
        adapter_class&.max_fetch_bytes_for(account&.settings || {})
      end

      def roomed_channel_ids(community)
        room_ids = models.room.where(community_id: community.id).select_map(:id)
        return [] if room_ids.empty?

        models.room_channel.where(room_id: room_ids).select_map(:channel_id)
      end

      # Why a connection draws no behaviour form, or nil when it draws one.
      def behavior_note(connection, account)
        return "Behaviour settings need an account configured for this adapter first." if account.nil?
        return nil unless behavior_settings(connection, account).empty?

        "#{connection.adapter} has no editable behaviour settings yet."
      end

      # One connection's editable behaviour settings, each already resolved to
      # the control that fits its schema field: a select for a bounded set, a
      # toggle for a boolean (a checkbox submits nothing when unticked, which
      # would read as leave it alone rather than false), a number for a whole
      # number, text otherwise.
      def behavior_settings(connection, account)
        return [] if account.nil?

        fields = ControlPlane::PlatformConnections::BEHAVIOR_FIELDS.fetch(connection.adapter.to_sym, [])
        overrides = connection.json_value(:settings)
        schema = account.adapter_class&.account_schema
        fields.map do |name|
          field = schema&.fields&.[](name)
          value = if overrides.key?(name.to_s) then overrides[name.to_s]
                  else account.settings[name]
                  end
          behavior_setting_payload(name, field, value)
        end
      end

      def behavior_setting_payload(name, field, value)
        row = {
          "name" => name.to_s,
          "description" => field&.description.to_s,
          "value" => value.nil? ? "" : value.to_s,
          "options" => []
        }
        return row.merge("type" => "select", "options" => field.one_of.map(&:to_s)) if field&.one_of

        case field&.type
        when :boolean then row.merge("type" => "toggle", "value" => [true, "true"].include?(value).to_s)
        when :integer then row.merge("type" => "number")
        else row.merge("type" => "text")
        end
      end

      # One channel on a connection. A discovered row that is not in a room yet
      # is marked apart, so it is never read as a live, mapped one.
      def channel_row_payload(channel, roomed)
        discovered = channel.endpoint_key.to_s
                            .start_with?("#{ControlPlane::ChannelDiscovery::ENDPOINT_KEY_PREFIX}:")
        mapped = roomed.include?(channel.id)
        direction = [channel.receives ? "in" : nil, channel.sends ? "out" : nil].compact.join("+")
        puppet = puppet_status_payload(channel)
        {
          "endpoint_key" => channel.endpoint_key.to_s,
          "label" => channel.label.to_s,
          "route_key" => channel.route_key.to_s,
          "direction" => direction.empty? ? "off" : direction,
          "status" => channel_status(discovered, mapped),
          "status_tone" => discovered && !mapped ? "warn" : "good",
          "puppet_status" => puppet[:label],
          "puppet_status_tone" => puppet[:tone]
        }
      end

      def channel_status(discovered, mapped)
        return "live" unless discovered

        mapped ? "mapped" : "discovered, unmapped"
      end

      # Only Discord and Fluxer puppet a sender at all; every other adapter's
      # channel reads "n/a" rather than an unexplained "not yet observed".
      # Written by Core::PuppetStatusSweep off the live adapter's own webhook
      # cache (#1700), so a channel with no traffic since the last restart
      # reads "not yet observed" rather than a stale answer.
      PUPPET_CAPABLE_ADAPTERS = %w[discord fluxer].freeze

      PUPPET_STATUS_LABELS = {
        "active" => { label: "puppeting", tone: "good" },
        "degraded" => { label: "bot fallback (check Manage Webhooks)", tone: "warn" },
        "off" => { label: "off (webhook: off)", tone: "neutral" }
      }.freeze

      def puppet_status_payload(channel)
        return { label: "n/a", tone: "neutral" } unless PUPPET_CAPABLE_ADAPTERS.include?(channel.adapter.to_s)

        PUPPET_STATUS_LABELS.fetch(channel.puppet_status.to_s) { { label: "not yet observed", tone: "unknown" } }
      end

      def fluxer_instance_payload(instance, token_env_set)
        present = token_env_set[instance.api_key_env.to_s]
        {
          "id" => instance.id,
          "label" => instance.label.to_s,
          "kind" => instance.kind.to_s,
          "kind_label" => instance.kind.to_s == "flagship" ? "Flagship" : "Self-hosted",
          "self_hosted" => instance.kind.to_s != "flagship",
          "endpoint_url" => instance.endpoint_url.to_s,
          "api_key_env" => instance.api_key_env.to_s,
          "key_status" => present ? "key present" : "not set in this process",
          "key_tone" => present ? "good" : "warn"
        }
      end

      # Every grant, grouped the way the matrix draws it. Each row carries the
      # ticked state as the one-entry list the checklist control reads, since
      # the route behind it decides on the key being present at all.
      def permission_groups
        @deps.action_permissions.grouped_rows.map do |group, rows|
          {
            "group" => group,
            "rows" => rows.map do |row|
              {
                "action" => row[:action].to_s,
                "label" => row[:label],
                "allowed" => row[:operator_writable] ? ["1"] : []
              }
            end
          }
        end
      end

      # A requester named the way the page names one: whatever they are shown
      # as, with the native id underneath so two people with the same display
      # name are still told apart.
      def requester_label(display, username, native_id)
        shown = presence(display) || presence(username) || native_id.to_s
        presence(username) ? "#{shown} (@#{username})" : shown
      end

      def operator_request_payload(row)
        {
          "id" => row.id,
          "requester" => requester_label(row.requester_display, row.requester_username, row.requester_native_id),
          "native_id" => row.requester_native_id.to_s,
          "adapter" => row.adapter.to_s,
          "requested_at" => iso8601(row.requested_at)
        }
      end

      def community_viewer_request_payload(row)
        {
          "id" => row[:id],
          "requester" => requester_label(row[:requester_display], row[:requester_username],
                                         row[:requester_native_id]),
          "native_id" => row[:requester_native_id].to_s,
          "adapter" => row[:adapter].to_s,
          "requested_at" => iso8601(row[:requested_at])
        }
      end

      # The shipped floor first, then the rows an operator granted here. A
      # deployment-configured handle reads every community and cannot be taken away, so it
      # carries no id for a control to act on.
      def community_viewer_rows(community)
        baked_in = @deps.community_viewers.baked_in.map do |entry|
          {
            "id" => nil, "handle" => entry[:handle], "adapter" => baked_in_kind_label(entry[:kind]),
            "granted_at" => nil, "granted_by" => nil, "removable" => false,
            "note" => "ships with the deployment, reads every community"
          }
        end
        baked_in + @deps.community_viewers.granted(community_id: community.id).map do |row|
          {
            "id" => row[:id],
            "handle" => presence(row[:label]) ? "#{row[:handle]} (#{row[:label]})" : row[:handle],
            "adapter" => row[:adapter].to_s, "granted_at" => iso8601(row[:granted_at]),
            "granted_by" => row[:granted_by].to_s, "removable" => true, "note" => ""
          }
        end
      end

      # How a deployment-configured floor entry's kind reads: an id-based kind names its
      # platform, matrix reads as an MXID, a bare username is left alone.
      def baked_in_kind_label(kind)
        case kind.to_s
        when "matrix" then "Matrix ID"
        when "telegram_id" then "Telegram ID"
        when "discord_id" then "Discord ID"
        else "username"
        end
      end

      def auth_token_row_payload(row)
        {
          "public_id" => row[:public_id].to_s,
          "label" => presence(row[:label]) || "unlabelled",
          "grants" => @deps.auth_tokens.grant_words(row),
          "state" => @deps.auth_tokens.state_of(row),
          "state_tone" => @deps.auth_tokens.live?(row) ? "good" : "neutral",
          "live" => @deps.auth_tokens.live?(row),
          "expires_at" => iso8601(row[:expires_at]),
          "created_by" => row[:created_by].to_s
        }
      end

      # The operator accounts a DM was last refused at, so the screen can say
      # the audience is smaller than the operator list makes it look.
      def unreachable_operator_rows(community)
        @deps.operator_reachability.unreachable(community_id: community.id).map do |entry|
          {
            "person" => entry[:person] || "person ##{entry[:person_id]}",
            "adapter" => entry[:adapter].to_s, "native_id" => entry[:native_id].to_s,
            "refused_at" => iso8601(entry[:refused_at]), "reason" => entry[:reason].to_s
          }
        end
      end

      # The always-operators fail-safe first, then this community's own rows.
      # The floor is code-owned and owner-level in every community, so it
      # carries no id either.
      def operator_rows(community)
        baked_in = Security::ProtectedOperators.default.entries.map do |entry|
          {
            "id" => nil, "person" => entry[:handle], "kind" => baked_in_kind_label(entry[:kind]),
            "actions" => "all", "scope" => "all", "granted_at" => nil, "granted_by" => nil,
            "removable" => false
          }
        end
        baked_in + models.operator.where(community_id: community.id).order(:id).all.map do |row|
          person = models.person[row.person_id]
          {
            "id" => row.id, "person" => person&.name || "person ##{row.person_id}",
            "kind" => "", "actions" => row.actions.to_s, "scope" => row.scope.to_s,
            "granted_at" => iso8601(row.granted_at), "granted_by" => row.granted_by.to_s,
            "removable" => true
          }
        end
      end

      # The eleven reports the analytics screen draws, in the order it draws
      # them. Each one is a title, whether the datastore can answer it at all,
      # its StatRow triples and its charts, so the screen walks a list rather
      # than carrying eleven near-identical blocks of its own.
      def analytics_reports(report, channel_view)
        messages = report[:messages]
        moderation = report[:moderation]
        members = report[:members]
        [
          analytics_messages(messages, channel_view),
          analytics_moderation(moderation),
          {
            "id" => "members", "title" => "Active senders", "available" => true,
            "stats" => [[members[:active], "active in window"],
                        [members[:new_in_window], "first seen in window"],
                        [members[:total], "known senders"]],
            "charts" => [analytics_chart("Active senders by platform", members[:by_platform],
                                         "No senders seen in this window.")]
          },
          analytics_reactions(report[:reactions]),
          analytics_guests(report[:guests]),
          analytics_safety(report[:warnings], report[:sanctions]),
          analytics_events(report[:events]),
          analytics_multiposts(report[:multiposts]),
          analytics_onboarding(report[:onboarding]),
          analytics_operator_requests(report[:operator_requests]),
          analytics_model_calls(report[:model_calls])
        ]
      end

      # What the model-backed features cost, and what is queued for them now.
      # A community that has never run one reads as nothing recorded rather
      # than as a row of zeroes, the way every other absent panel here does.
      def analytics_model_calls(figures)
        if !figures[:available] || (figures[:features].to_a.empty? && figures[:queue].to_a.empty?)
          return analytics_absent("model_calls", "Model-backed features",
                                  "Nothing has been recorded for the model-backed features here yet.")
        end

        {
          "id" => "model_calls", "title" => "Model-backed features", "available" => true,
          "note" => MODEL_CALL_NOTE,
          "stats" => model_call_stats(figures), "charts" => model_call_charts(figures)
        }
      end

      # Totals first, the endpoint's own health where there is something to
      # say, then how long each feature takes and what is waiting.
      def model_call_stats(figures)
        totals = figures[:totals] || {}
        [[totals[:calls].to_i, "checks in window"],
         [totals[:failures].to_i, "calls that failed", "#{totals[:retries].to_i} asked again"],
         [totals[:unusable].to_i, "answers not usable as a decision", "the call worked, the shape did not"],
         [totals[:truncated].to_i, "answers cut short", "the budget ran out first"],
         [totals[:discarded].to_i, "jobs dropped as stale", "queued past their own age limit"]] +
          model_call_endpoint_rows(figures) + model_call_speeds(figures) + model_call_queue(figures)
      end

      # These features share one endpoint, so every one of them failing every
      # call is a statement about the endpoint rather than about any of them.
      # Drawn only when that is true, since a healthy window has nothing to add
      # here, and it points at the page that can say whether the endpoint
      # answers rather than restating the failure count above.
      def model_call_endpoint_rows(figures)
        ran = Array(figures[:features]).select { |feature| feature[:calls].to_i.positive? }
        return [] if ran.empty? || ran.any? { |feature| feature[:failures].to_i < feature[:calls].to_i }

        [[ran.length, "features failing every call", "one shared endpoint; Integrations says whether it answers"]]
      end

      def model_call_speeds(figures)
        Array(figures[:features]).filter_map do |feature|
          next nil if feature[:median].nil?

          [feature[:median], "#{feature[:label]}, median", "p95 #{feature[:slowest]}"]
        end
      end

      def model_call_queue(figures)
        Array(figures[:queue]).map do |row|
          [row[:depth], "#{row[:label]}, waiting now", model_call_wait(row[:oldest_seconds])]
        end
      end

      def model_call_wait(seconds)
        return nil if seconds.nil?

        "oldest waiting #{ControlPlane::ModelCallStats.duration_label(seconds.to_i * 1000)}"
      end

      # Volume and outcome across the features, then one response time
      # distribution per feature, since their shapes differ too much to read as
      # one figure.
      def model_call_charts(figures)
        features = Array(figures[:features])
        [analytics_chart("Checks by feature", model_call_volume(features), "No checks in this window."),
         analytics_chart("What happened to the checks", model_call_outcomes(figures[:totals] || {}),
                         "No checks in this window."),
         analytics_chart("Token budget and what was generated", model_call_tokens(features),
                         "No tokens counted in this window.")] +
          features.filter_map { |feature| model_call_latency_chart(feature) }
      end

      def model_call_volume(features)
        features.map { |feature| { label: feature[:label], count: feature[:calls].to_i } }
      end

      def model_call_outcomes(totals)
        answered = totals[:calls].to_i - totals[:failures].to_i
        [{ label: "Answered", count: answered }, { label: "Failed", count: totals[:failures].to_i },
         { label: "Not usable", count: totals[:unusable].to_i },
         { label: "Asked again", count: totals[:retries].to_i },
         { label: "Cut short", count: totals[:truncated].to_i },
         { label: "Dropped as stale", count: totals[:discarded].to_i }]
      end

      # A feature that answered nothing has no tokens to compare, so it is left
      # out rather than drawn as a pair of empty bars.
      def model_call_tokens(features)
        features.flat_map do |feature|
          budget = feature[:budget_tokens].to_i
          next [] unless budget.positive?

          [{ label: "#{feature[:label]}, budget", count: budget },
           { label: "#{feature[:label]}, generated", count: feature[:used_tokens].to_i }]
        end
      end

      def model_call_latency_chart(feature)
        rows = Array(feature[:latency])
        return nil if rows.empty?

        analytics_chart("Response time, #{feature[:label].downcase}", rows, "Nothing timed yet.")
          .merge("limit" => rows.length)
      end

      def analytics_messages(messages, channel_view)
        unless messages[:available]
          return analytics_absent("messages", "Message volume",
                                  "Message volume is unavailable: this datastore has no message map yet. " \
                                  "It appears once the bot has relayed on this connection.")
        end

        by_channel = channel_view == "room" ? messages[:by_room] : messages[:by_channel]
        channel_title = channel_view == "room" ? "Relayed messages by room" : "Relayed messages by channel"
        {
          "id" => "messages", "title" => "Message volume", "available" => true,
          "note" => "Relayed messages per hour. The message map is derived state kept for about " \
                    "#{messages[:retention_hours]} hours, so volume only looks back a day whatever " \
                    "window is selected above.",
          "stats" => [[messages[:total], "relayed messages (last #{messages[:retention_hours]}h)"]],
          "charts" => [
            analytics_series("Relayed messages per hour", messages[:series]),
            analytics_chart(channel_title, by_channel, "No relayed messages in the last day.")
              .merge("tabs" => "channel_view"),
            analytics_chart("Relayed messages by platform", messages[:by_platform],
                            "No relayed messages in the last day."),
            analytics_chart("Busiest hours", messages[:busiest_hours], "No relayed messages in the last day.")
          ]
        }
      end

      def analytics_moderation(moderation)
        {
          "id" => "moderation", "title" => "Moderation activity", "available" => true,
          "note" => "Moderation actions over time, from the audit log.",
          "stats" => [[moderation[:total], "actions in window"]],
          "charts" => [
            analytics_series("Moderation actions per hour", moderation[:series]),
            analytics_chart("Moderation by action", moderation[:by_action], "No moderation actions in this window."),
            analytics_chart("Moderation by source", moderation[:by_source], "No moderation actions in this window."),
            analytics_chart("Moderation by platform", moderation[:by_platform],
                            "No moderation actions in this window."),
            analytics_chart("Moderation by channel", moderation[:by_channel], "No moderation actions in this window.")
          ]
        }
      end

      def analytics_reactions(reactions)
        unless reactions[:available]
          return analytics_absent("reactions", "Reactions", "Reaction activity is unavailable on this datastore.")
        end

        {
          "id" => "reactions", "title" => "Reactions", "available" => true,
          "stats" => [[reactions[:total], "live reactions (last #{reactions[:retention_hours]}h)"]],
          "charts" => [analytics_chart("Top reactions", reactions[:by_emoji], "No reactions in the last day.")]
        }
      end

      def analytics_guests(guests)
        {
          "id" => "guests", "title" => "Guest portal", "available" => true,
          "stats" => [[guests[:active], "active invites"],
                      [guests[:issued_in_window], "issued in window"],
                      [guests[:redeemed_in_window], "redeemed in window"],
                      ["#{guests[:redemption_rate]}%", "redemption rate"],
                      ["#{guests[:average_session_minutes]}m", "average session"],
                      [guests[:total], "invites all time"]],
          "charts" => []
        }
      end

      def analytics_safety(warnings, sanctions)
        unless warnings[:available] && sanctions[:available]
          return analytics_absent("safety", "Warnings and sanctions",
                                  "Warnings and sanctions are unavailable on this datastore.")
        end

        {
          "id" => "safety", "title" => "Warnings and sanctions", "available" => true,
          "stats" => [[warnings[:total], "warnings issued in window"],
                      [warnings[:active], "active warnings"],
                      ["#{warnings[:repeat_offender_rate]}%", "repeat-offender rate"],
                      [sanctions[:active], "active sanctions"]],
          "charts" => [
            analytics_chart("Warnings by platform", warnings[:by_platform], "No warnings in this window."),
            analytics_chart("Active sanctions by action", sanctions[:by_action], "No active sanctions.")
          ]
        }
      end

      def analytics_events(events)
        return analytics_absent("events", "Events", "Events are unavailable on this datastore.") unless events[:available]

        {
          "id" => "events", "title" => "Events", "available" => true,
          "stats" => [[events[:created], "created in window"],
                      [events[:upcoming], "upcoming scheduled"],
                      [events[:attendance], "positive RSVPs"]],
          "charts" => [
            analytics_chart("Events by kind", events[:by_kind], "No events yet."),
            analytics_chart("RSVP responses", events[:rsvps], "No RSVPs yet.")
          ]
        }
      end

      def analytics_multiposts(multiposts)
        unless multiposts[:available]
          return analytics_absent("multiposts", "Multipost watchdog",
                                  "Multipost aggregates are unavailable on this datastore.")
        end

        {
          "id" => "multiposts", "title" => "Multipost watchdog", "available" => true,
          "stats" => [[multiposts[:detections],
                       "cross-channel fingerprints (last #{multiposts[:retention_hours]}h)"]],
          "charts" => [analytics_chart("Multipost fingerprints by channel", multiposts[:by_channel],
                                       "No multipost fingerprints in the last day.")]
        }
      end

      def analytics_onboarding(onboarding)
        unless onboarding[:available]
          return analytics_absent("onboarding", "Onboarding",
                                  "Pending-space onboarding is unavailable on this datastore.")
        end

        {
          "id" => "onboarding", "title" => "Onboarding", "available" => true,
          "stats" => [[onboarding[:pending], "pending spaces"],
                      [onboarding[:approved], "approved in window"],
                      [onboarding[:denied], "denied in window"],
                      ["#{onboarding[:approval_rate]}%", "approval rate"]],
          "charts" => [analytics_chart("Spaces by platform", onboarding[:by_platform], "No reviewed spaces yet.")]
        }
      end

      def analytics_operator_requests(requests)
        unless requests[:available]
          return analytics_absent("operator_requests", "Operator requests",
                                  "Operator request metrics are unavailable on this datastore.")
        end

        {
          "id" => "operator_requests", "title" => "Operator requests", "available" => true,
          "stats" => [[requests[:pending], "pending requests"],
                      [requests[:decided], "decided in window"],
                      ["#{requests[:average_minutes]}m", "average decision time"]],
          "charts" => []
        }
      end

      def analytics_absent(id, title, reason)
        { "id" => id, "title" => title, "available" => false, "reason" => reason, "stats" => [], "charts" => [] }
      end

      # A categorical breakdown as the Chart primitive's own rows.
      def analytics_chart(title, rows, empty)
        {
          "title" => title, "shape" => "categorical_distribution", "empty" => empty,
          "rows" => Array(rows).map { |row| { "label" => row[:label].to_s, "count" => row[:count].to_i } }
        }
      end

      # A time-bucketed series, its bucket start already turned into the label
      # a reader sees so no raw timestamp travels as a chart label.
      def analytics_series(title, series)
        rows = Array(series).map do |point|
          { "label" => analytics_bucket_label(point), "count" => point[:count].to_i }
        end
        {
          "title" => title, "shape" => "time_series", "empty" => "No activity in this window.",
          "limit" => rows.length, "rows" => rows
        }
      end

      def analytics_bucket_label(point)
        at = point[:at]
        return at.to_s unless at.respond_to?(:strftime)

        point[:step] == 3600 ? at.strftime("%H:00") : at.strftime("%b %-d")
      end

      # One row of the recency list. The identity directory records who was
      # seen and when, never a message count, so this is recency and the
      # screen says as much beside it.
      def sender_row_payload(row)
        {
          "adapter" => row[:adapter].to_s,
          "username" => row[:username].to_s,
          "display_name" => row[:display_name].to_s,
          "last_seen_at" => iso8601(row[:last_seen_at])
        }
      end

      def scope_options(community)
        rooms = models.room.where(community_id: community.id).order(:room_key).all
        [{ "value" => "all", "label" => "all" }] + rooms.map do |room|
          { "value" => room.room_key, "label" => room.label.to_s.empty? ? room.room_key : room.label }
        end
      end

      # Appearance tokens as the value and label pairs a select is built from.

      # Every known feature at one scope, decorated for display: a display
      # name and category from {FeatureDisplay}, and file_rehosting
      # expanded into its two split rows (see #feature_display_rows). A
      # feature with no feature_settings row runs at its code default: off,
      # except the bridge (the always-on relay). identify_topic and
      # disabled_command_notice run unconditionally too ("locked" => true),
      # so the theme draws them as always on rather than a toggle
      # {Features::Pipeline#enabled?} never reads.
      def feature_rows(community, scope)
        configured = @deps.feature_controls.list(community, selector: scope)
                          .each_with_object({}) { |entry, memo| memo[entry[:feature]] = entry }
        rows = Features::Catalog.dashboard_names.flat_map do |name|
          entry = configured[name]
          config = entry ? entry[:config] : {}
          locked = Features::Catalog.class_for(name)&.always_enabled? == true
          enabled = locked || (entry ? truthy?(entry[:enabled]) : (name == "bridge"))
          feature_display_rows(name, config, locked, enabled)
        end
        # Catalog.dashboard_names is pipeline order, meaningful for the router
        # but not for an operator scanning a list: alphabetise by the label
        # actually shown, here at the display boundary only.
        rows.sort_by { |row| row["label"] }
      end

      # One catalog feature's own row(s): file_rehosting becomes its two
      # split rows (File Rehosting, File Uploads), sharing its feature_config
      # and each reading only its own key; anything else stays one row.
      def feature_display_rows(name, config, locked, enabled)
        base = {
          "feature" => name,
          "description" => Features::Catalog.description(name),
          "locked" => locked,
          "configurable" => !Features::Catalog.config_schema(name).nil?,
          "config_pairs" => config_pairs(config),
          "bespoke_path" => FeatureDisplay.bespoke_config_page(name)
        }
        unless name == Features::FileRehosting.feature_name
          return [base.merge("label" => FeatureDisplay.name_for(name),
                              "category" => FeatureDisplay.category_for(name)&.to_s,
                              "toggle_key" => nil, "enabled" => enabled)]
        end

        FeatureDisplay::FILE_REHOSTING_SPLIT.map { |split| file_rehosting_split_row(base, config, enabled, split) }
      end

      # +split+'s own half of file_rehosting's row: enabled only when the
      # feature itself is, AND this half's own config boolean is (defaulting
      # true, see Features::FileRehosting#config_schema).
      def file_rehosting_split_row(base, config, enabled, split)
        active = case split[:key]
                 when "rehost_inbound" then Features::FileRehosting.rehost_inbound?(config)
                 when "enable_upload_command" then Features::FileRehosting.upload_command_enabled?(config)
                 end
        base.merge("label" => split[:display], "category" => split[:category]&.to_s, "description" => split[:description],
                   "toggle_key" => split[:key], "enabled" => enabled && active)
      end

      # Every scope one feature can be set at, whether or not it has a row of
      # its own: the community-wide default first, then one per room. A room
      # with no row resolves exactly the way {ControlPlane::Snapshot} resolves
      # it at runtime, so what a scope shows is what the bot acts on.
      def feature_matrix(community, feature)
        rows = @deps.feature_controls.list(community).select { |entry| entry[:feature] == feature }
        default = rows.find { |entry| entry[:scope] == :community }
        by_room = rows.each_with_object({}) { |entry, out| out[entry[:room_key].to_s] = entry }
        rooms = models.room.where(community_id: community.id).order(:room_key).all
        [feature_matrix_row("all", "all", default, nil)] + rooms.map do |room|
          label = room.label.to_s.empty? ? room.room_key : room.label
          feature_matrix_row(room.room_key, label, by_room[room.room_key.to_s], default)
        end
      end

      def feature_matrix_row(key, label, row, default)
        {
          key: key, label: label, community: key == "all", configured: !row.nil?,
          enabled: (row || default)&.fetch(:enabled) || false,
          config: merge_feature_config(default ? default[:config] : {}, row ? row[:config] : {})
        }
      end

      # Community config under room config, the same deep merge
      # {ControlPlane::Snapshot} does, so the mode a room shows is the mode it
      # actually runs under.
      def merge_feature_config(base, overlay)
        base.to_h.merge(overlay.to_h) do |_key, a, b|
          a.is_a?(Hash) && b.is_a?(Hash) ? merge_feature_config(a, b) : b
        end
      end

      # The word filter's mode choices, value and operator-facing label, in
      # the order the select lists them.
      WORD_FILTER_MODES = [
        ["off", "Off"],
        ["slurs", "Slurs only"],
        ["slurs_profanity", "Slurs + profanity"]
      ].freeze

      def word_filter_scope(entry)
        config = entry[:config]
        {
          "key" => entry[:key],
          "label" => entry[:label],
          "community" => entry[:community],
          "configured" => entry[:configured],
          "enabled" => entry[:enabled],
          "status_tone" => entry[:enabled] ? "good" : "neutral",
          "status" => entry[:enabled] ? "on" : "off",
          "follows_default" => !entry[:community] && !entry[:configured],
          "mode" => Features::WordFilter.resolve_mode(config),
          "action" => config["action"].to_s.empty? ? "delete" : config["action"].to_s,
          "exempt_operators" => exempt_operators?(config),
          "custom" => entries_as_lines(config, "custom")
        }
      end

      # Whether operators are filtered at this scope. Exempt by default, which
      # is also why somebody testing the filter on their own messages sees
      # nothing happen.
      def exempt_operators?(config)
        raw = config["exempt_operators"]
        raw.nil? ? true : !%w[false 0 no off].include?(raw.to_s.strip.downcase)
      end

      # A feature config's entry list one per line, so a textarea shows what
      # is there without the JSON scaffolding around it.
      def entries_as_lines(config, key)
        entries = config[key]
        return "" unless entries.is_a?(Array)

        entries.map do |entry|
          entry.is_a?(Hash) ? (entry["pattern"] || entry["keyword"] || entry["command"]).to_s : entry.to_s
        end.join("\n")
      end

      def faq_scope(entry)
        entries = entry[:config]["entries"]
        entries = [] unless entries.is_a?(Array)
        {
          "key" => entry[:key],
          "label" => entry[:label],
          "community" => entry[:community],
          "configured" => entry[:configured],
          "enabled" => entry[:enabled],
          "status_tone" => entry[:enabled] ? "good" : "neutral",
          "status" => entry[:enabled] ? "on" : "off",
          "follows_default" => !entry[:community] && !entry[:configured],
          "entry_count" => entries.length,
          "entries" => entries.map { |row| faq_entry_payload(row) }
        }
      end

      def faq_entry_payload(entry)
        command = entry["command"].to_s
        {
          "id" => entry["id"].to_s,
          "trigger" => command.empty? ? "keyword: #{entry['keyword'] || entry['pattern']}" : "command: #{command}",
          "response" => entry["response"].to_s
        }
      end

      # A feature's config as [label, value, format] triples ready for the
      # KeyValues primitive. An empty config yields no rows at all, since
      # the caller already knows to draw nothing rather than a "Defaults"
      # placeholder in that case.
      def config_pairs(config)
        return [] unless config.is_a?(Hash)

        config.map { |key, value| config_pair(key, value) }
      end

      def config_pair(key, value)
        label = ConfigHumanizer.humanize_key(key)
        case value
        when true, false
          { "label" => label, "value" => value, "format" => "boolean" }
        when Numeric
          { "label" => label, "value" => value, "format" => (ConfigHumanizer.duration_key?(key) ? "duration" : "text") }
        when Array
          config_pair_array(label, key, value)
        when Hash
          { "label" => label, "value" => (value.empty? ? "none" : ConfigHumanizer.scalar_text(value)), "format" => "text" }
        when nil
          { "label" => label, "value" => "not set", "format" => "text" }
        else
          { "label" => label, "value" => value.to_s, "format" => "text" }
        end
      end

      # A list-valued config entry: a run of raw second counts ships as
      # "durations" so the client's own Format.duration draws each one. A
      # run of Hashes (bridge's timestamp_timezones) has no Format case to
      # reach for, so it is flattened to chip text here the same way
      # ConfigHumanizer.chip_text does for the ERB page.
      def config_pair_array(label, key, value)
        return { "label" => label, "value" => "none", "format" => "text" } if value.empty?
        return { "label" => label, "value" => value, "format" => "durations" } if duration_array?(key, value)
        if value.any? { |item| item.is_a?(Hash) }
          return { "label" => label, "value" => value.map { |item| ConfigHumanizer.chip_text(item) }, "format" => "text" }
        end
        return { "label" => label, "value" => value, "format" => "boolean" } if value.all? { |item| [true, false].include?(item) }

        { "label" => label, "value" => value, "format" => "text" }
      end

      def duration_array?(key, value)
        ConfigHumanizer.duration_key?(key) && value.all? { |item| item.is_a?(Numeric) }
      end

      # An accepted duration string a schema field's own placeholder used to
      # carry in the ERB input, folded into the hint instead since Field has
      # no placeholder of its own.
      DURATION_FIELD_HINT = "accepts 24h, 90m, or a plain number of seconds"

      # One config_schema field, as a themed Field draws it: type chosen the
      # same way _config_fields.erb's own <% if %>/<% elsif %> chain picks a
      # control, boolean first, mapped onto :toggle rather than a bare
      # checkbox. A checkbox that submits nothing when unticked has already
      # caused a bug once, and Field's own :toggle (a Yes/No select) is the
      # primitive vocabulary's answer to that, not something re-decided here.
      def field_payload(field, config, feature = nil)
        type = primitive_field_type(field)
        payload = {
          "name" => field.name.to_s,
          "label" => ConfigHumanizer.humanize_key(field.name),
          "type" => type,
          "size" => primitive_field_size(type),
          "value" => field_value(field, config),
          "options" => (field.one_of ? field.one_of.map(&:to_s) : nil),
          "hint" => field_hint(field),
          "required" => field.required ? true : false
        }.merge(field_bounds(field))
        entry_schema = mapping_entry_schema(field)
        return payload if entry_schema.nil?

        payload.merge(
          "entry_fields" => entry_schema.fields.each_value.map { |entry| mapping_entry_field_payload(entry) },
          "entry_variant" => (field.variants ? "string_or_mapping" : "mapping"),
          "entry_presets" => Dashboard::FeatureDisplay.field_presets(feature, field.name)
        )
      end

      # What a number control may hold and how finely it moves, from the schema
      # rather than guessed per type. Absent for every other control, and for a
      # number the schema said nothing about, so nothing here invents a bound.
      def field_bounds(field)
        return {} unless %i[integer float].include?(field.type)

        bounds = {}
        bounds["min"] = field.range.first unless field.range.nil?
        bounds["max"] = field.range.last unless field.range.nil?
        # A float with no declared step still needs one: the browser's default
        # of 1 makes any fractional value invalid and steps it off its scale.
        step = field.step || (field.type == :float ? "any" : nil)
        bounds["step"] = step unless step.nil?
        bounds
      end

      def primitive_field_type(field)
        return "toggle" if field.type == :boolean
        return "select" if field.one_of
        return "mapping-list" if mapping_entry_schema(field)
        return "multiline" if field.type == :array || field.multiline
        return "number" if %i[integer float].include?(field.type)

        "text"
      end

      # Short for a compact control (several fit on one row, which is the fix
      # for the ERB page's own checkbox pile-up: four boolean toggles now sit
      # side by side instead of stacking one per line); full for a list,
      # which needs the row to itself; medium otherwise.
      def primitive_field_size(type)
        case type
        when "toggle", "number", "select" then "short"
        when "multiline", "mapping-list" then "full"
        else "medium"
        end
      end

      def mapping_entry_schema(field)
        return nil unless field.type == :array
        return field.schema unless field.schema.nil?

        Array(field.variants).find { |variant| variant.is_a?(Config::Schema) }
      end

      def mapping_entry_field_payload(field)
        type = primitive_field_type(field)
        {
          "name" => field.name.to_s,
          "label" => ConfigHumanizer.humanize_key(field.name),
          "type" => type,
          "size" => primitive_field_size(type),
          "default" => field.default,
          "options" => (field.one_of ? field.one_of.map(&:to_s) : nil),
          "hint" => field_hint(field),
          "required" => field.required ? true : false
        }.merge(field_bounds(field))
      end

      def field_value(field, config)
        key = field.name.to_s
        config.key?(key) ? config[key] : field.default
      end

      # Whole, however long the schema's description is: cutting here is a cut
      # every theme inherits with no way back to the rest, and the Field
      # primitive is where the display limit belongs.
      def field_hint(field)
        text = field.description.to_s.strip
        text = text.empty? ? DURATION_FIELD_HINT : "#{text} (#{DURATION_FIELD_HINT})" if field.type == :duration
        return nil if text.empty?

        text
      end

      # A room and what is mapped into it. The community is written into the
      # channel query as well as being implied by the join, since room_channels
      # could in principle carry a row from somewhere else and a room_key is
      # unique only within one community.
      def room_payload(community, room)
        channels = room.channels_dataset.where(community_id: community.id).order(:adapter, :account).all
        {
          "room_key" => room.room_key,
          "label" => room.label,
          "channels" => channels.map { |channel| channel_payload(channel) }
        }
      end

      def room_board_payload(community, room)
        channels = room.channels_dataset.where(community_id: community.id).order(:adapter, :account).all
        {
          "room_key" => room.room_key,
          "label" => room.label,
          "name" => room_name(room),
          "channel_count" => channels.length,
          "platforms" => channels.map(&:adapter).uniq.sort.join(", "),
          "channels" => channels.map { |channel| channel_payload(channel) }
        }
      end

      def automatic_mapping_payload(proposal)
        channel = proposal.channel
        action = proposal.bind? ? "Bind to #{proposal.room_label}" : "Create #{proposal.room_label}"
        {
          "endpoint_key" => channel.endpoint_key,
          "channel" => room_board_channel_name(channel, proposed: truthy?(channel.suggested)),
          "platform" => "#{channel.adapter} / #{channel.account}",
          "action" => action,
          "room_key" => proposal.room_key,
          "reason" => proposal.reason
        }
      end

      def room_memberships(community, channel)
        room_ids = models.room_channel.where(channel_id: channel.id).select_map(:room_id)
        return [] if room_ids.empty?

        community.rooms_dataset.where(id: room_ids).order(:room_key).all
      end

      def room_member_rows(community, room)
        room.channels_dataset.where(community_id: community.id).order(:adapter, :account, :route_key).all.map do |channel|
          rooms = room_memberships(community, channel)
          row = room_board_channel_payload(channel, rooms)
          row.slice("id", "channel", "platform", "state", "state_tone")
        end
      end

      def room_board_channel_payload(channel, rooms)
        proposed = truthy?(channel.suggested)
        named = !channel.label.to_s.strip.empty?
        room = rooms.first
        mapped = !room.nil?
        filter_states = []
        filter_states << "unroomed" unless mapped
        filter_states << "unnamed" unless named
        filter_states << "suggested" if proposed
        state, tone = room_board_channel_state(mapped: mapped, named: named, proposed: proposed)
        {
          "id" => channel.id,
          "endpoint_key" => channel.endpoint_key,
          "adapter" => channel.adapter,
          "account" => channel.account,
          "route_key" => channel.route_key,
          "channel" => room_board_channel_name(channel, proposed: proposed),
          "platform" => "#{channel.adapter} / #{channel.account}",
          "room" => room_board_room_label(room, rooms.length),
          "room_key" => room&.room_key,
          "state" => state,
          "state_tone" => tone,
          "filter_states" => filter_states,
          "suggested" => proposed,
          "mapped" => mapped
        }
      end

      def room_board_state(state)
        %w[all unroomed unnamed suggested].include?(state.to_s) ? state.to_s : "all"
      end

      def room_board_counts(rows)
        {
          "all" => rows.length,
          "unroomed" => rows.count { |row| row["filter_states"].include?("unroomed") },
          "unnamed" => rows.count { |row| row["filter_states"].include?("unnamed") },
          "suggested" => rows.count { |row| row["filter_states"].include?("suggested") }
        }
      end

      def room_board_channel_state(mapped:, named:, proposed:)
        return ["Needs a room", "bad"] unless mapped
        return ["Name needs approval", "warn"] if proposed
        return ["Unnamed", "neutral"] unless named

        ["Ready", "good"]
      end

      def room_board_channel_name(channel, proposed:)
        name = channel.label.to_s.strip
        if name.empty?
          native_id = channel.route_key.to_s.split("/").last
          noun = channel.adapter.to_s == "telegram" && channel.route_key.to_s.include?("/") ? "topic" : "channel"
          name = "#{channel.adapter.to_s.capitalize} #{noun} #{native_id}"
        end
        proposed ? "#{name} (proposed)" : name
      end

      def room_board_room_label(room, room_count)
        return "Not in a room" if room.nil?

        suffix = if room_count > 1
                   "#{room_count} rooms"
                 else
                   members = room.channels_dataset.count
                   members == 1 ? "only this one" : "#{members} channels"
                 end
        "#{room_name(room)}, #{suffix}"
      end

      def room_name(room)
        label = room.label.to_s.strip
        label.empty? ? room.room_key : label
      end

      def channel_payload(channel)
        {
          "endpoint_key" => channel.endpoint_key,
          "adapter" => channel.adapter,
          "account" => channel.account,
          "route_key" => channel.route_key,
          "label" => channel.label,
          "receives" => truthy?(channel.receives),
          "sends" => truthy?(channel.sends)
        }
      end

      # One endpoint row, timeout_seconds left as a raw integer on purpose:
      # Format.duration on the client is what turns it into "5s" rather than
      # this handing over a string the table's :duration column format
      # would then have to un-format.
      def endpoint_payload(row)
        {
          "id" => row.id,
          "name" => row.name,
          "http_method" => row.http_method,
          "url" => row.url,
          "description" => row.description.to_s,
          "enabled" => truthy?(row.enabled),
          "enabled_tone" => truthy?(row.enabled) ? "good" : "neutral",
          "timeout_seconds" => row.timeout_seconds
        }
      end

      # Header values do not share the list's payload because viewers may read
      # endpoint oversight without being allowed to read credentials. The
      # existing server form gives administrators the real value and everyone
      # else one redacted marker; the internal surface keeps that boundary.
      def endpoint_form_payload(row)
        return {
          "id" => nil, "name" => "", "http_method" => "GET", "description" => "", "url" => "",
          "query_params" => "", "headers" => "", "timeout_seconds" => 2, "enabled" => true
        } if row.nil?

        {
          "id" => row.id,
          "name" => row.name,
          "http_method" => row.http_method,
          "description" => row.description.to_s,
          "url" => row.url,
          "query_params" => ControlPlane::ScriptEndpoints.pairs_to_lines(row.query_params),
          "headers" => endpoint_headers(row),
          "timeout_seconds" => row.timeout_seconds,
          "enabled" => truthy?(row.enabled)
        }
      end

      def endpoint_headers(row)
        return "[redacted]" unless @role.administrator?

        ControlPlane::ScriptEndpoints.headers_to_lines(row.headers)
      end

      # A room's on-screen name: its configured label where one is set, the
      # raw room_key otherwise, title-cased either way. Real deployment
      # labels are lifted from platform topic names verbatim (bridge.config.
      # yaml's own GENERAL, GAMING & SCHEDULING and so on), which reads as a
      # raw key rather than a name.
      def room_display_name(room)
        raw = room.label.to_s.empty? ? room.room_key : room.label
        raw.split(" ").map(&:capitalize).join(" ")
      end

      # The kind and label joined, unless the label already says the kind: a
      # session titled "Friday trivia" needs no "trivia:" prefix repeating
      # what it already says.
      def session_summary(session)
        kind = session["kind"].to_s
        label = session["label"].to_s
        return kind if label.empty?
        return label if label.downcase.include?(kind.downcase)

        "#{kind}: #{label}"
      end

      # One room's open session and its open round, or nil when nothing is
      # running there. opened_at reads as a relative distance, since Room
      # games is what recency gets scanned on; closes_at stays a real ISO
      # 8601 string for the client's own Format.timestamp.
      def participation_row(community, room)
        session = @deps.participation.session(community: community, room_key: room.room_key)
        return nil if session.nil?

        round = @deps.participation.round(community: community, room_key: room.room_key)
        {
          "id" => room.id,
          "room" => room_display_name(room),
          "session" => session_summary(session),
          "rounds" => session["rounds"],
          "round_opened_at" => round && relative(Time.at(round["opened_at"].to_i)),
          "round_closes_at" => round && round["closes_at"] ? iso8601(Time.at(round["closes_at"].to_i)) : nil
        }
      end

      # A Time as YAMLCamel can carry it, which is nothing: it raises
      # YAMLCamel::UnsupportedTypeError on a raw Time, so every timestamp on
      # the wire goes through here rather than each payload method reaching
      # for strftime by hand. nil stays nil, since a column with nothing in
      # it draws blank rather than an empty string pretending to be a time.
      def iso8601(value)
        return nil if value.nil?

        value.respond_to?(:utc) ? value.utc.iso8601 : value.to_s
      end

      # A past Time (or an already ISO 8601 string, for a value ViewData did
      # not just build itself) read as a distance rather than a date, nil
      # safe the same way iso8601 is above.
      def relative(value)
        return nil if value.nil?

        time = value.is_a?(String) ? Time.parse(value) : value
        Primitives::Format.relative(time)
      end

      # One alert row, seen_at collapsed to a boolean: the table draws
      # "Mark seen" or "Seen" from it, and never needs the timestamp itself.
      def alert_payload(row)
        {
          "id" => row.id,
          "created_at" => relative(row.created_at),
          "room_key" => row.room_key,
          "script" => row.script,
          "text" => row.text,
          "how" => alert_how(row),
          "how_tone" => alert_how_tone(row),
          "seen" => !row.seen_at.nil?
        }
      end

      # The tone beside "how", because only this side counted: a loud alert
      # that reached nobody and one that DMed two operators read as the same
      # column and are opposite outcomes.
      def alert_how_tone(row)
        return "neutral" unless row.mode == Rubotty::ControlPlane::Alerts::LOUD

        row.delivered_to.to_i.positive? ? "good" : "warn"
      end

      # "Loud, reached nobody" is the case worth naming: every operator this
      # community has is on a platform rubotty cannot open a DM on, and this
      # is the only place that ever says so.
      def alert_how(row)
        return "Quiet" unless row.mode == Rubotty::ControlPlane::Alerts::LOUD

        reached = row.delivered_to.to_i
        reached.positive? ? "Loud, DMed #{reached}" : "Loud, reached nobody"
      end

      # One rehosted file row. The download secret never appears here (only
      # its digest is stored at all), so there is nothing on this payload
      # that could reissue or reveal a working link.
      def file_payload(row)
        {
          "id" => row.id,
          "filename" => row.filename,
          "room_key" => row.room_key.to_s,
          "created_by" => row.created_by.to_s,
          "byte_size" => row.byte_size,
          "expires_at" => iso8601(row.expires_at),
          "served_count" => row.served_count.to_i,
          "serve_limit" => row.serve_limit.to_i,
          "serves_remaining" => [row.serve_limit.to_i - row.served_count.to_i, 0].max
        }
      end

      # Every trigger type as the editor needs it: the name it submits, the
      # sentence describing it, the boxes it reads and the calls it hands the
      # script. Read off the trigger classes, so the editor cannot offer a box
      # a trigger ignores or promise behaviour the code does not have.
      def trigger_catalogue
        Scripting::Triggers::TYPES.map do |type|
          {
            "name" => type.type_name,
            "summary" => type.summary,
            "fields" => type.fields,
            "hands" => type.hands_over
          }
        end
      end

      # One script as the authoring flow reads it: the row, its two states,
      # and its conditions unpacked into the primary, the extras and the
      # shared settings the boxes are filled from.
      def script_form_payload(row)
        return script_form_blank if row.nil?

        config = @deps.scripts.trigger_config(row)
        declared = Scripting::Triggers.declared(row.trigger_type.to_s, config)
        {
          "id" => row.id,
          "name" => row.name,
          "kind" => row.kind,
          "language" => row.language,
          "source" => row.source.to_s,
          "yaml_data" => row.yaml_data.to_s,
          "trigger_type" => row.trigger_type,
          "trigger_also" => declared.drop(1).map(&:first),
          "trigger_edits" => truthy?(config["edits"]),
          "trigger_config" => trigger_config_payload(config),
          "live" => @deps.scripts.runnable?(row),
          "verified" => @deps.scripts.verified?(row),
          "verification_notes" => row.verification_notes.to_s,
          "disabled_reason" => row.disabled_at.nil? ? "" : row.disabled_reason.to_s
        }
      end

      def script_form_blank
        {
          "id" => nil, "name" => "", "kind" => ControlPlane::Scripts::KINDS.first,
          "language" => "lua", "source" => %(return { action = "allow" }\n), "yaml_data" => "",
          "trigger_type" => Scripting::Triggers::TYPES.first.type_name,
          "trigger_also" => [], "trigger_edits" => false,
          "trigger_config" => trigger_config_payload({}),
          "live" => false, "verified" => false, "verification_notes" => "", "disabled_reason" => ""
        }
      end

      # What one script has been up to: its failure counter, its recorded
      # errors, its alerts and how many times it has run, read once for the
      # themed page below it. Mirrors ViewController#script_activity, except
      # every value here is already the text a reader sees rather than a raw
      # column a client-side formatter would have to know how to read.
      def script_activity_payload(script)
        alerts = @deps.alerts.for_script(community_id: script.community_id, script: script.name)
        errors = @deps.scripts.error_history(script)
        totals = @deps.scripts.run_totals(script)
        {
          "stats" => script_activity_stats(script, alerts: alerts, errors: errors, totals: totals),
          "pairs" => script_activity_pairs(script),
          "errors" => errors.map { |entry| script_error_payload(entry) },
          "alerts" => alerts.map { |row| script_alert_payload(row) }
        }
      end

      def script_activity_stats(script, alerts:, errors:, totals:)
        failures = script.consecutive_failures.to_i
        days = Rubotty::ControlPlane::Alerts::RETENTION / (24 * 60 * 60)
        run_days = Rubotty::ControlPlane::Scripts::RUN_RETENTION_DAYS
        [[totals[:runs], "runs", "#{totals[:failures]} failed, kept #{run_days} days"],
         [failures, "consecutive failures", script_failure_detail(script, failures)],
         [errors.length, "recorded errors", "the last #{Rubotty::ControlPlane::Scripts::ERROR_HISTORY} are kept"],
         [alerts.length, "alerts raised", "kept for #{days} days"]]
      end

      def script_failure_detail(script, failures)
        return "already switched off" unless script.disabled_at.nil?
        return "nothing failing" if failures.zero?

        "switched off if it keeps failing"
      end

      def script_activity_pairs(script)
        pairs = [["last edited", relative(script.updated_at)],
                 ["last passed check", script.verified_at ? relative(script.verified_at) : "never"]]
        pairs << ["last error", script.last_error.to_s] unless script.last_error.to_s.empty?
        pairs << ["last error at", relative(script.last_error_at)] if script.last_error_at
        pairs << ["switched off", script.disabled_reason.to_s] unless script.disabled_at.nil?
        pairs
      end

      # One recorded error as a row, the stored time read back where it
      # parses and left as the raw string where it does not.
      def script_error_payload(entry)
        { "at" => script_error_relative(entry["at"]), "message" => entry["message"].to_s }
      end

      def script_error_relative(value)
        relative(value.to_s)
      rescue ArgumentError
        value.to_s
      end

      # One alert this script raised, room defaulted the same way the ERB
      # page defaults it, since "" reads as a room key rather than as none.
      def script_alert_payload(row)
        {
          "id" => row.id,
          "created_at" => relative(row.created_at),
          "room_key" => presence(row.room_key) || "any room",
          "text" => row.text.to_s,
          "how" => alert_how(row),
          "how_tone" => alert_how_tone(row)
        }
      end

      # The shared settings behind every condition on the script, as the text
      # each box holds. A list-valued one arrives as one entry per line, the
      # same shape the form posts back.
      def trigger_config_payload(config)
        {
          "name" => config["name"].to_s,
          "window" => config["window"].to_s,
          "minutes" => config["minutes"].to_s,
          "count" => config["count"].to_s,
          "every" => config["every"].to_s,
          "at" => config["at"].to_s,
          "words" => Array(config["words"]).join("\n"),
          "names" => Array(config["names"]).join("\n")
        }
      end

      # One script row. kind, language and trigger_type are left as their raw
      # stored tokens, the same way http_method is for an endpoint: Format.enum
      # and Format.code on the client are what turn "processor" into
      # "Processor" and "command_name" into a monospace cell, rather than this
      # handing over text the table's column format would then un-format.
      def script_payload(row)
        {
          "id" => row.id,
          "name" => row.name,
          "kind" => row.kind,
          "language" => row.language,
          "trigger_type" => row.trigger_type,
          "live" => @deps.scripts.runnable?(row),
          "verified" => @deps.scripts.verified?(row)
        }
      end

      # The numbers scripts wrote with increment_stat and record_stat, flat,
      # since the stat name is a column here rather than a heading a themed
      # page would need a third level for.
      def script_stat_payload(community)
        @deps.script_stats.report(community).flat_map do |stat, entries|
          entries.map do |entry|
            { "stat" => stat, "row" => entry[:row], "value" => entry[:value],
              "room" => entry[:room_key].to_s.empty? ? "any room" : entry[:room_key] }
          end
        end
      end

      # One redirection row. The status token reads as the two-phase move it
      # actually is (redirection_state in app.rb's ERB helper draws the same
      # two words), rather than the raw "posting"/"deleting" a themed reader
      # would otherwise have to already know this feature's vocabulary to
      # follow; a finished row's own status word ("done", "cancelled",
      # "failed") passes straight through since there is no phase left to name.
      def redirection_payload(row)
        {
          "id" => row.id,
          "created_at" => relative(row.created_at),
          "operator" => row.operator,
          "source_endpoint_id" => row.source_endpoint_id,
          "target_room_id" => row.target_room_id,
          "message_count" => row.message_count,
          "state" => redirection_state_label(row.status),
          "can_stop" => row.status == Rubotty::ControlPlane::Redirections::POSTING
        }
      end

      def redirection_state_label(status)
        case status
        when Rubotty::ControlPlane::Redirections::POSTING then "reposting"
        when Rubotty::ControlPlane::Redirections::DELETING then "clearing the original"
        else status.to_s
        end
      end
      # A room scope as the reader sees it: the blank room_key a
      # community-wide row carries reads as "every room" wherever a room
      # scope is shown, on the subscriptions table and the deliveries table
      # alike (the ERB pair used to only spell this out on one of the two).
      def room_scope_label(room_key)
        room_key.to_s.empty? ? "every room" : room_key.to_s
      end

      def webhook_subscription_payload(row)
        {
          "label" => row.label.to_s.empty? ? "(no label)" : row.label,
          "url" => row.url,
          "events" => Rubotty::ControlPlane::Webhooks.event_types_of(row).join(", "),
          "room" => room_scope_label(row.room_key),
          "state" => webhook_state_label(row)
        }
      end

      # A rotation still in flight is worth saying out loud (webhook_state in
      # app.rb's ERB helper does the same): it is the window in which a
      # subscriber may be verifying with either secret.
      def webhook_state_label(row)
        return "off" unless truthy?(row.active)
        return "on" unless @deps.webhooks.rotating?(row)

        "on, rotating"
      end

      def webhook_delivery_payload(row)
        {
          "id" => row.id,
          "created_at" => relative(row.created_at),
          "event_type" => row.event_type,
          "room" => room_scope_label(row.room_key),
          "outcome" => webhook_outcome_label(row),
          "attempts" => row.attempts.to_i,
          "last_error" => row.last_error.to_s,
          "can_retry" => row.status.to_s == "failed"
        }
      end

      # Three outcomes worth telling apart: it landed, it is still going to be
      # tried, or it has been given up on (webhook_delivery_status in app.rb's
      # ERB helper draws the same three).
      def webhook_outcome_label(row)
        case row.status.to_s
        when "delivered"
          code = row.response_status.to_i
          code.positive? ? "delivered, #{code}" : "delivered"
        when "failed" then "given up"
        else "waiting to retry"
        end
      end

      # One space waiting on a decision. sample_channels is capped here rather
      # than in the theme, so every theme shows the same ten and the wire
      # carries no more than the page can use.
      def pending_payload(row)
        channels = row.json_value(:sample_channels)
        {
          "id" => row.id,
          "name" => row.name,
          "external_id" => row.external_id,
          "label" => row.name || row.external_id,
          "platform" => "#{row.adapter}/#{row.account}",
          "inviter" => pending_inviter(row),
          "invited_by_someone" => !row.inviter_native_id.nil?,
          "member_count" => row.member_count,
          "channels" => channels.is_a?(Array) ? channels.first(10) : [],
          "created_at" => relative(row.created_at),
          "expires_at" => iso8601(row.expires_at),
          # A protected title is pended with no job behind it, so a blanket
          # "auto-leaves around" line would promise a departure never coming.
          "auto_leaves" => !row.job_id.nil?
        }
      end

      def pending_inviter(row)
        name = row.inviter_display || row.inviter_username || row.inviter_native_id
        return nil if name.nil?
        return "#{name} (@#{row.inviter_username})" if row.inviter_username && row.inviter_display

        name.to_s
      end

      def denied_payload(row)
        {
          "id" => row.id,
          "space" => row.name || row.external_id,
          "platform" => "#{row.adapter}/#{row.account}",
          "decided_at" => relative(row.decided_at),
          "decided_by" => row.decided_by
        }
      end

      # One outstanding login link. The digest {WebLoginTokens#active_tokens}
      # exposes is the only id that ever leaves the store, never the raw token.
      def operator_token_payload(token)
        operator = token[:operator] || {}
        communities = Array(token[:communities]).map { |row| row["slug"] || row[:slug] }
        {
          "id" => token[:id],
          "operator" => operator["label"] || operator[:label],
          "platform" => "#{operator["adapter"] || operator[:adapter]}/#{operator["account"] || operator[:account]}",
          "communities" => communities.empty? ? "none" : communities.join(", "),
          "reads" => token[:viewer] ? "Every community" : "The ones listed",
          "issued_at" => relative(token[:issued_at]),
          "expires_at" => token[:expires_at]
        }
      end

      def administrator_payload(row)
        {
          "id" => row[:id], "adapter" => row[:adapter], "handle" => row[:handle],
          "label" => row[:label], "granted_at" => iso8601(row[:granted_at]), "granted_by" => row[:granted_by]
        }
      end

      def baked_in_administrator_payload(entry)
        { "handle" => entry[:handle], "kind" => entry[:kind] }
      end

      def administrator_tokens
        @deps.auth_tokens.list(community_id: nil).select { |row| @deps.auth_tokens.administrator_token?(row) }
      end

      def administrator_token_payload(row)
        {
          "public_id" => row[:public_id], "label" => row[:label],
          "state" => @deps.auth_tokens.state_of(row), "live" => @deps.auth_tokens.live?(row),
          "expires_at" => iso8601(row[:expires_at]), "created_by" => row[:created_by],
          "used_by" => presence(row[:redeemed_username]) || presence(row[:redeemed_native_id])
        }
      end

      # A deployment-wide token that hands over reading every community, which
      # is every non-administrator one: a community-scoped token is minted on
      # that community's own Operators page and never reaches this list.
      def viewer_tokens
        @deps.auth_tokens.list(community_id: nil).reject { |row| @deps.auth_tokens.administrator_token?(row) }
      end

      def viewer_request_payload(row)
        name = row[:requester_display] || row[:requester_username] || row[:requester_native_id]
        {
          "id" => row[:id],
          "requester" => name.to_s,
          "handle" => row[:requester_native_id].to_s,
          "platform" => row[:adapter].to_s,
          "requested_at" => relative(row[:requested_at])
        }
      end

      def viewer_payload(row)
        {
          "id" => row[:id], "handle" => row[:handle], "platform" => row[:adapter],
          "name" => presence(row[:label]) || "", "granted_at" => iso8601(row[:granted_at]),
          "granted_by" => row[:granted_by]
        }
      end

      # The shipped list's own rows, which name a handle by the kind of
      # identifier it is rather than by a platform an operator picked.
      BAKED_IN_KINDS = {
        "matrix" => "Matrix ID", "telegram_id" => "Telegram ID", "discord_id" => "Discord ID"
      }.freeze

      def baked_in_viewer_payload(entry)
        { "handle" => entry[:handle], "kind" => BAKED_IN_KINDS.fetch(entry[:kind].to_s, "username") }
      end

      # One stored account: its identity, its env pill (nil when the adapter
      # takes no token_env at all, e.g. the guest portal is excluded upstream
      # but a future adapter might not need one either), and the schema
      # fields an edit form draws in place. +schema+ is looked up again
      # rather than carried from the caller since the list method never
      # resolved one, one row at a time being the whole reason it is cheap
      # here: an adapter unregistered in this process still draws a row, with
      # no edit form for it, the same fallback the ERB page takes.
      def account_payload(account, token_env_set)
        settings = account.json_value(:settings)
        schema = account_schema_or_nil(account.adapter)
        token_env = presence(settings["token_env"])
        {
          "id" => account.id,
          "adapter" => account.adapter,
          "name" => account.name,
          "from_yaml" => account.source == ControlPlane::Accounts::SOURCE_YAML,
          "token_env" => token_env,
          "token_env_set" => token_env.nil? ? nil : !!token_env_set[token_env],
          "editable" => !schema.nil?,
          "fields" => schema ? schema_field_payloads(schema, settings) : []
        }
      end

      # An adapter's account_schema, or nil for one nothing is registered
      # under in this process. Nil rather than raising, the same reason
      # App#account_schema is: a row a differently-configured process wrote
      # must still list, as an account this one cannot edit, instead of
      # taking the whole page down.
      def account_schema_or_nil(adapter)
        ControlPlane::Accounts.schema_for(adapter)
      rescue ControlPlane::Accounts::Invalid
        nil
      end

      # A schema's fields as {#field_payload} draws them, over a plain
      # settings hash rather than a feature's config entry: the two
      # {Config::Schema} instances the dashboard already turns into fields
      # this way, feature config and account settings, read alike.
      def schema_field_payloads(schema, config)
        schema.fields.each_value.map { |field| field_payload(field, config) }
      end

      # One API key. Scope and community read as one fact because an
      # administrator key has no community and a developer key is nothing
      # without one, so two columns would leave one of them empty every row.
      def api_key_payload(row, named)
        community = row.community_id && named[row.community_id]
        {
          "public_id" => row.public_id,
          "label" => presence(row.label) || "(no label)",
          "scope" => community ? "developer: #{community.slug}" : "administrator, every community",
          "platform_account" => presence(row.platform_account) || "-",
          "created_by" => row.created_by,
          "last_used_at" => row.last_used_at.nil? ? "never" : relative(row.last_used_at),
          "state" => row.revoked_at.nil? ? "live" : "revoked",
          "state_tone" => row.revoked_at.nil? ? "good" : "neutral",
          "live" => row.revoked_at.nil?
        }
      end

      # One integration row, saved or the unsaved stand-in {ControlPlane::Integrations#list}
      # hands back for a name never configured yet. The key itself never rides
      # this wire, only whether one is stored, mirroring the ERB card's own
      # password-field behaviour.
      def integration_payload(row, openarc = nil)
        payload = {
          "name" => row.name,
          "url" => row.url,
          "configured" => !presence(row.url).nil?,
          "key_stored" => !presence(row.api_key).nil?,
          "allowed_pairs" => row.name == "libretranslate" ? row.json_value(:config)["allowed_pairs"] : nil
        }
        row.name == "openarc" ? payload.merge(openarc_payload(openarc)) : payload
      end

      # The OpenArc card's model half: what the server offers, what is stored,
      # whether the stored one has gone, and whether the server answered at
      # all, which are the failures the card has to name rather than leaving
      # them to the first summary that breaks. reachable is nil for a
      # connection with no URL saved, where there is nothing to have answered.
      def openarc_payload(openarc)
        openarc ||= openarc_models
        settings = openarc[:settings]
        chosen = settings.model_chosen? ? settings.model : nil
        available = openarc[:available]
        {
          "models" => available,
          "model" => chosen,
          "effective_model" => settings.model,
          "default_model" => OpenArc::Settings::DEFAULT_MODEL,
          "model_error" => openarc[:error],
          "model_missing" => available.any? && !available.include?(settings.model),
          "reachable" => openarc[:reachable]
        }
      end

      # One community's totals. The operator request wait arrives as an
      # average in minutes and goes on the wire as seconds, so the client
      # draws it through Format.duration like every other span rather than
      # stapling an "m" to a number.
      def analytics_overview_payload(row)
        community = row[:community]
        {
          "slug" => community.slug,
          "name" => community.name,
          "active_members" => row[:active_members],
          "moderation_actions" => row[:moderation_actions],
          "messages_recent" => row[:messages_recent],
          "active_guests" => row[:active_guests],
          "operators" => row[:operators],
          "upcoming_events" => row[:upcoming_events],
          "pending_spaces" => row[:pending_spaces],
          "request_wait" => (row[:operator_request_minutes].to_f * 60).round
        }
      end

      def audit_event_payload(event)
        {
          "created_at" => iso8601(event.created_at), "source" => event.source, "action" => event.action,
          "actor" => event.actor, "subject" => event.subject, "reason" => event.reason,
          "outcome" => event.outcome
        }
      end

      def audit_log_event_payload(event)
        subject = [presence(event.subject), presence(event.channel)].compact.join(" in ")
        {
          "created_at" => iso8601(event.created_at), "community" => event.community,
          "action" => event.action, "actor" => event.actor, "subject" => subject,
          "reason" => event.reason, "outcome" => event.outcome
        }
      end

      # The /identify-topic names a non-operator proposed, waiting on an
      # operator to approve or reject them.
      def suggested_channels(community)
        community.channels_dataset.where(suggested: true).order(:id).all
      end

      # The community row for each id a batch of cross-community rows names,
      # in one query rather than one per row. Mirrors app.rb's own
      # #communities_by_id helper, which the ERB backfill-proposals route
      # uses for the same reason; kept separate rather than shared since one
      # is a Sinatra route helper and this is a plain object with no request.
      def communities_by_id(rows)
        ids = rows.map { |row| row[:community_id] }.uniq
        return {} if ids.empty?

        models.community.where(id: ids).all.each_with_object({}) { |c, index| index[c.id] = c }
      end

      # One backfill proposal, with its item previews inline: the point of
      # opening a themed row is seeing exactly what would be sent, and a
      # second fetch per row is not worth a second internal route yet.
      def backfill_proposal_payload(row, communities)
        community = communities[row[:community_id]]
        {
          "id" => row[:id],
          "community_name" => community&.name,
          "endpoint_id" => row[:endpoint_id],
          "created_at" => relative(row[:created_at]),
          "expires_at" => iso8601(row[:expires_at]),
          "fetched" => row[:fetched].to_i,
          "gaps" => row[:gaps].to_i,
          "ours" => row[:ours].to_i,
          "claimed" => row[:claimed].to_i,
          "below_floor" => row[:below_floor].to_i,
          "items" => backfill_proposal_items(community, row).map { |item| backfill_proposal_item_payload(item) }
        }
      end

      # Nothing for a proposal whose community has been deleted: the previews
      # only ever belonged to that tenant.
      def backfill_proposal_items(community, row)
        return [] if community.nil?

        @deps.backfill_proposals.items(community: community, proposal_id: row[:id])
      end

      def backfill_proposal_item_payload(item)
        {
          "sent_at" => iso8601(item[:sent_at]),
          "author_label" => item[:author_label].to_s,
          "preview" => item[:preview].to_s
        }
      end

      # Read through the same service the Rooms page consults, so the themed
      # section and the ERB one can never disagree about whether the create
      # controls belong on screen.
      def channel_management_enabled?(community)
        row = @deps.feature_controls.list(community, selector: "all")
                   .find { |entry| entry[:feature] == Features::ChannelManagement.feature_name }
        row ? row[:enabled] : Features::ChannelManagement.default_enabled?
      end

      # SQLite hands a boolean column back as 1 or 0, so a payload built
      # straight off the row would put a number on the wire on one backend and
      # a boolean on another.
      def truthy?(value)
        [true, 1, "1", "t", "true"].include?(value)
      end
    end
  end
end
