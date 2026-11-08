# frozen_string_literal: true

require "sequel"

module Rubotty
  module Api
    # The bundle of control-plane operations the REST admin API drives, built
    # once over one Sequel connection and shared by every request.
    #
    # This process holds no handle on a running bot's live Snapshot, so a write
    # here lands in the database and the bot's own {ControlPlane::ChangeDetector}
    # poll picks it up, exactly like a dashboard edit.
    class Deps
      attr_reader :db, :models, :api_keys, :rate_limiter, :feature_controls, :channel_discovery,
                  :word_filter_entries, :faq_entries, :platform_links, :platform_connections,
                  :irc_networks, :fluxer_instances, :guest_invites, :event_scheduling, :analytics,
                  :lifecycle, :moderation, :room_provisioning,
                  :accounts, :log_buffer, :bot_logs, :auto_mapper, :channel_mapper,
                  :scripts, :script_endpoints, :script_stats, :script_compiler, :smoke_test, :script_pool,
                  :api_messages, :api_wrapper_events, :api_message_actions, :live_room_feed, :webhooks, :alerts,
                  :rehosted_files, :config,
                  :pending_spaces, :space_suggestions, :audit, :dashboard_viewers, :dashboard_administrators, :community_viewers,
                  :auth_tokens, :backfill_proposals, :bot_relay, :operators, :bridged_nicknames, :integrations,
                  :participation, :storage, :action_permissions, :content_policy_misfires

      # @param log_buffer [RingBuffer, nil] nil answers source=web with "not configured" instead of empty
      # @param bot_secret [String, nil] shared secret for {Core::HealthServer::RELOAD_SECRET_HEADER}
      # @param file_store_path [String, nil] unusable leaves {#rehosted_files} nil, 503ing file routes
      # @param config [Config::Model, nil] feeds the relay_claim_ttl a backfill write is checked against
      # @param bot_relay [#relay_proposal, nil] built from bot_url/bot_secret when nil
      # @param storage [Storage::Base, nil] nil makes react/edit/delete routes 404 instead of queuing
      def initialize(db:, logger: nil, rate_max: ControlPlane::ApiRateLimiter::DEFAULT_MAX,
                     rate_window: ControlPlane::ApiRateLimiter::DEFAULT_WINDOW_SECONDS,
                     log_buffer: nil, bot_url: nil, bot_secret: nil, file_store_path: nil, config: nil,
                     bot_relay: nil, storage: nil)
        @db = db
        @logger = logger
        @storage = storage
        @log_buffer = log_buffer
        @config = config
        @bot_logs = BotLogsClient.new(bot_url: bot_url, secret: bot_secret, logger: logger)
        @models = ControlPlane.models(db)
        @api_keys = ControlPlane::ApiKeys.new(models: @models, logger: logger)
        @rate_limiter = ControlPlane::ApiRateLimiter.new(models: @models, max: rate_max, window_seconds: rate_window)
        @feature_controls = ControlPlane::FeatureControls.new(
          models: @models, logger: logger, relay_claim_ttl: config&.relay_claim_ttl
        )
        # Read-only through this service; mapping is applied through @channel_mapper.
        @channel_discovery = ControlPlane::ChannelDiscovery.new(models: @models, logger: logger)
        # Each of these is one config key on a feature_settings row.
        @word_filter_entries = ControlPlane::WordFilterEntries.new(feature_controls: @feature_controls, logger: logger)
        @faq_entries = ControlPlane::FaqEntries.new(feature_controls: @feature_controls, logger: logger)
        @platform_links = ControlPlane::PlatformLinks.new(feature_controls: @feature_controls, logger: logger)
        @platform_connections = ControlPlane::PlatformConnections.new(models: @models, logger: logger)
        @irc_networks = ControlPlane::IrcNetworks.new(models: @models, logger: logger)
        @fluxer_instances = ControlPlane::FluxerInstances.new(models: @models, logger: logger)
        @guest_invites = ControlPlane::GuestInvites.new(models: @models, logger: logger)
        @event_scheduling = ControlPlane::EventScheduling.new(models: @models, logger: logger)
        @analytics = ControlPlane::Analytics.new(db: db, models: @models)
        @accounts = ControlPlane::Accounts.new(models: @models, logger: logger)
        # The deployment-wide connections rubotty plugs into, e.g. LibreTranslate.
        # Read-only from here, same as accounts and the gateway connections
        # above: every write still goes through the dashboard.
        @integrations = ControlPlane::Integrations.new(models: @models, logger: logger)
        # The pool degrades to unavailable with no Lua interpreter installed.
        @script_pool = Scripting::Pool.new(size: Scripting::Pool.configured_size, logger: logger)
        @smoke_test = Scripting::SmokeTest.new(pool: @script_pool, logger: logger)
        @script_compiler = Scripting::Compiler.new(logger: logger)
        @scripts = ControlPlane::Scripts.new(models: @models, logger: logger,
                                             smoke_test: @smoke_test, compiler: @script_compiler)
        @script_endpoints = ControlPlane::ScriptEndpoints.new(models: @models, logger: logger)
        @script_stats = ControlPlane::ScriptStats.new(models: @models, logger: logger)
        # Propose here, apply through the same ChannelMapper the dashboard uses.
        @auto_mapper = ControlPlane::AutoMapper.new(models: @models, logger: logger)
        @channel_mapper = ControlPlane::ChannelMapper.new(models: @models, logger: logger)
        # This process only writes the queue and only reads the buffer; the bot
        # drains one and fills the other.
        @api_messages = ControlPlane::ApiMessages.new(models: @models)
        # The api_wrapper platform adapter's own inbound queue: this process
        # writes once a request authenticates with a platform-account scoped
        # key, and every configured api_wrapper account's own adapter instance
        # in the bot drains its own rows.
        @api_wrapper_events = ControlPlane::ApiWrapperEvents.new(models: @models)
        # The room-level react/edit/delete queue: this process writes once a
        # message id resolves against @storage above, and the bot's own API
        # adapter drains its rows back out, the same split as api_messages.
        @api_message_actions = ControlPlane::ApiMessageActions.new(models: @models)
        @live_room_feed = ControlPlane::LiveRoomFeed.new(models: @models)
        # Sending is a durable job only the bot schedules, so a subscription created
        # here starts receiving on the bot's next reconcile tick.
        @webhooks = ControlPlane::Webhooks.new(models: @models, logger: logger)
        @alerts = ControlPlane::Alerts.new(models: @models, logger: logger)
        # The samples /vindicate leaves behind, so a tuning script can read the
        # same corpus the dashboard's misfire page shows.
        @content_policy_misfires = ControlPlane::ContentPolicyMisfires.new(models: @models, logger: logger)
        # What a backfill sweep held back, over the same service the dashboard's
        # page drives, so the two surfaces cannot disagree about what is waiting.
        @backfill_proposals = ControlPlane::BackfillProposals.new(models: @models, logger: logger)
        # Accepting a proposal only writes a row here; the bot process holds the
        # adapters, so the same push the dashboard sends is what makes it go out.
        @bot_relay = bot_relay || Dashboard::BotNudge.new(bot_url: bot_url, secret: bot_secret, logger: logger)
        @audit = Core::AuditLog::Sequel.new(db: db, logger: logger)
        build_onboarding_services(db, logger)
        # These services only record durable state and jobs. The running bot
        # notices them through its normal change detector and scheduler, just
        # as it does for a dashboard request.
        @lifecycle = ControlPlane::CommunityLifecycle.new(models: @models, logger: logger)
        @moderation = ControlPlane::ModerationActions.new(
          store: Core::WarningsStore::Sequel.new(db: db, logger: logger), scheduler: @scheduler,
          audit: @audit, logger: logger
        )
        @room_provisioning = ControlPlane::RoomProvisioning.new(
          models: @models, scheduler: @scheduler, adapters: {}, registry: nil, audit: @audit, logger: logger
        )
        # The admin-only viewer roster: the shipped YAML as a floor, granted rows
        # on top, and the requests waiting on a decision. The same service the
        # dashboard drives, so the two surfaces cannot disagree about who reads
        # every community.
        @dashboard_viewers = ControlPlane::DashboardViewers.new(
          models: @models, logger: logger, audit: @audit
        )
        # The deployment's highest role follows the same roster shape as
        # viewers: granted rows sit above the shipped floor, and only an
        # administrator key may change either route's deployment-wide scope.
        @dashboard_administrators = ControlPlane::DashboardAdministrators.new(
          models: @models, logger: logger, audit: @audit
        )
        # The community-scoped half, which lives on the ordinary community path
        # because a developer key confined to one community may drive it.
        @community_viewers = ControlPlane::CommunityViewers.new(
          models: @models, logger: logger, audit: @audit
        )
        # Minting, listing and revoking only: redeeming happens in a DM to the
        # bot, so this process never needs the services a grant is applied
        # through and is not given them.
        @auth_tokens = ControlPlane::AuthTokens.new(models: @models, logger: logger, audit: @audit)
        # No registry, the same as every other write here: this process holds no
        # live Snapshot, so a grant is picked up by the bot's own change detector.
        @operators = ControlPlane::OperatorFlow.new(models: @models, logger: logger)
        # The name a person is bridged as, over the exact store the /nickname
        # command and the dashboard's people page write to.
        @bridged_nicknames = ControlPlane::BridgedNicknames.new(models: @models, logger: logger)
        # The session, round and standings behind a script's trivia, poll or Q&A.
        # Developer reachable: a community's own scoreboard is no more sensitive
        # than its alerts, and closing a stuck session is the same call a
        # script's own close_session makes.
        @participation = ControlPlane::Participation.new(models: @models, logger: logger)
        # Deployment-wide, same table the dashboard's Operators page checkbox
        # grid reads and writes through POST /operator-permissions.
        @action_permissions = Dashboard::ActionPermissions.new(models: @models)
        build_file_services(file_store_path)
      end

      # The community row for a slug, or nil. A bad slug and a community a developer
      # key cannot see both become the same 404 (see {App#community!}).
      def community(slug)
        @models.community.where(slug: slug.to_s).first
      end

      # Every community, ordered by slug, for the admin-only listing.
      def communities
        @models.community.order(:slug).all
      end

      private

      # The onboarding queue and its name-matching guesses, wired exactly the way the
      # dashboard wires them. The scheduler is never #start-ed here: this process only
      # enqueues the auto-leave job, and whichever bot process is running polls the
      # same table and carries the departure out.
      def build_onboarding_services(db, logger)
        @scheduler = Core::DurableScheduler.new(
          store: Core::DurableSchedulerStore::Sequel.new(db: db, logger: logger),
          session_id: "api", logger: logger
        )
        @pending_spaces = ControlPlane::PendingSpaces.new(
          models: @models, authorization: ControlPlane::AuthorizationDirectory.new(models: @models),
          scheduler: @scheduler, logger: logger
        )
        # Proposes only; accepting one runs the same approve the onboarding queue runs.
        @space_suggestions = ControlPlane::SpaceSuggestions.new(models: @models, logger: logger)
      end

      # The rehosted-file service, or nil when the object store is not usable from
      # this process, so a mount that did not come up only takes out the file routes.
      def build_file_services(configured)
        # No path named means no store, rather than a store directory initialised
        # beside whatever the working directory happens to be.
        return if configured.to_s.strip.empty?

        store = Storage::ObjectStore.new(root: Storage::ObjectStore.path_from(configured), logger: @logger)
        store.ready!
        @rehosted_files = ControlPlane::RehostedFiles.new(models: @models, store: store, logger: @logger)
      rescue Storage::ObjectStore::Unavailable => e
        @logger&.warn { "file store unavailable, so the API's file routes are off: #{e.message}" }
        @rehosted_files = nil
      end
    end
  end
end
