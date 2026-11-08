# frozen_string_literal: true

require "sequel"

module Rubotty
  module Dashboard
    # The bundle of control-plane operations the dashboard drives, built once over
    # one Sequel connection and shared by every request. Each object is a service
    # the bot already uses, so a dashboard edit takes a chat command's own path.
    class Deps
      attr_reader :db, :models, :feature_controls, :lifecycle, :operators, :audit,
                  :guest_invites, :guest_retention, :analytics, :identities, :moderation, :web_login,
                  :config, :logger, :event_scheduling, :event_policy, :channel_mapper, :channel_discovery,
                  :pending_spaces, :space_suggestions, :room_provisioning, :action_permissions, :fluxer_instances,
                  :irc_networks,
                  :accounts, :api_keys, :word_filter_entries, :faq_entries, :platform_links, :auto_mapper,
                  :scripts, :script_pool, :smoke_test, :script_compiler, :script_endpoints,
                  :script_stats, :redirections, :alerts, :webhooks,
                  :platform_connections, :bridged_nicknames, :backfill_proposals, :dashboard_viewers,
                  :dashboard_administrators, :community_viewers, :auth_tokens, :integrations,
                  :participation, :rehosted_files, :polls, :poll_lifecycle, :search,
                  :operator_reachability, :content_policy_misfires, :debug_logs, :durable_jobs

      # @param db [Sequel::Database] the already-migrated control-plane connection
      # @param logger [#info, #warn, nil]
      # @param config [Config::Model, nil] boot-time YAML config, read only (an
      #   account's compiled settings and token_env NAME, never the resolved secret)
      # @param file_store_path [String, nil] where the sealed object store keeps
      #   bulk bytes; the dashboard only UNLINKs it, when revoking a guest invite
      #   reclaims that session's uploads
      # @param debug_logs [DebugLogs] what the Logs page reads, wired to neither process by default
      def initialize(db:, logger: nil, config: nil, file_store_path: config&.file_store_path,
                     debug_logs: DebugLogs.new)
        @db = db
        @logger = logger
        @config = config
        @debug_logs = debug_logs
        @models = ControlPlane.models(db)
        # relay_claim_ttl feeds validation for backfill's safe_horizon_seconds, so
        # a write through the dashboard's config form is checked against the same
        # number the API and the CLI check it against.
        @feature_controls = ControlPlane::FeatureControls.new(
          models: @models, logger: logger, relay_claim_ttl: config&.relay_claim_ttl
        )
        # Both compose over {@feature_controls}: each is one config key on one
        # feature_settings row it already reads and writes correctly.
        @word_filter_entries = ControlPlane::WordFilterEntries.new(feature_controls: @feature_controls, logger: logger)
        @faq_entries = ControlPlane::FaqEntries.new(feature_controls: @feature_controls, logger: logger)
        # The /platforms page's public join-link editor. The link array lives inside
        # utility_commands' feature config.
        @platform_links = ControlPlane::PlatformLinks.new(feature_controls: @feature_controls, logger: logger)
        @lifecycle = ControlPlane::CommunityLifecycle.new(models: @models, logger: logger)
        @operators = ControlPlane::OperatorFlow.new(models: @models, logger: logger)
        # Read only here: the dashboard never sends a DM, it only says which
        # operator accounts the last one was refused at.
        @operator_reachability = ControlPlane::OperatorReachability.new(models: @models, logger: logger)
        @audit = Core::AuditLog::Sequel.new(db: db, logger: logger)
        @action_permissions = ActionPermissions.new(models: @models)
        # The events page lists, creates and cancels through the same service the
        # /event chat command drives, so the two surfaces cannot disagree.
        @event_scheduling = ControlPlane::EventScheduling.new(models: @models, logger: logger)
        # The read-only room policy resolver (enabled + who_can_create).
        @event_policy = ControlPlane::EventPolicy.new(models: @models)
        # The passively-learned identity directory: who has been seen talking. The
        # moderation page searches it to find a mute target by handle, and the
        # people page lists it.
        @identities = ControlPlane::IdentityDirectory.new(models: @models)
        # The bridged-nickname store the /nickname command itself writes to. The
        # people page drives the exact same write, so a nickname set from the
        # dashboard cannot behave any differently than one set in chat.
        @bridged_nicknames = ControlPlane::BridgedNicknames.new(models: @models, logger: logger)
        # Manual mute / unmute, on the same Sequel stores the bot's warnings ladder
        # uses. Built directly, since the dashboard only runs over real Sequel.
        warnings_store = Core::WarningsStore::Sequel.new(db: db, logger: logger)
        scheduler_store = Core::DurableSchedulerStore::Sequel.new(db: db, logger: logger)
        # Never #start-ed: this instance only enqueues rows into scheduled_jobs, and
        # whichever bot process is running polls that same table and runs them.
        scheduler = Core::DurableScheduler.new(store: scheduler_store, session_id: "dashboard", logger: logger)
        # The same never-started instance, read from rather than written to: the
        # failed rows the Jobs page shows are in this database, not in whichever
        # bot process wrote them, so no hop to the bot is needed to read them.
        @durable_jobs = scheduler
        # Guest invites, their retention job and the departure notice all ride the
        # never-started +scheduler+ above. Revoking needs no bot, since it reclaims
        # immediately here.
        @guest_announcer = ControlPlane::GuestAnnouncer.new(
          models: @models, scheduler: scheduler, logger: logger
        )
        build_file_services(file_store_path)
        @guest_retention = ControlPlane::GuestRetention.new(
          models: @models, scheduler: scheduler, logger: logger,
          grace: config ? config.guest_retention : ControlPlane::GuestRetention::DEFAULT_GRACE,
          announcer: @guest_announcer, uploads: @guest_uploads
        )
        @guest_invites = ControlPlane::GuestInvites.new(
          models: @models, logger: logger, retention: @guest_retention, announcer: @guest_announcer
        )
        @moderation = ControlPlane::ModerationActions.new(
          store: warnings_store, scheduler: scheduler, audit: @audit, logger: logger
        )
        # Pending communities: record the decision here, schedule the platform action
        # for the running bot. An approve made here authorizes the very next
        # membership event any bot process sees.

        @pending_spaces = ControlPlane::PendingSpaces.new(
          models: @models, authorization: ControlPlane::AuthorizationDirectory.new(models: @models),
          scheduler: scheduler, logger: logger
        )
        # Name-matching guesses at which community a pending space belongs to.
        # Proposes only; accepting one runs @pending_spaces.approve like any other.
        @space_suggestions = ControlPlane::SpaceSuggestions.new(models: @models, logger: logger)
        # Read-only aggregate views: it counts and buckets the audit log, the identity
        # directory, guest invites and the derived message map, and never writes.
        @analytics = ControlPlane::Analytics.new(db: db, models: @models)
        # The bot-DM to dashboard login handoff: the token the operator console's
        # `web-login` command issues and this process redeems. #migrate! is
        # idempotent, so it is safe whether or not the bot created the table first.
        state_store = Storage::SequelStore.new(db: db, logger: logger).tap(&:migrate!)
        @web_login = ControlPlane::WebLoginTokens.new(store: state_store, logger: logger)
        # The same service the bot DM console's `map` command drives.
        @channel_mapper = ControlPlane::ChannelMapper.new(models: @models, logger: logger)
        # Approving and rejecting a Rooms-board suggestion: pure row reads and writes,
        # with no live gateway sighting, so watch: is left at its nil default.
        @channel_discovery = ControlPlane::ChannelDiscovery.new(models: @models, logger: logger)
        # Name-matching proposals for automatic mapping. Proposes only; the route
        # applies the approved subset through @channel_mapper.
        @auto_mapper = ControlPlane::AutoMapper.new(models: @models, logger: logger)
        # The pool is built lazily and degrades to unavailable with no Lua interpreter
        # installed, so a deployment that never turned scripts on is unaffected.
        @script_pool = Scripting::Pool.new(size: Scripting::Pool.configured_size, logger: logger)
        @smoke_test = Scripting::SmokeTest.new(pool: @script_pool, logger: logger)
        # Everything but Lua is transpiled here, at save time, so only Lua ever
        # reaches the sandbox. A dialect whose transpiler this image lacks is
        # reported unavailable.
        @script_compiler = Scripting::Compiler.new(logger: logger)
        @scripts = ControlPlane::Scripts.new(models: @models, logger: logger, smoke_test: @smoke_test,
                                             compiler: @script_compiler)
        # The named outbound endpoints those scripts may call.
        @script_endpoints = ControlPlane::ScriptEndpoints.new(models: @models, logger: logger)
        @script_stats = ControlPlane::ScriptStats.new(models: @models, logger: logger)
        # What those scripts raised for the operators. The dashboard only reads them
        # and marks them seen.
        @alerts = ControlPlane::Alerts.new(models: @models, logger: logger)
        # The samples /vindicate leaves behind: what a policy matched, why the
        # model thought so, and why an operator disagreed. Read only here.
        @content_policy_misfires = ControlPlane::ContentPolicyMisfires.new(models: @models, logger: logger)
        # Where a community's events are sent and what happened to each attempt. The
        # dashboard reads the history and can requeue a dead-lettered delivery.
        @webhooks = ControlPlane::Webhooks.new(models: @models, logger: logger)
        # Runs of messages moved between rooms. The dashboard reads the log and stops
        # a move that is still posting.
        @redirections = ControlPlane::Redirections.new(models: @models, logger: logger)
        # The dashboard only ever calls the REQUEST half (#request_create /
        # #request_delete), which enqueues a durable job. Calling #create or #delete
        # on THIS instance raises past a nil adapter lookup, deliberately.
        @room_provisioning = ControlPlane::RoomProvisioning.new(
          models: @models, scheduler: scheduler, adapters: {}, registry: nil, audit: @audit, logger: logger
        )
        # A community's flagship plus self-hosted Fluxer connections.
        @fluxer_instances = ControlPlane::FluxerInstances.new(models: @models, logger: logger)
        # A community's IRC networks, the same DB+panel-config bucket Fluxer uses.
        @irc_networks = ControlPlane::IrcNetworks.new(models: @models, logger: logger)
        # Connection CRUD plus per-account behaviour settings, so the API drives the
        # same create/edit/remove checks a Platforms-page write does.
        @platform_connections = ControlPlane::PlatformConnections.new(models: @models, logger: logger)
        # The deployment's credentialed gateway accounts. A write here is picked up by
        # the bot's next BOOT instead of its change detector.
        @accounts = ControlPlane::Accounts.new(models: @models, logger: logger)
        # The dashboard issues, lists and revokes REST admin API keys; the API process
        # reads the rows.
        @api_keys = ControlPlane::ApiKeys.new(models: @models, logger: logger)
        # What a backfill sweep proposed and is waiting on an operator for. The
        # dashboard reads the list and decides; only the bot process (over the
        # internal hop, see BotNudge#relay_proposal) can actually send.
        @backfill_proposals = ControlPlane::BackfillProposals.new(models: @models, logger: logger)
        # Who reads every community and changes nothing: the shipped YAML as a
        # floor, granted rows on top, and the requests waiting on an
        # administrator. Every grant and revocation is audited, since a role
        # that spans the deployment is the one worth accounting for later.
        @dashboard_viewers = ControlPlane::DashboardViewers.new(
          models: @models, logger: logger, audit: @audit
        )
        # Who administers the deployment, arranged the same way one rung up.
        # Read on every redemption of a sign-in link that claims the role, so a
        # revoked administrator's outstanding link opens nothing.
        @dashboard_administrators = ControlPlane::DashboardAdministrators.new(
          models: @models, logger: logger, audit: @audit
        )
        # The same thing scoped to one community, which is why an operator of
        # that community may hand it out: it reaches no further than they do.
        @community_viewers = ControlPlane::CommunityViewers.new(
          models: @models, logger: logger, audit: @audit
        )
        # Minting, listing and revoking the tokens that hand somebody a role.
        # Redeeming one happens in a DM to the bot, so this process is never
        # given the services a grant is applied through.
        @auth_tokens = ControlPlane::AuthTokens.new(models: @models, logger: logger, audit: @audit)
        # The deployment-wide connections rubotty plugs into, e.g.
        # LibreTranslate. A write here is picked up by the bot's next translation,
        # the same live-reread every other control-plane-backed setting gets.
        @integrations = ControlPlane::Integrations.new(models: @models, logger: logger)
        # The session, round and standings behind a script's trivia, poll or
        # Q&A. Read-only from here except for closing a stuck session, the
        # same call a script's own close_session makes.
        @participation = ControlPlane::Participation.new(models: @models, logger: logger)
        # Built with no live registry or adapters, like @room_provisioning
        # above: a dashboard cancel really withdraws the armed timekeeper
        # job against +scheduler+'s durable store, but the closed-room
        # announcement Board#announce_results would post is a silent no-op.
        @polls = ControlPlane::Polls.new(models: @models, logger: logger)
        poll_ballot = Polls::Ballot.new(models: @models, logger: logger)
        poll_board = Polls::Board.new(
          registry: nil, models: @models, adapters: {}, polls: @polls, ballot: poll_ballot, logger: logger
        )
        poll_timekeeper = Polls::Timekeeper.new(scheduler: scheduler, logger: logger)
        @poll_lifecycle = Polls::Lifecycle.new(
          polls: @polls, board: poll_board, timekeeper: poll_timekeeper, logger: logger
        )
        # Read-only navigation lookup for the command bar. It is handed the
        # reader's grants per request (see {SearchScope}) rather than holding
        # any, so this one instance is safe to share across sessions.
        @search = ControlPlane::Search.new(models: @models, logger: logger)
      end

      # The community row for a slug, or nil, so a bad slug becomes a clean 404.
      def community(slug)
        @models.community.where(slug: slug.to_s).first
      end

      # Every community, ordered by slug, for the index and the audit picker.
      def communities
        @models.community.order(:slug).all
      end

      private

      # The guest-upload and rehosted-file services, over the same object store, or
      # both nil when this dashboard has no store to reach. The path is never
      # defaulted: a dashboard that invented one would unlink nothing while
      # looking like it had.
      def build_file_services(path)
        return if path.to_s.strip.empty?

        store = Storage::ObjectStore.new(root: path, logger: @logger)
        store.ready!
        @guest_uploads = ControlPlane::GuestUploads.new(models: @models, store: store, logger: @logger)
        @rehosted_files = ControlPlane::RehostedFiles.new(models: @models, store: store, logger: @logger)
      rescue Storage::ObjectStore::Unavailable => e
        @logger&.warn do
          "file store unavailable, so revoking a guest session reclaims its rows and leaves its " \
            "uploaded files on disk, and the files panel has nothing to show: #{e.message}"
        end
        @guest_uploads = nil
        @rehosted_files = nil
      end
    end
  end
end
