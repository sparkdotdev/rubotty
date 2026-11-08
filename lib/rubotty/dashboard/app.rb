# frozen_string_literal: true

require "sinatra/base"
require "securerandom"
require "digest"
require "json"
require "time"
require "uri"
require "openssl"
require "yamlcamel"

module Rubotty
  # Sinatra front end for an operator to read and edit the control-plane
  # database. Runs as its own process, sharing the datastore (not the
  # process) with the bot through the same {ControlPlane} services; a write
  # here bumps the feature_settings change marker so the bot's
  # {ControlPlane::ChangeDetector} picks it up live with no restart.
  module Dashboard
    # The Sinatra application.
    #
    # Built per deployment through {.assemble}, which returns a configured anonymous
    # subclass so a test can stand up an isolated app over an in-memory control
    # plane without any process-global state. Routes and settings are inherited
    # by the subclass; only the injected dependencies differ.
    class App < Sinatra::Base
      # Raised for a line of a list field the form cannot read, so a save is
      # refused with the line named instead of storing something else.
      class ConfigFieldError < Rubotty::Error; end

      # The env var NAMES the dashboard reads. Only the names live in code; the
      # secrets themselves come from the environment at run time and are never
      # written down here.
      DEFAULT_SECRET_ENV = "DASHBOARD_SECRET"
      DEFAULT_SESSION_SECRET_ENV = "DASHBOARD_SESSION_SECRET"
      PASSWORD_SESSION_TTL = 8 * 60 * 60

      set :public_folder, File.expand_path("public", __dir__)

      # Deterministic from the session-secret env var when set, so sessions
      # survive a restart and stay valid across instances sharing one
      # datastore; otherwise a random per-process key, which still clears
      # Rack's minimum secret length but logs everyone out on restart.
      def self.derive_session_secret(env:, name: DEFAULT_SESSION_SECRET_ENV, logger: nil)
        raw = env[name].to_s
        return Digest::SHA512.hexdigest(raw) unless raw.empty?

        logger&.warn do
          "dashboard: #{name} is not set, using a random per-process session secret; " \
            "sessions will not survive a restart. Set #{name} to a stable value."
        end
        SecureRandom.hex(64)
      end

      # Build a configured app over a set of dependencies.
      #
      # @param bot_nudge [BotNudge, nil] defaults to one built from
      #   RUBOTTY_BOT_INTERNAL_URL and RUBOTTY_INTERNAL_SECRET; either missing
      #   makes every nudge a no-op (see {BotNudge#configured?}).
      # @param deploy_drift [Core::DeployDrift, nil] defaults to one built
      #   from the deployment's config, inert unless deploy_head_url or the
      #   bot hop is set
      def self.assemble(deps:, env: ENV, secret_env: DEFAULT_SECRET_ENV,
                        session_secret_env: DEFAULT_SESSION_SECRET_ENV, logger: nil, bot_nudge: nil,
                        deploy_drift: nil)
        Class.new(self) do
          set :deps, deps
          set :secret_env, secret_env
          set :dashboard_env, env
          set :session_secret, App.derive_session_secret(env: env, name: session_secret_env, logger: logger)
          set :bot_nudge, bot_nudge || BotNudge.new(
            bot_url: env["RUBOTTY_BOT_INTERNAL_URL"], secret: env["RUBOTTY_INTERNAL_SECRET"], logger: logger
          )
          set :deploy_drift, deploy_drift || App.build_deploy_drift(config: deps.config, env: env, logger: logger)
        end
      end

      # The header's drift check, over the same internal hop and env vars
      # {BotNudge} already uses, plus whatever `behaviour.deploy_head_url` names.
      # The token is read from the env var the config NAMED, never written down.
      #
      # @param config [Config::Model, nil]
      # @param env [Hash]
      # @param logger [#debug, nil]
      # @return [Core::DeployDrift]
      def self.build_deploy_drift(config:, env:, logger: nil)
        bot = Api::BotLogsClient.new(
          bot_url: env["RUBOTTY_BOT_INTERNAL_URL"], secret: env["RUBOTTY_INTERNAL_SECRET"], logger: logger
        )
        token_env = config&.deploy_head_token_env
        Core::DeployDrift.new(
          head_url: config&.deploy_head_url,
          token: token_env ? env[token_env] : nil,
          bot_info: bot.configured? ? -> { bot.fetch_info } : nil,
          commit: Core::BuildInfo.commit,
          grace: config ? config.deploy_drift_grace : Core::DeployDrift::DEFAULT_GRACE,
          logger: logger
        )
      end

      # Empty rather than ENV, so a subclass built directly rather than through
      # {.assemble} reads no secret and no switch out of the real environment.
      set :dashboard_env, {}

      # The compiled head script for a public folder, read once and kept: it is
      # inlined into every client-rendered page, so a per-request file read would be a
      # syscall on the hot path for a few hundred bytes that rarely change.
      #
      # @param public_folder [String] where npm run build put its output
      # @return [String] the script, or "" when the assets have not been built
      def self.dashboard_head_script(public_folder)
        @dashboard_head_scripts ||= {}
        @dashboard_head_scripts[public_folder.to_s] ||= begin
          path = File.join(public_folder.to_s, "dashboard-head.js")
          File.exist?(path) ? File.read(path) : ""
        end
      end

      # The content floor, always served, and the primitive classes underneath
      # it, served only when the dashboard stylesheet is unavailable. Kept beside
      # the layout as CSS so a cascade check can resolve them the way a browser
      # does (see spec/support/css_cascade.rb).
      FALLBACK = "fallback.css"
      FALLBACK_VOCABULARY = "fallback-vocabulary.css"

      # @param name [String] a file in the views directory
      # @return [String] its contents
      def self.stylesheet(name)
        @stylesheets ||= {}
        @stylesheets[name] ||= File.read(File.expand_path("views/#{name}", __dir__), encoding: "UTF-8")
      end

      # The fallback styles cover the dashboard when assets have not been built.
      #
      # @param public_folder [String] where npm run build put its output
      def self.dashboard_stylesheet?(public_folder)
        @dashboard_stylesheets ||= {}
        key = public_folder.to_s
        @dashboard_stylesheets.fetch(key) do
          @dashboard_stylesheets[key] = File.exist?(File.join(public_folder.to_s, "dashboard.css"))
        end
      end

      # A safe, inert default (no URL, no secret, so every #nudge is a no-op)
      # for any subclass built directly rather than through {.assemble} (a
      # test standing up a bare App). {.assemble} overrides this with one
      # read from the real environment.
      set :bot_nudge, BotNudge.new(bot_url: nil, secret: nil)

      # Inert for the same reason: nothing to compare against, so nothing to say.
      set :deploy_drift, Core::DeployDrift.new

      set :views, File.expand_path("views", __dir__)
      # Stdlib ERB (no erubi in the bundle) does not auto-escape, so every view
      # wraps dynamic, operator-supplied or DB-derived value in the `h` helper.
      # Static template markup is emitted raw, which is what lets a helper return
      # a small HTML fragment (the community nav) for `<%= %>`.
      set :erb, escape_html: false
      # Serve behind a reverse proxy without leaking a stack trace to the browser,
      # and let a test see the real error.
      disable :show_exceptions
      enable :raise_errors
      disable :dump_errors
      # SameSite=Lax keeps a cross-site form post from riding the session, and
      # Secure keeps it off a plain-http hop. DASHBOARD_COOKIE_INSECURE=1 drops
      # Secure for a deployment genuinely served over http.
      enable :sessions
      set :sessions, httponly: true, same_site: :lax,
                     secure: !%w[1 true yes].include?(ENV["DASHBOARD_COOKIE_INSECURE"].to_s.strip.downcase)
      set :session_secret, SecureRandom.hex(64)
      # Runs behind a reverse proxy (rubotty.example.org) that terminates the
      # public hostname, so Sinatra's Host whitelist would otherwise reject
      # every proxied request. The proxy is the trust boundary; the login
      # secret still gates every route.
      set :host_authorization, permitted_hosts: []

      # Behind the TLS-terminating proxy, Rack::Protection::HttpOrigin sees
      # the request URL as http:// while the browser's Origin is https://,
      # so it silently drops the session on every unsafe method. allow_if
      # accepts same-host Origins regardless of scheme instead.
      set :protection, allow_if: lambda { |env|
        origin = env["HTTP_ORIGIN"].to_s
        next false if origin.empty?

        begin
          origin_host = URI.parse(origin).host
        rescue URI::InvalidURIError
          next false
        end
        request_host = Rack::Request.new(env).host.to_s
        !origin_host.to_s.empty? && origin_host.casecmp?(request_host)
      }

      # Authentication (who is signed in) and authorization (what the
      # signed-in role may do).

      # Everything but the login form and a bare liveness probe requires a
      # session. An unauthenticated request is bounced to the login form rather
      # than shown any data.
      before do
        refresh_session_authorization!
        # /licence is open because the base licence conditions every right on
        # agreeing to it, and the person weighing up whether they may deploy at
        # all has no dashboard session yet.
        next if %w[/login /healthz /operator-login /licence].include?(request.path_info)
        # The internal surface has its own filter below, which refuses in YAML
        # instead of bouncing to a login page a fetch() cannot do anything with.
        next if internal_surface_path?

        redirect to("/login") unless authenticated?
      end

      # Signed out answers 401 with a YAML body rather than the redirect above,
      # since the caller is a fetch() inside an already-open client-rendered page.
      before "/internal/*" do
        content_type "application/yaml"
        # The licence document is open for the same reason /licence itself is,
        # and it has to be: a client-rendered page whose section read answers 401 falls
        # back to a full page load, which starts the runtime again and reads
        # again, so a signed-out reader would sit in a reload loop.
        next if request.path_info == "/internal/licence"

        halt 401, internal_yaml("error" => "not signed in") unless authenticated?
      end

      # Every POST but the two auth routes writes to the control plane, so tell
      # the bot to re-read now rather than wait for its next poll. Best effort
      # (see BotNudge), a no-op unless the bot's URL and secret are both set.
      after do
        next unless request.post?
        next if %w[/login /operator-login].include?(request.path_info)
        # Nothing under the internal surface writes, so a POST there is a path
        # that does not exist rather than a change worth waking the bot for.
        next if internal_surface_path?

        settings.bot_nudge.nudge(reason: "dashboard write #{request.path_info}")
      end

      get "/healthz" do
        content_type "text/plain"
        "ok\n"
      end

      get "/login" do
        redirect to("/") if authenticated?

        erb :login
      end

      post "/login" do
        secret = configured_secret
        if secret.empty?
          @error = "The dashboard login secret is not configured. Set the #{settings.secret_env} " \
                   "environment variable on the dashboard host, then reload."
          status 503
          return erb :login
        end

        if Rack::Utils.secure_compare(secret, params[:secret].to_s)
          # Same first move /operator-login makes: without it an operator's
          # community scope survives into the administrator session.
          session.clear
          # The root password grants the administrator role, not a generic
          # "signed in" flag, so {#current_role} has one thing to read
          # regardless of which login path produced the session.
          session[:role] = Role::ADMINISTRATOR.to_s
          session[:login_kind] = "password"
          session[:password_binding] = password_session_binding
          session[:expires_at] = Time.now.to_i + PASSWORD_SESSION_TTL
          redirect to("/")
        else
          @error = "That secret is not correct."
          status 401
          erb :login
        end
      end

      post "/logout" do
        session.clear
        redirect to("/login")
      end

      # Target of the operator console's `/web-login` DM command and `/auth`
      # token reply, bypassing the session gate above since its job is to
      # create a session, not require one. GET only previews the token (a
      # platform's link-preview fetch cannot spend it); POST redeems it.

      get "/operator-login" do
        outcome = deps.web_login.preview(token: params[:token])
        # A token that will not work reveals nothing about why: the visitor is
        # simply left unauthenticated, and the gate above bounces them to the
        # login form exactly as it bounces any other anonymous request.
        redirect to("/") unless outcome.ok?

        @login_token = params[:token].to_s
        @login_operator = outcome.operator
        @login_expires_at = outcome.expires_at
        @login_scope = login_scope_label(outcome)
        erb :operator_login
      end

      post "/operator-login" do
        outcome = deps.web_login.redeem(token: params[:token])
        session.clear
        session[:login_token_id] = outcome.token_id if outcome.ok?
        if outcome.ok? && still_an_administrator?(outcome)
          # The heaviest session this deployment has, so the token's claim is
          # never enough on its own: the roster was asked again just above.
          session[:role] = Role::ADMINISTRATOR.to_s
          session[:operator_handle] = operator_identity(outcome.operator)
        elsif outcome.ok?
          session[:role] = Role::OPERATOR.to_s
          # The canonical session key for an operator's granted community
          # ids: the same +:operator_communities+ that {#current_role} reads
          # back and write-own scoping resolves against. The roster is asked
          # again, so a later demotion narrows an outstanding link too.
          session[:operator_communities] = current_operator_communities(outcome)
          # The viewer dimension, carried on the same token and kept in its own
          # key so it never mixes with the community ids above: one is what this
          # person may read, the other is what they may change. The token
          # identifies the person; the roster says whether the grant remains.
          session[:viewer] = still_a_viewer?(outcome)
          # Its community-scoped half, in a third key for the same reason: these
          # are read and never written to, whatever else the token carries.
          session[:viewer_communities] = current_viewer_communities(outcome)
          session[:operator_handle] = operator_identity(outcome.operator)
        end
        # Always land on the bare dashboard root, success or failure alike,
        # so the token never lingers in the address bar, history or a
        # Referer header. A bad or already-used token just leaves the
        # visitor unauthenticated for the `before` gate to bounce.
        redirect to("/")
      end

      # Admin view over active /web-login links, so an administrator can see
      # who has one outstanding and kill it early. Admin-only since a token
      # is a path into an operator session, which an operator never manages
      # for themselves.

      get "/operator-tokens" do
        require_admin!
        @tokens = deps.web_login.active_tokens
        @wide_page = true
        @client_section = "operator_tokens"
        erb :operator_tokens
      end

      post "/operator-tokens/:id/revoke" do
        require_admin!
        revoked = deps.web_login.revoke(id: params[:id])
        flash_result(revoked ? "Login link revoked." : "No such active login link.", error: !revoked)
        redirect to("/operator-tokens")
      end

      # Viewers read every community; administrator-only on every route since
      # an operator of one community must not grant oversight of the rest. The
      # shipped YAML stays a floor underneath: a handle named there shows as
      # deployment-configured with no revoke control, same as the Operators page.

      get "/viewers" do
        require_admin!
        @baked_in_viewers = deps.dashboard_viewers.baked_in
        @granted_viewers = deps.dashboard_viewers.granted
        @viewer_requests = deps.dashboard_viewers.pending
        @viewer_adapters = ControlPlane::DashboardViewers::ADAPTERS
        @viewer_audit = deps.dashboard_viewers.audit_trail
        @auth_tokens = deployment_tokens(administrator: false)
        # Shown exactly once, the same way a freshly issued API key is: spent
        # by relay_flash on this very render, so a reload never shows it again.
        @issued_auth_token = relay_flash(:auth_token)
        # Ported: the same five jobs Administrators already draws, against the
        # role that reads every community and changes nothing.
        @client_section = "viewers"
        erb :viewers
      end

      # A token that hands over reading every community. Administrator-only
      # since the token IS the grant, made ahead of time; anything less
      # would be a way around the check on handing it over directly.
      post "/auth-tokens" do
        require_admin!
        with_auth_token_error do
          issued = deps.auth_tokens.mint(
            minter: dashboard_minter, community_id: nil, viewer: true,
            ttl_seconds: token_ttl(params[:ttl_hours]), label: presence(params[:label])
          )
          session[:auth_token] = issued.token
          flash_result("Minted a token that hands over reading every community. Copy it now; it is shown once.")
        end
        redirect to("/viewers")
      end

      post "/auth-tokens/:public_id/revoke" do
        require_admin!
        flash_auth_token_revocation(deps.auth_tokens.revoke(public_id: params[:public_id],
                                                            revoked_by: operator_label, every: true))
        redirect to("/viewers")
      end

      post "/viewers" do
        require_admin!
        with_viewer_error do
          row = deps.dashboard_viewers.grant(
            adapter: params[:adapter], handle: params[:handle].to_s,
            label: presence(params[:label]), granted_by: operator_label
          )
          flash_result("#{row[:handle]} now reads every community.")
        end
        redirect to("/viewers")
      end

      post "/viewers/:id/revoke" do
        require_admin!
        result = deps.dashboard_viewers.revoke(id: params[:id], revoked_by: operator_label)
        case result.status
        when :removed
          flash_result("#{result.viewer[:handle]} no longer reads every community.")
        when :protected
          flash_result(
            "That handle is named in the deployment's shipped list, so it cannot be revoked from here.",
            error: true
          )
        else
          flash_result("No such viewer.", error: true)
        end
        redirect to("/viewers")
      end

      post "/viewer-requests/:id/approve" do
        require_admin!
        decide_viewer_request(params[:id], :approve)
        redirect to("/viewers")
      end

      post "/viewer-requests/:id/deny" do
        require_admin!
        decide_viewer_request(params[:id], :deny)
        redirect to("/viewers")
      end

      # Administrators hold every read and every write, everywhere. The
      # shipped YAML is a floor underneath, and the root password stays the
      # way back in, which is why revoking the last row here locks nobody
      # out.

      get "/administrators" do
        require_admin!
        @client_section = "administrators"
        @baked_in_administrators = deps.dashboard_administrators.baked_in
        @granted_administrators = deps.dashboard_administrators.granted
        @administrator_adapters = ControlPlane::DashboardAdministrators::ADAPTERS
        @administrator_audit = deps.dashboard_administrators.audit_trail
        @auth_tokens = deployment_tokens(administrator: true)
        # Shown exactly once, cleared by take_flash on this very render.
        @issued_auth_token = take_flash(:auth_token)
        erb :administrators
      end

      post "/administrators" do
        require_admin!
        with_administrator_error do
          row = deps.dashboard_administrators.grant(
            adapter: params[:adapter], handle: params[:handle].to_s,
            label: presence(params[:label]), granted_by: operator_label
          )
          flash_result("#{row[:handle]} now administers this deployment.")
        end
        redirect to("/administrators")
      end

      post "/administrators/:id/revoke" do
        require_admin!
        result = deps.dashboard_administrators.revoke(id: params[:id], revoked_by: operator_label)
        case result.status
        when :removed
          flash_result("#{result.administrator[:handle]} no longer administers this deployment.")
        when :protected
          flash_result(
            "That handle is named in the deployment's shipped list, so it cannot be revoked from here.",
            error: true
          )
        else
          flash_result("No such administrator.", error: true)
        end
        redirect to("/administrators")
      end

      # A token that hands over administering the deployment. Administrator-only
      # since the token IS the grant, made ahead of time; anything less would be
      # a way around the check on handing it over directly.
      post "/administrator-tokens" do
        require_admin!
        with_auth_token_error do
          issued = deps.auth_tokens.mint(
            minter: dashboard_minter, community_id: nil, administrator: true,
            ttl_seconds: token_ttl(params[:ttl_hours]), label: presence(params[:label])
          )
          session[:auth_token] = issued.token
          flash_result("Minted a token that hands over administering this deployment. " \
                       "Copy it now; it is shown once.")
        end
        redirect to("/administrators")
      end

      post "/administrator-tokens/:public_id/revoke" do
        require_admin!
        flash_auth_token_revocation(deps.auth_tokens.revoke(public_id: params[:public_id],
                                                            revoked_by: operator_label, every: true))
        redirect to("/administrators")
      end

      # Deployment-wide credentialed gateway connections, admin-only. A new
      # account needs a bot restart: it is a live transport connection
      # built at boot, not a row the change detector re-reads.

      get "/accounts" do
        require_admin!
        @accounts = deps.accounts.list
        @adapter_names = ControlPlane::Accounts.adapter_names
        # Two-step add, with no JavaScript: pick an adapter, come back with
        # that adapter's OWN account_schema rendered as a form. There is no
        # single set of account fields to render up front, which is the point:
        # Telegram's schema and Discord's share only token_env.
        @new_adapter = presence(params[:adapter])
        @new_schema = @new_adapter && account_schema_or_flash(@new_adapter)
        @new_adapter = nil if @new_schema.nil?
        @wide_page = true
        # Ported: the account list, its env pill, and the two-step add form.
        @client_section = "accounts"
        erb :accounts
      end

      post "/accounts" do
        require_admin!
        with_account_error do
          with_config_field_error do
            schema = ControlPlane::Accounts.schema_for(params[:adapter])
            deps.accounts.create(
              adapter: params[:adapter], name: params[:name],
              settings: account_settings_from_params(schema, params)
            )
            flash_result("Added the account. Restart the bot to bring it online.")
          end
        end
        redirect to("/accounts")
      end

      post "/accounts/:id" do
        require_admin!
        account = account!(params[:id])
        with_account_error do
          with_config_field_error do
            schema = ControlPlane::Accounts.schema_for(account.adapter)
            settings = account_settings_from_params(schema, params, account.json_value(:settings))
            deps.accounts.update(account: account, settings: settings)
            flash_result("Updated the account. Restart the bot to apply it.")
          end
        end
        redirect to("/accounts")
      end

      post "/accounts/:id/delete" do
        require_admin!
        removed = deps.accounts.remove(id: params[:id])
        flash_result(
          removed ? "Removed the account. It stays connected until the bot restarts." : "No such account.",
          error: !removed
        )
        redirect to("/accounts")
      end

      # Deployment-wide connections to outside services (e.g. LibreTranslate),
      # administrator only since a connection here is shared by every community.
      # Whether a community uses an integration is a separate per-community
      # toggle in Features::Catalog; this page only owns the shared connection.

      get "/integrations" do
        require_admin!
        @integrations = deps.integrations.list
        # Asked of the server itself, so the model choice offers what is really
        # loaded rather than anything written down here.
        @openarc = openarc_model_state
        @client_section = "integrations"
        erb :integrations
      end

      post "/integrations/libretranslate" do
        require_admin!
        with_integration_error do
          deps.integrations.save(
            name: "libretranslate", url: params[:url], api_key: params[:api_key],
            config: { "allowed_pairs" => params[:allowed_pairs] }
          )
          flash_result("Saved the LibreTranslate connection.")
        end
        redirect to("/integrations")
      end

      # Tries the submitted url and key live rather than only what is saved,
      # so a typo is caught here rather than turning into silently
      # untranslated messages hours later. A blank field means the same as
      # on Save (use what's stored); this route saves nothing either way.
      post "/integrations/libretranslate/test" do
        require_admin!
        stored = deps.integrations.find("libretranslate")
        store = Struct.new(:url, :api_key, :allowed_pairs).new(
          presence(params[:url]) || stored&.url, presence(params[:api_key]) || stored&.api_key, nil
        )
        client = Translation::Client.new(settings: Translation::Settings.new(env: {}, store: store), logger: deps.logger)
        begin
          languages = client.test_connection
          flash_result("Connected. LibreTranslate reports #{languages.length} language(s) available.")
        rescue Translation::Client::Error => e
          flash_result(e.message, error: true)
        end
        redirect to("/integrations")
      end

      # The model is stored beside the url and the key, so it is rotated live
      # rather than by editing Ruby and redeploying. Saving one the server does
      # not have is allowed deliberately: a server that is down at save time
      # would otherwise block an edit, and the page says so on the next draw.
      post "/integrations/openarc" do
        require_admin!
        with_integration_error do
          stored = deps.integrations.find("openarc")&.json_value(:config) || {}
          deps.integrations.save(
            name: "openarc", url: params[:url], api_key: params[:api_key],
            config: stored.merge("model" => presence(params[:model])).compact
          )
          flash_result("Saved the OpenArc connection.")
        end
        redirect to("/integrations")
      end

      # The same unsaved-field test pattern as LibreTranslate: the connection
      # is checked without changing what a running bridge currently uses. The
      # chosen model is checked against the listing here too, which is the one
      # place an operator can find out before a summary silently fails.
      post "/integrations/openarc/test" do
        require_admin!
        settings = OpenArc::Settings.new(store: submitted_openarc_store)
        begin
          flash_openarc_test(settings, OpenArc::Client.new(settings: settings).test_connection)
        rescue OpenArc::Client::Error => e
          flash_result(e.message, error: true)
        end
        redirect to("/integrations")
      end

      # Loads a new model through OpenArc's register-and-load call, using
      # only the connection already saved, not a submitted url or key.
      # Deliberately slow: the client's own timeout is generous, so this
      # waits for OpenArc's real answer rather than timing out early.
      post "/integrations/openarc/load" do
        require_admin!
        settings = OpenArc::Settings.new(store: ControlPlane::Integrations::OpenArcSettings.new(deps.integrations))
        begin
          raise OpenArc::Client::Error, "save the OpenArc connection first" unless settings.configured?

          OpenArc::Client.new(settings: settings, logger: deps.logger).load_model(
            model_path: params[:model_path], model_name: params[:model_name],
            model_type: params[:model_type], engine: params[:engine], device: params[:device],
            cache_dir: presence(params[:cache_dir])
          )
          remember_openarc_reload_spec
          flash_result("Loaded #{params[:model_name]} onto the OpenArc server, and kept how it was " \
                       "done, so it goes back by itself if this server drops it.")
        rescue OpenArc::Client::Error => e
          flash_result(e.message, error: true)
        end
        redirect to("/integrations")
      end

      # Stops a dropped model being put back on its own, for an operator taking
      # this server somewhere the bridge should not follow it to. The model
      # stays loaded and stays chosen; only the standing instruction goes.
      post "/integrations/openarc/forget" do
        require_admin!
        with_integration_error do
          merge_openarc_config("reload" => nil)
          flash_result("Rubotty will no longer put a model back when this server drops it.")
        end
        redirect to("/integrations")
      end

      # Import only ever succeeds against an EMPTY datastore (Storage::Snapshot's
      # own guard), so this route mostly matters for a freshly bootstrapped box:
      # stand it up, open its dashboard once, restore the snapshot from there
      # instead of needing a shell on the container at all.
      get "/settings/datastore" do
        require_admin!
        @client_section = "datastore"
        erb :datastore_settings
      end

      get "/settings/datastore/export" do
        require_admin!
        bytes = Storage::Snapshot.document_bytes(deps.db, label: "dashboard export")
        filename = "rubotty-datastore-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}.yaml.gz"
        content_type "application/gzip"
        attachment filename
        bytes
      end

      post "/settings/datastore/import" do
        require_admin!
        file = params[:file]
        unless file.is_a?(Hash) && file[:tempfile]
          flash_result("No file was uploaded.", error: true)
          redirect to("/settings/datastore")
        end

        begin
          report = Storage::Snapshot.restore_bytes(deps.db, file[:tempfile].read, source: file[:filename] || "upload")
          restored = report.tables.count { |t| t[:rows].positive? }
          flash_result("Datastore restored: #{report.total} rows across #{restored} tables.")
        rescue Storage::Snapshot::Invalid => e
          flash_result(e.message, error: true)
        end
        redirect to("/settings/datastore")
      end

      # Bearer credentials the REST admin API (mounted at /api) authenticates
      # against. Admin-only, never authorize!: a key is a path into the API
      # with real read/write access.

      get "/api-keys" do
        require_admin!
        # The community row resolved once per key here, not in the view,
        # mirroring the guests route's { room: models.room[invite.room_id] }
        # shape: nil for an administrator key, which has none.
        @api_keys = deps.api_keys.list.map do |key|
          { row: key, community: key.community_id && models.community[key.community_id] }
        end
        @communities = deps.communities
        # The freshly issued raw token, shown exactly once, mirroring the
        # guest-invite route's session[:guest_link]: spent by relay_flash
        # on this very render, so a page reload never shows it again.
        @issued_token = relay_flash(:api_key_token)
        @issued_label = relay_flash(:api_key_label)
        # Every configured api_wrapper account name, offered as suggestions on
        # the platform-account field so an operator does not have to copy one
        # out by hand.
        @api_wrapper_account_names = platform_account_names
        @wide_page = true
        # Ported: the key list, the mint form, and the one-time raw key drawn
        # through Code.
        @client_section = "api_keys"
        erb :api_keys
      end

      post "/api-keys" do
        require_admin!
        with_api_key_error do
          # The community field only matters for a developer key (the form's
          # JS hides it for administrator). Ignoring it for any other scope
          # keeps a tampered value from narrowing a meant-to-be-global key.
          developer = params[:scope].to_s == ControlPlane::ApiKeys::SCOPE_DEVELOPER
          community = developer ? presence(params[:community]) && deps.community(params[:community]) : nil
          platform_account = developer ? presence(params[:platform_account]) : nil
          if platform_account && !platform_account_names.include?(platform_account)
            raise ControlPlane::ApiKeys::Invalid,
                  "#{platform_account.inspect} names no configured api_wrapper account. " \
                  "Leave it blank for an ordinary key, or add the account on the Accounts page first."
          end
          issued = deps.api_keys.issue(
            scope: params[:scope], community: community, platform_account: platform_account,
            label: params[:label].to_s, created_by: "dashboard"
          )
          session[:api_key_token] = issued.token
          session[:api_key_label] = issued.key_row.label
          flash_result("Issued an API key for #{issued.key_row.label.inspect}. Copy it now; it is shown once.")
        end
        redirect to("/api-keys")
      end

      post "/api-keys/:public_id/revoke" do
        require_admin!
        revoked = deps.api_keys.revoke_by_public_id(public_id: params[:public_id])
        flash_result(revoked ? "API key revoked." : "No such API key.", error: revoked.nil?)
        redirect to("/api-keys")
      end

      # Search: the lookup behind the command bar, JSON since the only caller
      # is a browser fetch. No authorize! here because the scope IS the
      # authorization: built from this session's role into the WHERE clause of
      # every query, so a reader with no grants gets an empty answer, not a refusal.
      get "/search.json" do
        content_type :json
        results = deps.search.call(
          query: params[:q].to_s,
          scope: SearchScope.for(role: current_role, communities: deps.communities)
        )
        JSON.generate(
          "query" => results.query, "truncated" => results.truncated?,
          "entities" => results.entities.map { |hit| search_payload(hit) },
          "destinations" => results.destinations.map { |offer| search_payload(offer) }
        )
      end

      # Communities.

      get "/" do
        authorize!(:list_communities, community: Role::DEPLOYMENT)
        @communities = deps.communities.map do |community|
          {
            row: community,
            channels: models.channel.where(community_id: community.id).count,
            operators: operator_count(community.id),
            pending: models.operator_request.where(community_id: community.id, state: "pending").count
          }
        end
        # A count and a link, never the list itself: the queue lives on
        # /onboarding, and two screens rendering the same rows would drift.
        # Administrator-only, since nobody else may act on it.
        @waiting_spaces = current_role.administrator? ? deps.pending_spaces.pending.length : 0
        @wide_page = true
        # Ported: one table of counts per community, the Onboarding count as a
        # Notice above it, and one Open per row.
        @client_section = "communities"
        erb :index
      end

      get "/communities/:slug" do
        @community = community!(params[:slug])
        # A community this operator does not run is not a 403 dead end: they can
        # see it exists from the index, so the useful answer is a way to ask for
        # access rather than a wall. Nothing about the community is rendered.
        return erb :request_access unless current_role.can?(:view_community, community: @community)

        authorize!(:view_community, community: @community)
        @connections = models.platform_connection.where(community_id: @community.id).count
        @channels = models.channel.where(community_id: @community.id).count
        @operators = operator_count(@community.id)
        @pending = deps.operators.pending(community_id: @community.id).length
        @features = models.feature_setting.where(community_id: @community.id).count
        # The request-access branch
        # above stays on the ERB renderer: the internal surface answers 404
        # for a community this session may not read, matching the REST API's
        # non-disclosure rule, so it has nothing to hand a client redraw here.
        @client_section = "overview"
        erb :community
      end

      # Ask an administrator for access to a community this operator does not
      # run. Written to the same operator_requests table the in-chat /operator
      # flow uses, so an administrator approves both from the same page.
      post "/communities/:slug/request-access" do
        community = community!(params[:slug])
        halt 403, erb(:forbidden) unless current_role.operator?

        @community = community
        @requested = record_access_request(community)
        erb :request_access
      end

      post "/communities/:slug/start" do
        community = community!(params[:slug])
        require_admin!
        result = deps.lifecycle.start(community: community)
        flash_result(result.changed? ? "Community started." : "Community was already active.")
        redirect to("/communities/#{community.slug}")
      end

      post "/communities/:slug/stop" do
        community = community!(params[:slug])
        require_admin!
        if protected_community?(community)
          flash_result("#{community.name} is a protected community and can never be stopped from the dashboard.",
                       error: true)
          redirect to("/communities/#{community.slug}")
          next
        end
        result = deps.lifecycle.stop(community: community)
        flash_result(result.changed? ? "Community stopped." : "Community was already suspended.")
        redirect to("/communities/#{community.slug}")
      end

      # A space the bot was added to but not yet mapped to a community,
      # administrator-only throughout since approve/deny decide whether the
      # bot is even present somewhere.

      get "/onboarding" do
        require_admin!
        @pending_spaces = deps.pending_spaces.pending
        @denied_spaces = deps.pending_spaces.denied
        # The "attach to an existing community" dropdown on each pending card.
        @attachable_communities = deps.communities
        @client_section = "onboarding"
        erb :onboarding
      end

      post "/pending/:id/approve" do
        require_admin!
        pending = pending_space!(params[:id])
        result =
          if params[:target].to_s == "existing"
            deps.pending_spaces.approve(
              id: pending.id, admin: operator_label, community_id: params[:community_id],
              make_operator: params[:make_operator] == "true"
            )
          else
            deps.pending_spaces.approve(
              id: pending.id, admin: operator_label, new_community_name: params[:new_community_name],
              make_operator: params[:make_operator] == "true"
            )
          end
        flash_result(approve_flash(result), error: !result.approved?)
        redirect to(pending_return_path)
      end

      post "/pending/:id/deny" do
        require_admin!
        pending = pending_space!(params[:id])
        result = deps.pending_spaces.deny(id: pending.id, admin: operator_label)
        label = pending.name || pending.external_id
        flash_result(
          result.denied? ? "Denied and left #{label}." : "That request is no longer pending.",
          error: !result.denied?
        )
        redirect to(pending_return_path)
      end

      post "/pending/:id/clear" do
        require_admin!
        pending = pending_space!(params[:id])
        label = pending.name || pending.external_id
        cleared = deps.pending_spaces.clear(id: pending.id)
        flash_result(
          cleared ? "Cleared the blacklist entry for #{label}." : "That entry is not denied.",
          error: !cleared
        )
        redirect to("/onboarding")
      end

      # Platform connections + channels. A connection carries the bot's own
      # credentials, but the READ half also answers a viewer since every join
      # link goes through {#redact_secret}: a viewer reads the connection's
      # shape, never its credentials.

      get "/communities/:slug/platforms" do
        @community = community!(params[:slug])
        authorize!(:view_platforms, community: @community)
        @connections = models.platform_connection.where(community_id: @community.id).order(:adapter, :account).all
        @channels_by_connection = models.channel.where(community_id: @community.id).all
                                        .group_by(&:platform_connection_id)
        # Each connection decorated with its adapter/token status and its
        # editable behaviour settings; see #connection_view.
        @connection_views = @connections.map { |connection| connection_view(connection) }
        @known_adapters = ControlPlane::PlatformConnections::KNOWN_ADAPTERS
        # Fluxer instances: a separate DB+panel-config bucket from
        # @connections above, so they are listed alongside the
        # platform_connections table instead of merged into it.
        @fluxer_instances = deps.fluxer_instances.list(community: @community)
        @fluxer_kinds = ControlPlane::FluxerInstances::KINDS
        # IRC networks: the same bucket, listed alongside the Fluxer instances.
        @irc_networks = deps.irc_networks.list(community: @community)
        @irc_network_modes = ControlPlane::IrcNetworks::MODES
        # The /platforms invite links live in the utility_commands feature config
        # (each entry a { platform, label, url } map), one set per scope, so the
        # edit screen lists them exactly the word-filter and FAQ screens list theirs.
        @platform_settings = feature_rows(@community, "utility_commands")
        @scopes = scope_options(@community)
        # A discovered-but-unmapped channel is rendered with a distinct
        # marker in the channels table below, so it is never mistaken for a
        # live, mapped one; see #discovered? and #roomed_channel_ids.
        @roomed_channel_ids = roomed_channel_ids(@community)
        @client_section = "platforms"
        erb :platforms
      end

      # Writes the invite-links array through {ControlPlane::PlatformLinks},
      # the same service the /platforms command reads, so a save here takes
      # effect live and the two can never disagree on what counts as valid.
      post "/communities/:slug/platforms" do
        community = community!(params[:slug])
        require_admin!
        selector = presence(params[:selector]) || "all"
        with_feature_error do
          with_platform_links_error do
            entries = deps.platform_links.replace(
              community: community, selector: selector, entries: platform_link_rows_from_params
            )
            flash_result("Saved #{entries.length} platform link#{entries.length == 1 ? "" : "s"} for #{selector}.")
          end
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      # Add a new platform connection: the only way to onboard a platform the
      # initial config seed never declared, since discovery can only attach
      # channels to a connection that already exists. Picked up on the
      # adapter's next bulk channel sync.
      post "/communities/:slug/platforms/connections" do
        community = community!(params[:slug])
        require_admin!
        with_platform_connection_error do
          connection = deps.platform_connections.create(
            community: community, adapter: params[:adapter], account: params[:account],
            external_id: params[:external_id], label: params[:label]
          )
          flash_result(
            "Added the #{connection.adapter} connection. Its channels show up on Discovered Channels the " \
            "next time that adapter's gateway does its bulk channel sync (its next connect or restart)."
          )
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      # A community's IRC networks. Registered before the generic
      # "/platforms/:id" route on purpose: Sinatra dispatches in
      # registration order, and "/platforms/irc-networks" would otherwise
      # match that route's :id segment.

      post "/communities/:slug/platforms/irc-networks" do
        community = community!(params[:slug])
        require_admin!
        with_irc_network_error do
          deps.irc_networks.create(community: community, **irc_network_form_attrs)
          flash_result("Added the IRC network.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      post "/communities/:slug/platforms/irc-networks/:id" do
        community = community!(params[:slug])
        require_admin!
        network = irc_network!(community, params[:id])
        with_irc_network_error do
          deps.irc_networks.update(network: network, **irc_network_form_attrs)
          flash_result("Updated the IRC network.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      post "/communities/:slug/platforms/irc-networks/:id/delete" do
        community = community!(params[:slug])
        require_admin!
        removed = deps.irc_networks.remove(community: community, id: params[:id])
        flash_result(removed ? "Removed the IRC network." : "No such IRC network.", error: !removed)
        redirect to("/communities/#{community.slug}/platforms")
      end

      # A community's flagship-plus-self-hosted Fluxer connections, admin-only
      # since a row here names the env var holding a real API key. Registered
      # before the generic "/platforms/:id" route since Sinatra dispatches
      # in registration order.

      post "/communities/:slug/platforms/fluxer" do
        community = community!(params[:slug])
        require_admin!
        with_fluxer_instance_error do
          deps.fluxer_instances.create(
            community: community, label: params[:label], kind: params[:kind],
            endpoint_url: params[:endpoint_url], api_key_env: params[:api_key_env]
          )
          flash_result("Added the Fluxer instance.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      post "/communities/:slug/platforms/fluxer/:id" do
        community = community!(params[:slug])
        require_admin!
        instance = fluxer_instance!(community, params[:id])
        with_fluxer_instance_error do
          deps.fluxer_instances.update(
            instance: instance, label: params[:label], kind: params[:kind],
            endpoint_url: params[:endpoint_url], api_key_env: params[:api_key_env]
          )
          flash_result("Updated the Fluxer instance.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      post "/communities/:slug/platforms/fluxer/:id/delete" do
        community = community!(params[:slug])
        require_admin!
        removed = deps.fluxer_instances.remove(community: community, id: params[:id])
        flash_result(removed ? "Removed the Fluxer instance." : "No such Fluxer instance.", error: !removed)
        redirect to("/communities/#{community.slug}/platforms")
      end

      # Update a platform connection's identity: which adapter and account
      # serve it, its coarse space id (Telegram chat_id / Discord guild_id),
      # and its label. See ControlPlane::PlatformConnections#update_identity,
      # which refuses the edit outright for a protected community's connection.
      post "/communities/:slug/platforms/:id" do
        community = community!(params[:slug])
        require_admin!
        connection = platform_connection!(community, params[:id])
        with_platform_connection_error do
          deps.platform_connections.update_identity(
            connection: connection, adapter: params[:adapter], account: params[:account],
            external_id: params[:external_id], label: params[:label]
          )
          flash_result("Updated the #{connection.adapter} connection.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      # Remove a platform connection, the counterpart of the create form above,
      # mirroring the Fluxer instance delete route. Channel rows cascade with
      # it; a protected community's connection is refused, the same bar
      # update_identity holds.
      post "/communities/:slug/platforms/:id/delete" do
        community = community!(params[:slug])
        require_admin!
        connection = platform_connection!(community, params[:id])
        with_platform_connection_error do
          adapter = connection.adapter
          deps.platform_connections.remove(connection: connection)
          flash_result("Removed the #{adapter} connection and the channels that hung off it.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      # Save an operator's edit to a connection's per-account behaviour
      # settings; see ControlPlane::PlatformConnections#save_behavior_settings
      # for what this does and does not yet do. +account+ is resolved here
      # from the accounts table, since the service has none of its own.
      post "/communities/:slug/platforms/:id/settings" do
        community = community!(params[:slug])
        require_admin!
        connection = platform_connection!(community, params[:id])
        with_platform_connection_error do
          account = account_for(connection)
          deps.platform_connections.save_behavior_settings(
            connection: connection, account: account, raw_settings: params[:setting] || {}
          )
          flash_result("Saved behaviour settings for #{connection.adapter} / #{connection.account}.")
        end
        redirect to("/communities/#{community.slug}/platforms")
      end

      # The former Discovered connections URL remains as a bookmark-safe
      # redirect. Unroomed channels are ordinary channel rows regardless of
      # how they first arrived, and the Rooms board is their one home.

      get "/communities/:slug/discovered" do
        community = community!(params[:slug])
        authorize!(:view_rooms, community: community)
        redirect to("/communities/#{community.slug}/rooms?state=unroomed")
      end

      # Propose bindings for every unroomed channel at once. A POST
      # because it is the start of a flow rather than a page anyone should
      # be able to link to, but it still writes nothing: the proposals are
      # rendered for confirmation and only the apply route below saves.
      post "/communities/:slug/discovered/auto-map" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        redirect to("/communities/#{community.slug}/rooms/automatic-mapping")
      end

      # Apply only the ticked proposals, through the SAME
      # ChannelMapper#resolve_selection a manual mapping goes through, so the
      # automatic path can never disagree with the manual one about what
      # mapping means.
      post "/communities/:slug/discovered/auto-map/apply" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        with_mapping_error do
          applied = apply_auto_mappings(community)
          flash_result("Mapped #{applied} #{applied == 1 ? "channel" : "channels"}.")
        end
        redirect to("/communities/#{community.slug}/rooms?state=unroomed")
      end

      get "/communities/:slug/rooms/automatic-mapping" do
        @community = community!(params[:slug])
        authorize!(:manage_discovered, community: @community)
        @client_section = "automatic_mapping"
        erb :automatic_mapping
      end

      # Map one unroomed channel into a room. The route only turns form
      # params into ChannelMapper#resolve_selection's keywords, the same
      # method the DM console's `map` command uses.
      post "/communities/:slug/discovered/:id/map" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        channel = discovered_channel!(community, params[:id])
        with_mapping_error do
          result = deps.channel_mapper.resolve_selection(
            community: community, channel: channel, room_key: presence(params[:room_key]),
            partner: presence(params[:partner]), solo: presence(params[:solo]), label: presence(params[:label])
          )
          flash_result(
            "Mapped #{channel.label.to_s.empty? ? channel.endpoint_key : channel.label} into room " \
            "#{result.room.room_key}. It stays dormant: no feature was enabled by mapping it."
          )
        end
        redirect to("/communities/#{community.slug}/rooms?state=unroomed")
      end

      get "/communities/:slug/rooms/channels/:id" do
        @community = community!(params[:slug])
        authorize!(:view_rooms, community: @community)
        @client_section = "room_channel"
        erb :room_channel
      end

      post "/communities/:slug/rooms/channels/:id/name" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        channel = community_channel!(community, params[:id])
        channel.update(label: presence(params[:label]), updated_at: Time.now)
        flash_result("Saved the channel name.")
        redirect to("/communities/#{community.slug}/rooms/channels/#{channel.id}")
      end

      # A channel moves only after its new mapping exists. That keeps a bad
      # destination from briefly taking a live channel out of every room.
      post "/communities/:slug/rooms/channels/:id/mapping" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        channel = community_channel!(community, params[:id])
        with_mapping_error do
          room_key, partner, solo = mapping_selection_from(params)
          previous_rooms = channel_rooms_for(community, channel)
          result = deps.channel_mapper.resolve_selection(
            community: community, channel: channel, room_key: room_key,
            partner: partner, solo: solo, label: presence(params[:label])
          )
          previous_rooms.reject { |room| room.id == result.room.id }.each do |room|
            deps.channel_mapper.unlink(room: room, channel: channel)
          end
          flash_result("Mapped the channel into #{result.room.room_key}.")
        end
        redirect to("/communities/#{community.slug}/rooms/channels/#{channel.id}")
      end

      post "/communities/:slug/rooms/channels/:id/unlink" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        channel = community_channel!(community, params[:id])
        with_mapping_error do
          room = community_room!(community, params[:room_key])
          deps.channel_mapper.unlink(room: room, channel: channel)
          flash_result("Removed the channel from #{room.room_key}. The room and its settings remain.")
        end
        redirect to("/communities/#{community.slug}/rooms/channels/#{channel.id}")
      end

      get "/communities/:slug/rooms/:room_key" do
        @community = community!(params[:slug])
        authorize!(:view_rooms, community: @community)
        @client_section = "room_detail"
        erb :room_detail
      end

      post "/communities/:slug/rooms/:room_key/name" do
        community = community!(params[:slug])
        authorize!(:manage_rooms, community: community)
        room = community_room!(community, params[:room_key])
        label = presence(params[:label])
        if label.nil?
          flash_result("Enter a room name.", error: true)
        else
          room.update(label: label, updated_at: Time.now)
          flash_result("Saved the room name.")
        end
        redirect to("/communities/#{community.slug}/rooms/#{room.room_key}")
      end

      # Room provisioning: create/delete meta-channels, gated behind the
      # channel_management flag and manage_rooms. This only writes a request
      # row and enqueues a durable job: this process has no live adapter, so
      # whichever bot process is running for the community carries it out.

      get "/communities/:slug/rooms" do
        @community = community!(params[:slug])
        authorize!(:view_rooms, community: @community)
        @channel_management_enabled = channel_management_enabled?(@community)
        @rooms = models.room.where(community_id: @community.id).order(:room_key).all
        @connections = models.platform_connection.where(community_id: @community.id).order(:adapter, :account).all
        # /identify-topic suggestions (a non-operator's run of it) awaiting an
        # operator's approve or reject, same community scope as everything
        # else on this page.
        @suggested = models.channel.where(community_id: @community.id, suggested: true).order(:id).all
        @client_section = "rooms"
        erb :rooms
      end

      post "/communities/:slug/suggested/:id/approve" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        suggested_channel!(community, params[:id])
        channel = deps.channel_discovery.approve_suggestion(params[:id].to_i)
        flash_result(
          channel ? "Approved #{h(channel.label)}." : "That suggestion is no longer pending."
        )
        redirect to("/communities/#{community.slug}/rooms")
      end

      post "/communities/:slug/suggested/:id/reject" do
        community = community!(params[:slug])
        authorize!(:manage_discovered, community: community)
        suggested_channel!(community, params[:id])
        removed = deps.channel_discovery.reject_suggestion(params[:id].to_i)
        flash_result(removed ? "Rejected the suggestion." : "That suggestion is no longer pending.")
        redirect to("/communities/#{community.slug}/rooms")
      end

      post "/communities/:slug/rooms" do
        community = community!(params[:slug])
        authorize!(:manage_rooms, community: community)
        deny_unless_channel_management_enabled!(community)
        with_room_provisioning_error do
          platforms = Array(params[:platforms]).filter_map do |value|
            adapter, account = value.to_s.split("/", 2)
            { adapter: adapter, account: account } if adapter && account
          end
          deps.room_provisioning.request_create(
            community: community, name: params[:name].to_s, platforms: platforms,
            template_channel: presence(params[:template_channel]), requested_by: operator_label
          )
          flash_result(
            "Requested room #{h(params[:name])}. The running bot will provision it on each chosen " \
            "platform shortly; check the audit log for the outcome."
          )
        end
        redirect to("/communities/#{community.slug}/rooms")
      end

      post "/communities/:slug/rooms/:id/delete" do
        community = community!(params[:slug])
        authorize!(:manage_rooms, community: community)
        deny_unless_channel_management_enabled!(community)
        room = models.room.where(community_id: community.id, id: params[:id]).first
        halt 404 if room.nil?

        with_room_provisioning_error do
          deps.room_provisioning.request_delete(
            community: community, room: room, confirmed_name: params[:confirm_name].to_s,
            requested_by: operator_label,
            delete_platform_channels: params[:delete_platform_channels] == "1",
            force_channel_ids: Array(params[:force_channel_ids]).map(&:to_i)
          )
          flash_result("Requested deletion of room #{h(room.room_key)}.")
        end
        redirect to("/communities/#{community.slug}/rooms")
      end

      # Operators + pending requests, readable by an operator of this
      # community so the viewer-granting form is reachable by whoever may
      # use it. Deployment-wide permission switches draw only for a reader
      # whose sight is the whole deployment.

      get "/communities/:slug/operators" do
        @community = community!(params[:slug])
        authorize!(:view_operators, community: @community)
        @operators = models.operator.where(community_id: @community.id).order(:id).all.map do |operator|
          { row: operator, person: models.person[operator.person_id] }
        end
        # The deployment-configured "always operators" fail-safe is enforced everywhere
        # already; without this it is invisible on the page, so a deployment-configured-
        # only operator looks like they have no access. Listed separately
        # from the DB rows, with no delete control.
        @baked_in_operators = Security::ProtectedOperators.default.entries
        # The operator accounts a DM was last refused at. Without this the page
        # shows an audience that is bigger than the one alerts actually reach.
        @unreachable_operators = deps.operator_reachability.unreachable(community_id: @community.id)
        @pending = deps.operators.pending(community_id: @community.id)
        @approver = first_operator(@community)
        @permission_rows = deps.action_permissions.rows
        @permission_groups = deps.action_permissions.grouped_rows
        # Who reads this one community and changes nothing in it. Alongside the
        # operators because it answers the same question about the same
        # community, and an operator here may hand it out.
        @community_viewers = deps.community_viewers.granted(community_id: @community.id)
        @community_viewer_requests = deps.community_viewers.pending(community_id: @community.id)
        @baked_in_viewers = deps.community_viewers.baked_in
        @viewer_adapters = ControlPlane::CommunityViewers::ADAPTERS
        # The tokens that hand somebody either role here, beside the roles
        # themselves, because minting one is how a role is handed to a person
        # nobody has met yet.
        @auth_tokens = deps.auth_tokens.list(community_id: @community.id)
        # Relayed rather than taken: the client render replaces this body, so the
        # token has to survive one more read to reach it.
        @issued_auth_token = relay_flash(:auth_token)
        @client_section = "operators"
        erb :operators
      end

      # Community viewers: who reads this community and changes nothing in it.
      # An operator here can grant it, unlike the deployment-wide Viewers page
      # (administrator-only, since it reaches every other community too); the
      # shipped YAML is the floor under both.

      post "/communities/:slug/viewers" do
        community = community!(params[:slug])
        authorize!(:manage_community_viewers, community: community)
        with_community_viewer_error do
          row = deps.community_viewers.grant(
            community_id: community.id, adapter: params[:adapter], handle: params[:handle].to_s,
            label: presence(params[:label]), granted_by: operator_label
          )
          flash_result("#{row[:handle]} now reads #{community.slug}.")
        end
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/communities/:slug/viewers/:id/revoke" do
        community = community!(params[:slug])
        authorize!(:manage_community_viewers, community: community)
        result = deps.community_viewers.revoke(
          community_id: community.id, id: params[:id], revoked_by: operator_label
        )
        case result.status
        when :removed
          flash_result("#{result.viewer[:handle]} no longer reads #{community.slug}.")
        when :protected
          flash_result(
            "That handle is named in the deployment's shipped list, so it cannot be revoked from here.",
            error: true
          )
        else
          flash_result("No such viewer.", error: true)
        end
        redirect to("/communities/#{community.slug}/operators")
      end

      # A token that hands over a role in THIS community: operator, viewer, or
      # both. Gated on the same permission as granting the viewer directly,
      # because the token reaches exactly as far as the operator minting it.
      post "/communities/:slug/auth-tokens" do
        community = community!(params[:slug])
        authorize!(:manage_community_viewers, community: community)
        with_auth_token_error do
          issued = deps.auth_tokens.mint(
            minter: dashboard_minter, community_id: community.id,
            operator: params[:operator] == "1", viewer: params[:viewer] == "1",
            ttl_seconds: token_ttl(params[:ttl_hours]), label: presence(params[:label])
          )
          session[:auth_token] = issued.token
          flash_result("Minted a token for #{community.slug}. Copy it now; it is shown once.")
        end
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/communities/:slug/auth-tokens/:public_id/revoke" do
        community = community!(params[:slug])
        authorize!(:manage_community_viewers, community: community)
        flash_auth_token_revocation(
          deps.auth_tokens.revoke(public_id: params[:public_id], community_id: community.id,
                                  revoked_by: operator_label)
        )
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/communities/:slug/viewer-requests/:id/approve" do
        community = community!(params[:slug])
        authorize!(:manage_community_viewers, community: community)
        decide_community_viewer_request(community, params[:id], :approve)
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/communities/:slug/viewer-requests/:id/deny" do
        community = community!(params[:slug])
        authorize!(:manage_community_viewers, community: community)
        decide_community_viewer_request(community, params[:id], :deny)
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/operator-permissions" do
        require_admin!
        deps.action_permissions.update(params[:permissions] || {})
        flash_result("Saved operator permissions.")
        redirect to(local_path(params[:back]))
      end

      post "/communities/:slug/operators/:id/approve" do
        community = community!(params[:slug])
        authorize!(:manage_operator_requests, community: community)
        decide_request(community, params[:id], :approve)
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/communities/:slug/operators/:id/deny" do
        community = community!(params[:slug])
        authorize!(:manage_operator_requests, community: community)
        decide_request(community, params[:id], :deny)
        redirect to("/communities/#{community.slug}/operators")
      end

      post "/communities/:slug/operators/:id/delete" do
        community = community!(params[:slug])
        authorize!(:manage_operators, community: community)
        result = deps.operators.remove(community_id: community.id, id: params[:id])
        case result.status
        when :removed
          flash_result("Operator removed.")
        when :protected
          flash_result("This operator is baked in and protected (issue #119); it cannot be removed.", error: true)
        else
          flash_result("No such operator.", error: true)
        end
        redirect to("/communities/#{community.slug}/operators")
      end

      # Feature toggles: the generic control for every feature in the
      # catalog. Renders one row per {Features::Catalog} entry, not just
      # ones with a feature_settings row, so an untouched feature still
      # shows its real running state.

      get "/communities/:slug/features" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @scope = presence(params[:scope]) || "all"
        @scopes = scope_options(@community)
        # Catalog.dashboard_names is pipeline order, meaningful for the router
        # but not for an operator scanning a page: sort by display name here,
        # at render time only, so the shared order other callers rely on stays
        # intact.
        @features = Features::Catalog.dashboard_names.sort_by { |name| Dashboard::FeatureDisplay.name_for(name) }
        @feature_rows = display_feature_rows(feature_matrix_rows(@community, @scope))
        @feature_categories = group_feature_rows(@feature_rows)
        @wide_page = true
        # The scope selector is a GET filter
        # Form, so switching scope is a real navigation the runtime's own
        # router now carries the query string through rather than dropping.
        @client_section = "features"
        erb :features
      end

      post "/communities/:slug/features" do
        community = community!(params[:slug])
        selector = presence(params[:selector]) || "all"
        feature = params[:feature].to_s
        op = params[:op]
        # Turning a feature on is its own grant, separate from editing what
        # it does: toggle_ for enable/disable, configure_ for set. Anything
        # else is refused outright rather than falling through with no
        # check at all.
        case op
        when "enable", "disable" then authorize!(:"toggle_#{feature}", community: community)
        when "enable_flag", "disable_flag"
          authorize!(:"toggle_#{feature}", community: community)
          # File Rehosting and File Uploads' own toggle: writes ONE of
          # file_rehosting's two split config keys, whitelisted here, rather
          # than the whole feature's enabled flag both rows would share.
          unless feature == Features::FileRehosting.feature_name &&
                 Dashboard::FeatureDisplay.file_rehosting_split_key?(params[:key])
            halt 403, erb(:forbidden)
          end
        when "set" then authorize!(:"configure_#{feature}", community: community)
        else halt 403, erb(:forbidden)
        end
        with_feature_error do
          case op
          when "enable"
            deps.feature_controls.enable(community: community, selector: selector, feature: feature)
            flash_result("Enabled #{feature} for #{selector}.")
          when "disable"
            deps.feature_controls.disable(community: community, selector: selector, feature: feature)
            flash_result("Disabled #{feature} for #{selector}.")
          when "enable_flag"
            key = params[:key].to_s
            deps.feature_controls.enable(community: community, selector: selector, feature: feature)
            deps.feature_controls.set(community: community, selector: selector, feature: feature,
                                      key: key, value: "true")
            flash_result("Enabled #{feature}.#{key} for #{selector}.")
          when "disable_flag"
            key = params[:key].to_s
            deps.feature_controls.set(community: community, selector: selector, feature: feature,
                                      key: key, value: "false")
            flash_result("Disabled #{feature}.#{key} for #{selector}.")
          when "set"
            deps.feature_controls.set(community: community, selector: selector, feature: feature,
                                      key: params[:key].to_s, value: params[:value].to_s)
            flash_result("Set #{feature}.#{params[:key]} for #{selector}.")
          end
        end
        redirect to("/communities/#{community.slug}/features")
      end

      # Per-feature config editor: every feature that declares a config_schema
      # gets one typed field per declared key here, instead of only the
      # handful (word filter, FAQ, platforms, guests) with a bespoke page. Reuses
      # the same FeatureControls#set the "Set a config key" escape hatch drives.

      get "/communities/:slug/features/:feature/config" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @scope = presence(params[:scope]) || "all"
        @scopes = scope_options(@community)
        @feature = params[:feature].to_s
        @feature_class = Features::Catalog.class_for(@feature)
        @schema = @feature_class&.config_schema
        halt 404, "no feature #{@feature.inspect} with editable config" if @schema.nil?

        @config = deps.feature_controls.list(@community, selector: @scope)
                      .find { |entry| entry[:feature] == @feature }&.dig(:config) || {}
        @client_section = "feature_config"
        erb :feature_config
      end

      post "/communities/:slug/features/:feature/config" do
        community = community!(params[:slug])
        selector = presence(params[:selector]) || "all"
        feature = params[:feature].to_s
        # Editing what a feature does, which is the heavier half of the pair.
        authorize!(:"configure_#{feature}", community: community)
        schema = Features::Catalog.class_for(feature)&.config_schema
        halt 404, "no feature #{feature.inspect} with editable config" if schema.nil?

        with_feature_error do
          with_config_field_error do
            # Read the whole submission before writing any of it, so a line
            # the form cannot read refuses the save rather than landing half.
            config = feature_config_at(community, feature, selector)
            writes = schema.fields.each_value.filter_map do |field|
              value = config_field_submission(field, params, config)
              [field.name.to_s, value] unless value.nil?
            end
            writes.each do |key, value|
              deps.feature_controls.set(community: community, selector: selector,
                                        feature: feature, key: key, value: value)
            end
            flash_result("Updated #{feature} config for #{selector}.")
          end
        end
        redirect to(config_save_return(community, feature, selector))
      end

      # Word filter. On the operator allow list, so a later matrix change only
      # has to teach Role#can? about :edit_word_filter, not touch this route.

      get "/communities/:slug/word-filter" do
        @community = community!(params[:slug])
        # Reading a community you run needs no grant. Gating this on the
        # write grant meant an operator saw less than before grants
        # defaulted to nothing.
        authorize!(:view_community, community: @community)
        @settings = feature_rows(@community, "word_filter")
        @matrix = feature_matrix(@community, "word_filter")
        prepare_leftover_config(@community, "word_filter")
        @client_section = "word_filter"
        erb :word_filter
      end

      # The primary control is a MODE per scope (off / slurs / slurs_profanity),
      # not a raw word list, since the shipped base list already carries the
      # terms. `custom` layers supplemental words on top of whichever tier
      # `mode` selects, and applies even under `off`.
      post "/communities/:slug/word-filter" do
        community = community!(params[:slug])
        authorize!(:configure_word_filter, community: community)
        selector = presence(params[:selector]) || "all"
        with_feature_error do
          with_word_filter_entries_error do
            case params[:op]
            when "enable", "disable"
              authorize!(:toggle_word_filter, community: community)
              toggle_feature(community, selector, "word_filter", params[:op] == "enable")
            when "scope" then save_word_filter_scope(community, selector)
            when "save"
              mode = presence(params[:mode]) || Features::WordFilter::DEFAULT_MODE
              custom = lines_to_entries(params[:custom])
              deps.feature_controls.set(community: community, selector: selector,
                                        feature: "word_filter", key: "mode", value: mode)
              deps.word_filter_entries.replace(community: community, selector: selector, entries: custom)
              action = presence(params[:action])
              if action
                deps.feature_controls.set(community: community, selector: selector,
                                          feature: "word_filter", key: "action", value: action)
              end
              forced = apply_forced_enablement(community, selector, "word_filter", params[:enabled])
              flash_result("Saved the word filter for #{selector}: mode #{mode}, " \
                           "#{custom.length} custom word#{custom.length == 1 ? "" : "s"}" \
                           "#{forced ? " (forced #{forced})" : ""}.")
            end
          end
        end
        redirect to("/communities/#{community.slug}/word-filter")
      end

      # Operator authored scripts. Admin only: being an operator should not
      # by itself mean running code in the bot's process, so this needs its
      # own decision rather than riding the word filter and FAQ's allow list.

      get "/communities/:slug/scripts" do
        @community = community!(params[:slug])
        authorize!(:view_scripts, community: @community)
        @scripts = deps.scripts.list(@community)
        # Deleting archives rather than destroys, and the flash says the text
        # can be restored. Nothing exposed that until now, so the promise was
        # not one the dashboard could keep.
        @archived = deps.scripts.list(@community, archived: true)
        @runtime_available = deps.script_pool.available?
        # Community wide, since a stat row names no script, so it sits with the
        # scripts rather than on one script's page or among the bot's own
        # aggregates. Only drawn once something has been recorded.
        @script_stats = deps.script_stats.report(@community)
        @wide_page = true
        # The server-rendered page supplies initial content; the
        # runtime then replaces #rb-view with the shared Scripts screen.
        @client_section = "scripts"
        erb :scripts
      end

      # The endpoints a script may call: an endpoint row decides which hosts
      # this deployment reaches out to and carries the credentials it reaches
      # them with. A viewer reads the row for oversight, but the header block
      # goes through {#redact_secret} like every other stored secret here.

      # The scripting reference and the README, neither reachable any other
      # way on a private repository, so both render here rather than sending
      # an operator to read a file they cannot open.
      get "/documentation" do
        @wide_page = true
        @client_section = "documentation"
        erb :documentation
      end

      # The licence, served the same way for the same reason: the footer used to
      # send operators to a file on GitHub that a private repository will not show
      # them.
      get "/licence" do
        @wide_page = true
        @client_section = "licence"
        erb :licence
      end

      get "/communities/:slug/endpoints" do
        @community = community!(params[:slug])
        authorize!(:view_endpoints, community: @community)
        @endpoints = deps.script_endpoints.list(@community)
        @wide_page = true
        # The server-rendered page supplies initial content; the
        # runtime then replaces #rb-view with the shared Endpoints screen.
        @client_section = "endpoints"
        erb :endpoints
      end

      get "/communities/:slug/endpoints/new" do
        @community = community!(params[:slug])
        authorize!(:view_endpoints, community: @community)
        @endpoint = nil
        @client_section = "endpoint_edit"
        erb :endpoint_edit
      end

      get "/communities/:slug/endpoints/:id" do
        @community = community!(params[:slug])
        authorize!(:view_endpoints, community: @community)
        @endpoint = deps.script_endpoints.find(@community, params[:id]) || halt(404, erb(:not_found))
        @client_section = "endpoint_edit"
        erb :endpoint_edit
      end

      post "/communities/:slug/endpoints" do
        community = community!(params[:slug])
        require_admin!
        saved = with_endpoint_error(community) do
          row = deps.script_endpoints.save(
            community: community, id: presence(params[:id]), name: params[:name],
            url: params[:url], http_method: params[:http_method], description: params[:description],
            headers: params[:headers], allow_sync: params[:allow_sync] == "1",
            query_params: params[:query_params],
            timeout_seconds: params[:timeout_seconds], cache_seconds: params[:cache_seconds],
            enabled: %w[1 true].include?(params[:enabled]), created_by: session[:role].to_s
          )
          flash_result("Saved #{row.name.inspect}. A script reaches it with that name.")
          row
        end
        # A refused save goes back to the form the administrator was looking at,
        # so the flash explaining why is somewhere they can see it.
        return redirect to("/communities/#{community.slug}/endpoints") if saved

        redirect to("/communities/#{community.slug}/endpoints/#{presence(params[:id]) || "new"}")
      end

      post "/communities/:slug/endpoints/:id/delete" do
        community = community!(params[:slug])
        require_admin!
        with_endpoint_error(community) do
          row = deps.script_endpoints.delete(community, params[:id])
          flash_result("Deleted #{row.name.inspect}. Any script calling it now gets an error.")
        end
        redirect to("/communities/#{community.slug}/endpoints")
      end

      get "/communities/:slug/scripts/new" do
        @community = community!(params[:slug])
        authorize!(:view_scripts, community: @community)
        @script = nil
        @completions = script_completions
        @examples = script_examples
        @client_section = "script_edit"
        erb :script_edit
      end

      get "/communities/:slug/scripts/:id" do
        @community = community!(params[:slug])
        authorize!(:view_scripts, community: @community)
        @script = deps.scripts.find(@community, params[:id]) || halt(404, erb(:not_found))
        @verified = deps.scripts.verified?(@script)
        # Whether it is actually running, a different question from whether
        # it passed the check. A script that reads "checked" here and
        # nothing else looks live when it is still off.
        @live = deps.scripts.runnable?(@script)
        load_script_activity
        @completions = script_completions
        @examples = script_examples
        @client_section = "script_edit"
        erb :script_edit
      end

      post "/communities/:slug/scripts" do
        community = community!(params[:slug])
        require_admin!
        saved = with_script_error(community) do
          row = deps.scripts.save(
            community: community, id: presence(params[:id]), name: params[:name],
            kind: params[:kind], language: presence(params[:language]) || "lua",
            source: params[:source], trigger_type: params[:trigger_type],
            # The stored row is handed over so a condition somebody configured
            # over the API keeps its own settings through an unrelated save
            # here. The form has one set of boxes and cannot show them.
            trigger_config: script_trigger_config(script_being_saved(community)),
            created_by: session[:role].to_s,
            yaml_data: params[:yaml_data]
          )
          flash_result("Saved #{row.name.inspect}. Run the check before turning it on.")
          row
        end
        # A refused save goes back to the form the operator was looking at,
        # rather than nowhere, so the flash explaining why is somewhere they can
        # see it and their draft is still on screen.
        return redirect to("/communities/#{community.slug}/scripts/#{saved.id}") if saved

        redirect to("/communities/#{community.slug}/scripts/#{presence(params[:id]) || "new"}")
      end

      post "/communities/:slug/scripts/:id/verify" do
        community = community!(params[:slug])
        require_admin!
        with_script_error(community) do
          result = deps.scripts.verify(community, params[:id])
          if result.ok?
            flash_result("No obvious errors. It can be turned on now.")
          else
            flash_result("Not ready: #{result}", error: true)
          end
        end
        redirect to("/communities/#{community.slug}/scripts/#{params[:id]}")
      end

      post "/communities/:slug/scripts/:id/restore" do
        community = community!(params[:slug])
        require_admin!
        with_script_error(community) do
          row = deps.scripts.restore(community, params[:id])
          flash_result("Restored #{row.name.inspect}. It is off and needs checking again.")
        end
        redirect to("/communities/#{community.slug}/scripts")
      end

      # Run it once, now, against text the operator typed: the check answers
      # "does this fall over", this answers what a rule actually does to a
      # given message. Host functions are the check's stubs, so nothing posts
      # into a room or calls an endpoint.
      post "/communities/:slug/scripts/:id/try" do
        community = community!(params[:slug])
        require_admin!
        @community = community
        @script = deps.scripts.find(community, params[:id]) || halt(404, erb(:not_found))
        with_script_error(community) do
          trigger = Scripting::Triggers.build_all(@script.trigger_type, deps.scripts.trigger_config(@script))
          @tried_text = params[:try_text].to_s
          @tried_matched, @tried_answer = deps.smoke_test.try(
            kind: @script.kind.to_sym, source: @script.compiled.to_s,
            trigger: trigger, text: @tried_text, data: try_data(@tried_text),
            # The saved data file, so trying a rule out shows what it will
            # really decide rather than what it decides with no data.
            yaml_data: deps.scripts.yaml_data(@script)
          )
        end
        @verified = deps.scripts.verified?(@script)
        @live = deps.scripts.runnable?(@script)
        load_script_activity
        @completions = script_completions
        @examples = script_examples
        erb :script_edit
      end

      post "/communities/:slug/scripts/:id/enable" do
        community = community!(params[:slug])
        require_admin!
        with_script_error(community) do
          row = deps.scripts.enable(community, params[:id])
          flash_result("#{row.name.inspect} is live.")
        end
        redirect to(after_script_switch(community))
      end

      post "/communities/:slug/scripts/:id/disable" do
        community = community!(params[:slug])
        require_admin!
        with_script_error(community) do
          row = deps.scripts.disable(community, params[:id])
          flash_result("#{row.name.inspect} is off.")
        end
        redirect to(after_script_switch(community))
      end

      post "/communities/:slug/scripts/:id/delete" do
        community = community!(params[:slug])
        require_admin!
        with_script_error(community) do
          row = deps.scripts.find(community, params[:id])
          deps.scripts.archive(community, params[:id]) if row
          flash_result("Archived #{row ? row.name.inspect : "it"}. The text is kept and can be restored.")
        end
        redirect to("/communities/#{community.slug}/scripts")
      end

      # ------------------------------------------------------------------
      # room games
      # ------------------------------------------------------------------

      # What ControlPlane::Participation holds for each room: the open session
      # a script started with open_session, and its open round. The harness
      # tracks nothing about what either is for, so a script keeps its own
      # scoreboard in a bucket (remember, add, entries).

      get "/communities/:slug/participation" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @rooms = models.room.where(community_id: @community.id).order(:room_key).all.map do |room|
          { room: room, session: deps.participation.session(community: @community, room_key: room.room_key),
            round: deps.participation.round(community: @community, room_key: room.room_key) }
        end
        @wide_page = true
        # The server-rendered page supplies initial content; the
        # runtime then replaces #rb-view with the shared Room games screen.
        @client_section = "participation"
        erb :participation
      end

      # Close a room's open session, and whatever round is open inside it,
      # the same call a script's own close_session makes. A room with
      # nothing open answers the same refusal a script gets for the same call.
      post "/communities/:slug/participation/:room_id/close" do
        community = community!(params[:slug])
        authorize!(:manage_participation, community: community)
        room = models.room.where(community_id: community.id, id: params[:room_id]).first
        halt 404 if room.nil?

        result = deps.participation.close_session(community: community, room_key: room.room_key)
        if result == true
          flash_result("Closed the session in #{room.label.to_s.empty? ? room.room_key : room.label}.")
        else
          flash_result(result[1], error: true)
        end
        redirect to("/communities/#{community.slug}/participation")
      end

      # FAQ / custom commands. Also on the operator allow list: see the
      # word-filter section above for why this uses authorize! instead of
      # require_admin!.

      get "/communities/:slug/faq" do
        @community = community!(params[:slug])
        # Reading a community you run needs no grant. Gating this on the
        # write grant meant an operator saw less than before grants
        # defaulted to nothing.
        authorize!(:view_community, community: @community)
        @settings = feature_rows(@community, "faq")
        @matrix = feature_matrix(@community, "faq")
        @scopes = scope_options(@community)
        prepare_leftover_config(@community, "faq")
        @client_section = "faq"
        erb :faq
      end

      post "/communities/:slug/faq" do
        community = community!(params[:slug])
        authorize!(:configure_faq, community: community)
        selector = presence(params[:selector]) || "all"
        with_feature_error do
          with_faq_entries_error do
            case params[:op]
            when "enable", "disable"
              authorize!(:toggle_faq, community: community)
              toggle_feature(community, selector, "faq", params[:op] == "enable")
            when "scope" then save_faq_scope(community, selector)
            when "add"
              deps.faq_entries.add(community: community, selector: selector,
                                   trigger: params[:trigger], response: params[:response],
                                   trigger_type: params[:trigger_type])
              forced = apply_forced_enablement(community, selector, "faq", params[:enabled])
              flash_result("Added FAQ entry for #{selector}#{forced ? " (forced #{forced})" : ""}.")
            when "remove"
              deps.faq_entries.remove(community: community, selector: selector, id: params[:id])
              flash_result("Removed FAQ entry from #{selector}.")
            end
          end
        end
        redirect to("/communities/#{community.slug}/faq")
      end

      # Guest portal invites. Admin-only: a guest invite IS a join link,
      # and an operator viewing or creating one is denied, so this whole
      # section requires admin.

      get "/communities/:slug/guests" do
        @community = community!(params[:slug])
        authorize!(:view_guests, community: @community)
        # Room-scoped guest access: whether guests are allowed and who may
        # invite. A guest session is room-scoped too, so the issue form
        # offers only rooms that allow guests, and an invite can never be
        # framed for one the service would refuse.
        @room_access = models.room.where(community_id: @community.id).order(:room_key).all.map do |room|
          policy = deps.guest_invites.room_policy(community: @community, room: room)
          { room: room, allowed: policy[:allowed], who_can_invite: policy[:who_can_invite] }
        end
        @allowed_rooms = @room_access.select { |entry| entry[:allowed] }.map { |entry| entry[:room] }
        @invites = deps.guest_invites.list(community: @community).map do |invite|
          { row: invite, state: deps.guest_invites.state_of(invite), room: models.room[invite.room_id] }
        end
        # Relayed rather than taken outright: the client render replaces this
        # body, so the link has to survive one more read to reach it.
        @issued_link = relay_flash(:guest_link)
        @issued_nickname = relay_flash(:guest_nickname)
        prepare_leftover_config(@community, "guest_portal")
        @client_section = "guests"
        erb :guests
      end

      # Turn guest access on or off for a room and set who may invite, both
      # through FeatureControls (the same guest_portal feature the bot reads), so
      # the change applies live with no restart to every channel bridged into
      # that room.
      post "/communities/:slug/guests/access" do
        community = community!(params[:slug])
        require_admin!
        selector = presence(params[:room])
        with_feature_error do
          if selector.nil?
            flash_result("Pick a room.", error: true)
          else
            if params[:allowed] == "on"
              deps.feature_controls.enable(community: community, selector: selector, feature: "guest_portal")
            else
              deps.feature_controls.disable(community: community, selector: selector, feature: "guest_portal")
            end
            who = %w[operators everyone].include?(params[:who_can_invite]) ? params[:who_can_invite] : "operators"
            deps.feature_controls.set(community: community, selector: selector,
                                      feature: "guest_portal", key: "who_can_invite", value: who)
            flash_result("Updated guest access for #{selector}.")
          end
        end
        redirect to("/communities/#{community.slug}/guests")
      end

      post "/communities/:slug/guests" do
        community = community!(params[:slug])
        require_admin!
        with_guest_error do
          room = models.room.where(community_id: community.id, room_key: params[:room].to_s).first
          if room.nil?
            flash_result("Pick a room to scope the guest to.", error: true)
          else
            issued = deps.guest_invites.issue(
              community: community, room: room, nickname: params[:nickname].to_s,
              ttl_seconds: (params[:ttl_hours].to_f * 3600).round, created_by: "dashboard", as: :operator
            )
            session[:guest_link] = guest_link(issued.token)
            session[:guest_nickname] = issued.invite.nickname
            flash_result("Issued a guest link for #{issued.invite.nickname}. Copy it now; it is shown once.")
          end
        end
        redirect to("/communities/#{community.slug}/guests")
      end

      post "/communities/:slug/guests/:id/revoke" do
        community = community!(params[:slug])
        require_admin!
        invite = deps.guest_invites.revoke_by_id(community: community, id: params[:id])
        flash_result(invite ? "Guest link revoked." : "No such guest invite.", error: invite.nil?)
        redirect to("/communities/#{community.slug}/guests")
      end

      # ------------------------------------------------------------------
      # files
      # ------------------------------------------------------------------

      # Admin only, both routes: a listing names an uploader and a size, and
      # a file rubotty holds is member content. List and delete only: the
      # download UUID is never stored, only its digest, so nothing here can
      # show or reissue a working link.

      get "/communities/:slug/files" do
        @community = community!(params[:slug])
        require_admin!
        @files = deps.rehosted_files&.list(community_id: @community.id)
        @usage_bytes = deps.rehosted_files&.sealed_bytes_for(community_id: @community.id)
        @quota_bytes = deps.rehosted_files&.policy_for(community_id: @community.id)&.dig(:quota_bytes)
        @wide_page = true
        @client_section = "files"
        erb :files
      end

      post "/communities/:slug/files/:id/delete" do
        community = community!(params[:slug])
        require_admin!
        store = deps.rehosted_files
        row = store&.expire_by_id(community_id: community.id, id: params[:id])
        flash_result(row ? "File marked for deletion." : "No such file.", error: row.nil?)
        redirect to("/communities/#{community.slug}/files")
      end

      # Events, on the operator allow list, gated by
      # authorize!(:configure_events, community:): an operator may list,
      # create and cancel events in a community they operate.

      get "/communities/:slug/events" do
        @community = community!(params[:slug])
        # Reading a community you run needs no grant. Gating this on the
        # write grant meant an operator saw less than before grants
        # defaulted to nothing.
        authorize!(:view_community, community: @community)
        # Only rooms with the "events" feature turned on are offered to
        # schedule into, so a create can never fail on that gate; the
        # generic Features page is where an operator turns a room on.
        @room_access = models.room.where(community_id: @community.id).order(:room_key).all.map do |room|
          policy = deps.event_policy.room_policy(community: @community, room: room)
          { room: room, enabled: policy[:enabled], who_can_create: policy[:who_can_create] }
        end
        @enabled_rooms = @room_access.select { |entry| entry[:enabled] }.map { |entry| entry[:room] }
        @events = deps.event_scheduling.upcoming(community: @community)
        @rooms_by_id = models.room.where(community_id: @community.id).all.to_h { |room| [room.id, room] }
        prepare_leftover_config(@community, "events")
        @client_section = "events"
        erb :events
      end

      post "/communities/:slug/events" do
        community = community!(params[:slug])
        authorize!(:configure_events, community: community)
        with_event_error do
          room = models.room.where(community_id: community.id, room_key: params[:room].to_s).first
          if room.nil?
            flash_result("Pick a room.", error: true)
          else
            deps.event_scheduling.create(
              community: community, room: room, as: :operator,
              title: params[:title].to_s, starts_at: params[:starts_at].to_s,
              timezone: presence(params[:timezone]), kind: params[:kind].to_s,
              game_title: presence(params[:game_title]), server_address: presence(params[:server_address]),
              url: presence(params[:url]), rsvp_mode: presence(params[:rsvp_mode]) || "none",
              created_by: operator_label
            )
            flash_result("Scheduled the event.")
          end
        end
        redirect to("/communities/#{community.slug}/events")
      end

      post "/communities/:slug/events/:id/cancel" do
        community = community!(params[:slug])
        authorize!(:configure_events, community: community)
        event = deps.event_scheduling.cancel_by_id(community: community, id: params[:id])
        flash_result(event ? "Event cancelled." : "No such event.", error: event.nil?)
        redirect to("/communities/#{community.slug}/events")
      end

      # Polls: on the operator allow list, gated by
      # authorize!(:configure_poll, community:), the same grant
      # Features::Catalog generates for events. /poll and /schedule share
      # this one page, told apart by Polls::Poll#schedule?.

      get "/communities/:slug/polls" do
        @community = community!(params[:slug])
        # Reading a community you run needs no grant, same as events above.
        authorize!(:view_community, community: @community)
        @polls = deps.polls.open_polls(community: @community)
        @rooms_by_id = models.room.where(community_id: @community.id).all.to_h { |room| [room.id, room] }
        @option_counts = @polls.to_h { |poll| [poll.id, deps.polls.options(poll).size] }
        @vote_counts = @polls.to_h { |poll| [poll.id, models.poll_vote.where(poll_id: poll.id).count] }
        prepare_leftover_config(@community, "poll")
        @client_section = "polls"
        erb :polls
      end

      post "/communities/:slug/polls/:id/cancel" do
        community = community!(params[:slug])
        authorize!(:configure_poll, community: community)
        # Scoped by community first, same as events' cancel_by_id, so a
        # community operator can never reach another community's poll by id.
        # Closed through Polls::Lifecycle, not ControlPlane::Polls#close
        # directly, so the armed timekeeper job is actually withdrawn.
        poll = deps.polls.find(community: community, id: params[:id])
        closed = poll && deps.poll_lifecycle.close(poll.id)
        flash_result(closed ? "Poll cancelled." : "No such poll.", error: !closed)
        redirect to("/communities/#{community.slug}/polls")
      end

      # Moderation: mute / unmute, on the operator allow list, gated by
      # authorize!(:moderate_user, community:). ControlPlane::ModerationActions
      # works over the same warnings/sanctions tables the ladder writes; the
      # routes only translate params and flash the result.

      get "/communities/:slug/moderation" do
        @community = community!(params[:slug])
        # Reading a community you run needs no grant. Gating this on the
        # write grant meant an operator saw less than before grants
        # defaulted to nothing.
        authorize!(:view_community, community: @community)
        @query = presence(params[:q])
        @identities = @query ? deps.identities.search(community_id: @community.id, query: @query, limit: 25) : []
        @active_mutes = deps.moderation.active_mutes(community: @community)
        @client_section = "moderation"
        erb :moderation
      end

      post "/communities/:slug/moderation/mute" do
        community = community!(params[:slug])
        authorize!(:moderate_user, community: community)
        with_moderation_error do
          target = presence(params[:display]) || presence(params[:username]) || presence(params[:native_id])
          deps.moderation.mute(
            community: community, adapter: params[:adapter], native_id: params[:native_id],
            username: presence(params[:username]), display: presence(params[:display]),
            duration: presence(params[:duration]), reason: presence(params[:reason]),
            issued_by: operator_label
          )
          flash_result("Muted #{target}.")
        end
        redirect to("/communities/#{community.slug}/moderation")
      end

      post "/communities/:slug/moderation/:id/unmute" do
        community = community!(params[:slug])
        authorize!(:moderate_user, community: community)
        sanction = deps.moderation.unmute(community: community, id: params[:id])
        flash_result(sanction ? "Unmuted." : "No such active mute.", error: sanction.nil?)
        redirect to("/communities/#{community.slug}/moderation")
      end

      # People: the identity directory, with the bridged nickname each row
      # is shown under editable in place. Every write calls
      # ControlPlane::BridgedNicknames, the exact store the /nickname
      # command writes to, so a name set here behaves the same as in chat.

      get "/communities/:slug/people" do
        @community = community!(params[:slug])
        # Reading a community you run needs no grant, the same rule
        # word-filter and moderation above already follow.
        authorize!(:view_community, community: @community)
        @query = presence(params[:q])
        @cap = PEOPLE_CAP
        @who_can_set = nickname_who_can_set(@community)
        @who_can_set_field = config_field("nickname", :who_can_set)
        identities = deps.identities.recent(community_id: @community.id, query: @query, limit: @cap)
        @rows = people_rows(@community, identities)
        prepare_leftover_config(@community, "nickname")
        @client_section = "people"
        erb :people
      end

      post "/communities/:slug/people" do
        community = community!(params[:slug])
        authorize!(:configure_nickname, community: community)
        with_nickname_error do
          if nickname_who_can_set(community) == Features::Nickname::WHO_NOBODY
            flash_result("Nicknames are not being handed out here; turn who_can_set up under Features first.",
                         error: true)
          else
            save_dashboard_nickname(community)
          end
        end
        redirect to("/communities/#{community.slug}/people?q=#{Rack::Utils.escape(params[:q].to_s)}")
      end

      # Analytics.

      # Cross-community landing: one row per community over the selected window,
      # with a link into each community's detailed view. Same session gate and
      # community picker convention as the audit page.
      get "/analytics" do
        authorize!(:view_analytics, community: Role::DEPLOYMENT)
        @window = ControlPlane::Analytics.window_key(params[:window])
        @windows = ControlPlane::Analytics::WINDOWS.keys
        # Only the communities this reader may open, the same narrowing /audit
        # does: a scoped read passes authorize! with no community named.
        @rows = deps.analytics.community_rows(window: @window, only: readable_communities)
        @wide_page = true
        # Ported: the window filter as TabLinks over two tables, which is what
        # nine columns of counts become inside the seven a Table draws.
        @client_section = "analytics_overview"
        erb :analytics_overview
      end

      # The detailed per-community report: message volume, moderation activity,
      # active senders, reactions and guest usage over the selected window.
      get "/communities/:slug/analytics" do
        @community = community!(params[:slug])
        authorize!(:view_analytics, community: @community)
        @window = ControlPlane::Analytics.window_key(params[:window])
        @windows = ControlPlane::Analytics::WINDOWS.keys
        @channel_view = ControlPlane::Analytics.channel_view_key(params[:channel_view])
        @report = deps.analytics.overview(community: @community, window: @window)
        @client_section = "analytics"
        erb :analytics
      end

      # Audit is one read-only screen at both scopes. The deployment route
      # reads only communities this session may open, and the community route
      # passes its one community through the same rendering path.

      get "/audit" do
        authorize!(:view_audit_log, community: Role::DEPLOYMENT)
        @community = nil
        @source = presence(params[:source])
        @action = presence(params[:action])
        @events = deps.audit.query(
          communities: readable_communities.map(&:slug), source: @source, action: @action, limit: 200
        )
        @wide_page = true
        @client_section = "audit"
        erb :audit
      end

      get "/communities/:slug/audit" do
        @community = community!(params[:slug])
        authorize!(:view_audit_log, community: @community)
        @source = presence(params[:source])
        @action = presence(params[:action])
        @events = deps.audit.query(community: @community.slug, source: @source, action: @action, limit: 200)
        @wide_page = true
        @client_section = "audit"
        erb :audit
      end

      # Redirection.

      # What has been moved out of this community's rooms and into which
      # others. Read-only, so it rides the ordinary view grant rather than
      # asking for one of its own; the single thing on the page that changes
      # anything has its own grant below.
      get "/communities/:slug/redirections" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @redirections = deps.redirections.recent(community_id: @community.id)
        @wide_page = true
        # Ported: a table and a per-row Stop button, nothing this screen
        # needs beyond what Endpoints already proved out.
        @client_section = "redirections"
        erb :redirections
      end

      # Stop a move that is still posting: once reposts have landed and
      # deletes have started, stopping halfway would leave the run in both
      # rooms at once, worse than either end state. See
      # ControlPlane::Redirections#cancel.
      post "/communities/:slug/redirections/:id/stop" do
        @community = community!(params[:slug])
        authorize!(:manage_redirection, community: @community)
        if deps.redirections.cancel(id: params[:id].to_i, community_id: @community.id)
          flash_result("Stopped that move. Nothing has been deleted from the original room.")
        else
          flash_result("That move is not one I can stop: it has either finished or started deleting.", error: true)
        end
        redirect "#{request.script_name}/communities/#{@community.slug}/redirections"
      end

      # Alerts.

      # What this community's scripts have raised, newest first. Read-only, so
      # it rides the ordinary view grant; the two things on the page that change
      # anything share a grant of their own below.
      get "/communities/:slug/alerts" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @alerts = deps.alerts.recent(community_id: @community.id)
        @unseen = @alerts.count { |row| row.seen_at.nil? }
        @wide_page = true
        @client_section = "alerts"
        erb :alerts
      end

      post "/communities/:slug/alerts/:id/seen" do
        community = community!(params[:slug])
        authorize!(:manage_alerts, community: community)
        marked = deps.alerts.mark_seen(id: params[:id].to_i, community_id: community.id)
        flash_result(marked ? "Marked that alert seen." : "No such alert.", error: !marked)
        redirect to("/communities/#{community.slug}/alerts")
      end

      # Everything outstanding at once, for the operator coming back to a
      # backlog they have already read somewhere else.
      post "/communities/:slug/alerts/seen" do
        community = community!(params[:slug])
        authorize!(:manage_alerts, community: community)
        marked = deps.alerts.mark_all_seen(community_id: community.id)
        flash_result("Marked #{marked} #{marked == 1 ? "alert" : "alerts"} seen.")
        redirect to("/communities/#{community.slug}/alerts")
      end

      # Every content policy action an operator reversed with /vindicate: the
      # text a policy matched, the model's own reasoning and confidence, and
      # why the operator disagreed. Read as a corpus rather than a feed, since
      # what it is for is rewriting the description that drew each one.
      get "/communities/:slug/content-policy/misfires" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @misfires = deps.content_policy_misfires.recent(community_id: @community.id)
        @misfire_counts = deps.content_policy_misfires.counts_by_policy(community_id: @community.id)
        @wide_page = true
        # Drawn under the moderation section rather than one of its own: every
        # dashboard has a client renderer for that, and a section with none behind it is a
        # page the dashboard router takes over and then cannot fill.
        @client_section = "moderation"
        erb :content_policy_misfires
      end

      post "/communities/:slug/content-policy/misfires/:id/delete" do
        community = community!(params[:slug])
        authorize!(:configure_content_policy, community: community)
        removed = deps.content_policy_misfires.delete(community_id: community.id, id: params[:id].to_i)
        flash_result(removed ? "Dropped that sample." : "No such sample.", error: !removed)
        redirect to("/communities/#{community.slug}/content-policy/misfires")
      end

      # Where this community's events are sent, and what happened to every
      # attempt. Subscriptions are created over the REST API, not here,
      # since creating one hands out a signing secret; what an operator
      # needs here is the failures.
      get "/communities/:slug/webhooks" do
        @community = community!(params[:slug])
        authorize!(:view_community, community: @community)
        @subscriptions = deps.webhooks.list(community_id: @community.id)
        @deliveries = deps.webhooks.deliveries(community_id: @community.id, limit: 200)
        @failed = deps.webhooks.failed_count(community_id: @community.id)
        @wide_page = true
        # Ported: two tables and a per-row retry button, same shape as
        # Redirections; subscriptions are still created over the REST API.
        @client_section = "webhooks"
        erb :webhooks
      end

      post "/communities/:slug/webhooks/deliveries/:id/retry" do
        community = community!(params[:slug])
        authorize!(:manage_webhooks, community: community)
        sent = deps.webhooks.retry_delivery(id: params[:id].to_i, community_id: community.id)
        flash_result(
          sent ? "Queued that delivery again. It goes out on the next pass." : "That delivery is not one I can send again.",
          error: !sent
        )
        redirect to("/communities/#{community.slug}/webhooks")
      end

      # Backfill proposals. Administrator only, never authorize!: judging one
      # means reading a preview of what would be sent, which PRIVACY.md's
      # narrow exception allows only for this audience, and accepting one
      # relays real messages into a live room.

      # Every channel a sweep has proposed restoring, across every community,
      # grouped by where it stands: waiting on a decision, accepted but not
      # confirmed sent yet, or expired unread. Read-only.
      get "/backfill-proposals" do
        require_admin!
        every = ControlPlane::BackfillProposals::EVERY_COMMUNITY
        @pending = deps.backfill_proposals.pending(community: every)
        @awaiting_relay = deps.backfill_proposals.awaiting_relay(community: every)
        @expired = deps.backfill_proposals.expired(community: every)
        @communities = communities_by_id(@pending + @awaiting_relay + @expired)
        # The server-rendered page supplies initial content; the
        # runtime then replaces #rb-view with the shared Backfill screen.
        @client_section = "backfill_proposals"
        erb :backfill_proposals
      end

      # Both processes' recent log lines, oldest first, for reading a fault
      # without a shell on the box. Administrator only, and never narrowed to a
      # community: a log line carries whatever the code that wrote it put there,
      # which is not scoped to one tenant and is not an operator's to read.
      get "/logs" do
        require_admin!
        @source = DebugLogs.source_of(params[:source])
        @level = DebugLogs.level_of(params[:level])
        @limit = DebugLogs.limit_of(params[:limit])
        view = deps.debug_logs.fetch(source: @source, level: @level, limit: @limit)
        @entries = view["entries"]
        @errors = view["errors"]
        # No @client_section: the dashboard runtime has no Logs screen to swap in,
        # and claiming one would blank the page it is meant to replace.
        @wide_page = true
        erb :logs
      end

      # Durable jobs that gave up, read straight from the scheduled_jobs rows the
      # bot writes rather than over a hop to it. Administrator only and never
      # narrowed to a community: a failure reason carries whatever the handler
      # raised, and most kinds are housekeeping with no tenant at all.
      get "/jobs" do
        require_admin!
        @window = JobFailures.window_of(params[:window])
        @failures = deps.durable_jobs.recent_failures(
          since: Time.now - JobFailures.seconds_of(@window), limit: JobFailures::LIMIT
        )
        # No @client_section: the dashboard runtime has no Jobs screen to swap in,
        # and claiming one would blank the page it is meant to replace.
        @wide_page = true
        erb :jobs
      end

      # Accept one channel's list. The service stamps it approved and hands
      # back the stored items; this route never recomputes what to send, it
      # only asks the bot process (the one holding the adapters) to relay
      # exactly that.
      post "/backfill-proposals/:id/accept" do
        require_admin!
        with_backfill_proposal_error do
          deps.backfill_proposals.approve(community: backfill_proposal_community!(params[:id].to_i),
                                          proposal_id: params[:id].to_i, decided_by: operator_label)
          push_backfill_relay(params[:id].to_i,
                              success: "Accepted. The bot is relaying it now, one message at a time.")
        end
        redirect to("/backfill-proposals")
      end

      post "/backfill-proposals/:id/reject" do
        require_admin!
        with_backfill_proposal_error do
          deps.backfill_proposals.reject(community: backfill_proposal_community!(params[:id].to_i),
                                         proposal_id: params[:id].to_i, decided_by: operator_label)
          flash_result("Rejected. Nothing from that channel will be sent.")
        end
        redirect to("/backfill-proposals")
      end

      # For a proposal accepted but never confirmed relayed, whether the bot
      # was unreachable or an operator wants to nudge it again. Safe to
      # press more than once: the bot skips whatever it already relayed
      # and only marks the proposal relayed once the whole list is through.
      post "/backfill-proposals/:id/retry-relay" do
        require_admin!
        push_backfill_relay(params[:id].to_i, success: "Asked the bot to relay it again.")
        redirect to("/backfill-proposals")
      end

      # The internal YAML surface a client-rendered page reads from: session-authed
      # through the same {Role} every ERB route consults, read-only (a write
      # goes through the form post beside it). See {ViewData} for why this is
      # not part of the public REST API.

      # The chrome around a page rather than the page itself (nav, scope
      # switcher, breadcrumb, brand), so the browser draws the shell and it
      # answers for every page, ported or not. +path+ is read for the current
      # entry but never echoed: every path in the answer is built from {Nav}.
      get "/internal/shell" do
        internal_view do
          view_data.shell(path: params[:path].to_s, prefix: request.script_name)
            .merge("brand" => shell_brand)
        end
      end

      get "/internal/communities" do
        internal_view { view_data.communities }
      end

      # The two deployment-wide sections, which belong to no community and so
      # sit outside the /internal/communities tree.
      get "/internal/onboarding" do
        internal_view { view_data.onboarding }
      end

      get "/internal/operator-tokens" do
        internal_view { view_data.operator_tokens }
      end

      get "/internal/administrators" do
        internal_view { view_data.administrators }
      end

      # The set/unset map ViewData#accounts draws its env pill from, resolved
      # here rather than handed a Deps method to read: which token env vars
      # are actually set is a fact of this process at request time, never
      # part of the control plane {Deps} bundles.
      get "/internal/accounts" do
        internal_view { view_data.accounts(adapter: params[:adapter], token_env_set: account_token_env_set) }
      end

      get "/internal/integrations" do
        internal_view { view_data.integrations }
      end

      get "/internal/settings/datastore" do
        internal_view { view_data.datastore }
      end

      get "/internal/analytics" do
        internal_view { view_data.analytics_overview(window: params[:window]) }
      end

      get "/internal/viewers" do
        internal_view { view_data.viewers(issued_token: take_flash(:auth_token_themed)) }
      end

      # The one-time raw key rides the relay the ERB render armed, since the
      # client render replaces the body that already spent the flash itself.
      get "/internal/api-keys" do
        internal_view do
          view_data.api_keys(
            issued_token: take_flash(:api_key_token_themed),
            issued_label: take_flash(:api_key_label_themed),
            platform_accounts: platform_account_names
          )
        end
      end

      get "/internal/communities/:slug" do
        internal_view { view_data.overview(params[:slug]) }
      end

      get "/internal/communities/:slug/rooms" do
        internal_view { view_data.rooms(params[:slug], state: params[:state]) }
      end

      get "/internal/communities/:slug/rooms/automatic-mapping" do
        internal_view { view_data.automatic_mapping(params[:slug]) }
      end

      get "/internal/communities/:slug/rooms/channels/:id" do
        internal_view { view_data.room_channel(params[:slug], params[:id]) }
      end

      get "/internal/communities/:slug/rooms/:room_key" do
        internal_view { view_data.room_detail(params[:slug], params[:room_key]) }
      end

      get "/internal/communities/:slug/endpoints" do
        internal_view { view_data.endpoints(params[:slug]) }
      end

      get "/internal/communities/:slug/endpoints/new" do
        internal_view { view_data.endpoint_edit(params[:slug]) }
      end

      get "/internal/communities/:slug/scripts/new" do
        internal_view { view_data.script_edit(params[:slug]) }
      end

      get "/internal/communities/:slug/scripts/:id" do
        internal_view { view_data.script_edit(params[:slug], id: params[:id]) }
      end

      get "/internal/communities/:slug/endpoints/:id" do
        internal_view { view_data.endpoint_edit(params[:slug], id: params[:id]) }
      end

      get "/internal/communities/:slug/redirections" do
        internal_view { view_data.redirections(params[:slug]) }
      end

      get "/internal/communities/:slug/webhooks" do
        internal_view { view_data.webhooks(params[:slug]) }
      end

      get "/internal/audit" do
        internal_view { view_data.audit(source: params[:source], action: params[:action]) }
      end

      get "/internal/communities/:slug/audit" do
        internal_view { view_data.audit(slug: params[:slug], source: params[:source], action: params[:action]) }
      end

      get "/internal/communities/:slug/scripts" do
        internal_view { view_data.scripts(params[:slug]) }
      end

      get "/internal/communities/:slug/features" do
        internal_view { view_data.features(params[:slug], scope: params[:scope]) }
      end

      get "/internal/communities/:slug/features/:feature/config" do
        internal_view { view_data.feature_config(params[:slug], params[:feature], scope: params[:scope]) }
      end

      get "/internal/communities/:slug/participation" do
        internal_view { view_data.participation(params[:slug]) }
      end

      get "/internal/communities/:slug/alerts" do
        internal_view { view_data.alerts(params[:slug]) }
      end

      get "/internal/communities/:slug/files" do
        internal_view { view_data.files(params[:slug]) }
      end

      get "/internal/communities/:slug/people" do
        internal_view { view_data.people(params[:slug], query: params[:q]) }
      end

      get "/internal/communities/:slug/moderation" do
        internal_view { view_data.moderation(params[:slug], query: params[:q]) }
      end

      get "/internal/communities/:slug/events" do
        internal_view { view_data.events(params[:slug]) }
      end

      get "/internal/communities/:slug/word-filter" do
        internal_view { view_data.word_filter(params[:slug]) }
      end

      get "/internal/communities/:slug/faq" do
        internal_view { view_data.faq(params[:slug]) }
      end

      # Which key env vars this process actually holds is a request-time fact
      # of the process, resolved here rather than through a Deps method, the
      # same split /internal/accounts makes.
      get "/internal/communities/:slug/platforms" do
        internal_view { view_data.platforms(params[:slug], token_env_set: platform_token_env_set(params[:slug])) }
      end

      # The one-time minted token rides the relay the ERB render armed, the
      # same hop /internal/api-keys makes for a raw key.
      get "/internal/communities/:slug/operators" do
        internal_view do
          view_data.operators(params[:slug], issued_token: take_flash(:auth_token_themed))
        end
      end

      get "/internal/communities/:slug/analytics" do
        internal_view do
          view_data.analytics(params[:slug], window: params[:window], channel_view: params[:channel_view])
        end
      end

      get "/internal/communities/:slug/polls" do
        internal_view { view_data.polls(params[:slug]) }
      end

      # The one-time guest link rides the relay the ERB render armed, the same
      # hop /internal/api-keys makes for a raw key.
      get "/internal/communities/:slug/guests" do
        internal_view do
          view_data.guests(params[:slug], issued_link: take_flash(:guest_link_themed),
                                          issued_nickname: take_flash(:guest_nickname_themed))
        end
      end

      get "/internal/backfill-proposals" do
        internal_view { view_data.backfill_proposals }
      end

      get "/internal/logs" do
        internal_view do
          view_data.logs(source: params[:source], level: params[:level], limit: params[:limit])
        end
      end

      get "/internal/documentation" do
        internal_view { view_data.documentation(prefix: request.script_name) }
      end

      get "/internal/licence" do
        internal_view { view_data.licence(prefix: request.script_name) }
      end

      # Helpers.

      helpers do
        # The control vocabulary. Both halves here, since the admin dashboard
        # is the surface that owns a navigation model; the guest portal takes
        # Primitives::Identity alone.
        include Primitives::Identity
        include Primitives::Layout

        def deps = settings.deps

        def models = settings.deps.models

        # DB rows plus the deployment-configured floor, which is owner-level in every community
        # and so counts once per community rather than once per deployment.
        def operator_count(community_id)
          models.operator.where(community_id: community_id).count + Security::ProtectedOperators.default.entries.size
        end

        def authenticated?
          [Role::ADMINISTRATOR.to_s, Role::OPERATOR.to_s].include?(session[:role])
        end

        # Cookies identify a login; current server-side grants authorize it.
        # Old cookies without a verifiable login are deliberately signed out.
        def refresh_session_authorization!
          return if session[:role].nil?

          if session[:login_kind] == "password"
            valid = session[:expires_at].is_a?(Integer) && session[:expires_at] > Time.now.to_i &&
                    !configured_secret.empty? &&
                    Rack::Utils.secure_compare(password_session_binding, session[:password_binding].to_s)
            session.clear unless valid
            return
          end

          outcome = deps.web_login.session_claims(id: session[:login_token_id])
          unless outcome.ok?
            session.clear
            return
          end

          session[:role] = still_an_administrator?(outcome) ? Role::ADMINISTRATOR.to_s : Role::OPERATOR.to_s
          session[:operator_communities] = current_operator_communities(outcome)
          session[:viewer] = still_a_viewer?(outcome)
          session[:viewer_communities] = current_viewer_communities(outcome)
        rescue StandardError => e
          logger&.warn { "dashboard: session authorization failed: #{e.class}" }
          session.clear
        end

        def password_session_binding
          OpenSSL::HMAC.hexdigest("SHA256", settings.session_secret, configured_secret)
        end

        def internal_surface_path?
          request.path_info.start_with?("/internal/")
        end

        # The reader behind a client-rendered section, built per request from the same
        # role every ERB route authorises against.
        def view_data
          ViewData.new(deps: deps, role: current_role)
        end

        def internal_yaml(value)
          YAMLCamel.dump(value)
        end

        # One section's document, or the refusal it raised. A community outside
        # this session's reach and a slug that names nothing answer with the
        # same 404, which is what keeps a response from confirming that another
        # community's resource is there.
        def internal_view
          internal_yaml(yield)
        rescue ViewData::NotFound
          halt 404, internal_yaml("error" => "not found")
        rescue ViewData::Forbidden
          halt 403, internal_yaml("error" => "forbidden")
        end

        # The compiled head script, inlined into <head> above every stylesheet.
        # Read from the built asset rather than written in Ruby, since it is
        # Civet like the rest of the runtime, and empty when npm run build has
        # not run, which is what everything else in that directory does.
        def dashboard_head_script
          App.dashboard_head_script(settings.public_folder)
        end

        # The floor inlined into every page: the content rules always, and the
        # primitive classes underneath them when no dashboard stylesheet is
        # drawing those. One tag rather than two, the same pair
        # spec/support/css_cascade.rb resolves as the un-client-rendered page.
        def floor_stylesheet
          return fallback_stylesheet if dashboard_stylesheet?

          "#{fallback_stylesheet}\n#{fallback_vocabulary_stylesheet}"
        end

        def fallback_stylesheet = App.stylesheet(App::FALLBACK)

        def fallback_vocabulary_stylesheet = App.stylesheet(App::FALLBACK_VOCABULARY)

        # Whether this deployment has the compiled dashboard stylesheet.
        def dashboard_stylesheet?
          App.dashboard_stylesheet?(settings.public_folder)
        end

        def initial_shell
          return signed_out_shell unless authenticated?

          view_data.shell(path: request.path_info, prefix: request.script_name).merge("brand" => shell_brand)
        end

        def initial_shell_json
          JSON.generate(initial_shell).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
        end

        # The configured login secret, read from the environment by NAME at
        # request time. Never cached, never written to disk.
        def configured_secret
          settings.dashboard_env[settings.secret_env].to_s
        end

        # The community row for a slug, or a clean 404.
        def community!(slug)
          row = deps.community(slug)
          halt 404, erb(:not_found) if row.nil?
          row
        end

        # One pending request per person per community is what the partial unique
        # index already enforces, so a second press is reported as already asked
        # rather than raising.
        def record_access_request(community)
          existing = models.operator_request.where(
            community_id: community.id, requester_native_id: requester_id, state: "pending"
          ).first
          return :already if existing

          models.operator_request.create(
            community_id: community.id, adapter: "web",
            requester_native_id: requester_id, requester_display: requester_id,
            state: "pending", requested_at: Time.now
          )
          :created
        rescue StandardError => e
          logger&.warn { "dashboard: could not record an access request: #{e.class}: #{e.message}" }
          :failed
        end

        # Who is asking. The web session carries the operator rows it resolved
        # from the login token, so the first is a stable enough identity for a
        # request an administrator reads by name.
        def requester_id
          ids = session[:operator_communities] || []
          "web-operator-#{ids.sort.join("-")}"
        end

        # One search result on the wire, with the mount point put back on the
        # front of its path so the caller can follow it from any deployment.
        def search_payload(entry)
          entry.to_h.merge(path: "#{request.script_name}#{entry.path}")
        end

        # Only the communities this reader may open: an administrator and a
        # viewer see them all, an operator only the ones they operate. Asked
        # through {Role#can?} rather than the write scope, so the picker and
        # the community page always agree.
        def readable_communities
          deps.communities.select { |row| current_role.can?(:view_community, community: row) }
        end

        # Authorization: the role behind the current session and the checks
        # every route consults before it does anything. The permission
        # matrix lives in {Role#can?}; this only resolves which {Role} a
        # session gets and gives every route one seam ({#authorize!}).

        # The {Role} behind this session, resolved fresh from +session[:role]+
        # on every call, never cached. Password login sets +administrator+;
        # the +/web-login+ flow sets +operator+ with
        # +session[:operator_communities]+ as the write scope, plus
        # +session[:viewer]+ and +session[:viewer_communities]+ for view-only
        # reach.
        def current_role
          if session[:role] == Role::OPERATOR.to_s
            Role.operator(
              community_ids: session[:operator_communities] || [],
              write_actions: deps.action_permissions.operator_write_actions,
              viewer: session[:viewer] == true,
              viewer_community_ids: session[:viewer_communities] || []
            )
          elsif session[:role] == Role::ADMINISTRATOR.to_s
            Role.administrator
          end
        end

        # Halt with 403 unless the session is an Administrator: for routes not
        # on any operator allow list (platform connections, join links, guest
        # invites, the feature-toggle escape hatch, community lifecycle). Also
        # the safe default for a route added later, since a viewer is refused
        # here until named in {Role::OVERSIGHT_READ_ACTIONS}.
        def require_admin!
          halt 403, erb(:forbidden) unless current_role&.administrator?
        end

        # The general-purpose check every other route consults: may the
        # current role take +action+ against +community+. Delegates to
        # {Role#can?}, which applies the permission matrix and write-own
        # scoping; no route needs to know either directly.
        # @param community [Object, Symbol] the community this page is about, or
        #   {Role::DEPLOYMENT} for one about the whole deployment. Required, so
        #   a route cannot lose the scope its grant is spent against.
        def authorize!(action, community:)
          halt 403, erb(:forbidden) unless current_role&.can?(action, community: community)
        end

        # The same question {#authorize!} asks, answered instead of halted,
        # for a view deciding whether to draw a control live or flat. :sign_in
        # answers true with no session (the login forms' own submit spends
        # it); anything else with no session answers false rather than raising.
        def may?(action, community:)
          return true if action == :sign_in

          role = current_role
          return false if role.nil?

          role.can?(action, community: community)
        end

        # Whether this session reads the whole deployment rather than a
        # community at a time, for a section of a community page that describes
        # every community at once. An operator of one community opens the page
        # around it and never sees that section.
        def deployment_wide_reader?
          current_role.administrator? || current_role.viewer?
        end

        # The one Help disclosure a screen gets: background, alpha policy and
        # reference prose read once. What a control does, risks or spends
        # stays beside that control, since none of that is background.
        # @param paragraphs [Array<String>] the prose, one Notice each
        # @param action [Symbol] the grant the reference link spends
        # @param community [Object, Symbol] the scope it is spent in
        # @param reference [Array, nil] the documentation, as [label, href]
        # @param title [String] the summary a reader opens
        def help_disclosure(paragraphs, action:, community:, reference: nil, title: "Help")
          body = Array(paragraphs).map { |text| notice(text, tone: :info) }.join
          label, href = reference
          body += button(label, action: action, community: community, variant: :secondary,
                         to: href, new_tab: true) if reference
          section(title: title, variant: :collapsible, body: body)
        end

        # A submit button, drawn flat and unclickable when the current role
        # may not take +action+ here, disabled rather than absent.
        # @param label [String] the button text
        # @param action [Symbol, Array<Symbol>] the grant it spends; an array is live if ANY is allowed
        # @param style [String, nil] an extra button class, "secondary" or "danger"
        # @param name [String, nil] a submit name, for a form with several buttons
        # @param value [String, nil] that submit's value
        # @param enabled [Boolean] a second reason to draw flat, unrelated to permission
        def act_button(label, action, community:, style: nil, name: nil, value: nil, enabled: true)
          permitted = Array(action).any? { |one| may?(one, community: community) }
          allowed = enabled && permitted
          classes = [style, ("disabled" unless allowed)].compact.join(" ")
          attrs = +%(type="submit")
          attrs << %( class="#{h(classes)}") unless classes.empty?
          attrs << %( name="#{h(name)}") unless name.nil?
          attrs << %( value="#{h(value)}") unless value.nil?
          attrs << " disabled" unless allowed
          # Only when permission is the reason, so a button flat for some other
          # reason does not blame the reader's role for it.
          attrs << %( title="Read only: you cannot change this here.") unless permitted
          # The observable signature of a button that spent a grant. The
          # Primitives::Identity#button that replaces this emits the same
          # attribute, and the rendered vocabulary spec fails any button
          # without one, which is how a raw <button> gets found.
          attrs << %( data-grant="#{h(Array(action).join(" "))}")
          "<button #{attrs}>#{h(label)}</button>"
        end

        # A join link, invite URL or secret token value, rendered for display.
        # An operator or viewer never sees a real one, a second independent
        # guard even though {#require_admin!} already keeps those routes out
        # of reach; an administrator sees +value+ unchanged, a blank +value+
        # passes through since there's nothing to redact.
        def redact_secret(value)
          return value if current_role.administrator? || value.to_s.empty?

          "[redacted]"
        end

        # Whether +community+ is explicitly protected by deployment configuration
        # (config/protected_communities.yml): identity and liveness are
        # locked down for these in the dashboard, so an admin cannot
        # fat-finger the most important communities into a broken state.
        # Channels and rooms stay fully mutable either way; only connection
        # identity ({ControlPlane::PlatformConnections#update_identity}
        # checks this itself) and start/stop below are guarded.
        def protected_community?(community)
          return false if community.nil?

          ControlPlane::ProtectedCommunities.default.protects_community?(community)
        end

        # Who the audit trail should name for this session's writes: the
        # handle a web-login token carried, when the session opened that way,
        # or the role alone for a root-password session that nobody in
        # particular owns.
        def operator_label
          handle = presence(session[:operator_handle])
          handle ? "dashboard:#{handle}" : "dashboard:#{current_role.kind}"
        end

        # The label or platform handle a web-login token's operator hash
        # names, or nil when the hash is missing or carries neither. The
        # hash arrives with string keys after its JSON round trip, so both
        # are read.
        def operator_identity(operator)
          return nil if operator.nil?

          label = presence(operator["label"] || operator[:label])
          adapter = presence(operator["adapter"] || operator[:adapter])
          native_id = presence(operator["native_id"] || operator[:native_id])
          label || presence([adapter, native_id].compact.join(":"))
        end

        # How the sign-in confirmation names the session a link would open,
        # falling back to a generic phrase when the token names nobody.
        def login_operator_label(operator)
          operator_identity(operator) || "an operator"
        end

        # The confirmation is the last place a person sees before a link
        # becomes a session, so it names the authority the token claims.
        def login_scope_label(outcome)
          return "administrator control of the whole deployment" if outcome.administrator == true
          return "read access to every community" if outcome.viewer == true

          ids = (Array(outcome.community_ids) + Array(outcome.viewer_communities)).uniq
          return "nothing beyond signing in" if ids.empty?

          "#{ids.length} #{ids.length == 1 ? "community" : "communities"}"
        end

        # Whether a sign-in link claiming the administrator role still finds its
        # holder on the roster. What the token carries is a claim from when it
        # was minted, so the roster is asked again here and a revoked
        # administrator's outstanding link opens an ordinary session instead.
        def still_an_administrator?(outcome)
          return false unless outcome.administrator == true

          operator = outcome.operator || {}
          adapter = presence(operator["adapter"] || operator[:adapter])
          return false if adapter.nil?

          deps.dashboard_administrators.administrator?(
            adapter: adapter,
            username: operator["username"] || operator[:username],
            native_id: operator["native_id"] || operator[:native_id]
          )
        rescue StandardError => e
          logger&.warn { "dashboard: could not resolve an administrator link: #{e.class}: #{e.message}" }
          false
        end

        # Whether a deployment-wide viewer claim still finds a live grant.
        def still_a_viewer?(outcome)
          return false unless outcome.viewer == true

          operator = outcome.operator || {}
          adapter = presence(operator["adapter"] || operator[:adapter])
          return false if adapter.nil?

          deps.dashboard_viewers.viewer?(adapter: adapter,
                                         username: operator["username"] || operator[:username],
                                         native_id: operator["native_id"] || operator[:native_id])
        rescue StandardError => e
          logger&.warn { "dashboard: could not resolve a viewer link: #{e.class}: #{e.message}" }
          false
        end

        # The operator scope the live roster still grants to the identity a
        # token names. A valid token can only narrow here, never gain a new
        # community it did not claim when it was issued.
        def current_operator_communities(outcome)
          operator = outcome.operator || {}
          adapter = presence(operator["adapter"] || operator[:adapter])
          return [] if adapter.nil?

          Array(outcome.community_ids).select do |community_id|
            deps.operators.resolve_operator(
              community_id: community_id, adapter: adapter,
              native_id: operator["native_id"] || operator[:native_id],
              username: operator["username"] || operator[:username]
            )
          end
        rescue StandardError => e
          logger&.warn { "dashboard: could not resolve operator communities for a link: #{e.class}: #{e.message}" }
          []
        end

        # The viewer-only community scope follows the same live lookup as the
        # operator scope, so a revoked viewer grant cannot survive in a token.
        def current_viewer_communities(outcome)
          operator = outcome.operator || {}
          adapter = presence(operator["adapter"] || operator[:adapter])
          return [] if adapter.nil?

          Array(outcome.viewer_communities).select do |community_id|
            deps.community_viewers.viewer?(
              community_id: community_id, adapter: adapter,
              native_id: operator["native_id"] || operator[:native_id],
              username: operator["username"] || operator[:username]
            )
          end
        rescue StandardError => e
          logger&.warn { "dashboard: could not resolve viewer communities for a link: #{e.class}: #{e.message}" }
          []
        end

        # The platform_connection row for a community + id, or a clean 404.
        def platform_connection!(community, id)
          row = models.platform_connection.where(community_id: community.id, id: id).first
          halt 404, erb(:not_found) if row.nil?
          row
        end

        # The fluxer_instance row for a community + id, or a clean 404.
        # Scoped to the community, same reasoning as
        # {#platform_connection!}: a caller cannot reach another community's
        # instance by guessing an id.
        def fluxer_instance!(community, id)
          row = models.fluxer_instance.where(community_id: community.id, id: id).first
          halt 404, erb(:not_found) if row.nil?
          row
        end

        # The irc_network row for a community + id, or a clean 404, the same
        # reasoning as {#fluxer_instance!}.
        def irc_network!(community, id)
          row = models.irc_network.where(community_id: community.id, id: id).first
          halt 404, erb(:not_found) if row.nil?
          row
        end

        # Accounts.

        # The accounts row for an id, or a clean 404. No community scoping,
        # unlike {#fluxer_instance!} above: an account belongs to the
        # deployment, so an id is the whole address.
        def account!(id)
          row = deps.accounts.find(id: id)
          halt 404, erb(:not_found) if row.nil?
          row
        end

        def with_account_error
          yield
        rescue ControlPlane::Accounts::Invalid => e
          flash_result(e.message, error: true)
        end

        # Every account's token_env name resolved against this process's own
        # environment, the map {ViewData#accounts} draws its "key present" /
        # "not set in this process" pill from. Built here rather than handed
        # settings.dashboard_env wholesale: ViewData reads only booleans it is
        # actually asked about, never the raw environment.
        # Every key env var the platforms screen shows a state for: the token
        # behind each configured account, and each Fluxer instance's own key.
        def platform_token_env_set(slug)
          community = deps.community(slug)
          map = account_token_env_set
          return map if community.nil?

          deps.fluxer_instances.list(community: community).each do |instance|
            name = presence(instance.api_key_env)
            map[name] = token_env_set?(name) if name
          end
          map
        end

        def account_token_env_set
          deps.accounts.list.each_with_object({}) do |account, map|
            name = presence(account.json_value(:settings)["token_env"])
            map[name] = token_env_set?(name) if name
          end
        end

        # The account_schema for an adapter picked from the add form, or nil
        # with the reason flashed. Guards against a hand-typed ?adapter= for a
        # platform nothing is registered under, which would otherwise raise out
        # of the view rather than the route.
        def account_schema_or_flash(adapter)
          schema = account_schema(adapter)
          flash_result("unknown adapter #{adapter.to_s.inspect}", error: true) if schema.nil?
          schema
        end

        # An adapter's account_schema, or nil when nothing is registered under
        # that name. Nil rather than raising because the LISTING has to survive
        # it: a row written by a deployment that had an extra adapter loaded
        # must still render, as an account this process cannot edit, instead of
        # taking the whole page down with a 500.
        def account_schema(adapter)
          ControlPlane::Accounts.schema_for(adapter)
        rescue ControlPlane::Accounts::Invalid
          nil
        end

        # One submitted account form, shaped for {ControlPlane::Accounts}: a
        # settings hash the adapter's schema then validates and coerces. An
        # absent or blank field is left out entirely (not sent as nil) so the
        # schema applies its default; unlike {#config_field_submission}, which
        # shapes FeatureControls' JSON blob, this wants the plain Ruby value.
        # A list reads by the same rules the feature config form uses, +current+
        # being the row's settings so an emptied box is told from a blank one.
        def account_settings_from_params(schema, params, current = {})
          schema.fields.each_value.with_object({}) do |field, out|
            key = field.name.to_s
            next unless params.key?(key)

            case field.type
            when :boolean then out[key] = params[key].to_s == "true"
            when :array
              entries = config_array_submission(field, params[key], current)
              out[key] = entries unless entries.nil?
            else
              value = presence(params[key])
              out[key] = value unless value.nil?
            end
          end
        end

        # One form control for an account field, rendered from that field's
        # own schema declaration, the same typed-input rules feature_config.erb
        # applies. A helper rather than inline ERB since the accounts page
        # renders these twice; the field name comes from the schema, never
        # operator input, so only the current value needs escaping.
        def account_field_control(field, value)
          name = field.name.to_s
          if field.type == :boolean
            checked = [true, "true"].include?(value) ? " checked" : ""
            return %(<input type="hidden" name="#{h(name)}" value="false">) +
                   %(<input type="checkbox" name="#{h(name)}" value="true"#{checked}> on)
          end

          if field.one_of
            options = field.one_of.map do |option|
              %(<option value="#{h(option)}"#{" selected" if option.to_s == value.to_s}>#{h(option)}</option>)
            end.join
            return %(<select name="#{h(name)}">#{options}</select>)
          end

          case field.type
          when :array
            %(<textarea name="#{h(name)}" rows="3">#{h(config_field_lines(value))}</textarea>)
          when :integer, :float
            step = field.type == :float ? ' step="any"' : ""
            %(<input type="number"#{step} name="#{h(name)}" value="#{h(value)}">)
          else
            %(<input type="text" name="#{h(name)}" value="#{h(value)}">)
          end
        end

        # What an account's field should show: the row's own stored value when
        # it set one, else the schema's declared default, so a form pre-fills
        # with what the gateway actually runs at rather than a blank that reads
        # as unset. Same rule as {#config_field_value}, over a settings blob
        # instead of a feature config blob.
        def account_field_value(field, settings)
          key = field.name.to_s
          settings.key?(key) ? settings[key] : field.default
        end

        # The pending_spaces row for an id, or a clean 404.
        def pending_space!(id)
          row = deps.pending_spaces.find(id)
          halt 404, erb(:not_found) if row.nil?
          row
        end

        # Where a decision on a pending space lands afterwards: back on the
        # community page a suggestion was accepted from, else the Onboarding
        # queue. The slug is resolved against a real community first, so the
        # submitted value can never steer the redirect anywhere else.
        def pending_return_path
          slug = presence(params[:from_community])
          community = slug && deps.community(slug)
          community ? "/communities/#{community.slug}/rooms?state=unroomed" : "/onboarding"
        end

        # The flash text for an approve attempt's result. Approval
        # deliberately writes no room (the space has no channel rows yet),
        # which used to leave an administrator on a community with no next
        # step named; that next step is spelled out here instead.
        def approve_flash(result)
          case result.status
          when :approved
            "Approved #{result.row.name || result.row.external_id}: presence and discovery only under " \
              "#{result.community.slug}, no feature was enabled. Next, once discovery has listed its " \
              "channels, map one into a room on Rooms: a room may hold a single channel, and " \
              "a room is what the word filter, FAQ, events and guest access attach to."
          when :not_pending
            "That request is no longer pending."
          when :invalid
            "Choose an existing community, or enter a name for a new one."
          else
            "That pending item was not found."
          end
        end

        # The Onboarding page, assembled here rather than in the view: the
        # primitive calls below return plain strings, and a block passed to one
        # of them from inside an .erb file would share that template's own
        # output buffer instead of returning its own, so composition happens in
        # Ruby and the view is the one line that renders the result.
        def onboarding_page
          intro = section(variant: :plain, body: onboarding_intro)
          queue = @pending_spaces.empty? ? notice("Nothing is waiting on a decision.", tone: :empty) : onboarding_queue
          sections = intro + queue
          sections += denied_spaces_section if @denied_spaces && !@denied_spaces.empty?
          page(title: "Onboarding", sections: sections)
        end

        def onboarding_intro
          notice(
            "Every space the bot has been added to that no community owns yet, whichever platform it came " \
            "from. Accept one as a brand new community or as another platform on a community that already " \
            "exists, or reject it. Accepting authorizes PRESENCE and channel discovery ONLY: it bridges " \
            "nothing and enables no feature. Left undecided, the bot leaves on its own around the time each " \
            "card shows, unless the card says it has no timer.", tone: :info
          ) + notice(
            "A pending space stays here until somebody accepts it, so this remains the full list.", tone: :info
          )
        end

        def onboarding_queue
          @pending_spaces.map { |pending| pending_space_section(pending) }.join
        end

        # One pending space: what it is, who added it, and the accept/reject
        # forms. A Section per card, the same shape the queue always had, with
        # KeyValues taking over the loose cfg-row paragraphs and a list-valued
        # pair (Channels) drawing as Tags on its own.
        def pending_space_section(pending)
          channels = pending.json_value(:sample_channels)
          channels = channels.is_a?(Array) ? channels.first(10) : []
          body = tag("#{pending.adapter}/#{pending.account}") + key_values(pending_space_info(pending, channels)) +
                 pending_accept_form(pending) + pending_reject_form(pending)
          section(title: pending.name || pending.external_id, body: body)
        end

        def pending_space_info(pending, channels)
          info = [["Space id", pending.external_id]]
          if pending.inviter_display || pending.inviter_username || pending.inviter_native_id
            inviter = pending.inviter_display || pending.inviter_username || pending.inviter_native_id
            inviter = "#{inviter} (@#{pending.inviter_username})" if pending.inviter_username && pending.inviter_display
            info << ["Added by", inviter]
          end
          info << ["Members", pending.member_count] if pending.member_count
          info << ["Channels", channels] unless channels.empty?
          info << ["Pending since", pending.created_at, :timestamp]
          info << if pending.job_id
                    ["Auto-leaves", pending.expires_at, :timestamp]
                  else
                    ["Auto-leaves", "no timer, waits here until somebody decides"]
                  end
          info
        end

        # target/new_community_name/community_id/make_operator, unchanged from
        # the params the POST handler already reads; only the controls drawing
        # them move onto Field. make_operator becomes a toggle rather than a
        # checkbox, so declining it is a submitted "false" instead of the
        # value simply being absent, which is the toggle Field's whole reason
        # to exist over a checkbox.
        def pending_accept_form(pending)
          has_targets = @attachable_communities && !@attachable_communities.empty?
          fields = +""
          hidden = {}
          if has_targets
            fields << field(name: "target", label: "Target", type: :choice, value: "new",
                            options: [["new", "New community"], ["existing", "Attach to existing"]])
            fields << field(name: "new_community_name", label: "New community name", type: :text,
                            value: pending.name, hint: "Used when target is New community.")
            fields << field(name: "community_id", label: "Existing community", type: :select,
                            options: @attachable_communities.map { |c| [c.id, "#{c.slug} - #{c.name}"] },
                            hint: "Used when target is Attach to existing.")
          else
            hidden[:target] = "new"
            fields << field(name: "new_community_name", label: "New community name", type: :text, value: pending.name)
          end
          if pending.inviter_native_id
            inviter = pending.inviter_display || pending.inviter_username || "the inviter"
            fields << field(name: "make_operator", label: "Make operator", type: :toggle, value: "true",
                            hint: "Grants #{inviter} operator access to the resulting community.")
          end
          form(action: "#{request.script_name}/pending/#{pending.id}/approve", fields: fields, hidden: hidden,
               submit: button("Accept", action: :manage_pending_spaces, community: Role::DEPLOYMENT))
        end

        def pending_reject_form(pending)
          form(action: "#{request.script_name}/pending/#{pending.id}/deny",
               submit: button("Reject", action: :manage_pending_spaces, community: Role::DEPLOYMENT,
                              variant: :destructive))
        end

        def denied_spaces_section
          body = notice(
            "Rejected spaces. The bot has left (or gone inert) in each; clear an entry to let a future " \
            "re-add be reviewed again instead of refused on sight.", tone: :info
          ) + denied_spaces_table
          section(title: "Blacklisted spaces", body: body)
        end

        def denied_spaces_table
          table(
            columns: [
              { key: :space, header: "Space" }, { key: :platform, header: "Platform", format: :code },
              { key: :decided_at, header: "Decided", format: :timestamp }, { key: :decided_by, header: "By" }
            ],
            rows: @denied_spaces.map { |denied|
              { id: denied.id, space: denied.name || denied.external_id,
                platform: "#{denied.adapter}/#{denied.account}",
                decided_at: denied.decided_at, decided_by: denied.decided_by }
            },
            empty: "No blacklisted spaces.",
            actions: ->(row) { denied_space_clear_form(row) }
          )
        end

        # A raw, unstyled <form>: the same plumbing-not-a-component choice the
        # Endpoints table's own row actions make, since Table's actions column
        # is one compact inline slot and Form draws a block of its own.
        def denied_space_clear_form(row)
          target = "#{request.script_name}/pending/#{h(row[:id])}/clear"
          %(<form method="post" action="#{target}">#{button("Clear", action: :manage_pending_spaces, community: Role::DEPLOYMENT, variant: :secondary)}</form>)
        end

        # The Operator login links page, assembled the same way Onboarding is.
        def operator_tokens_page
          about = section(title: "About web-login links", body: operator_tokens_about)
          active = section(title: "Active links", body: operator_tokens_table)
          page(title: "Operator login links", sections: about + active)
        end

        def operator_tokens_about
          notice(
            "A web-login link is what an operator gets back from DMing the bot /web-login: a short-lived " \
            "link (about an hour) that signs them into this dashboard as an operator, scoped to the " \
            "communities they run. It stays usable for its whole lifetime, so opening it more than once " \
            "is fine; revoking it here ends it early.", tone: :info
          ) + notice(
            "A link can also carry viewer, which reads every community and changes nothing. Grant and " \
            "revoke it on the Viewers page; only an administrator can, since it spans every community. A " \
            "handle named in the configuration that ships with this deployment holds it too, and that " \
            "floor cannot be revoked from anywhere. A viewer who also operates a community gets both on " \
            "one link: they read everything, and they change only what an operator of that community may " \
            "change.", tone: :info
          )
        end

        def operator_tokens_table
          table(
            columns: [
              { key: :operator_label, header: "Operator" }, { key: :platform, header: "Platform", format: :code },
              { key: :communities_label, header: "Communities" }, { key: :reads_label, header: "Reads" },
              { key: :issued_at, header: "Issued", format: :timestamp },
              { key: :expires_at, header: "Expires", format: :timestamp }
            ],
            rows: @tokens.map { |token| operator_token_row(token) },
            empty: "No active operator login links.",
            actions: ->(row) { operator_token_revoke_form(row) }
          )
        end

        def operator_token_row(token)
          operator = token[:operator] || {}
          communities = Array(token[:communities]).map { |c| c["slug"] || c[:slug] }
          {
            id: token[:id], operator_label: operator["label"] || operator[:label],
            platform: "#{operator["adapter"] || operator[:adapter]}/#{operator["account"] || operator[:account]}",
            communities_label: communities.empty? ? "none" : communities.join(", "),
            reads_label: token[:viewer] ? "Every community" : "The ones listed",
            issued_at: parse_token_time(token[:issued_at]), expires_at: parse_token_time(token[:expires_at])
          }
        end

        # issued_at/expires_at arrive as ISO 8601 strings off the token
        # payload; parsed to a real Time so Format.timestamp draws them in the
        # one shape every other absolute time on the dashboard uses, rather
        # than the raw string passing straight through.
        def parse_token_time(value)
          Time.parse(value.to_s)
        rescue ArgumentError, TypeError
          value
        end

        def operator_token_revoke_form(row)
          target = "#{request.script_name}/operator-tokens/#{h(row[:id])}/revoke"
          %(<form method="post" action="#{target}">#{button("Revoke", action: :manage_operator_tokens, community: Role::DEPLOYMENT, variant: :destructive)}</form>)
        end

        # The policy misfires page, assembled the way Operator login links is.
        # Every row is one match an operator called wrong, kept so a policy's
        # own wording can be rewritten against real examples.
        def content_policy_misfires_page
          sections = section(title: "About policy misfires", body: content_policy_misfires_about)
          sections += section(title: "Which description is drawing them",
                              body: content_policy_misfire_counts_table) if @misfire_counts.any?
          sections += section(title: "Reversed matches", body: content_policy_misfires_table)
          page(title: "#{@community.name}: policy misfires", sections: sections)
        end

        def content_policy_misfires_about
          notice(
            "Every content policy action an operator reversed with /vindicate, newest first. Each row " \
            "is one labelled mistake: the text a policy matched, the model's own reasoning and how sure " \
            "it was, and the reason the operator gave for disagreeing. They are here so a description " \
            "that keeps drawing the wrong messages can be rewritten against real examples rather than " \
            "guesses, and so a minimum_confidence can be set from numbers that actually misfired.",
            tone: :info
          ) + notice(
            "No author is recorded: who wrote a message teaches a prompt nothing, and leaving the " \
            "identity out is what makes it defensible to keep the text at all. Samples are kept for " \
            "this community's #{Features::ContentPolicy::MISFIRE_WINDOW_FIELD} setting, at most " \
            "#{ControlPlane::ContentPolicyMisfires::MAX_WINDOW_DAYS} days.", tone: :info
          )
        end

        def content_policy_misfire_counts_table
          rows = @misfire_counts.sort_by { |_name, count| -count }.map do |name, count|
            { policy: name.to_s.empty? ? "(unnamed policy)" : name, count: count }
          end
          table(
            columns: [{ key: :policy, header: "Policy" }, { key: :count, header: "Reversed matches" }],
            rows: rows, empty: "Nothing reversed yet."
          )
        end

        # Six columns plus the drop control, inside the seven a Table draws. The
        # policy, its confidence and who reversed it share one column: they are
        # the provenance of the row, and the three texts beside them are what a
        # tuning pass actually reads.
        def content_policy_misfires_table
          table(
            columns: [
              { key: :created_at, header: "Reversed", format: :timestamp },
              { key: :policy, header: "Policy" },
              { key: :action, header: "Did", format: :code },
              { key: :body, header: "Message" },
              { key: :reasoning, header: "Why it matched" },
              { key: :statement, header: "Why that was wrong" }
            ],
            rows: @misfires.map { |row| content_policy_misfire_row(row) },
            empty: "Nothing here yet. A row appears when an operator answers an alert with /vindicate.",
            actions: ->(row) { content_policy_misfire_drop_form(row) }
          )
        end

        # The policy carries its own confidence and the operator who reversed
        # it, so one column says which description fired, how sure it was and
        # who disagreed without spending three of the seven.
        def content_policy_misfire_row(row)
          confidence = row.confidence.nil? ? nil : format("%.2f", row.confidence)
          policy = [row.policy, confidence && "at #{confidence}", row.reversed_by && "by #{row.reversed_by}"]
          {
            id: row.id, created_at: row.created_at, policy: policy.compact.join(", "),
            action: row.action, body: row.body, reasoning: row.reasoning, statement: row.statement
          }
        end

        def content_policy_misfire_drop_form(row)
          target = "#{request.script_name}/communities/#{h(@community.slug)}" \
                   "/content-policy/misfires/#{h(row[:id])}/delete"
          drop = button("Drop", action: :configure_content_policy, community: @community,
                        variant: :destructive)
          %(<form method="post" action="#{target}">#{drop}</form>)
        end

        # The Administrators page, assembled the way Operator login links is.
        # Every control on it spends :manage_administrators, which is in no
        # grantable action list, so it can only ever be an administrator's.
        def administrators_page
          sections = section(title: "About the administrator role", body: administrators_about) +
                     section(title: "Who administers this deployment", body: administrators_table) +
                     section(title: "Grant the administrator role", body: administrators_grant_form) +
                     section(title: "Hand it over with a token", body: administrator_tokens_body) +
                     section(title: "What has been handed out",
                             body: audit_events_table(@administrator_audit, empty: "Nothing recorded yet."))
          page(title: "Administrators",
               lede: "Every read and every write, everywhere on this deployment.", sections: sections)
        end

        def administrators_about
          notice(
            "An administrator holds every read and every write on every community, plus the pages " \
            "nobody else reaches: accounts, API keys, integrations, operator login links, onboarding, " \
            "and this one. There is nothing above it. Naming somebody here hands them the deployment.",
            tone: :warning
          ) + notice(
            "Only an administrator grants or revokes it, which is the rule this page exists to keep. " \
            "An operator of one community who could hand this out would be handing out every other " \
            "community as well. Nobody can ask for it either: viewer is requested by DM and approved " \
            "on the Viewers page, while this one arrives here, from the shipped list, or on a token.",
            tone: :info
          ) + notice(
            "An administrator named here sends the bot web-login in a private message and gets a " \
            "sign-in link, so the root password does not have to be copied around. That link is much " \
            "shorter lived than an ordinary one because it opens the whole deployment, and it is " \
            "checked against this table again at the moment it is used.", tone: :info
          ) + notice(
            "The root password stays the bootstrap and the way back in. Every row here is revocable, " \
            "including the last one, because an account that goes astray has to be removable in a " \
            "hurry, and the shipped list plus the password are what stand underneath.", tone: :info
          )
        end

        # The shipped list and the granted rows in one table, since a reader
        # wants to know who administers this and not which half named them.
        def administrators_table
          table(
            columns: [
              { key: :handle, header: "Handle", format: :code }, { key: :platform, header: "Platform" },
              { key: :name, header: "Name" },
              { key: :granted_at, header: "Granted", format: :timestamp },
              { key: :granted_by, header: "By" }
            ],
            rows: baked_in_administrator_rows + granted_administrator_rows,
            empty: "Nobody is named as an administrator, so the root password is the only way in.",
            actions: ->(row) { administrator_revoke_form(row) }
          )
        end

        def baked_in_administrator_rows
          @baked_in_administrators.map do |entry|
            { id: nil, handle: entry[:handle], platform: baked_in_kind_label(entry[:kind]),
              name: "shipped with the deployment", granted_at: nil, granted_by: "n/a" }
          end
        end

        def granted_administrator_rows
          @granted_administrators.map do |row|
            { id: row[:id], handle: row[:handle], platform: row[:adapter], name: row[:label],
              granted_at: row[:granted_at], granted_by: row[:granted_by] }
          end
        end

        # A shipped handle draws the state pill the Operators page draws for an
        # always-operator instead of a control, since there is nothing here that
        # could take it away.
        def administrator_revoke_form(row)
          return state("Protected", tone: :neutral) if row[:id].nil?

          target = "#{request.script_name}/administrators/#{h(row[:id])}/revoke"
          %(<form method="post" action="#{target}">) +
            button("Revoke", action: :manage_administrators, community: Role::DEPLOYMENT, variant: :destructive,
                   confirm: "Revoke #{row[:handle]}? They stop administering this deployment at once.") +
            "</form>"
        end

        def administrators_grant_form
          fields = field(name: "adapter", label: "Platform", type: :select, size: :short,
                         options: @administrator_adapters,
                         hint: "The platform the handle is on.") +
                   field(name: "handle", label: "Handle", required: true,
                         hint: "The username they own, never their display name. On Matrix the full " \
                               "ID, @someone:example.org; everywhere else the bare username.") +
                   field(name: "label", label: "Name", hint: "Optional, shown beside the handle.")
          form(action: "#{request.script_name}/administrators", fields: fields,
               submit: button("Grant", action: :manage_administrators, community: Role::DEPLOYMENT))
        end

        def administrator_tokens_body
          notice(
            "For somebody whose handle you do not have yet. Mint a token, give it to them however you " \
            "like, and they send the bot /auth and the token in a private message. That grants them " \
            "the role and sends them their first sign-in link in the same reply.", tone: :info
          ) + notice(
            "A token here hands over the whole deployment, so only an administrator mints one: the " \
            "token is the grant, taken in advance. It works once, it expires whether or not anybody " \
            "uses it, and it can be taken back until it is used. Keep the lifetime as short as the " \
            "handover allows.", tone: :warning
          ) + issued_administrator_token + administrator_tokens_table + administrator_mint_form
        end

        # Shown on this render and no other, the same way a freshly issued API
        # key is.
        def issued_administrator_token
          return "" if @issued_auth_token.nil?

          notice("Here is the token. It is shown once and cannot be shown again. Anybody who has it " \
                 "administers this deployment, so send it over something private and keep no copy.",
                 tone: :success) + code(@issued_auth_token, variant: :block)
        end

        def administrator_tokens_table
          table(
            columns: [
              { key: :label, header: "For" }, { key: :state, header: "State" },
              { key: :expires_at, header: "Expires", format: :timestamp },
              { key: :created_by, header: "Minted by" }, { key: :used_by, header: "Used by" }
            ],
            rows: @auth_tokens.map { |row| administrator_token_row(row) },
            empty: "No administrator tokens have been minted.",
            actions: ->(row) { administrator_token_revoke_form(row) }
          )
        end

        def administrator_token_row(row)
          {
            public_id: row[:public_id], label: presence(row[:label]) || "unlabelled",
            state: deps.auth_tokens.state_of(row), expires_at: row[:expires_at],
            created_by: row[:created_by], live: deps.auth_tokens.live?(row),
            used_by: presence(row[:redeemed_username]) || presence(row[:redeemed_native_id])
          }
        end

        def administrator_token_revoke_form(row)
          return "" unless row[:live]

          target = "#{request.script_name}/administrator-tokens/#{h(row[:public_id])}/revoke"
          %(<form method="post" action="#{target}">) +
            button("Revoke", action: :manage_administrators, community: Role::DEPLOYMENT, variant: :destructive,
                   confirm: "Revoke this token? Nobody can use it after that.") +
            "</form>"
        end

        def administrator_mint_form
          fields = field(name: "ttl_hours", label: "Good for (hours)", type: :number, value: "4",
                         size: :short, hint: "Up to 336, which is a fortnight.") +
                   field(name: "label", label: "Who it is for",
                         hint: "Optional, shown beside the token in the list above.")
          form(action: "#{request.script_name}/administrator-tokens", fields: fields,
               submit: button("Mint", action: :manage_administrators, community: Role::DEPLOYMENT))
        end

        # The login and operator-login pages, both unauthenticated, both a
        # short Form with no fields of their own but a hidden token in the
        # second case. Neither draws through the dashboard runtime's client-side
        # mount: that lifecycle fetches its data from /internal, which rides
        # the session these pages exist to create, and there is nothing to
        # fetch before one does.
        def dashboard_login_page
          secret_field = field(name: "secret", label: "Dashboard secret", type: :secret, required: true)
          sign_in = form(action: "#{request.script_name}/login", fields: secret_field,
                        submit: button("Sign in", action: :sign_in, community: Role::DEPLOYMENT))
          body = @error ? notice(@error, tone: :danger) + sign_in : sign_in
          page(title: "Sign in", lede: "Operator dashboard.", sections: section(variant: :plain, body: body))
        end

        def operator_login_page
          scope = notice("This link opens #{@login_scope}.", tone: :info)
          info = notice(
            "This link stops working at #{@login_expires_at}. If you did not ask for it, close this page " \
            "and tell an administrator.", tone: :info
          )
          sign_in = form(action: "#{request.script_name}/operator-login",
                        submit: button("Sign in", action: :sign_in, community: Role::DEPLOYMENT),
                        hidden: { token: @login_token })
          page(title: "Sign in", lede: "Sign in as #{login_operator_label(@login_operator)}?",
               sections: section(variant: :plain, body: scope + info + sign_in))
        end

        # The ids of every channel already bridged into one of the
        # community's rooms. Shared by the Platforms page (to mark a channel
        # "mapped") and the Rooms board (to state whether a channel needs a
        # room), so the two screens never disagree about what "mapped" means.
        def roomed_channel_ids(community)
          room_ids = models.room.where(community_id: community.id).select_map(:id)
          return [] if room_ids.empty?

          models.room_channel.where(room_id: room_ids).select_map(:channel_id)
        end

        # Whether a channel row is one discovery recorded: its endpoint_key
        # carries ChannelDiscovery::ENDPOINT_KEY_PREFIX, the SAME constant
        # discovery itself stamps a row with, reused here rather than the
        # literal string so the two can never drift apart.
        def discovered?(channel)
          channel.endpoint_key.to_s.start_with?("#{ControlPlane::ChannelDiscovery::ENDPOINT_KEY_PREFIX}:")
        end

        # An unroomed channel row for a community + id, or a
        # clean 404: the map action only ever applies to a row this page
        # itself listed, never an arbitrary channel id typed into the URL.
        # {ControlPlane::ChannelDiscovery#unmapped} is the shared
        # definition of that list, so the dashboard and the REST admin API's
        # read of the same resource can never disagree.
        def discovered_channel!(community, id)
          row = deps.channel_discovery.unmapped(community).find { |channel| channel.id.to_s == id.to_s }
          halt 404, erb(:not_found) if row.nil?
          row
        end

        def community_channel!(community, id)
          row = models.channel.where(community_id: community.id, id: id.to_i).first
          halt 404, erb(:not_found) if row.nil?

          row
        end

        def community_room!(community, room_key)
          row = models.room.where(community_id: community.id, room_key: room_key.to_s).first
          halt 404, erb(:not_found) if row.nil?

          row
        end

        def channel_rooms_for(community, channel)
          room_ids = models.room_channel.where(channel_id: channel.id).select_map(:room_id)
          return [] if room_ids.empty?

          models.room.where(community_id: community.id, id: room_ids).all
        end

        def mapping_selection_from(params)
          case params[:destination].to_s
          when "room"
            [presence(params[:room_key]), nil, false]
          when "partner"
            [nil, presence(params[:partner]), false]
          when "solo"
            [nil, nil, true]
          else
            raise ControlPlane::ChannelMapper::Invalid, "choose where this channel belongs."
          end
        end

        # A suggested channel row for a community + id, or a clean 404: same
        # discipline as #discovered_channel! above, so approve/reject only
        # ever apply to a row this community's Rooms page itself listed.
        def suggested_channel!(community, id)
          row = models.channel.where(community_id: community.id, suggested: true, id: id.to_i).first
          halt 404, erb(:not_found) if row.nil?
          row
        end

        # Platform connections: identity + behaviour settings.

        # Decorate one platform_connection row with everything the Platforms
        # page shows about it: the matching account (nil only when the
        # accounts table does not name it), its token_env status, and each
        # behaviour setting's effective value: the connection's own stored
        # override when present, else the account's compiled setting, else
        # the field's schema default.
        def connection_view(connection)
          account = account_for(connection)
          fields = ControlPlane::PlatformConnections::BEHAVIOR_FIELDS.fetch(connection.adapter.to_sym, [])
          schema = account&.adapter_class&.account_schema
          overrides = connection.json_value(:settings)
          behavior = fields.map do |name|
            field = schema&.fields&.[](name)
            value = if overrides.key?(name.to_s)
                      overrides[name.to_s]
                    elsif account
                      account.settings[name]
                    else
                      field&.default
                    end
            { name: name, field: field, value: value }
          end
          {
            connection: connection,
            account: account,
            token_env: account && account.settings[:token_env],
            token_set: account ? token_env_set?(account.settings[:token_env]) : false,
            behavior: behavior,
            fetch_ceiling: fetch_ceiling_for(connection, account)
          }
        end

        # The largest file this connection's adapter can pull back off its own
        # platform, in bytes, or nil for a platform that draws no such
        # distinction from a real upload (see {Adapters::Base.max_fetch_bytes_for}).
        # Read off the adapter class directly rather than a live instance: the
        # dashboard never boots one, and Telegram's own answer depends only on
        # the account's api_base setting, not on anything a running adapter holds.
        def fetch_ceiling_for(connection, account)
          adapter_class = account&.adapter_class || Adapters::Registry[connection.adapter]
          adapter_class&.max_fetch_bytes_for(account&.settings || {})
        end

        # Whether the named environment variable currently holds a value,
        # read from the same environment the dashboard itself was
        # configured from (App.assemble's env:), never cached and never
        # logged. Only answers "is the key present to try"; whether the
        # adapter actually connected with it is a separate question.
        def token_env_set?(name)
          return false if name.to_s.empty?

          !settings.dashboard_env[name].to_s.empty?
        end

        # One form control for a behaviour setting, matching its schema
        # field's type: a <select> for one_of values, a true/false <select>
        # for :boolean (a checkbox submits nothing when unchecked, which
        # would read as "leave it alone" rather than "false"), a plain
        # input otherwise. The field name is a fixed Symbol from
        # {ControlPlane::PlatformConnections::BEHAVIOR_FIELDS}, never
        # operator input; only the current value is escaped.
        def behavior_control(setting)
          field = setting[:field]
          name = "setting[#{setting[:name]}]"
          current = setting[:value]
          return %(<input type="text" name="#{h(name)}" value="#{h(current)}">) if field.nil?

          if field.one_of
            options = field.one_of.map do |option|
              %(<option value="#{h(option)}"#{" selected" if option.to_s == current.to_s}>#{h(option)}</option>)
            end.join
            return %(<select name="#{h(name)}">#{options}</select>)
          end

          case field.type
          when :boolean
            truthy = [true, "true"].include?(current)
            %(<select name="#{h(name)}"><option value="true"#{" selected" if truthy}>true</option>) +
              %(<option value="false"#{" selected" unless truthy}>false</option></select>)
          when :integer, :float
            step = field.type == :float ? ' step="any"' : ""
            %(<input type="number"#{step} name="#{h(name)}" value="#{h(current)}">)
          else
            %(<input type="text" name="#{h(name)}" value="#{h(current)}">)
          end
        end

        # The scope selector options for a community: the community-wide default
        # plus every room, as { value: room_key, label: } pairs so a <select>
        # submits the room_key (what FeatureControls resolves on) while showing
        # the operator-facing label.
        def scope_options(community)
          rooms = models.room.where(community_id: community.id).order(:room_key).all
          [{ value: "all", label: "all" }] + rooms.map do |room|
            { value: room.room_key, label: room.label.to_s.empty? ? room.room_key : room.label }
          end
        end

        # The feature_settings rows for one feature across every scope, decorated
        # for display: the community default first, then per-room overrides.
        def feature_rows(community, feature)
          deps.feature_controls.list(community)
              .select { |entry| entry[:feature] == feature }
              .sort_by { |entry| [entry[:scope] == :community ? 0 : 1, entry[:room_key].to_s] }
        end

        # The people page: most rows on one screen, and pleasant there, is the
        # target; a busy community's directory is not meant to be rendered
        # whole. Search narrows the same capped query rather than lifting the
        # cap.
        PEOPLE_CAP = 50

        # The community-wide who_can_set the nickname feature is configured
        # with, read the exact way Features::Nickname itself falls back, so the
        # people page never shows or enforces a policy the command would not.
        def nickname_who_can_set(community)
          row = feature_rows(community, "nickname").find { |entry| entry[:scope] == :community }
          Features::Nickname.who_can_set(row ? row[:config] : {})
        end

        # The platforms a nickname could ever be shown on here, exactly what
        # Features::Nickname#platform? checks a chat /nickname against: every
        # adapter this community actually bridges.
        def bridged_platforms(community)
          community.channels.map { |channel| channel.adapter.to_s }.uniq.sort
        end

        # Each identity row plus one entry per other platform this
        # community bridges, each carrying whatever that person already
        # holds there. Read through the same ControlPlane::BridgedNicknames
        # the write goes through, so the page can never show a value it did
        # not actually get from that store.
        def people_rows(community, identities)
          platforms = bridged_platforms(community)
          identities.map do |identity|
            person = deps.bridged_nicknames.person_for_identity(
              community_id: community.id, adapter: identity.adapter, native_id: identity.native_id
            )
            held = person ? deps.bridged_nicknames.for_person(community_id: community.id, person_id: person.id) : {}
            targets = (platforms - [identity.adapter.to_s]).map do |adapter|
              { adapter: adapter, nickname: held[adapter] }
            end
            { identity: identity, targets: targets }
          end
        end

        # Every scope a feature can be set at, whether or not it has a row of
        # its own: the community-wide default first, then one per room. A
        # room with no row resolves exactly the way ControlPlane::Snapshot
        # resolves it at runtime, so the state shown is the state the bot
        # acts on, not a blank standing in for one.
        def feature_matrix(community, feature)
          rows = feature_rows(community, feature)
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
        # ControlPlane::Snapshot#feature_config does, so the mode a matrix row
        # shows for a room is the mode that room actually runs under.
        def merge_feature_config(base, overlay)
          base.to_h.merge(overlay.to_h) do |_key, a, b|
            a.is_a?(Hash) && b.is_a?(Hash) ? merge_feature_config(a, b) : b
          end
        end

        # The short commit sha this deployment is running, or nil when
        # unknown (a local run, or Coolify's "Include Source Commit in
        # Build" left off). SOURCE_COMMIT is the variable Coolify itself
        # populates; nothing else needs to set it.
        def build_commit
          return nil unless settings.respond_to?(:dashboard_env)

          sha = settings.dashboard_env["SOURCE_COMMIT"].to_s.strip
          sha.empty? ? nil : sha[0, 7]
        end

        # What the header says about a merge that never deployed, or about the
        # bot and web processes having landed on different versions. Empty when
        # they agree, when a difference is still inside its grace period, and
        # when the check could not run at all.
        def deploy_drift
          return [] unless settings.respond_to?(:deploy_drift)

          settings.deploy_drift.warnings
        rescue StandardError
          []
        end

        def flash_result(message, error: false)
          session[error ? :error : :notice] = message
        end

        def take_flash(key)
          value = session.delete(key)
          value
        end

        # Spends a one-time flash and re-arms it for the client render of the
        # same page load, which reads the internal surface after this body has
        # already been rendered. Any later render of the page finds nothing to
        # spend and clears the relay with it, so the value still shows once.
        def relay_flash(key)
          value = take_flash(key)
          relay = :"#{key}_themed"
          value.nil? ? session.delete(relay) : session[relay] = value
          value
        end

        def h(text) = Rack::Utils.escape_html(text.to_s)

        # How a deployment-configured floor entry's "kind" reads on the dashboard: id-based
        # kinds name their platform, "matrix" reads as an MXID, and a bare
        # username is left as is.
        def baked_in_kind_label(kind)
          case kind.to_s
          when "matrix" then "Matrix ID"
          when "telegram_id" then "Telegram ID"
          when "discord_id" then "Discord ID"
          else "username"
          end
        end

        # The scripting catalog is written in markdown, because the reference in
        # docs/scripting.md renders from the same strings. This is that text as
        # HTML: escaped first, then the backtick runs turned into <code>, so a
        # type or a limit reads on the page the way it reads in the doc.
        def inline_code(text) = h(text).gsub(/`([^`]+)`/, "<code>\\1</code>")

        # A compact one-line rendering of a JSON config blob.
        def json_inline(value)
          return "" if value.nil? || (value.respond_to?(:empty?) && value.empty?)

          JSON.generate(value)
        end

        def json_pretty(value)
          JSON.pretty_generate(value)
        rescue StandardError
          value.to_s
        end

        # A feature's config, human-readable: built from {ConfigHumanizer.rows},
        # never the raw JSON blob, each row rendering as "Label: value" or
        # "Label:" with a chip per list entry. An empty config renders a muted
        # placeholder rather than an empty cell, so "nothing set" reads as a
        # deliberate state.
        def config_summary(config)
          rows = ConfigHumanizer.rows(config)
          return %(<span class="muted">Defaults</span>) if rows.empty?

          rows.map { |row| config_summary_row(row) }.join
        end

        def config_summary_row(row)
          label = %(<strong>#{h(row[:label])}:</strong>)
          if row[:chips]
            chips = row[:chips].map { |chip| %(<span class="chip">#{h(chip)}</span>) }.join
            %(<div class="cfg-row">#{label} <span class="chip-list">#{chips}</span></div>)
          else
            %(<div class="cfg-row">#{label} #{h(row[:text])}</div>)
          end
        end

        # The value one field of the generic config form should show: this
        # scope's own written value when there is one, else the schema's
        # declared default, so an unconfigured feature's form pre-fills
        # with what it actually runs at rather than a blank that looks
        # unset.
        def config_field_value(field, config)
          key = field.name.to_s
          config.key?(key) ? config[key] : field.default
        end

        # An array field's current value, one entry per line, for a textarea.
        # Mirrors entries_as_lines but works from a schema field's resolved
        # value (which may be the schema default, an Array already) rather
        # than always reading a raw config hash key. A mapping or a nested
        # list prints as JSON, which is the shape {#config_field_entries}
        # reads back, so the round trip returns the entry it started from.
        def config_field_lines(value)
          Array(value).map { |entry| config_field_line(entry) }.join("\n")
        end

        def config_field_line(entry)
          entry.is_a?(Hash) || entry.is_a?(Array) ? JSON.generate(entry) : entry.to_s
        end

        # What a list field's box asks for, said only where it is not
        # obvious: a free list is where a mapping entry lives, and a mapping
        # has to be written as JSON for the round trip to give it back.
        def config_field_entry_hint(field)
          return "One entry per line." unless field.element_type.nil?

          "One entry per line. An entry that is a mapping is written as JSON."
        end

        # The entries one submitted textarea stands for, read against the
        # shape the schema declares rather than guessed from the text: a
        # declared element type keeps every line a scalar of that type, and a
        # free list (the only shape a mapping entry can be declared under)
        # reads a line written as JSON back into the mapping it came from.
        def config_field_entries(field, text)
          lines_to_entries(text).map { |line| config_field_entry(field, line) }
        end

        # One line of an array field. A number is read as one only where the
        # schema asked for numbers, so a room id or a domain in a string list
        # stays the text an operator typed.
        def config_field_entry(field, line)
          case field.element_type
          when :integer then line.match?(/\A-?\d+\z/) ? Integer(line, 10) : line
          when :float then line.match?(/\A-?\d+(\.\d+)?\z/) ? Float(line) : line
          when :string, :symbol, :duration then line
          else structured_config_entry(line)
          end
        end

        # A free list's line: JSON where it opens as a mapping or a list, the
        # literal text otherwise, so a bare-word entry stays a bare word. A
        # line that opens as JSON and does not parse is refused rather than
        # stored as text, which is how a structured entry used to go missing.
        def structured_config_entry(line)
          return line unless line.start_with?("{", "[")

          JSON.parse(line)
        rescue JSON::ParserError
          raise ConfigFieldError, "cannot read #{line[0, 60].inspect} as an entry. Each line is one " \
                                  "entry, written as JSON where the entry is a mapping."
        end

        # One submitted config field, shaped for FeatureControls#set: nil
        # means "leave this key alone" (a blank scalar never clears a value).
        # A boolean's hidden+checkbox pair submits whenever the form drew that
        # field, so an undrawn form leaves the stored value alone; an array
        # field is one entry per line, kept as the list the schema declares.
        def config_field_submission(field, params, config = {})
          key = field.name.to_s
          return nil unless params.key?(key)

          case field.type
          when :boolean then params[key].to_s
          when :array
            return config_mapping_list_submission(field, params[key], config) if mapping_entry_schema(field)

            config_array_submission(field, params[key], config)
          else presence(params[key])
          end
        end

        # A mapping list arrives as Rack's nested field hash instead of the
        # one-textarea string an ordinary list posts. Each row is read against
        # the nested schema before anything is written, so an unknown key or
        # an unreadable value is a form error rather than a rule the runtime
        # silently skips later.
        def config_mapping_list_submission(field, raw, config)
          entries = mapping_list_rows(field, raw).filter_map.with_index do |row, index|
            config_mapping_list_entry(field, row, index)
          end
          return entries unless entries.empty?
          return nil if Array(config_field_value(field, config)).empty?

          entries
        end

        def mapping_list_rows(field, raw)
          case raw
          when Hash
            raw.keys.sort_by { |key| key.to_s.match?(/\A\d+\z/) ? key.to_i : key.to_s }
               .map { |key| raw[key] }
          when Array then raw
          when String then config_field_entries(field, raw)
          else []
          end
        end

        def config_mapping_list_entry(field, raw, index)
          return presence(raw) if mapping_string_variant?(field) && raw.is_a?(String)
          return nil if mapping_list_row_blank?(raw)

          schema = mapping_entry_schema(field)
          unless raw.is_a?(Hash)
            result = schema.call(raw, path: "#{field.name}[#{index}]")
            raise ConfigFieldError, result.problems.join(" ")
          end
          if mapping_string_variant?(field) && raw["_kind"].to_s == "word"
            return presence(raw["pattern"])
          end

          path = "#{field.name}[#{index}]"
          input = mapping_entry_input(schema, raw)
          result = schema.call(input, path: path)
          return result.value.slice(*input.keys.map(&:to_sym)) if result.valid?

          raise ConfigFieldError, result.problems.join(" ")
        end

        def mapping_list_row_blank?(raw)
          return false unless raw.is_a?(Hash)

          raw.reject { |key, _value| key.to_s == "_kind" }.values.all? do |value|
            value.respond_to?(:empty?) ? value.empty? : value.nil?
          end
        end

        def mapping_entry_input(schema, raw)
          schema.fields.each_value.each_with_object({}) do |entry_field, input|
            key = entry_field.name.to_s
            next unless raw.key?(key)

            value = mapping_entry_value(entry_field, raw[key])
            next if value.nil?

            input[key] = value
          end
        end

        def mapping_entry_value(field, raw)
          return raw.to_s == "true" if field.type == :boolean
          return config_field_entries(field, raw.to_s) if field.type == :array

          presence(raw)
        end

        def mapping_entry_schema(field)
          return field.schema unless field.schema.nil?

          Array(field.variants).find { |variant| variant.is_a?(Config::Schema) }
        end

        def mapping_string_variant?(field)
          Array(field.variants).include?(:string)
        end

        # Which of a mapping row's two accepted shapes an existing entry is:
        # a bare string is the "word" shorthand, anything else (including a
        # brand new row's {}) is the full "rule" mapping. Mirrors the "_kind"
        # a submitted row carries back in config_mapping_list_entry.
        def mapping_row_kind(entry)
          entry.is_a?(String) ? "word" : "rule"
        end

        # One sub-field's value to prefill a mapping row's control with: the
        # bare-string shorthand only ever fills "pattern", a mapping fills
        # from its own key, and anything absent falls back to that sub-field's
        # own schema default.
        def mapping_row_value(entry, sub_field)
          key = sub_field.name.to_s
          return entry if entry.is_a?(String) && key == "pattern"
          return sub_field.default unless entry.is_a?(Hash)

          entry.key?(key) ? entry[key] : sub_field.default
        end

        # The one thing a mapping-list row's own labelled inputs do not
        # already say: that a field taking the bare-string shorthand also
        # takes a full mapping, and the Kind select on each row picks which.
        def config_mapping_list_hint(field)
          return nil unless mapping_string_variant?(field)

          "A simple word matches that pattern literally. A full rule sets its own matching mode, " \
            "case sensitivity, and action."
        end

        # A submitted list, or nil to leave the key alone. An emptied box is
        # a deliberate empty list, since the form draws what the scope runs
        # at right now and the operator had to clear it; a box that was
        # already blank is nobody having typed anything, and writing an
        # empty list there would pin an answer over whatever default the
        # feature ships next.
        def config_array_submission(field, text, config)
          entries = config_field_entries(field, text)
          return entries unless entries.empty?
          return nil if Array(config_field_value(field, config)).empty?

          entries
        end

        # The entries of a feature config rendered one per line for a
        # textarea: a bare-string entry prints as-is, a mapping prints its
        # pattern, so an operator sees what is there without the JSON
        # scaffolding. +key+ selects which list: "entries" (default) or
        # "custom" for the word filter's supplemental list.
        def entries_as_lines(config, key = "entries")
          entries = config[key]
          return "" unless entries.is_a?(Array)

          entries.map do |entry|
            entry.is_a?(Hash) ? (entry["pattern"] || entry["keyword"] || entry["command"]).to_s : entry.to_s
          end.join("\n")
        end

        # Whether operators are filtered at this scope. Defaults to exempt, which
        # is the right default (a moderator quoting a slur to discuss it should
        # not be filtered) and also the reason somebody testing the filter on
        # their own messages sees nothing happen.
        def word_exempt_operators?(config)
          raw = config["exempt_operators"]
          raw = config[:exempt_operators] if raw.nil?
          raw.nil? ? true : !%w[false 0 no off].include?(raw.to_s.strip.downcase)
        end

        # The current default action a word-filter config declares, for the form.
        def word_action(config)
          config["action"].to_s.empty? ? "delete" : config["action"].to_s
        end

        # What the word filter may do on a hit, read off the schema rather than
        # typed out here, so the dropdown offers every action the field accepts
        # (warn and mute included, which fall back to `stub_action` when the
        # warnings service is not wired).
        def word_filter_actions = Features::WordFilter::ACTIONS

        # The word filter's mode choices, value and operator-facing label,
        # in the order the dropdown lists them.
        WORD_FILTER_MODES = [
          ["off", "Off"],
          ["slurs", "Slurs only"],
          ["slurs_profanity", "Slurs + profanity"]
        ].freeze

        def word_filter_modes = WORD_FILTER_MODES

        # The effective mode a word-filter config resolves to: the canonical
        # `mode` field, or the legacy `vulgarity_mode` field folded onto its
        # equivalent, defaulting to "off". Delegates to the feature's own
        # {Features::WordFilter.resolve_mode} so the dropdown always shows
        # exactly what the running filter would apply, not a re-derived guess.
        def word_filter_mode(config)
          Features::WordFilter.resolve_mode(config)
        end

        # The trigger text of an FAQ entry, for the list view.
        def faq_trigger(entry)
          command = entry["command"] || entry[:command]
          return "command: #{command}" if command && !command.to_s.empty?

          keyword = entry["keyword"] || entry[:keyword] || entry["pattern"] || entry[:pattern]
          "keyword: #{keyword}"
        end

        # A feature whose config outgrew the generic form gets its own richer
        # page (structured lists, dedicated actions) instead of one row per
        # config_schema key. The Features page's Config link goes there
        # instead of /features/:feature/config for exactly these; the map
        # itself lives on Dashboard::FeatureDisplay so view_data.rb's client
        # payload names the same set of features without a second copy.
        BESPOKE_CONFIG_PAGE = Dashboard::FeatureDisplay::BESPOKE_CONFIG_PAGE

        # Which config_schema keys a bespoke page already draws its own control
        # for. Everything else the feature declares is rendered underneath it by
        # the same schema form the generic page uses, so a key can never be
        # invisible just because the richer page predates it.
        BESPOKE_CONFIG_HANDLED = {
          "word_filter" => %w[mode action exempt_operators custom],
          "faq" => %w[entries],
          "events" => [],
          "guest_portal" => %w[who_can_invite],
          "nickname" => %w[who_can_set],
          "poll" => []
        }.freeze

        # The token a bespoke page's schema form sends so the save lands back on
        # it. The destination itself is looked up from the feature, so this
        # parameter names an intent and can never carry a URL.
        BESPOKE_RETURN = "bespoke"

        # The token the Features page's own inline config form sends, so a save
        # lands back on the row it was opened from instead of the standalone
        # config page nobody navigated to on purpose.
        FEATURES_RETURN = "features"

        # Whether a feature's config can also be edited inline in its Features
        # row, alongside the summary Config link every row carries: true for
        # everything except the handful with a bespoke page, whose richer
        # editor is not something a collapsed row can reasonably fold in.
        def feature_config_expandable?(feature)
          !BESPOKE_CONFIG_PAGE.key?(feature)
        end

        # The token the view sends back for {#config_save_return} to recognise.
        def features_return_token = FEATURES_RETURN

        # The Features page's own per-row summary: a toggle switch, a Config
        # link for every feature with anything to configure (see
        # {#feature_summary_config_link}), then the state marker, display
        # name and description. Trusted markup rather than escaped text,
        # since a plain string could not carry the toggle's own form.
        # Mirrors toggleSummary in assets/dashboard/runtime/primitives.civet.
        # data-feature carries the stable feature_name to find a row by key;
        # data-feature-key adds file_rehosting's own split key too.
        def feature_row_summary(row)
          marker = row[:enabled] ? "[x]" : "[ ]"
          key_attr = row[:toggle_key] ? %( data-feature-key="#{h(row[:toggle_key])}") : ""
          %(<span data-feature-toggle="#{row[:enabled] ? "on" : "off"}">#{feature_toggle_form(row)}</span>) +
            feature_summary_config_link(row[:feature]) +
            %(<span data-feature-heading data-feature="#{h(row[:feature])}"#{key_attr}>) +
            %(<strong>#{h(marker)} #{h(row[:display_name])}</strong>) +
            %(<p data-feature-desc>#{h(row[:description])}</p></span>)
        end

        # The row summary's own Config link, for every feature with anything
        # to configure: that link needs nothing from the row's collapsed
        # body, so it sits beside the toggle instead of costing an extra
        # click to expand the row first. {#feature_config_path} picks the
        # bespoke page or the generic form, which is the only difference
        # between one feature and the next here. Empty for a feature with no
        # config_schema, which has nowhere to link to.
        def feature_summary_config_link(feature)
          return "" if Features::Catalog.class_for(feature)&.config_schema.nil?

          %(<a class="button secondary" href="#{feature_config_path(@community, feature)}">Config</a>)
        end

        # Whether a feature runs unconditionally: identify_topic and
        # disabled_command_notice are catalogued for lookup and description,
        # but {Features::Pipeline#enabled?} never reads their feature_settings
        # row, so an Enable/Disable control on them would toggle nothing.
        def feature_locked_on?(feature)
          Rubotty::Features::Catalog.class_for(feature)&.always_enabled? == true
        end

        # The row's own Enable/Disable control: a Form wrapping one Button so
        # its two hidden fields (selector, feature) travel with it. Never
        # primary: every row carries an identical control, and a primary
        # button repeated that many times reads as one anyway. A locked-on
        # feature gets a plain note instead, since it can never be toggled.
        def feature_toggle_form(row)
          return %(<span class="muted">Always on</span>) if feature_locked_on?(row[:feature])

          action = "#{request.script_name}/communities/#{h(@community.slug)}/features"
          split = row[:toggle_key]
          op = split ? (row[:enabled] ? "disable_flag" : "enable_flag") : (row[:enabled] ? "disable" : "enable")
          toggle = act_button(row[:enabled] ? "Disable" : "Enable", :"toggle_#{row[:feature]}",
                              community: @community, style: "secondary", name: "op", value: op)
          key_field = split ? %(<input type="hidden" name="key" value="#{h(split)}">) : ""
          %(<form class="inline" method="post" action="#{action}">) +
            %(<input type="hidden" name="selector" value="#{h(@scope)}">) +
            %(<input type="hidden" name="feature" value="#{h(row[:feature])}">#{key_field}#{toggle}</form>)
        end

        # Where a feature's Config link on the Features page goes: its own
        # bespoke page when it has one, else the generic per-schema-field form.
        def feature_config_path(community, feature)
          slug = h(community.slug)
          bespoke = BESPOKE_CONFIG_PAGE[feature]
          return "#{request.script_name}/communities/#{slug}/#{bespoke}" if bespoke

          "#{request.script_name}/communities/#{slug}/features/#{h(feature)}/config?scope=#{h(@scope)}"
        end

        # The schema fields a bespoke page has to render itself, in declared
        # order: every key the feature declares that the page does not already
        # have a control for.
        def leftover_config_fields(feature)
          schema = Features::Catalog.class_for(feature)&.config_schema
          return [] if schema.nil?

          handled = BESPOKE_CONFIG_HANDLED.fetch(feature, [])
          schema.fields.each_value.reject { |field| handled.include?(field.name.to_s) }
        end

        # One schema field by name, for a page that wants to draw a single key
        # with its own wording rather than in the leftover block.
        def config_field(feature, name)
          Features::Catalog.class_for(feature)&.config_schema&.fields&.fetch(name.to_sym, nil)
        end

        # The label the generic form gives a schema field.
        def config_field_label(field) = field.name.to_s.tr("_", " ").capitalize

        # Everything the schema form under a bespoke page needs: the scope it
        # edits, the scopes it can be pointed at, that scope's stored config and
        # the fields the page does not draw itself. Its own query parameter
        # (config_scope) so the picker never collides with whatever the page
        # already reads off the query string.
        def prepare_leftover_config(community, feature)
          @leftover_feature = feature
          @leftover_fields = leftover_config_fields(feature)
          @leftover_scope = presence(params[:config_scope]) || "all"
          @leftover_scopes = scope_options(community)
          @leftover_config = feature_config_at(community, feature, @leftover_scope)
        end

        # One feature's stored config for one scope, string-keyed straight off
        # the row, the same read the generic config form does.
        def feature_config_at(community, feature, scope)
          deps.feature_controls.list(community, selector: scope)
              .find { |entry| entry[:feature] == feature }&.dig(:config) || {}
        end

        # The token a bespoke page's schema form posts, for the view.
        def leftover_return_token = BESPOKE_RETURN

        # The query this page was already reading, minus the scope picker's own
        # key, re-emitted as hidden inputs so picking a scope for the schema
        # form below does not throw away a search the page is showing.
        def leftover_scope_carry
          request.params.reject { |key, value| key == "config_scope" || !value.is_a?(String) }
                 .map { |key, value| %(<input type="hidden" name="#{h(key)}" value="#{h(value)}">) }
                 .join
        end

        # Where a config save lands: back on the bespoke page that posted it
        # when it asked to come back, back on the Features page when its own
        # inline row form posted, else the generic form it came from.
        def config_save_return(community, feature, selector)
          bespoke = BESPOKE_CONFIG_PAGE[feature]
          case params[:return_to].to_s
          when BESPOKE_RETURN
            return "/communities/#{community.slug}/#{bespoke}" \
                   "?config_scope=#{Rack::Utils.escape(selector)}#schema-config" if bespoke
          when FEATURES_RETURN
            return "/communities/#{community.slug}/features?scope=#{Rack::Utils.escape(selector)}"
          end

          "/communities/#{community.slug}/features/#{feature}/config?scope=#{selector}"
        end

        # The full guest link for a freshly issued token. GUEST_PORTAL_URL is the
        # public base the guest portal is served at (rubotty.example.org); when it is
        # unset the path alone is shown, which an operator can prefix by hand.
        def guest_link(token)
          base = settings.dashboard_env["GUEST_PORTAL_URL"].to_s.sub(%r{/+\z}, "")
          "#{base}/g/#{token}"
        end

        # A byte count the way a person reads one, for the files panel.
        def human_bytes(count)
          size = count.to_i.to_f
          unit = "B"
          %w[KB MB GB TB].each do |candidate|
            break if size < 1000

            size /= 1000.0
            unit = candidate
          end
          unit == "B" ? "#{size.to_i} B" : format("%.1f %s", size, unit)
        end

        # The navigation, and the fallback header that draws it: what the
        # sections are lives in {Nav}, shared with /internal/shell so the dashboard
        # draws the same document. Visible only while the dashboard boots or its
        # assets fail to load: reaching navigation does not depend on browser scripts.

        # The page path as {Nav} writes one: the mount prefix on the front
        # (empty standalone, the dashboard's prefix when mounted under one,
        # e.g. /admin-panel), and the bare prefix for the landing page.
        def current_page_path
          return Nav.root_path(request.script_name) if request.path_info == "/"

          "#{request.script_name}#{request.path_info}"
        end

        # The community this page's chrome is about, or nil. The
        # request_access dead end renders this layout for a community the
        # reader may not open, and its nav points at none of those pages.
        def nav_community
          return nil if @community.nil?

          current_role&.can?(:view_community, community: @community) ? @community : nil
        end

        # The scopes this page carries. The switcher's community list and the
        # badge counts are left out here and asked for only over
        # /internal/shell: the header draws neither, and both cost queries on
        # a path every single page render takes.
        def nav_scopes
          Nav.scopes(role: current_role, community: nav_community,
                     prefix: request.script_name, path: current_page_path)
        end

        # Everything the header's one navigation row shows: where the reader
        # is, the scope they are in, and the other scope folded away.
        def main_nav
          scopes = nav_scopes
          here, elsewhere = scopes.partition { |scope| scope["current"] }
          nav_crumbs + here.flat_map { |scope| nav_groups(scope["groups"]) }.join +
            elsewhere.map { |scope| nav_folded(scope) }.join
        end

        # The breadcrumb: every crumb but the last as a way back out, the last
        # in hand. Drawn only inside a community, where the deployment landing
        # link is not already saying the same thing.
        def nav_crumbs
          community = nav_community
          return "" if community.nil?

          title = Nav.title_for(path: current_page_path, community: community,
                                prefix: request.script_name)
          Nav.crumbs(community: community, title: title, prefix: request.script_name)
             .each_with_index.map { |crumb, index| nav_crumb(crumb, first: index.zero?) }.join
        end

        def nav_crumb(crumb, first:)
          separator = first ? "" : %(<span class="crumb-sep">/</span>)
          body = if crumb["current"]
                   %(<b class="crumb-current">#{h(crumb["label"])}</b>)
                 else
                   %(<a class="crumb" href="#{h(crumb["path"])}">#{h(crumb["label"])}</a>)
                 end
          "#{separator}#{body}"
        end

        # One scope's groups, as a small HTML fragment: a group with no label
        # is a bare run of links (Overview, Communities), a labelled one is a
        # native <details> dropdown, so a dozen sections stop competing for
        # one row.
        def nav_groups(groups)
          groups.map do |group|
            links = group["items"].map { |item| nav_link(item) }.join
            next %(<span class="nav-group">#{links}</span>) if group["label"].nil?

            # Highlighted on the summary itself so a group reads as "you are
            # here" even collapsed, not just once opened.
            current = group["items"].any? { |item| item["current"] } ? ' class="active"' : ""
            %(<details class="nav-dropdown"><summary#{current}>#{h(group["label"])}</summary>) +
              %(<span class="menu">#{links}</span></details>)
          end
        end

        def nav_link(item)
          active = item["current"] ? ' class="active"' : ""
          %(<a href="#{h(item["path"])}"#{active}>#{h(item["label"])}</a>)
        end

        # The scope the reader is not in, folded into one collapsible summary
        # rather than rendered inline: on a community page the deployment-wide
        # pages are seldom what an operator came for, and rendering them as
        # their own row is the second bar this nav replaces. Its landing link
        # is left out, since the breadcrumb already goes there.
        def nav_folded(scope)
          links = scope["groups"].flat_map { |group| group["items"] }
                                 .reject { |item| item["path"] == Nav.root_path(request.script_name) }
                                 .map { |item| nav_link(item) }.join
          %(<details class="deployment"><summary>#{h(scope["label"])}</summary>) +
            %(<span class="menu">#{links}</span></details>)
        end

        # The brand facts the chrome carries: what this is, which build, and
        # any deploy that never went out. Read off settings rather than the
        # control plane, which is why they are added to the shell document
        # here rather than inside {ViewData}.
        def shell_brand
          { "product" => "rubotty", "version" => Rubotty::VERSION,
            "commit" => build_commit, "drift" => deploy_drift }
        end

        def signed_out_shell
          {
            "section" => "shell", "scopes" => [], "communities" => [], "crumbs" => [],
            "operator" => { "label" => "Sign in", "administrator" => false, "read_only" => true },
            "search" => { "path" => "", "placeholder" => "" }, "logout_path" => "",
            "brand" => shell_brand
          }
        end

        # A short hint for a community with channels but no rooms, as a small
        # HTML fragment (empty string otherwise): feature scoping is
        # room-based, so such a community sees every room-scoped page as a
        # silently empty table with no explanation why. Only the slug is
        # interpolated, escaped.
        def no_rooms_notice(community)
          return "" unless no_rooms_dead_end?(community)

          href = "#{request.script_name}/communities/#{h(community.slug)}/rooms?state=unroomed"
          <<~HTML
            <div class="card">
              <p class="muted">
                This community has channels but <strong>no rooms yet</strong>. Every room-scoped setting
                attaches to a room, so guest access and events have nothing to configure here, and the word
                filter and FAQ can only use the community-wide <code>all</code> scope. Map a channel into a
                room on <a href="#{href}">Rooms</a>: a room may hold a single channel, so a
                community that lives on one platform gets one too.
              </p>
            </div>
          HTML
        end

        # Whether a community is in that dead end: at least one channel row and
        # no room row. A community with no channels at all is a different (and
        # earlier) state, so it is left alone here.
        def no_rooms_dead_end?(community)
          return false if models.room.where(community_id: community.id).count.positive?

          models.channel.where(community_id: community.id).count.positive?
        end

        # Analytics rendering. Every chart on the page is the Chart primitive,
        # so this file has no chart renderer of its own: the figure is drawn in
        # the browser by whichever engine {#chart_engine} names, and the numbers
        # ship as the table the primitive already puts under it.

        # A compact label for one time bucket: the hour for a 24h series, the day
        # for a longer one.
        def bucket_label(point)
          at = point[:at]
          return at.to_s unless at.respond_to?(:strftime)

          point[:step] == 3600 ? at.strftime("%H:00") : at.strftime("%b %-d")
        end

        # A time-bucketed series in the Chart primitive's { label:, count: } row
        # shape, one row per bucket. The shape a caller then names is
        # :time_series; the drawing that becomes is the client's business.
        def series_rows(series)
          Array(series).map { |point| { label: bucket_label(point), count: point[:count].to_i } }
        end

        # The window selector: one pill per window, the current one marked. Keeps
        # the current path and only swaps the query string.
        def window_tabs(base, windows, current)
          links = windows.map do |key|
            active = key == current ? ' class="active"' : ""
            # Prefix the mount point so the tabs resolve when the dashboard is
            # served under a path (e.g. /admin-panel); empty when standalone.
            %(<a href="#{request.script_name}#{base}?window=#{key}"#{active}>#{h(key)}</a>)
          end
          %(<div class="window-tabs">#{links.join}</div>)
        end

        # The "By channel" grouping toggle: platform channel (default)
        # versus metachannel/room. Same link-pill shape as {window_tabs},
        # keeping the current window in the query string so switching the
        # grouping never resets it.
        def channel_view_tabs(community, window, current)
          base = "#{request.script_name}/communities/#{h(community.slug)}/analytics"
          options = { "channel" => "By platform channel", "room" => "By room" }
          links = options.map do |value, label|
            active = value == current ? ' class="active"' : ""
            %(<a href="#{base}?window=#{h(window)}&channel_view=#{value}"#{active}>#{h(label)}</a>)
          end
          %(<div class="window-tabs">#{links.join}</div>)
        end

        # Audit log rendering, shared by /audit and /communities/:slug/audit:
        # identical columns, one HTML fragment either view drops into its
        # own <table>, so the two never drift apart.
        def audit_events_table(events, empty:)
          return %(<p class="muted">#{h(empty)}</p>) if events.empty?

          rows = events.map { |event| audit_event_row(event) }.join
          %(<table>) +
            %(<thead><tr><th>When</th><th>Source</th><th>Action</th><th>Actor</th>) +
            %(<th>Subject</th><th>Channel</th><th>Reason</th><th>Outcome</th></tr></thead>) +
            %(<tbody>#{rows}</tbody></table>)
        end

        def audit_event_row(event)
          channel = event.channel.to_s.empty? ? "" : "<code>#{h(event.channel)}</code>"
          %(<tr>) +
            %(<td class="muted">#{h(event.created_at)}</td>) +
            %(<td>#{h(event.source)}</td>) +
            %(<td><strong>#{h(event.action)}</strong></td>) +
            %(<td>#{h(event.actor)}</td>) +
            %(<td>#{h(event.subject)}</td>) +
            %(<td>#{channel}</td>) +
            %(<td>#{h(event.reason)}</td>) +
            %(<td class="muted">#{h(event.outcome)}</td>) +
            %(</tr>)
        end

        # The community and deployment Audit log share one compact table. The
        # source remains a filter, while a channel is part of its subject so
        # each scope stays within the Table primitive's column limit.
        def audit_log_events_table(events, empty:, include_community:)
          return %(<p class="muted">#{h(empty)}</p>) if events.empty?

          headers = ["When", *(include_community ? ["Community"] : []), "Action", "Actor", "Subject", "Reason", "Outcome"]
          rows = events.map { |event| audit_log_event_row(event, include_community: include_community) }.join
          %(<table><thead><tr>#{headers.map { |header| "<th>#{header}</th>" }.join}</tr></thead><tbody>#{rows}</tbody></table>)
        end

        def audit_log_event_row(event, include_community:)
          subject = [event.subject, event.channel].map(&:to_s).reject(&:empty?).join(" in ")
          cells = [
            %(<td class="muted">#{h(event.created_at)}</td>),
            *(include_community ? [%(<td>#{h(event.community)}</td>)] : []),
            %(<td><strong>#{h(event.action)}</strong></td>),
            %(<td>#{h(event.actor)}</td>),
            %(<td>#{h(subject)}</td>),
            %(<td>#{h(event.reason)}</td>),
            %(<td class="muted">#{h(event.outcome)}</td>)
          ]
          "<tr>#{cells.join}</tr>"
        end

        # The redirection log. A helper for the same reason the audit
        # table above is: the columns answer "what was moved", so the next
        # place that wants to show a move does not have to rewrite them.
        def redirections_table(rows, community:, empty:)
          return %(<p class="muted">#{h(empty)}</p>) if rows.empty?

          body = rows.map { |row| redirection_row(row, community: community) }.join
          %(<table>) +
            %(<thead><tr><th>When</th><th>By</th><th>From</th><th>To</th>) +
            %(<th>Messages</th><th>State</th><th></th></tr></thead>) +
            %(<tbody>#{body}</tbody></table>)
        end

        def redirection_row(row, community:)
          %(<tr>) +
            %(<td class="muted">#{h(row.created_at)}</td>) +
            %(<td>#{h(row.operator)}</td>) +
            %(<td><code>#{h(row.source_endpoint_id)}</code></td>) +
            %(<td><code>#{h(row.target_room_id)}</code></td>) +
            %(<td>#{h(row.message_count)}</td>) +
            %(<td>#{redirection_state(row)}</td>) +
            %(<td>#{redirection_stop_button(row, community: community)}</td>) +
            %(</tr>)
        end

        # The two live states say which half of the move is running, because
        # that is the difference between "nothing has been deleted yet" and
        # "the reposts are all in". Anything else is just its outcome.
        def redirection_state(row)
          label = case row.status
                  when ControlPlane::Redirections::POSTING then "reposting"
                  when ControlPlane::Redirections::DELETING then "clearing the original"
                  else row.status
                  end
          %(<span class="pill">#{h(label)}</span>)
        end

        # A move that has already finished has nothing to stop, so there is no
        # button at all. A live one always draws its button, flat for a reader
        # who may not press it, so what an operator here could do is visible.
        def redirection_stop_button(row, community:)
          return "" unless row.status == ControlPlane::Redirections::POSTING

          action = "#{request.script_name}/communities/#{h(community.slug)}/redirections/#{row.id}/stop"
          button = act_button("Stop", :manage_redirection, community: community)
          %(<form method="post" action="#{action}">#{button}</form>)
        end

        # What the scripts raised. A helper for the same reason the two
        # tables above are: the columns answer "what happened and did
        # anybody hear about it", so the next surface does not restate them.
        def alerts_table(rows, community:, empty:)
          return %(<p class="muted">#{h(empty)}</p>) if rows.empty?

          body = rows.map { |row| alert_row(row, community: community) }.join
          %(<table>) +
            %(<thead><tr><th>When</th><th>Room</th><th>Script</th><th>Alert</th>) +
            %(<th>How</th><th></th></tr></thead>) +
            %(<tbody>#{body}</tbody></table>)
        end

        def alert_row(row, community:)
          %(<tr>) +
            %(<td class="muted">#{h(row.created_at)}</td>) +
            %(<td><code>#{h(row.room_key)}</code></td>) +
            %(<td>#{h(row.script)}</td>) +
            %(<td>#{h(row.text)}</td>) +
            %(<td>#{alert_mode(row)}</td>) +
            %(<td>#{alert_seen_button(row, community: community)}</td>) +
            %(</tr>)
        end

        # The audience an alert really has. An operator a DM cannot reach reads
        # as an operator everywhere else on this page, so without this the
        # audience looks bigger than the one an alert gets. Drawn only when
        # there is somebody in it.
        def unreachable_operators_section(rows)
          return "" if Array(rows).empty?

          about = notice(
            "These operators hold everything an operator holds and hear none of it: the last direct " \
            "message to each was refused. The person has to open a private chat with the bot and " \
            "send /start, once, before anything reaches them.",
            tone: :warning
          )
          section(title: "Operators nothing can reach", body: about + unreachable_operators_table(rows))
        end

        def unreachable_operators_table(rows)
          table(
            columns: [
              { key: :person, header: "Person" },
              { key: :native_id, header: "Native id", format: :code },
              { key: :adapter, header: "Platform", format: :enum },
              { key: :refused_at, header: "Last refused", format: :timestamp },
              { key: :reason, header: "Why" }
            ],
            rows: rows.map { |entry| entry.merge(person: entry[:person] || "person ##{entry[:person_id]}") },
            empty: "Every operator can be reached."
          )
        end

        # A loud alert that reached nobody is the case worth spelling out: it
        # means the operators are only on platforms rubotty cannot open a DM
        # on, and the page is the only place that ever says so. It gets the
        # grey pill rather than the green one for that reason.
        def alert_mode(row)
          return %(<span class="pill">quiet</span>) unless row.mode == ControlPlane::Alerts::LOUD

          reached = row.delivered_to.to_i
          label = reached.positive? ? "loud, DMed #{reached}" : "loud, reached nobody"
          %(<span class="pill #{reached.positive? ? "on" : "off"}">#{h(label)}</span>)
        end

        # An alert already seen says so instead of offering the button again.
        def alert_seen_button(row, community:)
          return %(<span class="muted">seen</span>) unless row.seen_at.nil?

          action = "#{request.script_name}/communities/#{h(community.slug)}/alerts/#{row.id}/seen"
          button = act_button("Mark seen", :manage_alerts, community: community, style: "secondary")
          %(<form class="inline" method="post" action="#{action}">#{button}</form>)
        end

        # Backfill proposals.

        # Run a control-plane write, turning a BackfillProposals::Invalid (a
        # proposal that is not there, or has already been decided, or has
        # expired since the page was loaded) into a flash message rather than
        # a 500.
        def with_backfill_proposal_error
          yield
        rescue ControlPlane::BackfillProposals::Invalid => e
          flash_result(e.message, error: true)
        end

        # The community that owns a proposal. This page spans every tenant and
        # so carries none of its own, which is why the decision has to name one
        # rather than the service accepting a bare id from the url.
        def backfill_proposal_community!(proposal_id)
          row = deps.backfill_proposals.find_in_any_community(proposal_id)
          raise ControlPlane::BackfillProposals::Invalid, "no such proposal" if row.nil?

          community = models.community[row[:community_id]]
          return community if community

          raise ControlPlane::BackfillProposals::Invalid, "that proposal's community no longer exists"
        end

        # Ask the running bot to relay one accepted proposal, over the same
        # internal hop the reload nudge already uses (BotNudge#relay_proposal).
        # Unlike the best-effort write nudge, a failure here is not silently
        # swallowed: only the bot holds the adapters that can actually send,
        # so an operator has to be told plainly when it could not be reached
        # rather than seeing a bare "accepted".
        def push_backfill_relay(proposal_id, success:)
          result = settings.bot_nudge.relay_proposal(proposal_id)
          flash_result(
            result.ok? ? success : "Could not reach the bot to relay it: #{result.error}",
            error: !result.ok?
          )
        end

        # The community row for each id a batch of cross-community proposal
        # rows names, in one query rather than one per row.
        def communities_by_id(rows)
          ids = rows.map { |row| row[:community_id] }.uniq
          return {} if ids.empty?

          models.community.where(id: ids).all.each_with_object({}) { |c, index| index[c.id] = c }
        end

        def backfill_proposals_table(rows, communities:, state:, empty:)
          return %(<p class="muted">#{h(empty)}</p>) if rows.empty?

          rows.map { |row| backfill_proposal_card(row, communities: communities, state: state) }.join
        end

        def backfill_proposal_card(row, communities:, state:)
          community = communities[row[:community_id]]
          items = community ? deps.backfill_proposals.items(community: community, proposal_id: row[:id]) : []
          %(<div class="card">) +
            backfill_proposal_header(row, community) +
            backfill_proposal_stats(row) +
            %(<details><summary>#{items.size} message#{items.size == 1 ? "" : "s"}</summary>) +
            backfill_proposal_items_table(items) +
            %(</details>) +
            backfill_proposal_actions(row, state: state) +
            %(</div>)
        end

        def backfill_proposal_header(row, community)
          label = community ? h(community.name) : "(community no longer exists)"
          %(<p><strong>#{label}</strong> &middot; <code>#{h(row[:endpoint_id])}</code> &middot; ) +
            %(#{backfill_proposal_pill(row)}</p>) +
            %(<p class="muted">Proposed #{h(row[:created_at])}, expires #{h(row[:expires_at])}.</p>)
        end

        def backfill_proposal_pill(row)
          case row[:status]
          when "pending" then %(<span class="pill">waiting on a decision</span>)
          when "approved" then %(<span class="pill on">accepted, not yet confirmed sent</span>)
          when "expired" then %(<span class="pill suspended">expired, nothing decided</span>)
          else %(<span class="pill">#{h(row[:status])}</span>)
          end
        end

        # The counts the sweep saw: ours gets the loudest treatment, how many
        # fetched messages the sweep decided were already our own relayed
        # copies and skipped. A zero here on a channel bridged for months
        # means the ownership check is broken, and accepting would push those
        # copies right back in.
        def backfill_proposal_stats(row)
          ours = row[:ours].to_i
          %(<div class="grid">) +
            %(<div class="stat"><div class="n">#{row[:fetched]}</div><div class="l">fetched</div></div>) +
            %(<div class="stat"><div class="n">#{row[:gaps]}</div><div class="l">would send</div></div>) +
            %(<div class="stat"><div class="n">) +
            %(<span class="pill #{ours.zero? ? "alert" : "on"}">#{ours}</span></div>) +
            %(<div class="l">ours, skipped</div></div>) +
            %(<div class="stat"><div class="n">#{row[:claimed]}</div><div class="l">already relayed</div></div>) +
            %(<div class="stat"><div class="n">#{row[:below_floor]}</div><div class="l">too old</div></div>) +
            %(</div>) +
            (ours.zero? ? backfill_ours_zero_warning : "")
        end

        def backfill_ours_zero_warning
          %(<p class="flash error">Ours is zero. On a channel that has bridged before, that means ) +
            "the ownership check found nothing of its own among what it fetched, which is usually " \
            "a sign it is broken right now. Look into that before accepting this proposal." +
            %(</p>)
        end

        def backfill_proposal_items_table(items)
          return %(<p class="muted">Nothing is stored for this proposal.</p>) if items.empty?

          body = items.map { |item| backfill_proposal_item_row(item) }.join
          %(<table><thead><tr><th>When</th><th>Author</th><th>Preview</th></tr></thead>) +
            %(<tbody>#{body}</tbody></table>)
        end

        def backfill_proposal_item_row(item)
          %(<tr>) +
            %(<td class="muted">#{h(item[:sent_at])}</td>) +
            %(<td>#{h(item[:author_label])}</td>) +
            %(<td>#{h(item[:preview])}</td>) +
            %(</tr>)
        end

        def backfill_proposal_actions(row, state:)
          base = "#{request.script_name}/backfill-proposals/#{row[:id]}"
          case state
          when :pending
            %(<form class="inline" method="post" action="#{base}/accept">) +
              %(<button type="submit">Accept</button></form> ) +
              %(<form class="inline" method="post" action="#{base}/reject">) +
              %(<button class="secondary" type="submit">Reject</button></form>)
          when :awaiting_relay
            %(<form class="inline" method="post" action="#{base}/retry-relay">) +
              %(<button class="secondary" type="submit">Retry relay</button></form>)
          else
            ""
          end
        end

        # Where the events go, and what happened to them.
        def webhook_subscriptions_table(rows, empty:)
          return %(<p class="muted">#{h(empty)}</p>) if rows.empty?

          body = rows.map { |row| webhook_subscription_row(row) }.join
          %(<table>) +
            %(<thead><tr><th>Label</th><th>URL</th><th>Events</th><th>Room</th><th>State</th></tr></thead>) +
            %(<tbody>#{body}</tbody></table>)
        end

        def webhook_subscription_row(row)
          events = ControlPlane::Webhooks.event_types_of(row).join(", ")
          room = row.room_key.to_s.empty? ? "every room" : row.room_key.to_s
          %(<tr>) +
            %(<td>#{h(row.label.to_s.empty? ? "(no label)" : row.label)}</td>) +
            %(<td><code>#{h(row.url)}</code></td>) +
            %(<td>#{h(events)}</td>) +
            %(<td><code>#{h(room)}</code></td>) +
            %(<td>#{webhook_state(row)}</td>) +
            %(</tr>)
        end

        # A rotation still in flight is worth saying out loud: it is the window
        # in which a subscriber may be verifying with either secret, and an
        # operator who has forgotten one is open will not think to ask.
        def webhook_state(row)
          return %(<span class="pill off">off</span>) unless row.active

          return %(<span class="pill on">on</span>) unless deps.webhooks.rotating?(row)

          %(<span class="pill on">on</span> <span class="pill">rotating</span>)
        end

        def webhook_deliveries_table(rows, community:, empty:)
          return %(<p class="muted">#{h(empty)}</p>) if rows.empty?

          body = rows.map { |row| webhook_delivery_row(row, community: community) }.join
          %(<table>) +
            %(<thead><tr><th>When</th><th>Event</th><th>Room</th><th>Outcome</th>) +
            %(<th>Tries</th><th>Why</th><th></th></tr></thead>) +
            %(<tbody>#{body}</tbody></table>)
        end

        def webhook_delivery_row(row, community:)
          %(<tr>) +
            %(<td class="muted">#{h(row.created_at)}</td>) +
            %(<td>#{h(row.event_type)}</td>) +
            %(<td><code>#{h(row.room_key)}</code></td>) +
            %(<td>#{webhook_delivery_status(row)}</td>) +
            %(<td>#{row.attempts.to_i}</td>) +
            %(<td class="muted">#{h(row.last_error.to_s)}</td>) +
            %(<td>#{webhook_retry_button(row, community: community)}</td>) +
            %(</tr>)
        end

        # Three outcomes worth telling apart: it landed, it is still going to
        # be tried, or it has been given up on. The last is the only one that
        # needs somebody to do something, so it gets the loud pill.
        def webhook_delivery_status(row)
          case row.status.to_s
          when "delivered"
            code = row.response_status.to_i
            %(<span class="pill on">#{h(code.positive? ? "delivered, #{code}" : "delivered")}</span>)
          when "failed"
            %(<span class="pill off">given up</span>)
          else
            %(<span class="pill">waiting to retry</span>)
          end
        end

        # Only a dead delivery can be sent again, so anything else has no button
        # to draw; the one it does draw goes flat for a reader who may not press it.
        def webhook_retry_button(row, community:)
          return "" unless row.status.to_s == "failed"

          action = "#{request.script_name}/communities/#{h(community.slug)}/webhooks/deliveries/#{row.id}/retry"
          button = act_button("Send again", :manage_webhooks, community: community, style: "secondary")
          %(<form class="inline" method="post" action="#{action}">#{button}</form>)
        end
      end

      private

      # The bootstrap operator the dashboard acts as when approving or
      # denying a request: OperatorFlow requires an existing operator to
      # decide, and the dashboard admin is not one itself. Nil for a
      # community with no operator yet, which the operators view surfaces
      # rather than silently failing.
      def first_operator(community)
        models.operator.where(community_id: community.id).order(:id).first
      end

      def decide_request(community, id, verb)
        request = deps.operators.find_request(community_id: community.id, id: id)
        if request.nil?
          flash_result("No such operator request.", error: true)
          return
        end
        approver = first_operator(community)
        if approver.nil?
          flash_result("This community has no operator yet, so there is nobody to #{verb} as.", error: true)
          return
        end

        result = deps.operators.public_send(verb, request: request, approver: approver)
        flash_result(decision_message(result, verb), error: !result.ok?)
      end

      def decision_message(result, verb)
        case result.status
        when :approved then "Request approved; the requester is now an operator."
        when :denied then "Request denied."
        when :not_pending then "That request was already decided."
        when :forbidden then "The approving operator is not allowed to #{verb} this request."
        else "Could not #{verb} the request (#{result.status})."
        end
      end

      # Every known feature, at one scope, decorated with its current enabled
      # state and config for the Features matrix, in the order the pipeline
      # runs its message features. A feature with no
      # feature_settings row runs at its code default, off except the bridge
      # (the always-on relay, see
      # ControlPlane::Snapshot::Community#feature_enabled?).
      def feature_matrix_rows(community, scope)
        configured = deps.feature_controls.list(community, selector: scope)
                         .each_with_object({}) { |entry, memo| memo[entry[:feature]] = entry }
        Features::Catalog.dashboard_names.map do |feature|
          entry = configured[feature]
          if feature_locked_on?(feature)
            { feature: feature, enabled: true, config: entry ? entry[:config] : {} }
          elsif entry
            { feature: feature, enabled: entry[:enabled], config: entry[:config] }
          else
            { feature: feature, enabled: feature == "bridge", config: {} }
          end
        end
      end

      # {#feature_matrix_rows} decorated for the Features page: a display
      # name and category (see Dashboard::FeatureDisplay), and
      # file_rehosting expanded into its two independently toggleable rows
      # instead of its own. Sorted by display name, the reader's alphabet
      # rather than the pipeline's.
      def display_feature_rows(matrix_rows)
        matrix_rows.flat_map { |row| feature_display_rows_for(row) }.sort_by { |row| row[:display_name] }
      end

      # One matrix row's display rows: file_rehosting's own row becomes two
      # (File Rehosting, File Uploads), sharing its feature_config; anything
      # else stays one row with its catalog description.
      def feature_display_rows_for(row)
        return [normal_display_row(row)] unless row[:feature] == Features::FileRehosting.feature_name

        Dashboard::FeatureDisplay::FILE_REHOSTING_SPLIT.map { |split| split_display_row(row, split) }
      end

      def normal_display_row(row)
        row.merge(
          display_name: Dashboard::FeatureDisplay.name_for(row[:feature]),
          category: Dashboard::FeatureDisplay.category_for(row[:feature]),
          description: Features::Catalog.description(row[:feature]),
          toggle_key: nil
        )
      end

      # +split+'s own half of file_rehosting's config: enabled only when the
      # feature itself is, AND this half's own boolean is (defaulting true,
      # see Features::FileRehosting#config_schema).
      def split_display_row(row, split)
        active = case split[:key]
                 when "rehost_inbound" then Features::FileRehosting.rehost_inbound?(row[:config])
                 when "enable_upload_command" then Features::FileRehosting.upload_command_enabled?(row[:config])
                 end
        row.merge(display_name: split[:display], category: split[:category], description: split[:description],
                  toggle_key: split[:key], enabled: row[:enabled] && active)
      end

      # Display rows bucketed into Dashboard::FeatureDisplay::CATEGORIES'
      # nine buckets, in that constant's own order, plus a flat :rest bucket
      # for anything FeatureDisplay has not assigned a category to yet.
      def group_feature_rows(rows)
        grouped = Dashboard::FeatureDisplay::CATEGORIES.keys.to_h { |key| [key, []] }
        grouped[:rest] = []
        rows.each { |row| grouped.fetch(row[:category], grouped[:rest]) << row }
        grouped
      end

      # Every row rendered the one way a Features row is drawn, whether it
      # sits inside a category group or the flat list below them.
      def render_feature_rows(rows)
        rows.map do |row|
          section(variant: :collapsible, chevron: :end, summary: feature_row_summary(row),
                  body: erb(:_feature_row, layout: false, locals: { row: row }))
        end.join
      end

      def toggle_feature(community, selector, feature, enabled)
        if enabled
          deps.feature_controls.enable(community: community, selector: selector, feature: feature)
          flash_result("Enabled #{feature} for #{selector}.")
        else
          deps.feature_controls.disable(community: community, selector: selector, feature: feature)
          flash_result("Disabled #{feature} for #{selector}.")
        end
      end

      # The tri-state "Enabled" control a bespoke page's add-a-scope form
      # offers: blank/absent means leave it alone (inherit, never a silent
      # off), "on"/"off" forces it explicitly in the same write as the
      # config. Deliberately excludes the custom word list: routing it
      # through the existing "save" would quietly replace every custom word a
      # scope has with an empty submission.
      def save_word_filter_scope(community, selector)
        return inherit_scope(community, selector, "word_filter") if params[:enabled].to_s == "inherit"

        mode = presence(params[:mode]) || Features::WordFilter::DEFAULT_MODE
        deps.feature_controls.set(community: community, selector: selector,
                                  feature: "word_filter", key: "mode", value: mode)
        action = presence(params[:action])
        if action
          deps.feature_controls.set(community: community, selector: selector,
                                    feature: "word_filter", key: "action", value: action)
        end
        exempt = (params[:exempt] || {})[selector.to_s]
        unless exempt.nil?
          deps.feature_controls.set(community: community, selector: selector, feature: "word_filter",
                                    key: "exempt_operators", value: exempt.to_s == "on" ? "true" : "false")
        end
        forced = apply_forced_enablement(community, selector, "word_filter", params[:enabled])
        flash_result("Saved the word filter for #{selector}: mode #{mode}#{forced ? " (forced #{forced})" : ""}.")
      end

      # The FAQ matrix row, which carries enablement and nothing else:
      # entries are per-scope lists edited in that scope's own card.
      def save_faq_scope(community, selector)
        return inherit_scope(community, selector, "faq") if params[:enabled].to_s == "inherit"

        forced = apply_forced_enablement(community, selector, "faq", params[:enabled])
        flash_result("Set the FAQ for #{selector}#{forced ? " to #{forced}" : ""}.")
      end

      # Drop a room's own row so it falls back to the community-wide default,
      # the third state the matrix's Enabled control offers. Never reachable for
      # "all", which the matrix renders without the option and which
      # ControlPlane::FeatureControls#reset refuses outright.
      def inherit_scope(community, selector, feature)
        deps.feature_controls.reset(community: community, selector: selector, feature: feature)
        flash_result("#{selector} follows the community-wide setting again.")
      end

      # The trigger's settings arrive as a small set of named fields rather than
      # free text, which is what keeps the catalog closed: an operator can only
      # configure a rule there is a form field for.
      def script_trigger_config(existing = nil)
        {
          "name" => presence(params[:trigger_name]),
          "words" => lines_to_entries(params[:trigger_words]),
          "names" => lines_to_entries(params[:trigger_names]),
          "window" => presence(params[:trigger_window]),
          "count" => presence(params[:trigger_count]),
          # The recurring trigger's two settings: how often, and the time
          # of day for a daily or weekly one.
          "every" => presence(params[:trigger_every]),
          "at" => presence(params[:trigger_at]),
          # The time window, for a rule about pace rather than volume.
          "minutes" => presence(params[:trigger_minutes]),
          # Whether edits count as messages too, one tick for the whole
          # script rather than per condition. A toggle select submits the
          # word either way, so an off toggle has to read as off rather
          # than as the non-empty string it is.
          "edits" => (truthy_param?(params[:trigger_edits]) ? "true" : nil),
          # The second and later conditions, as bare type names sharing the
          # boxes above. A script that has to hear a command and free text
          # and a clock used to be three scripts, which could not share a
          # memo between them since memos are scoped per script.
          Scripting::Triggers::EXTRA_KEY => extra_triggers(existing)
        }.compact.reject { |_key, value| value.respond_to?(:empty?) && value.empty? }
      end

      # The extra conditions the form ticked, minus the one already named by
      # trigger_type so picking it twice does not fold the same message in
      # twice. Anything outside the catalog is dropped here rather than saved
      # and refused later; a condition the API gave settings of its own keeps
      # them as long as it is still ticked.
      # Whether a submitted flag is on, whichever control sent it.
      def truthy_param?(value) = %w[true 1 yes on t].include?(value.to_s.strip.downcase)

      def extra_triggers(existing = nil)
        held = stored_extra_triggers(existing)
        offered = Scripting::Triggers.type_names
        Array(params[:trigger_also]).map(&:to_s)
                                    .select { |type| offered.include?(type) }
                                    .reject { |type| type == params[:trigger_type].to_s }
                                    .uniq
                                    .map { |type| held[type] || type }
      end

      # The row this save is about to overwrite, resolved the way the store
      # itself resolves it: by id when the form carries one, and otherwise by
      # name, since saving a name that already exists updates it in place.
      def script_being_saved(community)
        id = presence(params[:id])
        return deps.scripts.find(community, id) if id

        deps.scripts.find_by_name(community, params[:name].to_s)
      end

      # What is already stored, as type name to the entry that declared it, so a
      # tick that was already there comes back as it was written.
      def stored_extra_triggers(existing)
        return {} if existing.nil?

        entries = Array(deps.scripts.trigger_config(existing)[Scripting::Triggers::EXTRA_KEY])
        entries.filter_map { |entry| [entry["type"].to_s, entry] if entry.is_a?(Hash) }.to_h
      rescue StandardError
        {}
      end

      # Where turning a script on or off returns to: both switches sit on the
      # list AND the script's own page, and being thrown back to the list
      # after flipping one from its own page loses your place. The form says
      # which page it is on; the answer is one of two fixed paths, so no
      # redirect target ever comes in off the wire.
      def after_script_switch(community)
        return "/communities/#{community.slug}/scripts" unless params[:back] == "script"

        "/communities/#{community.slug}/scripts/#{params[:id]}"
      end

      # What the editor's autocomplete offers, generated from the same
      # catalog the runtime serves, so it can never suggest a function
      # that is not there. A callback or recurring script's try box holds
      # data rather than text, read as YAML since that is what the rest of
      # this API already speaks; anything else is simply no data, since
      # this page is for trying things rather than validating them.
      def try_data(text)
        parsed = YAMLCamel.load(text.to_s)
        parsed.is_a?(Hash) ? parsed : nil
      rescue StandardError
        nil
      end

      def script_completions
        JSON.generate(Scripting::HostFunctions.completions)
      end

      # The shipped examples, embedded so picking one fills the body, the kind,
      # the language and the trigger in a single gesture. They are exercised by
      # the suite, so what an operator copies is known to run.
      def script_examples
        JSON.generate(Scripting::Examples.payload)
      end

      def with_script_error(_community)
        yield
      rescue ControlPlane::Scripts::Invalid, Scripting::Error => e
        flash_result(e.message, error: true)
        nil
      end

      # What one script has been up to, read once for the page below it.
      def load_script_activity
        @alerts = deps.alerts.for_script(community_id: @community.id, script: @script.name)
        @errors = script_error_rows(@script)
        @run_totals = deps.scripts.run_totals(@script)
      end

      # The stored error history as rows. The recorded time is text in the
      # column, so it is read back where it parses and left alone where it
      # does not, rather than the page showing a date in two shapes.
      def script_error_rows(script)
        deps.scripts.error_history(script).map do |entry|
          { at: script_error_time(entry["at"]), message: entry["message"].to_s }
        end
      end

      def script_error_time(value)
        Time.parse(value.to_s)
      rescue StandardError
        value.to_s
      end

      # What this script has done since it was last edited, and what it has
      # raised.
      def script_activity(script, alerts:, errors:, run_totals:)
        columns = [{ key: :at, header: "When", format: :relative },
                   { key: :message, header: "What went wrong" }]
        body = stat_row(script_activity_stats(script, alerts: alerts, errors: errors, run_totals: run_totals)) +
               key_values(script_activity_pairs(script)) +
               table(columns: columns, rows: errors, empty: "This script has not failed on real traffic.")
        section(title: "Activity", body: body) + script_alerts_section(script, alerts: alerts)
      end

      def script_activity_stats(script, alerts:, errors:, run_totals:)
        failures = script.consecutive_failures.to_i
        days = ControlPlane::Alerts::RETENTION / (24 * 60 * 60)
        run_days = ControlPlane::Scripts::RUN_RETENTION_DAYS
        [[run_totals[:runs], "runs", "#{run_totals[:failures]} failed, kept #{run_days} days"],
         [failures, "consecutive failures", script_failure_detail(script, failures)],
         [errors.length, "recorded errors", "the last #{ControlPlane::Scripts::ERROR_HISTORY} are kept"],
         [alerts.length, "alerts raised", "kept for #{days} days"]]
      end

      # The counter the circuit breaker reads, so what it costs is worth
      # saying beside it.
      def script_failure_detail(script, failures)
        return "already switched off" unless script.disabled_at.nil?
        return "nothing failing" if failures.zero?

        "switched off if it keeps failing"
      end

      def script_activity_pairs(script)
        pairs = [["last edited", script.updated_at, :relative],
                 ["last passed check", script.verified_at || "never", script.verified_at ? :relative : :text]]
        pairs << ["last error", script.last_error.to_s] unless script.last_error.to_s.empty?
        pairs << ["last error at", script.last_error_at, :relative] if script.last_error_at
        pairs << ["switched off", script.disabled_reason.to_s] unless script.disabled_at.nil?
        pairs
      end

      # Matched on the name written into each alert, which is worth saying on
      # a page where that name is an editable box.
      def script_alerts_section(script, alerts:)
        columns = [{ key: :at, header: "When", format: :relative },
                   { key: :room, header: "Room" }, { key: :text, header: "Alert" },
                   { key: :how, header: "How", tone: :tone }]
        rows = alerts.map do |row|
          { at: row.created_at, room: presence(row.room_key) || "any room", text: row.text.to_s,
            how: alert_how(row), tone: alert_tone(row) }
        end
        body = notice("What #{script.name} raised with rubotty.alert, matched on the name it carried " \
                      "at the time, so a rename leaves older alerts under the old one.") +
               table(columns: columns, rows: rows, empty: "This script has raised no alerts.")
        section(title: "Alerts", body: body)
      end

      def alert_how(row)
        return "quiet" unless row.mode == ControlPlane::Alerts::LOUD

        reached = row.delivered_to.to_i
        reached.positive? ? "loud, DMed #{reached}" : "loud, reached nobody"
      end

      # A loud alert nobody was reachable for is the case worth marking: it
      # went nowhere, and the dashboard is the only thing that says so.
      def alert_tone(row)
        return :neutral unless row.mode == ControlPlane::Alerts::LOUD

        row.delivered_to.to_i.positive? ? :good : :warn
      end

      # Numbers this community's scripts recorded for themselves. A stat row
      # carries no script name, so this is one table for the community rather
      # than anything one script's page could answer.
      def script_stats_section(stats)
        return "" if stats.nil? || stats.empty?

        columns = [{ key: :stat, header: "Stat" }, { key: :row, header: "Row" },
                   { key: :value, header: "Value", align: :end }, { key: :room, header: "Room" }]
        body = notice("Numbers your own scripts recorded with increment_stat and record_stat, rather " \
                      "than anything rubotty counts by itself. They expire after 90 days, and each " \
                      "stat holds a limited number of rows.") +
               table(columns: columns, rows: script_stat_rows(stats), empty: "Nothing recorded yet.")
        section(title: "What your scripts recorded", body: body)
      end

      def script_stat_rows(stats)
        stats.flat_map do |stat, entries|
          entries.map do |entry|
            { stat: stat, row: entry[:row], value: entry[:value],
              room: presence(entry[:room_key]) || "any room" }
          end
        end
      end

      # An endpoint IS refused when it is wrong, unlike a script, so this
      # is the path a bad URL or a taken name takes back to the form.
      def with_endpoint_error(_community)
        yield
      rescue ControlPlane::ScriptEndpoints::Invalid => e
        flash_result(e.message, error: true)
        nil
      end

      def apply_forced_enablement(community, selector, feature, raw)
        forced = presence(raw)
        case forced
        when "on" then deps.feature_controls.enable(community: community, selector: selector, feature: feature)
        when "off" then deps.feature_controls.disable(community: community, selector: selector, feature: feature)
        end
        forced
      end

      # Turn a newline-separated textarea into a list of bare-string
      # entries, each read as a literal whole-word rule (the shorthand
      # Features::WordFilter and Features::Faq both document). Used for
      # the word filter's `custom` list and for FAQ's `entries`.
      def lines_to_entries(text)
        text.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)
      end

      # The parallel platform[] / label[] / url[] form fields, zipped by
      # index into one raw row per url slot. Purely a Sinatra-params
      # concern, so it stays here rather than in
      # {ControlPlane::PlatformLinks}: no validation or defaulting happens
      # in this method, that is entirely
      # {ControlPlane::PlatformLinks.normalize}'s job.
      def platform_link_rows_from_params
        platforms = Array(params[:platform])
        labels = Array(params[:label])
        urls = Array(params[:url])
        urls.each_index.map { |i| { "platform" => platforms[i], "label" => labels[i], "url" => urls[i] } }
      end

      # An IRC network's submitted fields, ready for
      # {ControlPlane::IrcNetworks#create} or {#update}: neither raises on a
      # bad shape, that is entirely the service's own {ControlPlane::IrcNetworks::Invalid}
      # to report. tls is converted from the true/false <select> to a real
      # boolean here since Config::Schema's :boolean field only accepts one,
      # never the string a form submits.
      def irc_network_form_attrs
        {
          name: params[:name], host: params[:host], port: presence(params[:port]),
          tls: params[:tls] == "true", nick: params[:nick],
          sasl_user: presence(params[:sasl_user]), sasl_password_env: presence(params[:sasl_password_env]),
          channels: lines_to_entries(params[:channels]), mode: presence(params[:mode]),
          hub_channel: presence(params[:hub_channel]), channel_keys: irc_network_channel_keys_from_params
        }
      end

      # The parallel channel_key_channel[] / channel_key_env[] form fields,
      # zipped by index into a channel name => env var name Hash, the same
      # convention {#platform_link_rows_from_params} uses for its own rows. A
      # row missing either half is dropped rather than saved half-blank.
      def irc_network_channel_keys_from_params
        channels = Array(params[:channel_key_channel])
        envs = Array(params[:channel_key_env])
        channels.each_index.each_with_object({}) do |i, out|
          channel = presence(channels[i])
          env = presence(envs[i])
          out[channel] = env if channel && env
        end
      end

      # Run a control-plane write, turning a FeatureControls::Invalid (an unknown
      # feature, or a channel selector that matched nothing) into a flash message
      # rather than a 500. The caller redirects afterwards.
      def with_feature_error
        yield
      rescue ControlPlane::FeatureControls::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn a GuestInvites::Invalid (a missing nickname, a non-positive lifetime,
      # a channel from another community) into a flash message rather than a 500.
      def with_guest_error
        yield
      rescue ControlPlane::GuestInvites::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn an ApiKeys::Invalid (an unknown scope, a scope/community mismatch,
      # a blank label) into a flash message rather than a 500.
      def with_api_key_error
        yield
      rescue ControlPlane::ApiKeys::Invalid => e
        flash_result(e.message, error: true)
      end

      # Every account name configured under adapter: api_wrapper, so an
      # API key's platform_account can be checked against something real
      # before it is ever minted. The accounts table alone, which holds
      # every account a deployment has.
      def platform_account_names
        deps.accounts.names_for(adapter: Adapters::ApiWrapper::NAME)
      end

      # The Config::Account behind a platform connection, resolved from the
      # accounts table, the deployment's one account source.
      def account_for(connection)
        deps.accounts.resolved(adapter: connection.adapter, name: connection.account)
      end

      # What the current session may mint, read off the role it already holds,
      # so nobody can write themselves a token bigger than they are. The service
      # checks it again before a row exists; this is only where the answer comes
      # from.
      def dashboard_minter
        ControlPlane::AuthTokens::Minter.new(
          administrator: current_role.administrator?,
          community_ids: current_role.community_ids,
          # Every session that reaches a mint form here is an administrator or
          # an operator of the community it names, which the route has already
          # checked, and both hold the operator role they would be handing on.
          may_grant_operator: true,
          label: operator_label
        )
      end

      # The lifetime a mint form asked for, in hours, or the service's default
      # when the field was left alone.
      def token_ttl(hours)
        given = presence(hours)
        given.nil? ? ControlPlane::AuthTokens::DEFAULT_TTL : (given.to_f * 3600).round
      end

      # Turn an AuthTokens::Invalid (nothing granted, a scope the minter does
      # not hold, a lifetime out of range) into a flash message.
      def with_auth_token_error
        yield
      rescue ControlPlane::AuthTokens::Invalid => e
        flash_result(e.message, error: true)
      end

      def flash_auth_token_revocation(result)
        case result.status
        when :removed then flash_result("That token no longer works.")
        when :spent
          flash_result("That token has already been used, so there is nothing left to take back. " \
                       "Take the role itself back instead.", error: true)
        else flash_result("No such token.", error: true)
        end
      end

      # Turn a DashboardViewers::Invalid (an unknown platform, a blank handle,
      # a handle the shipped list already covers) into a flash message.
      def with_viewer_error
        yield
      rescue ControlPlane::DashboardViewers::Invalid => e
        flash_result(e.message, error: true)
      end

      # The same for an administrator grant, whose refusals read the same way.
      def with_administrator_error
        yield
      rescue ControlPlane::DashboardAdministrators::Invalid => e
        flash_result(e.message, error: true)
      end

      # The deployment-wide tokens that hand over one of the two roles, so the
      # Viewers page and the Administrators page each list only their own.
      def deployment_tokens(administrator:)
        deps.auth_tokens.list(community_id: nil).select do |row|
          deps.auth_tokens.administrator_token?(row) == administrator
        end
      end

      # Approve or deny one viewer request, flashing the outcome. Reached only
      # from the two administrator-only routes above.
      def decide_viewer_request(id, decision)
        request = deps.dashboard_viewers.find_request(id: id)
        return flash_result("No such viewer request.", error: true) if request.nil?

        with_viewer_error do
          result = if decision == :approve
                     deps.dashboard_viewers.approve(request: request, decided_by: operator_label)
                   else
                     deps.dashboard_viewers.deny(request: request, decided_by: operator_label)
                   end
          flash_viewer_decision(result, request)
        end
      end

      # The same for a community-scoped grant, whose refusals read the same way.
      def with_community_viewer_error
        yield
      rescue ControlPlane::CommunityViewers::Invalid => e
        flash_result(e.message, error: true)
      end

      # Approve or deny one community viewer request. The lookup is scoped to
      # the community, so an id from another one is simply not found here.
      def decide_community_viewer_request(community, id, decision)
        request = deps.community_viewers.find_request(community_id: community.id, id: id)
        return flash_result("No such viewer request.", error: true) if request.nil?

        with_community_viewer_error do
          result = if decision == :approve
                     deps.community_viewers.approve(request: request, decided_by: operator_label)
                   else
                     deps.community_viewers.deny(request: request, decided_by: operator_label)
                   end
          flash_community_viewer_decision(result, request, community)
        end
      end

      def flash_community_viewer_decision(result, request, community)
        who = presence(request[:requester_username]) || request[:requester_native_id]
        case result.status
        when :approved then flash_result("#{who} now reads #{community.slug}.")
        when :denied then flash_result("Denied #{who}.")
        when :not_pending then flash_result("That request has already been decided.", error: true)
        else flash_result("Could not decide that request.", error: true)
        end
      end

      def flash_viewer_decision(result, request)
        who = presence(request[:requester_username]) || request[:requester_native_id]
        case result.status
        when :approved then flash_result("#{who} now reads every community.")
        when :denied then flash_result("Denied #{who}.")
        when :not_pending then flash_result("That request has already been decided.", error: true)
        else flash_result("Could not decide that request.", error: true)
        end
      end

      # Turn a WordFilterEntries::Invalid (a value not present in the
      # custom list to remove) into a flash message. Nested inside
      # {#with_feature_error} in the word-filter route rather than
      # replacing it: that route's enable/disable ops still raise
      # ControlPlane::FeatureControls::Invalid, so both rescues are needed.
      def with_word_filter_entries_error
        yield
      rescue ControlPlane::WordFilterEntries::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn a {ConfigFieldError} (a list line written as JSON that does not
      # parse) into a flash message rather than a 500, so the save is refused
      # whole and nothing under it is written half-way.
      def with_config_field_error
        yield
      rescue ConfigFieldError => e
        flash_result(e.message, error: true)
      end

      # Turn a FaqEntries::Invalid (a missing trigger or response, an id that
      # matches no entry) into a flash message rather than a 500. Nested
      # inside {#with_feature_error} in the FAQ route for the same reason as
      # {#with_word_filter_entries_error} above.
      def with_faq_entries_error
        yield
      rescue ControlPlane::FaqEntries::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn an EventScheduling::Invalid (a disabled room, a blank title, an
      # unparsable start time, an unknown kind or rsvp_mode) into a flash
      # message rather than a 500.
      def with_event_error
        yield
      rescue ControlPlane::EventScheduling::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn a ModerationActions::Invalid (no platform/user id, or an unreadable
      # duration) into a flash message rather than a 500.
      def with_moderation_error
        yield
      rescue ControlPlane::ModerationActions::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn a BridgedNicknames::Invalid (too short or too long, a character
      # that would change how a mention parses, a blank platform) into a flash
      # message rather than a 500. The same exception the /nickname command
      # itself rescues.
      def with_nickname_error
        yield
      rescue ControlPlane::BridgedNicknames::Invalid => e
        flash_result(e.message, error: true)
      end

      # The people page's one write: a blank field clears a nickname, anything
      # else sets it, both through ControlPlane::BridgedNicknames so this
      # route and the /nickname command can never disagree. Two platforms are
      # in play and must not be confused: identity_adapter + native_id is
      # where the row was observed and finds/creates the person; target_adapter
      # is only where the nickname shows, the /nickname <platform> <name> arg.
      def save_dashboard_nickname(community)
        identity_adapter = params[:identity_adapter].to_s
        native_id = params[:native_id].to_s
        target_adapter = params[:target_adapter].to_s
        nickname = presence(params[:nickname])
        return clear_dashboard_nickname(community, identity_adapter, native_id, target_adapter) if nickname.nil?

        person = deps.bridged_nicknames.person_for(
          community_id: community.id, adapter: identity_adapter, native_id: native_id,
          username: presence(params[:username]), display: presence(params[:display])
        )
        result = deps.bridged_nicknames.set(
          community_id: community.id, person_id: person.id, adapter: target_adapter,
          nickname: nickname, set_by: operator_label
        )
        flash_nickname_result(result)
      end

      # Clearing never mints a person: an identity nobody ever gave a nickname
      # has none to clear, and looking it up read-only (rather than through
      # #person_for) keeps a blank submission from being a backdoor way to
      # create a person row just by loading the page and hitting Save.
      def clear_dashboard_nickname(community, identity_adapter, native_id, target_adapter)
        person = deps.bridged_nicknames.person_for_identity(
          community_id: community.id, adapter: identity_adapter, native_id: native_id
        )
        result = person && deps.bridged_nicknames.clear(
          community_id: community.id, person_id: person.id, adapter: target_adapter
        )
        flash_result(result&.ok? ? "Cleared the nickname on #{target_adapter}." :
                       "No nickname to clear on #{target_adapter}.", error: !result&.ok?)
      end

      def flash_nickname_result(result)
        case result.status
        when :set then flash_result("On #{result.adapter} they are now shown as #{result.nickname}.")
        when :taken then flash_result("#{result.nickname} is already taken on #{result.adapter}.", error: true)
        end
      end

      # Turn a ChannelMapper::Invalid (an unresolved selector, or fewer than
      # two channels named) into a flash message rather than a 500. The SAME
      # exception class the DM console's `map` command already rescues per
      # pair (see OperatorConsole#apply_pair); this is the dashboard's side of
      # that same contract.
      def with_mapping_error
        yield
      rescue ControlPlane::ChannelMapper::Invalid => e
        flash_result(e.message, error: true)
      end

      # Apply the ticked rows from the automatic-mapping confirmation page,
      # through ChannelMapper#resolve_selection, the same call a manual
      # mapping makes. Only endpoint keys still unroomed are
      # touched: the confirmation page is a snapshot, so a stale tick (already
      # mapped since rendering) is dropped rather than acted on.
      #
      # @return [Integer] how many channels were mapped
      def apply_auto_mappings(community)
        ticked = Array(params[:apply])
        return 0 if ticked.empty?

        eligible = deps.channel_discovery.unmapped(community).to_h { |channel| [channel.endpoint_key, channel] }
        room_keys = params[:room_key] || {}
        labels = params[:label] || {}
        proposals = if room_keys.empty?
                      rooms = models.room.where(community_id: community.id).order(:room_key).all
                      deps.auto_mapper.propose(channels: eligible.values, rooms: rooms)
                                     .reject(&:skip?).to_h { |proposal| [proposal.channel.endpoint_key, proposal] }
                    else
                      {}
                    end

        ticked.count do |endpoint_key|
          channel = eligible[endpoint_key.to_s]
          next false if channel.nil?

          proposal = proposals[endpoint_key.to_s]
          room_key = room_keys[endpoint_key.to_s].to_s
          room_key = proposal.room_key.to_s if room_key.empty? && proposal
          next false if room_key.empty?

          deps.channel_mapper.resolve_selection(
            community: community, channel: channel, room_key: room_key,
            label: labels[endpoint_key.to_s] || proposal&.room_label
          )
          true
        end
      end

      # Turn a FluxerInstances::Invalid (a blank label, a self-hosted
      # instance with no usable endpoint_url, a duplicate label) into a
      # flash message rather than a 500.
      def with_fluxer_instance_error
        yield
      rescue ControlPlane::FluxerInstances::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn an IrcNetworks::Invalid (a blank name/host/nick, an unknown mode,
      # a hub network with no usable hub_channel, a duplicate name) into a
      # flash message rather than a 500.
      def with_irc_network_error
        yield
      rescue ControlPlane::IrcNetworks::Invalid => e
        flash_result(e.message, error: true)
      end

      # What the Integrations page knows about the configured OpenArc server's
      # models: the ids it offers, the one stored, and whether that one is
      # still there. A server that cannot be reached reports the reason rather
      # than reading as a missing model. Carries the openarc/status read too,
      # and the standing reload instruction as stored and as the client reads
      # it, since a recipe naming another model is kept but never acted on.
      #
      # @return [Hash] available, error, reachable, chosen, effective, missing, status, status_error, reload, reloadable
      def openarc_model_state
        store = ControlPlane::Integrations::OpenArcSettings.new(deps.integrations)
        settings = OpenArc::Settings.new(store: store)
        state = { available: [], error: nil, reachable: nil, chosen: (settings.model if settings.model_chosen?),
                  effective: settings.model, missing: false, status: [], status_error: nil,
                  reload: settings.stored_reload_spec, reloadable: settings.reloadable? }
        return state unless settings.configured?

        client = OpenArc::Client.new(settings: settings)
        begin
          state[:available] = client.models
          state[:reachable] = true
        rescue OpenArc::Client::Error => e
          state[:error] = e.message
          state[:reachable] = false
          return state
        end
        state[:missing] = state[:available].any? && !state[:available].include?(state[:effective])

        begin
          state[:status] = client.status
        rescue OpenArc::Client::Error => e
          state[:status_error] = e.message
        end
        state
      end

      # Writes some of the OpenArc integration's config and leaves the rest of
      # it alone. Save replaces the whole hash, and the chosen model and the
      # reload recipe live side by side in there, so one is read back and
      # merged rather than each write flattening the other. A nil value drops
      # its key, which is how the recipe is forgotten.
      def merge_openarc_config(values)
        stored = deps.integrations.find("openarc")
        deps.integrations.save(
          name: "openarc", url: stored&.url,
          config: (stored&.json_value(:config) || {}).merge(values).compact
        )
      end

      # Keeps the load form's own fields, so a model this server later drops
      # can go back without an operator here to do it. Kept only once the load
      # has worked, which is what makes it a recipe rather than a guess at one,
      # and kept for every load: one naming a model nobody asks for is inert,
      # since OpenArc::Settings acts on a recipe only while it names the model
      # completions actually name.
      def remember_openarc_reload_spec
        spec = { "model_path" => presence(params[:model_path]), "model_name" => presence(params[:model_name]),
                 "model_type" => presence(params[:model_type]), "engine" => presence(params[:engine]),
                 "device" => presence(params[:device]), "cache_dir" => presence(params[:cache_dir]) }.compact
        merge_openarc_config("reload" => spec)
        true
      end

      # The url, key and model a Test connection submitted, each falling back
      # to what is stored, so a blank field means the same as it does on Save.
      def submitted_openarc_store
        stored = deps.integrations.find("openarc")
        Struct.new(:url, :api_key, :model).new(
          presence(params[:url]) || stored&.url,
          presence(params[:api_key]) || stored&.api_key,
          presence(params[:model]) || stored&.json_value(:config)&.[]("model")
        )
      end

      # What a Test connection says about a listing, which is mostly about the
      # chosen model: reaching the server proves nothing if it cannot run it.
      def flash_openarc_test(settings, available)
        if available.empty?
          flash_result("Connected, but this OpenArc server has no models loaded. Load one there " \
                       "first, then pick it here.", error: true)
        elsif available.include?(settings.model)
          flash_result("Connected. OpenArc has #{available.length} model(s) loaded, " \
                       "including #{settings.model}.")
        else
          flash_result("Connected, but #{settings.model} is not loaded on this OpenArc server. " \
                       "It has: #{available.join(", ")}.", error: true)
        end
      end

      # Turn an Integrations::Invalid (an unknown integration name, a URL
      # that is not http(s)) into a flash message rather than a 500.
      def with_integration_error
        yield
      rescue ControlPlane::Integrations::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn a PlatformLinks::Invalid into a flash message rather than a 500.
      # Nothing today raises it (a bad row is dropped, not rejected), but the
      # route wraps it anyway, matching every other write route's shape, so a
      # future validation there is caught here for free.
      def with_platform_links_error
        yield
      rescue ControlPlane::PlatformLinks::Invalid => e
        flash_result(e.message, error: true)
      end

      # Turn a PlatformConnections::Invalid (an unknown adapter, a blank
      # account or external id, a protected community's identity edit, an
      # unconfigured or field-less adapter's behaviour settings, or a
      # behaviour value that fails its schema) into a flash message rather
      # than a 500.
      def with_platform_connection_error
        yield
      rescue ControlPlane::PlatformConnections::Invalid => e
        flash_result(e.message, error: true)
      end

      # Whether the community opted into the room-provisioning controls,
      # read the same community-wide "all" scope every other feature falls
      # back to; there is no per-room meaning for a feature about creating
      # a room that does not exist yet. Off (no row at all) falls through
      # to the feature's own code default, also off.
      def channel_management_enabled?(community)
        row = deps.feature_controls.list(community, selector: "all")
                  .find { |entry| entry[:feature] == Features::ChannelManagement.feature_name }
        row ? row[:enabled] : Features::ChannelManagement.default_enabled?
      end

      # Turn an attempt at the room-provisioning routes with the feature off
      # into a clean flash-and-redirect rather than quietly enqueuing a job
      # the running bot has no reason to expect.
      def deny_unless_channel_management_enabled!(community)
        return if channel_management_enabled?(community)

        flash_result(
          "Channel management is not enabled for #{h(community.name)}. Turn it on from the Features page first.",
          error: true
        )
        redirect to("/communities/#{community.slug}/rooms")
      end

      # Turn a RoomProvisioning::Invalid (an empty name, an unknown platform,
      # a mistyped delete confirmation) into a flash message rather than a
      # 500. The same shape as {#with_mapping_error} and
      # {#with_moderation_error} above.
      def with_room_provisioning_error
        yield
      rescue ControlPlane::RoomProvisioning::Invalid => e
        flash_result(e.message, error: true)
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # A caller-supplied return path, reduced to somewhere on this dashboard.
      # Sinatra's `to` hands back an absolute URL unchanged once it carries a
      # scheme, so an unchecked one is an open redirect off the admin origin.
      def local_path(value)
        path = presence(value).to_s
        return "/" unless path.start_with?("/")
        return "/" if path.start_with?("//", "/\\")

        path
      end
    end
  end
end
