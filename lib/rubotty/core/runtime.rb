# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Core
    # Wires everything together and owns the process lifecycle. Boot order
    # is fixed: storage, then the loop guard (needs storage), the router
    # (needs the loop guard), the dispatcher (needs the router), then
    # adapters last, so nothing can arrive before something can route it.
    class Runtime
      # How long after boot the statistics retention first runs. Short, because
      # the schedule is rebuilt on every start and anything a full interval
      # away is never reached by a deployment that redeploys more often.
      SCRIPT_STATS_FIRST_PRUNE = 120

      # How long after boot the rehosted-file expiry first runs. Short, for
      # the same reason as the statistics retention above: the schedule is
      # rebuilt on every start, so a job a full day out would never be
      # reached by a deployment that redeploys daily.
      REHOSTED_FILES_FIRST_EXPIRY = 180

      # How long after boot the identity-directory prune first runs. Short,
      # for the same reason as the two constants above it.
      IDENTITY_DIRECTORY_FIRST_PRUNE = 150

      # How much longer the operator startup DM lives than the room banner, a
      # multiple of config.announce_delete_after rather than its own setting
      # so the two cannot drift apart. An operator reads a DM on their own
      # schedule rather than while watching a channel, so the window that
      # makes sense in a room is too short for a DM.
      OPERATOR_DM_DELETE_MULTIPLIER = 3

      # How often the straggler banner sweep re-runs. Boot alone was not enough:
      # a banner posted while the delete window was zero has no durable row, so
      # nothing removes it until the next restart happens to sweep it.
      BANNER_SWEEP_INTERVAL = 24 * 60 * 60

      # Remembers the previous announcement's group id so a fresh restart can
      # delete it immediately rather than leaving two banners visible until
      # the older one's own timer catches up. A frequent redeploy cycle can
      # restart faster than the delete window, which is exactly when this
      # matters most.
      ANNOUNCE_LAST_GROUP_STATE_KEY = "announce.last_group_id"

      # @param log_buffer [RingBuffer, nil] recent HTTP-readable log lines.
      #   A custom logger must supply its own buffer; only its caller can tee
      #   the logger (see CLI#command_run).
      def initialize(config:, logger: nil, storage: nil, env: ENV, community_slug: nil, log_buffer: nil)
        @config = config
        @log_buffer = log_buffer || (logger ? nil : RingBuffer.new)
        @logger = logger || Log.build(level: config.log_level, ring_buffer: @log_buffer)
        @env = env
        @storage = storage
        @community_slug = community_slug
        @adapters = {}
        @adapter_health = AdapterHealth.new(window: adapter_health_window)
        @registry = nil
        @channel_resolver = nil
        @identity_directory = nil
        @bridged_nicknames = nil
        @participants = nil
        @change_detector = nil
        @script_recurrence_watch = nil
        @event_lifecycle = nil
        @event_recurrence = nil
        @control_watcher = nil
        @native_mirror = nil
        @guest_retention = nil
        @guest_announcer = nil
        @guest_uploads = nil
        @object_store = nil
        @rehoster = nil
        @health = nil
        @gateway_cycle = nil
        @quiet_gateway_watchdog = nil
        @stopping = false
        # Durable ephemeral rows carry this boot id, distinguishing this
        # session's pending deletes from rows a crashed session orphaned.
        @session_id = SecureRandom.uuid
      end

      attr_reader :config, :logger, :storage, :adapters, :adapter_health, :router, :dispatcher, :loop_guard,
                  :registry, :channel_resolver, :health, :ephemeral, :durable_scheduler, :log_buffer,
                  :operator_flow, :admin_reach, :control_lane, :operator_console, :join_guard, :onboarding,
                  :identity_recorder, :identity_directory, :change_detector, :session_id, :warnings,
                  :keyword_watches, :announcements, :audit_log, :guest_adapter, :channel_discovery,
                  :event_scheduling, :event_announcer, :event_reminders, :event_rsvp_ledger, :event_lifecycle,
                  :event_recurrence,
                  :polls, :poll_board, :poll_ballot, :poll_activity, :poll_timekeeper, :poll_lifecycle,
                  :native_mirror, :scheduler, :pending_spaces, :admin_notifier, :control_watcher,
                  :guest_retention, :guest_announcer, :guest_invites, :room_provisioning, :link_annotator,
                  :translation_relay, :room_summaries, :semantic_analysis, :topic_router, :content_policy,
                  :gateway_cycle, :quiet_gateway_watchdog

      def build
        @storage ||= build_storage
        logger.info { "storage: #{@storage.describe}" }

        @loop_guard = LoopGuard.new(storage: @storage)
        # Build the control plane before topology readers. With it, runtime
        # services read the Snapshot; otherwise they use config topology.
        build_control_plane
        # Shared operator request/approval operations. Nil without a control
        # plane, leaving the in-chat feature inert.
        @operator_flow = build_operator_flow
        # Best-effort pending-space DMs use the eventual adapter map. Build it
        # before admin reach; it is nil without a control plane.
        @admin_notifier = build_admin_notifier
        # Resolves the communities a DM can act on for both DM lanes and web
        # login. Nil without a control plane.
        @admin_reach = build_admin_reach
        # Who reads every community and changes nothing: the shipped YAML
        # floor unioned with the granted rows. Both DM lanes below consult
        # it, one to recognise a viewer and one to file a request.
        @dashboard_viewers = build_dashboard_viewers
        # Who administers the whole deployment, resolved the same way from the
        # same kind of pair, so a `web-login` link carries the role its sender
        # actually holds rather than only the two smaller ones.
        @dashboard_administrators = build_dashboard_administrators
        # Who reads ONE community and changes nothing in it: the same dimension
        # scoped to a single community, which is the only one of the two a DM
        # can ask for.
        @community_viewers = build_community_viewers
        # Token credentials and `/auth`, shared by both DM lanes for consistent
        # reads regardless of the sender's route.
        @auth_tokens = build_auth_tokens
        @auth_command = build_auth_command
        # What a member reported. Built before the control lane, since the DM
        # report branch is the one thing in that lane a member with no standing
        # anywhere may reach.
        @member_reports = build_member_reports
        # Handles DM operator requests that miss channel routing. Nil without a
        # control plane, retaining the previous dropped-DM behaviour.
        @control_lane = build_control_lane
        # Decides whether a joined space is authorised before a short notice and
        # auto-leave. Nil without a control plane.
        @onboarding = build_onboarding
        @join_guard = build_join_guard
        # Passively records cross-platform identities. Nil without a control
        # plane, like other services that degrade on memory or pstore.
        @identity_recorder = build_identity_recorder
        # Who may take down a message rubotty put back, built before the command
        # parser because that parser is the only thing that reads it: a member
        # replying /delete to a restoration is authorised from here.
        @content_policy_reposts = build_content_policy_reposts
        # Moves the classifier wants an operator to confirm, and the corpus
        # those answers build. Built before the console that answers them.
        @topic_move_proposals = build_topic_move_proposals
        @commands = build_commands
        @scheduler = build_scheduler
        # Built before the durable worker, whose discard hook counts into it.
        @model_call_stats = build_model_call_stats
        # Cross-restart deferred actions use Sequel; memory and pstore have no
        # worker. This crash-safe backstop precedes ephemeral delete handlers.
        @durable_scheduler = build_durable_scheduler
        register_model_call_stats_prune
        # Register directory pruning now that the durable scheduler exists,
        # before boot recovery runs.
        register_identity_directory_prune
        register_identity_history_prune
        register_bridged_nickname_history_prune
        # Built before the ephemeral primitive, which is what writes to it.
        @bot_messages = build_bot_messages
        # Startup banners and moderation acknowledgements share this primitive.
        # It retains the adapter map and registers delete recovery before boot.
        @ephemeral = build_ephemeral
        register_bot_messages_prune
        # Built before the warnings service, which hands it whatever it could
        # not send, and before the console, which hands those over on contact.
        @undelivered_dms = build_undelivered_dms
        register_undelivered_dms_prune
        @warning_announcements = build_warning_announcements
        register_warning_announcements_prune
        # The store itself is built earlier, before the control lane that reads
        # it; the sweep needs the durable scheduler, which is not up until here.
        register_member_reports_prune
        # Warning strikes and sanctions persist through the control plane.
        # Register expiry recovery before boot so missed sanctions lift on start.
        @warnings = build_warnings
        # Keyword watches use the durable scheduler for expiry and recovery.
        # They are inert without it.
        @keyword_watches = build_keyword_watches
        # Build scripts here so deferred endpoint jobs register before boot
        # recovery, like warnings and announcements.
        build_scripting
        # Announcement jobs register before recovery, then reconcile once
        # adapters and the Snapshot settle. Inert without durable scheduling.
        @announcements = build_announcement_scheduler
        # Guest retention needs the object store to unlink upload bytes. Verify
        # it at boot; see #build_object_store.
        @object_store = build_object_store
        @guest_uploads = build_guest_uploads
        # Register link annotation jobs before recovery so queued lookups retain
        # a handler. Inert without durable scheduling.
        @link_annotator = build_link_annotator
        # Register translation jobs before recovery so queued work retains a
        # handler. Inert without durable scheduling.
        @translation_relay = build_translation_relay
        # Room summaries use the same durable worker boundary as translation,
        # keeping generation out of inbound message handling.
        @room_summaries = build_room_summaries
        @semantic_analysis = build_semantic_analysis
        # Guest retention recovers expired sessions at start. Its announcer is
        # built first because both revoke and expiry post through it.
        @guest_announcer = build_guest_announcer
        @guest_retention = build_guest_retention
        # Guest commands and adapter checks share one operations service. It is
        # nil without a control plane.
        @guest_invites = build_guest_invites
        # API outbound and live-stream tables must exist before routing. Both are
        # nil without a control plane.
        @api_messages = build_api_messages
        # API-wrapper accounts share this inbound queue, which their adapters
        # drain after the API process writes it.
        @api_wrapper_events = build_api_wrapper_events
        # API meta-message react, edit and delete requests queue here for the
        # API adapter to drain.
        @api_message_actions = build_api_message_actions
        @live_room_feed = build_live_room_feed
        # Webhook subscribers queue from the bridge's relay fan-out. Nil without
        # a control plane.
        @webhooks = build_webhooks
        # Built here only so the purge tick can age its table out. The bot
        # never limits anything: the web process does the counting, and this
        # process is the one with a periodic tick to do the deleting.
        @api_rate_limiter = build_api_rate_limiter
        # Moderation writes to a Sequel-backed audit log before routing. Memory
        # and pstore use a Null no-op.
        @audit_log = build_audit_log
        # Event services follow adapters and durable scheduling: announcer,
        # reminders, then writer. They are nil without a control plane.
        @event_announcer = build_event_announcer
        @event_reminders = build_event_reminders
        @event_scheduling = build_event_scheduling
        # The RSVP ledger shares the event database and accompanies the
        # announcer and writer for Features::EventRsvp.
        @event_rsvp_ledger = build_event_rsvp_ledger
        # Event lifecycle turns written events into announcements, mirrors and
        # reminders. It follows its dependencies and starts in #start.
        @event_lifecycle = build_event_lifecycle
        # Recurrence writes the next due event through event scheduling for the
        # lifecycle to detect.
        @event_recurrence = build_event_recurrence
        @native_mirror = build_native_mirror
        # Polls, built the same way as events above. Real only with a control
        # plane, which is what makes /poll inert on the memory/pstore path.
        build_polls
        # Pending-space review registers auto-leave recovery before boot. It is
        # nil without a control plane.
        @pending_spaces = build_pending_spaces
        # Dashboard room provisioning registers recovery handlers before boot
        # and retains the adapter map. Nil without a control plane.
        @room_provisioning = build_room_provisioning
        # Channel discovery backs mapping and /identify-topic. Nil without a
        # control plane.
        @channel_discovery = build_channel_discovery
        # Follows a Telegram group upgraded to a supergroup onto its new id. Nil
        # without a control plane.
        @space_migration = build_space_migration
        # Redirection registers durable recovery before routing so interrupted
        # moves resume on start.
        @redirections = build_redirections
        @redirection_window = build_redirection_window
        register_redirection_window_prune
        # Topic routing follows the redirection rows: an automatic move opens an
        # ordinary one-message redirection, paced by the same worker.
        @topic_router = build_topic_router
        register_topic_move_proposal_jobs
        # Built first: the service records through it, and the alert it sends
        # carries the code that record mints.
        @content_policy_actions = build_content_policy_actions
        # The corpus a reversal feeds, read by the dashboard's misfire page.
        @content_policy_misfires = build_content_policy_misfires
        @content_policy = build_content_policy
        register_content_policy_actions_prune
        register_content_policy_misfires_prune
        # Undoing one of those actions from an operator DM. Built here because
        # it needs the adapters and the ephemeral poster, and the console that
        # hosts the command is built next so it can hold this.
        @content_policy_vindication = build_content_policy_vindication
        # Authenticated operators use this stateful wrapper; others fall through
        # to the request lane. Nil without a control plane. Built after the
        # services its commands reach, which is why it comes this late.
        @operator_console = build_operator_console
        # Per-endpoint content records supplement relay claims. The bridge writes
        # both at fan-out; this is nil without a control plane.
        @relay_fingerprints = build_relay_fingerprints
        @pending_operations = PendingOperations.new(logger: Log.tagged(logger, "redirection"))
        # Build file rehosting before routing for bridge and `/upload` use.
        @rehosted_files = build_rehosted_files
        @upload_tickets = build_upload_tickets
        @rehoster = build_rehoster
        @upload_announcer = build_upload_announcer
        # Register daily file expiry before boot recovery.
        register_rehosted_file_expiry
        # Register webhook jobs before recovery so reclaimed pumps retain their
        # handlers.
        register_webhook_jobs
        # Where the bridge reports what became of each copy a paced backfill
        # relay fed in, shared with the sweep below that reads it back.
        @relay_outcomes = RelayOutcomes.new(logger: Log.tagged(logger, "relay"))
        # Delivery health for every live send, which relay_outcomes deliberately
        # does not cover: it records only what a sweep asked it to watch, so a
        # platform refusing posts left no trace anywhere. Read back over the
        # health server's stats hop, beside the inbound counters.
        @endpoint_health = EndpointHealth.new
        @router = Router.new(
          topology: routing_topology,
          adapters: @adapters,
          storage: @storage,
          loop_guard: @loop_guard,
          logger: Log.tagged(logger, "router"),
          default_display_name: config.display_name,
          ttl: config.message_ttl,
          claim_ttl: config.relay_claim_ttl,
          reply_preview_chars: config.reply_preview_chars,
          reply_preview_lines: config.reply_preview_lines,
          operators: routing_operators,
          commands: @commands,
          people: routing_people,
          suppress_notices: config.suppress_delivery_notices?,
          cleanup: @scheduler,
          cleanup_after: command_cleanup_after,
          acknowledge: command_acknowledge?,
          ephemeral: @ephemeral,
          retry_policy: RetryPolicy.new(
            attempts: config.delivery_attempts,
            logger: Log.tagged(logger, "retry")
          ),
          # The control plane resolves messages from its live Snapshot and gates
          # features by scope. Nil retains the legacy unconditional run.
          registry: @registry,
          relay_outcomes: @relay_outcomes,
          endpoint_health: @endpoint_health,
          # Pairs a warning's in-room notice with the message it was about, so
          # a delete through the bot takes the notice with it.
          warning_announcements: @warning_announcements,
          member_reports: @member_reports,
          # What /clean sweeps: the permanent posts EphemeralMessage recorded.
          bot_messages: @bot_messages,
          # Operator chat requests use this shared service. Nil leaves them inert
          # without a control plane.
          operator_flow: @operator_flow,
          # The pipeline records every community-scoped inbound identity. Nil
          # leaves it inert without a control plane.
          identity_recorder: @identity_recorder,
          # The bridge resolves cross-platform mentions through this directory.
          # Nil keeps rewriting inert without a control plane.
          identity_directory: @identity_directory,
          # `/nickname` stores bridged names here. Nil omits the command without
          # a control plane.
          bridged_nicknames: @bridged_nicknames,
          # Warnings and word-filter sanctions use this service. Only Sequel is
          # durable; memory and pstore leave the feature inactive.
          warnings: @warnings,
          # Moderation records executed commands here. Memory and pstore use a
          # Null no-op.
          audit: @audit_log,
          # `/event` uses this shared scheduler. Nil leaves it inert without a
          # control plane.
          event_scheduling: @event_scheduling,
          # `/rsvp` and reactions need the announcer and ledger. Both are nil
          # without a control plane.
          event_announcer: @event_announcer,
          event_rsvp_ledger: @event_rsvp_ledger,
          # Poll services are nil without a control plane, leaving `/poll` inert.
          polls: @polls,
          poll_board: @poll_board,
          poll_ballot: @poll_ballot,
          poll_lifecycle: @poll_lifecycle,
          poll_activity: @poll_activity,
          # `/identify-topic` writes through this channel target. Nil leaves it
          # inert where no channel rows exist.
          channel_discovery: @channel_discovery,
          # This coordinator enables `/watch` and its message cache. Nil without
          # durable scheduling leaves both inert.
          keyword_watches: @keyword_watches,
          # `/guest` uses this shared service. Nil leaves it inert without a
          # control plane.
          guest_invites: @guest_invites,
          # Script services are nil without a control plane or Lua, keeping the
          # feature absent rather than partial.
          scripts: @scripts,
          script_pool: @script_pool,
          script_endpoints: @script_endpoints,
          script_memory: @script_memory,
          # Script and community statistics enable their registered functions;
          # omitting the service registers none of them.
          script_stats: @script_stats,
          # Without this service, participation functions are not offered.
          participation: @participation,
          # Raised alerts write here and loud ones use the notifier. Both are nil
          # without a control plane or Lua; records still matter without DMs.
          alerts: @alerts,
          admin_notifier: @admin_notifier,
          # Script participant functions are absent without a control plane or
          # Lua, rather than returning empty answers.
          participants: @participants,
          analytics: @analytics,
          durable_scheduler: @durable_scheduler,
          # Link annotation. The feature only ever enqueues through this;
          # the fetch and the reply happen on the scheduler's worker.
          link_annotator: @link_annotator,
          # Translation enqueues here; the scheduler performs calls and delivery.
          # Nil without it leaves the feature inert.
          translation_relay: @translation_relay,
          room_summaries: @room_summaries,
          semantic_analysis: @semantic_analysis,
          topic_router: @topic_router,
          content_policy: @content_policy,
          # The API live stream reads the bridge's per-room relay buffer. Nil
          # leaves the relay unchanged without a control plane.
          live_feed: @live_room_feed,
          # The bridge queues each webhook subscriber per relayed message. Nil
          # leaves relaying unchanged without a control plane.
          webhooks: @webhooks,
          # Redirection rows are nil without a control plane, so the feature
          # refuses moves it cannot persist or scope.
          redirections: @redirections,
          # Redirection reads platform-limited history from this bridge-written
          # record. It is nil where redirection already refuses.
          redirection_window: @redirection_window,
          # The bridge writes this per-endpoint ledger on arrival and successful
          # posts. Nil leaves the relay unchanged without a control plane.
          relay_fingerprints: @relay_fingerprints,
          # Multi-message operations share one `/end` registry so the command
          # keeps one meaning.
          pending_operations: @pending_operations,
          # Rehosting and `/upload` ticketing require a control plane and usable
          # object store; both are nil otherwise.
          rehoster: @rehoster,
          upload_tickets: @upload_tickets,
          # /whitelist and /unwhitelist write approved_users back through this.
          # Nil without a control plane leaves both commands refused.
          feature_controls: @registry ? build_console_feature_controls : nil
        )
        # The quiet gateway watchdog compares endpoints through this inbound
        # activity record shared with the Dispatcher.
        @inbound_activity = InboundActivity.new
        @dispatcher = Dispatcher.new(
          topology: routing_topology,
          router: @router,
          logger: Log.tagged(logger, "dispatch"),
          queue_limit: config.queue_limit,
          activity: @inbound_activity
        )
        build_adapters
        # Subscribe the native mirror after adapters exist. Only Discord emits
        # changes; it is inert without a control plane.
        register_native_event_mirror
        self
      end

      # True when routing is sourced from the control-plane Snapshot rather than
      # from the static config. Diagnostics and tests.
      def control_plane? = !@registry.nil?

      # Immediately reload the control plane for a dashboard push nudge.
      # @param reason [String] log label for the reload
      # @return [Boolean] whether a watcher accepted it
      def reload_control_plane(reason: "requested")
        return false if @control_watcher.nil?

        @control_watcher.reload_now(reason: reason)
        true
      end

      # Complete a dashboard-accepted backfill using live adapters.
      # @return [Core::BackfillProposalRelay::Outcome]
      def relay_backfill_proposal(proposal_id:)
        if @registry.nil?
          return Core::BackfillProposalRelay::Outcome.new(ok: false, error: "no control plane")
        end

        Core::BackfillProposalRelay.new(
          models: control_plane_models, storage: @storage, adapters: @adapters, snapshot: @registry.current,
          logger: Log.tagged(logger, "backfill-relay"), outcomes: @relay_outcomes
        ).kick(proposal_id)
      end

      def start
        build if @router.nil?
        # The live topology when a control plane is active, not the static
        # config's own (empty in a database-only deployment).
        logger.info { config.summary(topology: routing_topology) }

        # Bind the health port before anything that can run long (adapter
        # starts, Discord guild resolution, the history sweep): a platform
        # health check that finds nothing listening for minutes rolls the
        # deploy back before boot ever finishes.
        start_health_server

        @dispatcher.start
        started = []
        started_mutex = Mutex.new
        # One platform's connect handshake (Discord's gateway wait especially)
        # should not hold up every other one; each runs on its own thread and
        # the loop below joins them all before deciding what actually started.
        threads = active_accounts.filter_map do |account|
          adapter = @adapters[[account.adapter_name, account.name]]
          next if adapter.nil?

          Thread.new do
            key = [account.adapter_name, account.name]
            begin
              adapter.start
              @loop_guard.register_identity(account.adapter_name, account.name, adapter.own_account_ids)
              @adapter_health.clear(key)
              started_mutex.synchronize { started << adapter }
            rescue AdapterError => e
              # A failed platform should not stop healthy peers from relaying.
              logger.error { "adapter #{account.adapter_name}/#{account.name} failed to start: #{e.message}" }
              @adapter_health.record_error(key, e)
            end
          end
        end
        threads.each(&:join)

        # Dormant accounts never enter +started+. Refuse startup only when an
        # enabled account failed, not while declared accounts await keys.
        if started.empty? && active_accounts.any? { |account| !account.dormant? }
          @dispatcher.stop
          raise Error, "no adapter started successfully, refusing to run"
        end

        # Give started adapters a bounded window to report ready before the
        # banner, covering a late gateway-ready event.
        await_adapters_ready(started)

        # Start the guest adapter after platform adapters so its sends can relay.
        # It is not a config account and is inert without control.
        start_guest_adapter
        # Start the API adapter after platforms so queued posts have a target.
        start_api_adapter
        # Relay was down before start, so any live-stream row is expired. Purge
        # before the first later tick.
        prune_live_room_feed
        # Purge expired redirection history but preserve in-window rows across
        # restarts, which is why they are durable.
        prune_redirection_window
        # And anything the content ledger holds past its own window (migration
        # 053), on the same terms as the two buffers above.
        prune_relay_fingerprints
        # Purge old alerts at boot too, covering communities whose scripts have
        # gone quiet and cannot trigger write-time cleanup.
        prune_alerts
        # Purge expired webhook deliveries at boot as well as on the tick; rows
        # include sent bodies and define the documented retention window.
        prune_webhooks

        # Resolve Discord's seeded `unresolved:<slug>` guilds from connected
        # adapter knowledge, then refresh the Snapshot idempotently.
        resolve_discord_guilds
        # One control-plane watcher drives Snapshot reloads and event lifecycle.
        # Start it after boot changes settle; it is inert without control.
        start_control_watcher
        start_purge_thread
        start_banner_sweep_thread
        start_script_stats_thread
        @scheduler&.start
        # Clear prior-session ephemeral messages after adapters and topology are
        # ready. Durable recovery backs this session's fast timer.
        sweep_ephemeral
        # Sweep history-only banner stragglers before announcing this boot.
        sweep_stray_banners
        # Recover durable jobs after adapters start, so platform handlers have a
        # target. The worker is inert without a database.
        recover_durable_scheduler
        # Reclaim expired guest sessions and re-arm active ones after the durable
        # worker begins polling.
        reconcile_guest_retention
        # Reconcile community announcement schedules into durable jobs on every
        # boot. Inert without a control plane.
        reconcile_announcements
        reconcile_room_summaries
        # Resume redirections interrupted between a step and its next durable
        # job, after the worker begins polling.
        resume_redirections
        # Replay missed traffic once adapters and Snapshot settle. It is paced,
        # deduplicated and runs off the boot thread.
        start_backfill
        # Cycle long-lived gateways nightly after backfill, so quiet but
        # apparently connected sessions cannot survive a day.
        start_gateway_cycle
        # Detect quiet endpoint stalls between nightly cycles and hand reconnects
        # to GatewayCycle.
        start_quiet_gateway_watchdog
        announce_startup
        self
      end

      # True when every adapter and required worker remains live. The endpoint
      # reads flags only, so health checks need no network round trip.
      def healthy?
        return false if @stopping
        return false if @adapters.empty?
        # Deferred cleanup is required too, or acknowledgements would remain
        # indefinitely despite a healthy-looking bridge.
        return false unless cleanup_scheduler_healthy?
        # The control-plane watcher must run or dashboard edits wait for deploy.
        return false unless control_watcher_healthy?
        return false unless gateway_cycle_healthy?
        # The quiet-gateway watchdog must run or stalls can go undetected.
        return false unless quiet_gateway_watchdog_healthy?
        # A gateway currently cycling is not unhealthy; a 503 would restart it
        # mid-reconnect.
        return true if @gateway_cycle&.cycling?

        # A stalled receiving endpoint remains unhealthy even after reconnect
        # starts, avoiding a silently one-way bridge.
        adapters_healthy? && !@quiet_gateway_watchdog&.stalled?
      end

      # An adapter counts as healthy while it is actively running, or, once
      # it is not, only for as long as its most recent connect/reconnect
      # failure is still inside AdapterHealth's window (#1478): a fresh boot
      # has had no chance to fail yet and answers true immediately, rather
      # than blocking a platform health check on every adapter's first
      # successful connect, while one that keeps failing stays unhealthy for
      # as long as it keeps failing rather than forever on one stale error.
      def adapters_healthy?
        @adapters.each do |key, adapter|
          next if adapter.running?

          # Nothing has been given the chance to connect yet, as opposed to
          # having tried and not (yet) succeeded; the two read the same to
          # AdapterHealth but only the latter is what its optimistic default
          # is for.
          return false unless @dispatcher&.running?
          return false unless @adapter_health.healthy?(key)
        end
        true
      end

      # Whether the nightly gateway cycle is still there to run. True when there
      # is none: a bridge with no gateway adapter, or one that turned the cycle
      # off, runs no such thread by design.
      def gateway_cycle_healthy?
        return true if @gateway_cycle.nil?

        healthy = @gateway_cycle.healthy?
        unless healthy
          logger.error do
            "the gateway cycle is not running (#{@gateway_cycle.failure}); " \
              "a stalled gateway will NOT be reconnected"
          end
        end
        healthy
      end

      # Whether the quiet gateway watchdog thread is still there to run its
      # next pass. True when there is none: a bridge that turned it off runs no
      # such thread by design.
      def quiet_gateway_watchdog_healthy?
        return true if @quiet_gateway_watchdog.nil?

        healthy = @quiet_gateway_watchdog.healthy?
        unless healthy
          logger.error do
            "the quiet gateway watchdog is not running (#{@quiet_gateway_watchdog.failure}); " \
              "a stalled gateway will NOT be noticed"
          end
        end
        healthy
      end

      # Whether the control-plane watcher remains live. No watcher is healthy on
      # backends that run none by design.
      def control_watcher_healthy?
        return true if @control_watcher.nil?

        healthy = @control_watcher.healthy?
        unless healthy
          logger.error do
            "the control-plane watcher is not running (#{@control_watcher.failure}); " \
              "live config changes are NOT being picked up"
          end
        end
        healthy
      end

      # Whether the cleanup scheduler remains live. No scheduler is healthy when
      # cleanup was not configured.
      def cleanup_scheduler_healthy?
        return true if @scheduler.nil?

        healthy = @scheduler.healthy?
        logger.error { "the cleanup scheduler is not running: #{@scheduler.failure}" } unless healthy
        healthy
      end

      def stop
        return self if @stopping

        @stopping = true
        logger.info { "shutting down" }
        @health&.stop
        # One watcher to stop now, rather than one per concern. Its wait
        # is woken rather than waited out, so this does not sit out the
        # rest of a poll interval on the way down.
        @control_watcher&.stop
        @purge_thread&.kill
        @banner_sweep_thread&.kill
        # Before the gateway cycle it may still be about to hand a verdict to,
        # so a shutdown cannot race a fresh reconnect into starting.
        @quiet_gateway_watchdog&.stop
        # Before the adapters, so a cycle cannot be reconnecting one while the
        # shutdown below is taking it down.
        @gateway_cycle&.stop
        # Killed before the flush below, so nothing is counting while the last
        # batch goes out.
        @script_stats_thread&.kill
        # Before the adapters, so a deferred cleanup cannot fire against an
        # adapter that is on its way down. Pending cleanups are abandoned, which
        # is the right call at shutdown.
        @scheduler&.stop
        # Same reasoning for the durable worker: stop polling before the adapters
        # go down. A job left claimed by this session is reclaimed by the next one,
        # so nothing is lost by not draining it here.
        @durable_scheduler&.stop
        # Cancel transient endpoint work before its callbacks lose the adapters
        # and database they still use. New calls are refused while shutdown runs.
        @script_endpoints&.close
        @adapters.each_value do |adapter|
          adapter.stop
        rescue StandardError => e
          logger.warn { "error stopping #{adapter.adapter_name}: #{e.message}" }
        end
        @dispatcher&.stop
        # Counted but not yet written. A crash still loses these, which is the
        # trade coalescing makes, but a clean restart has no reason to.
        flush_script_stats
        flush_script_runs
        flush_model_call_stats
        @storage&.close
        self
      end

      def flush_script_stats
        written = @script_stats&.flush
        logger.info { "scripts: wrote out #{written} pending stat rows" } if written&.positive?
      rescue StandardError => e
        logger.warn { "could not write out the pending script stats: #{e.class}: #{e.message}" }
      end

      def flush_script_runs
        written = @scripts&.flush_runs
        logger.info { "scripts: wrote out #{written} pending run count rows" } if written&.positive?
      rescue StandardError => e
        logger.warn { "could not write out the pending script run counts: #{e.class}: #{e.message}" }
      end

      def flush_model_call_stats
        written = @model_call_stats&.flush
        logger.info { "model stats: wrote out #{written} pending rows" } if written&.positive?
      rescue StandardError => e
        logger.warn { "could not write out the pending model call stats: #{e.class}: #{e.message}" }
      end

      # Block until a termination signal arrives. Used by the CLI.
      def run
        start
        install_signal_handlers
        @waiter = Thread.current
        sleep
      rescue Interrupt
        nil
      ensure
        stop
      end

      private

      # The database is the account source once a control plane is active: no
      # YAML union, no collision skip. Memory and pstore have no control
      # plane at all, so the YAML accounts they have always read remain the
      # only source there, same as before. Memoise so build and start agree.
      def active_accounts
        @active_accounts ||= control_plane? ? control_plane_accounts + irc_network_accounts : config.active_accounts
      end

      # Add control-plane accounts when available. A read failure yields no
      # accounts and does not prevent boot.
      def control_plane_accounts
        return [] unless @registry

        ControlPlane::Accounts
          .new(models: control_plane_models, logger: logger)
          .live(env: @env)
      rescue StandardError => e
        logger.error { "accounts: could not read the control plane (#{e.message})" }
        []
      end

      # Add dashboard-saved IRC networks. Community-namespaced accounts cannot
      # collide with YAML or account-table names.
      def irc_network_accounts
        return [] unless @registry

        ControlPlane::IrcNetworks
          .new(models: control_plane_models, logger: logger)
          .live(env: @env)
      rescue StandardError => e
        logger.error { "irc networks: could not read the control plane (#{e.message}); ignoring irc_networks" }
        []
      end

      # Resolve live storage, run the optional boot import, then connect. Only
      # the runtime performs imports.
      def build_storage
        live = Storage::Selector.live_config(config.storage, env: @env)
        Storage::BootImport.run(target_config: live, env: @env, logger: logger)
        # Arm the same file-storage guard as Selector.build_live after importing.
        Storage::Factory.build(live, env: @env, logger: nil, guard_ephemeral: true)
      end

      # Bounded post-start wait for adapters to report live before the banner.
      ADAPTER_READY_TIMEOUT = 5
      ADAPTER_READY_POLL_INTERVAL = 0.05

      # Wait briefly for adapters to report live, then log laggards and let normal
      # health recovery handle them.
      def await_adapters_ready(started)
        return if started.empty?

        deadline = monotonic_now + ADAPTER_READY_TIMEOUT
        pending = started.reject(&:running?)
        until pending.empty? || monotonic_now >= deadline
          sleep ADAPTER_READY_POLL_INTERVAL
          pending = pending.reject(&:running?)
        end

        pending.each do |adapter|
          logger.warn { "adapter #{adapter.adapter_name} not ready after #{ADAPTER_READY_TIMEOUT}s, posting the startup banner without it" }
        end
      end

      def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Post one linked ephemeral banner per active community, directly to its
      # nominated room. Without control, retain the config-room path.
      def announce_startup
        if @registry
          @registry.current.communities.each { |community| announce_community(community) }
        else
          announce_config_room
        end
      end

      # Without a control plane, announce only the configured room under global
      # suppression.
      def announce_config_room
        return unless config.announce?

        # A failed control plane has no trustworthy community switch, so stay
        # silent unless config explicitly permits this path.
        unless config.announce_without_control_plane?
          logger.info { "no control plane, so the startup banner is skipped; announce.without_control_plane turns it on" }
          return
        end

        room = routing_topology.rooms.find { |candidate| candidate.id == config.announce_room }
        if room.nil?
          logger.warn { "announce.room #{config.announce_room.inspect} matched no room, skipping the banner" }
          return
        end

        post_banner(room: room, scope: nil)
      rescue StandardError => e
        logger.warn { "could not post the startup announcement: #{e.class}: #{e.message}" }
      end

      # Community banners and operator DMs share one suppression claim, avoiding
      # a restart that posts one but suppresses the other.
      def announce_community(community)
        return unless community.active?

        # Community announcements are opt-in to avoid repeated deployment noise.
        banner_on = community.feature_enabled?(nil, Features::StartupBanner.feature_name)
        operator_dm_on = community.feature_enabled?(nil, Features::OperatorStartupDm.feature_name)
        return unless banner_on || operator_dm_on

        suppressor = build_announce_suppressor(scope: community.slug, community: community)
        return unless suppressor.claim

        post_banner_for_community(community) if banner_on
        post_operator_dm_for_community(community) if operator_dm_on
      rescue StandardError => e
        logger.warn do
          "could not post the startup announcement for #{community.slug}: #{e.class}: #{e.message}"
        end
      end

      # Deliver the community banner after suppression, selecting by precedence
      # and logging when no room is mapped.
      def post_banner_for_community(community)
        room = announce_room_for(community)
        if room.nil?
          logger.info { "community #{community.slug}: no room yet, skipping the startup banner" }
          return
        end

        deliver_banner(room, scope: community.slug, community: community)
      end

      # DM the room banner to reachable operators after suppression. Refuse DMs
      # that cannot later self-delete.
      def post_operator_dm_for_community(community)
        return if @operator_flow.nil? || @admin_notifier.nil?

        targets = operator_dm_targets(community)
        if targets.empty?
          logger.info { "community #{community.slug}: no operator reachable by DM, skipping the startup DM" }
          return
        end

        banner = Announcement.new(level: announce_setting(community, :detail, config.announce_detail))
        delay = announce_setting(community, :delete_after, config.announce_delete_after) * OPERATOR_DM_DELETE_MULTIPLIER
        state_key = announce_group_state_key(community.slug, "dm")
        supersede_previous_announcement(state_key)
        group = @ephemeral.post_dm(targets: targets, body: banner.body, name: config.name, delete_after: delay)
        if group.copies.empty?
          logger.info do
            "community #{community.slug}: no operator reachable by an ephemeral admin DM, skipping the startup DM"
          end
        end
        remember_announcement_group(state_key, group)
        @scheduler.after(delay) { group.delete_now } if delay.positive? && @scheduler && group.any?
      end

      # Map notifier candidates to DM targets so startup and alert DMs agree on
      # reachability.
      def operator_dm_targets(community)
        @admin_notifier.operator_candidates(community.id).map do |candidate|
          EphemeralMessage::DmTarget.new(
            adapter_name: candidate[:adapter].to_sym, account: candidate[:account].to_s,
            native_id: candidate[:native_id]
          )
        end
      end

      # Select a banner room: community override, seeded room, config room, then
      # first room. Return nil only for communities with no rooms.
      def announce_room_for(community)
        rooms = community.rooms
        return nil if rooms.empty?

        room_by_key(rooms, community.settings["announce_room"]) ||
          room_by_key(rooms, community.settings.dig("announce", "room")) ||
          room_by_key(rooms, config.announce_room) ||
          rooms.min_by(&:id)
      end

      def room_by_key(rooms, key)
        return nil if key.nil? || key.to_s.empty?

        rooms.find { |room| room.id == key.to_s }
      end

      # Post a globally or scope-suppressed banner for the config-only path.
      # Community announcements claim jointly before delivery.
      def post_banner(room:, scope:)
        suppressor = build_announce_suppressor(scope: scope)
        return unless suppressor.claim

        deliver_banner(room, scope: scope)
      end

      # Build a scope suppressor for room and operator banners. Include the
      # commit so same-release hotfixes remain new builds. community is nil on
      # the config-only path, where there is nothing to read an override from.
      def build_announce_suppressor(scope:, community: nil)
        Announcement::Suppressor.new(
          storage: @storage, window: announce_setting(community, :suppress_window, config.announce_suppress_window),
          version: "#{Rubotty::VERSION}+#{Core::BuildInfo.commit}", scope: scope,
          logger: Log.tagged(logger, "announce")
        )
      end

      # A community's own announce block, seeded verbatim from static config at
      # creation time, wins over the deployment-wide static value when it names
      # the key at all. nil community (the config-only path) always falls
      # through to the static value.
      def announce_setting(community, key, default)
        return default if community.nil?

        value = community.settings.dig("announce", key.to_s)
        value.nil? ? default : value
      end

      # Post the banner into +room+. Suppression is the caller's job; this
      # only does the ephemeral post and its scheduled delete. community is nil
      # on the config-only path.
      def deliver_banner(room, scope:, community: nil)
        banner = Announcement.new(level: announce_setting(community, :detail, config.announce_detail))
        delay = announce_setting(community, :delete_after, config.announce_delete_after)
        state_key = announce_group_state_key(scope, "room")
        supersede_previous_announcement(state_key)
        group = @ephemeral.post(
          # Use the room's fan-out targets, excluding receive-only endpoints.
          endpoints: room.targets_for(nil), body: banner.body, name: config.name, delete_after: delay
        )
        remember_announcement_group(state_key, group)
        # The local timer is the fast delete path; durable rows recover crashes.
        # A non-positive delay retains the banner.
        @scheduler.after(delay) { group.delete_now } if delay.positive? && @scheduler && group.any?
      end

      def announce_group_state_key(scope, kind)
        scope ? "#{ANNOUNCE_LAST_GROUP_STATE_KEY}.#{kind}.#{scope}" : "#{ANNOUNCE_LAST_GROUP_STATE_KEY}.#{kind}"
      end

      # Delete whatever the previous restart posted under this key before this
      # one posts its own, so a fast redeploy cycle never leaves two banners
      # standing at once. Silent no-op the first time a key is ever used.
      def supersede_previous_announcement(state_key)
        previous = @storage.get_state(state_key)
        return if previous.to_s.empty?

        @ephemeral.delete_group_now(previous)
      rescue StorageError => e
        logger.warn { "could not supersede the previous announcement: #{e.class}: #{e.message}" }
      end

      # Remember this restart's group id so the NEXT one can supersede it.
      # Kept well beyond any plausible restart gap; it is overwritten on every
      # post regardless, so a stale value only matters if nothing ever posts
      # under this key again.
      def remember_announcement_group(state_key, group)
        return unless group.any?

        @storage.put_state(state_key, group.id, expires_at: Time.now + (30 * 24 * 60 * 60))
      rescue StorageError => e
        logger.warn { "could not remember the announcement group for next restart: #{e.class}: #{e.message}" }
      end

      # Reap expired or prior-session ephemeral rows, preserving this session's
      # pending deletes.
      def sweep_ephemeral
        removed = @ephemeral.sweep(alive_session_ids: [@session_id])
        logger.info { "swept #{removed} orphaned ephemeral message(s) left by a previous session" } if removed.positive?
      rescue StandardError => e
        logger.warn { "ephemeral boot sweep failed: #{e.class}: #{e.message}" }
      end

      # Sweep bounded history for banner stragglers lacking durable rows.
      def sweep_stray_banners
        removed = Core::HistorySweep.new(
          adapters: @adapters, topology: routing_topology, logger: Log.tagged(logger, "history-sweep")
        ).sweep
        logger.info { "history sweep removed #{removed} straggler banner(s)" } if removed.positive?
      rescue StandardError => e
        logger.warn { "history sweep failed: #{e.class}: #{e.message}" }
      end

      # Build ephemeral messaging with a Sequel durable store when available.
      # The scheduler recovers deletes after a process crash.
      def build_ephemeral
        EphemeralMessage.new(
          adapters: @adapters,
          session_id: @session_id,
          store: EphemeralStore.for(@storage, logger: Log.tagged(logger, "ephemeral")),
          topology: routing_topology,
          loop_guard: @loop_guard,
          logger: Log.tagged(logger, "ephemeral"),
          default_name: config.name,
          durable_scheduler: @durable_scheduler,
          tracker: @bot_messages
        )
      end

      # Where a permanent bot post is written down so /clean can find it. Nil
      # without a control plane, like every store beside it.
      def build_bot_messages
        return nil unless @registry && control_plane_models

        ControlPlane::BotMessages.new(
          models: control_plane_models, logger: Log.tagged(logger, "bot-messages")
        )
      end

      # Drops a row once it is old enough that nobody is going to sweep it.
      def register_bot_messages_prune
        return if @durable_scheduler.nil? || @bot_messages.nil?

        @durable_scheduler.register(ControlPlane::BotMessages::PRUNE_KIND) do |_job|
          dropped = @bot_messages.prune
          logger&.info { "bot messages: pruned #{dropped} aged row(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::BotMessages::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::BotMessages::PRUNE_KIND,
          run_at: Time.now + ControlPlane::BotMessages::PRUNE_INTERVAL,
          recurrence: ControlPlane::BotMessages::PRUNE_INTERVAL, payload: {}
        )
      end

      # Build durable scheduling on Sequel, with Null storage on memory and
      # pstore. Features register handlers at boot.
      def build_durable_scheduler
        DurableScheduler.new(
          store: DurableSchedulerStore.for(@storage, logger: Log.tagged(logger, "scheduler")),
          session_id: @session_id,
          logger: Log.tagged(logger, "scheduler"),
          on_discard: ->(job) { record_discarded_job(job) }
        )
      end

      # Where the model-backed features' own numbers go. Inert without a
      # control plane, like every other rollup here.
      def build_model_call_stats
        return nil unless control_plane?

        ControlPlane::ModelCallStats.new(models: control_plane_models,
                                         logger: Log.tagged(logger, "model-stats"))
      end

      # A job dropped for being past its kind's max_age, counted against the
      # feature that queued it. The row carries its community's slug, which the
      # live snapshot turns into the id these stats are keyed by.
      def record_discarded_job(job)
        feature = ControlPlane::ModelCallStats.feature_for_kind(job.kind)
        return if feature.nil? || @model_call_stats.nil?

        community = @registry&.current&.community(job.community.to_s)
        @model_call_stats.discarded(community_id: community.id, feature: feature) if community
      end

      # Age out the model call statistics daily, the same way script statistics
      # are aged out.
      def register_model_call_stats_prune
        return if @durable_scheduler.nil? || @model_call_stats.nil?

        @durable_scheduler.register(ControlPlane::ModelCallStats::PRUNE_KIND) do |_job|
          dropped = @model_call_stats.prune
          logger&.info { "model stats: pruned #{dropped} row(s) past their retention" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::ModelCallStats::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::ModelCallStats::PRUNE_KIND,
          run_at: Time.now + SCRIPT_STATS_FIRST_PRUNE,
          recurrence: ControlPlane::ModelCallStats::PRUNE_INTERVAL, payload: {}
        )
      end

      # Build warning and sanction expiry before recovery. Memory and pstore use
      # Null storage; audit writes share the standard table.
      # The one warnings store, held so a content policy reversal can clear the
      # exact strike its action issued rather than the newest one.
      def warnings_store
        @warnings_store ||= WarningsStore.for(@storage, logger: Log.tagged(logger, "warnings"))
      end

      # Lifting a sanction down the same path the panel's unmute takes, so a
      # reversal and an operator's own click behave identically.
      def build_content_policy_moderation
        return nil unless @registry && control_plane_models && @durable_scheduler

        ControlPlane::ModerationActions.new(
          store: warnings_store, scheduler: @durable_scheduler,
          audit: @audit_log, logger: Log.tagged(logger, "content-policy")
        )
      end

      def build_warnings
        service = Warnings::Service.new(
          store: warnings_store,
          scheduler: @durable_scheduler,
          topology: routing_topology,
          adapters: @adapters,
          storage: @storage,
          audit: AuditLog.for(@storage, logger: Log.tagged(logger, "audit")),
          registry: @registry,
          undelivered: @undelivered_dms,
          # For the muted author a DM cannot reach: their messages vanish, and
          # the room is the only place left to tell them why.
          ephemeral: @ephemeral,
          logger: Log.tagged(logger, "warnings")
        )
        @durable_scheduler.register(Warnings::EXPIRE_KIND) { |job| service.expire(job) }
        @durable_scheduler.register(Warnings::DECAY_KIND) { |job| service.decay(job) }
        service
      end

      # The other end of a /delete that named a time: the booking is made by
      # the moderation feature and comes due here, however long after, and in
      # whichever process is running by then.
      def register_deferred_deletions
        return if @durable_scheduler.nil? || @storage.nil?

        deletions = DeferredDeletion.new(
          topology: routing_topology,
          removal: Watchdog::Removal.new(
            topology: routing_topology, adapters: @adapters, storage: @storage,
            logger: Log.tagged(logger, "deferred-delete"), source: DeferredDeletion::KIND
          ),
          audit: @audit_log, logger: Log.tagged(logger, "deferred-delete")
        )
        @durable_scheduler.register(DeferredDeletion::KIND) { |job| deletions.run(job) }
      end

      # Build scripting only with a control plane and Lua. Deferred jobs address
      # endpoints, never scripts, so they cannot re-enter Lua.
      def build_scripting
        return unless control_plane?

        @script_pool = Scripting::Pool.new(size: Scripting::Pool.configured_size, logger: Log.tagged(logger, "scripts"))
        unless @script_pool.available?
          # Explain why unavailable confinement disables the entire feature.
          reason = Scripting::Confined.satisfied? ? "no Lua interpreter on PATH" : Scripting::Confined.reason
          logger&.warn { "scripting: turned off, #{reason}." }
          return @script_pool = nil
        end

        warn_about_the_filter_tier
        @scripts = ControlPlane::Scripts.new(models: control_plane_models,
                                             logger: Log.tagged(logger, "scripts"))
        @script_endpoints = Scripting::Endpoints.new(models: control_plane_models,
                                                     logger: Log.tagged(logger, "scripts"))
        @script_memory = Scripting::Memory.new(models: control_plane_models,
                                               logger: Log.tagged(logger, "scripts"))
        @script_stats = ControlPlane::ScriptStats.new(models: control_plane_models,
                                                      logger: Log.tagged(logger, "scripts"))
        # Rubotty stores game sessions and standings; Lua supplies the game.
        @participation = ControlPlane::Participation.new(models: control_plane_models,
                                                         logger: Log.tagged(logger, "scripts"))
        # Scripts write alerts here and the dashboard reads the same table.
        @alerts = ControlPlane::Alerts.new(models: control_plane_models,
                                           logger: Log.tagged(logger, "scripts"))
        # Script participants read people, sightings and the current identity
        # directory.
        @participants = ControlPlane::Participants.new(models: control_plane_models,
                                                       directory: @identity_directory)
        # Only scripts read these analytics through `community_stats`.
        @analytics = ControlPlane::Analytics.new(db: ControlPlane::Boot.db_of(@storage), models: control_plane_models)
        register_script_stats_prune
        register_script_runs_prune
        register_participation_prune
        register_script_memory_sweep
        register_script_jobs
        register_deferred_deletions
      end

      # The filter walks down its tiers until the interpreter here survives
      # one, so a deployment that gave up the exec gate or the write denial
      # boots reading exactly like one behind the whole filter. Say which tier
      # it settled on, since `rubotty check` is otherwise the only place that
      # names it and nobody runs that after every deploy.
      def warn_about_the_filter_tier
        tier = Scripting::Seccomp.reduced_tier
        return if tier.nil?

        logger&.warn do
          "scripting: the system call filter settled on #{tier} rather than " \
            "#{Scripting::Seccomp::RUNTIME}. #{Scripting::Seccomp.describe}"
        end
      end

      # Prune finished participation sessions daily under their retention policy.
      def register_participation_prune
        return if @durable_scheduler.nil? || @participation.nil?

        @durable_scheduler.register(ControlPlane::Participation::PRUNE_KIND) do |_job|
          dropped = @participation.prune
          logger&.info { "scripts: pruned #{dropped} session(s) past their retention" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::Participation::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::Participation::PRUNE_KIND,
          run_at: Time.now + SCRIPT_STATS_FIRST_PRUNE,
          recurrence: ControlPlane::Participation::PRUNE_INTERVAL, payload: {}
        )
      end

      # Prune script statistics daily under their retention policy.
      def register_script_stats_prune
        return if @durable_scheduler.nil? || @script_stats.nil?

        @durable_scheduler.register(ControlPlane::ScriptStats::PRUNE_KIND) do |_job|
          dropped = @script_stats.prune
          logger&.info { "scripts: pruned #{dropped} stat rows past their retention" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::ScriptStats::PRUNE_KIND, every_community: true)
        # Schedule shortly after boot; recreating daily would otherwise postpone
        # the retention sweep indefinitely.
        @durable_scheduler.schedule(
          kind: ControlPlane::ScriptStats::PRUNE_KIND,
          run_at: Time.now + SCRIPT_STATS_FIRST_PRUNE,
          recurrence: ControlPlane::ScriptStats::PRUNE_INTERVAL, payload: {}
        )
      end

      # Drop script run counts past their retention daily, since a day's count
      # is a row per script and nothing else ever removes one.
      def register_script_runs_prune
        return if @durable_scheduler.nil? || @scripts.nil?

        @durable_scheduler.register(ControlPlane::Scripts::RUN_PRUNE_KIND) do |_job|
          dropped = @scripts.prune_runs
          logger&.info { "scripts: pruned #{dropped} run count rows past their retention" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::Scripts::RUN_PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::Scripts::RUN_PRUNE_KIND,
          run_at: Time.now + SCRIPT_STATS_FIRST_PRUNE,
          recurrence: ControlPlane::Scripts::RUN_PRUNE_INTERVAL, payload: {}
        )
      end

      # Sweep expired script memos daily.
      def register_script_memory_sweep
        return if @durable_scheduler.nil? || @script_memory.nil?

        @durable_scheduler.register(Scripting::Memory::PRUNE_KIND) do |_job|
          dropped = @script_memory.sweep
          logger&.info { "scripts: swept #{dropped} expired memo(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: Scripting::Memory::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: Scripting::Memory::PRUNE_KIND,
          run_at: Time.now + SCRIPT_STATS_FIRST_PRUNE,
          recurrence: Scripting::Memory::PRUNE_INTERVAL, payload: {}
        )
      end

      # Delete expired rehosted bytes daily through durable scheduling, so a
      # restart resumes rather than resets retention.
      def register_rehosted_file_expiry
        return if @durable_scheduler.nil? || @rehosted_files.nil?

        @durable_scheduler.register(ControlPlane::RehostedFiles::EXPIRY_KIND) do |_job|
          removed = @rehosted_files.expire
          @upload_tickets&.expire
          logger&.info { "rehosted files: deleted #{removed} past their retention" } if removed.positive?
          # Sweep orphaned objects after their expired rows have removed bytes.
          @rehosted_files.sweep_orphans
        end
        @durable_scheduler.forget(kind: ControlPlane::RehostedFiles::EXPIRY_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::RehostedFiles::EXPIRY_KIND,
          run_at: Time.now + REHOSTED_FILES_FIRST_EXPIRY,
          recurrence: ControlPlane::RehostedFiles::EXPIRY_INTERVAL, payload: {}
        )
      end

      # Prune redirectable messages daily through durable scheduling, with boot
      # recovery as a backstop for messages that expired while offline.
      def register_redirection_window_prune
        return if @durable_scheduler.nil? || @redirection_window.nil?

        @durable_scheduler.register(ControlPlane::RedirectionWindow::PRUNE_KIND) do |_job|
          removed = @redirection_window.prune
          logger&.info { "redirection: pruned #{removed} retained message(s) past their window" } if removed.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::RedirectionWindow::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::RedirectionWindow::PRUNE_KIND,
          run_at: next_utc_midnight,
          recurrence: ControlPlane::RedirectionWindow::PRUNE_INTERVAL, payload: {}
        )
      end

      def next_utc_midnight(now = Time.now)
        utc = now.utc
        today = Time.utc(utc.year, utc.month, utc.day)
        today + (24 * 60 * 60)
      end

      # Prune passively observed identities daily.
      # Six hourly, so a removed message's text never sits far past the window
      # an operator configured, and cheap enough that the interval can stay
      # short without anybody thinking about it.
      # Drops what has been handed over, and what expired before anybody wrote
      # in. The second half is the retention promise: a notice about a warning
      # that has since decayed is not kept waiting for somebody who never
      # comes back.
      def register_undelivered_dms_prune
        return if @durable_scheduler.nil? || @undelivered_dms.nil?

        @durable_scheduler.register(ControlPlane::UndeliveredDms::PRUNE_KIND) do |_job|
          dropped = @undelivered_dms.prune
          logger&.info { "warnings: pruned #{dropped} kept DM(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::UndeliveredDms::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::UndeliveredDms::PRUNE_KIND,
          run_at: Time.now + ControlPlane::UndeliveredDms::PRUNE_INTERVAL,
          recurrence: ControlPlane::UndeliveredDms::PRUNE_INTERVAL, payload: {}
        )
      end

      # What a member reported, kept until an operator has had the chance to
      # look. Nil without a control plane, like every store beside it, which
      # leaves the verb unhandled rather than swallowing a report into nothing.
      def build_member_reports
        return nil unless @registry && control_plane_models

        ControlPlane::MemberReports.new(
          models: control_plane_models, logger: Log.tagged(logger, "reports")
        )
      end

      # The DM half of reporting: a forwarded message or a pasted link, filed
      # against whichever community that message turns out to be in. Nil without
      # a store, which leaves the DM lane answering as it always has.
      def build_report_lane
        return nil if @member_reports.nil?

        ControlPlane::ReportLane.new(
          reports: @member_reports, registry: @registry, notifier: @admin_notifier,
          identities: @identity_directory, logger: Log.tagged(logger, "reports")
        )
      end

      # Drops a report once its window has passed, since this is one of the few
      # places holding message text and it is not meant to be an archive.
      def register_member_reports_prune
        return if @durable_scheduler.nil? || @member_reports.nil?

        @durable_scheduler.register(ControlPlane::MemberReports::PRUNE_KIND) do |_job|
          dropped = @member_reports.prune
          logger&.info { "reports: pruned #{dropped} expired report(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::MemberReports::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::MemberReports::PRUNE_KIND,
          run_at: Time.now + ControlPlane::MemberReports::PRUNE_INTERVAL,
          recurrence: ControlPlane::MemberReports::PRUNE_INTERVAL, payload: {}
        )
      end

      # Drops a pairing once the warning it belongs to has lapsed, so a notice
      # nobody removed is not tracked forever waiting for a delete.
      def register_warning_announcements_prune
        return if @durable_scheduler.nil? || @warning_announcements.nil?

        @durable_scheduler.register(ControlPlane::WarningAnnouncements::PRUNE_KIND) do |_job|
          dropped = @warning_announcements.prune
          logger&.info { "warnings: pruned #{dropped} lapsed notice pairing(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::WarningAnnouncements::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::WarningAnnouncements::PRUNE_KIND,
          run_at: Time.now + ControlPlane::WarningAnnouncements::PRUNE_INTERVAL,
          recurrence: ControlPlane::WarningAnnouncements::PRUNE_INTERVAL, payload: {}
        )
      end

      def register_content_policy_actions_prune
        return if @durable_scheduler.nil? || @content_policy_actions.nil?

        @durable_scheduler.register(ControlPlane::ContentPolicyActions::PRUNE_KIND) do |_job|
          dropped = @content_policy_actions.prune(window_days: content_policy_window_days)
          logger&.info { "content policy: pruned #{dropped} lapsed action records" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::ContentPolicyActions::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::ContentPolicyActions::PRUNE_KIND,
          run_at: Time.now + ControlPlane::ContentPolicyActions::PRUNE_INTERVAL,
          recurrence: ControlPlane::ContentPolicyActions::PRUNE_INTERVAL, payload: {}
        )
      end

      # The widest window any community asked for, since one prune serves them
      # all and the narrower ones lose nothing they would have kept anyway.
      def content_policy_window_days
        windows = @registry&.current&.communities.to_a.map do |community|
          config = community.feature_config(nil, ContentPolicy::Service::FEATURE)
          ControlPlane::ContentPolicyActions.window_days(config[ContentPolicy::Service::WINDOW_FIELD])
        end
        windows.max || ControlPlane::ContentPolicyActions::DEFAULT_WINDOW_DAYS
      end

      # Six hourly like the record prune above, and for the same reason: text
      # an operator kept for tuning still lapses on the window they set.
      def register_content_policy_misfires_prune
        return if @durable_scheduler.nil? || @content_policy_misfires.nil?

        @durable_scheduler.register(ControlPlane::ContentPolicyMisfires::PRUNE_KIND) do |_job|
          dropped = @content_policy_misfires.prune(window_days: content_policy_misfire_window_days)
          logger&.info { "content policy: pruned #{dropped} lapsed misfire samples" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::ContentPolicyMisfires::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::ContentPolicyMisfires::PRUNE_KIND,
          run_at: Time.now + ControlPlane::ContentPolicyMisfires::PRUNE_INTERVAL,
          recurrence: ControlPlane::ContentPolicyMisfires::PRUNE_INTERVAL, payload: {}
        )
      end

      # Two jobs: one closes proposals nobody answered, so approving can never
      # repost a message the room has moved on from, and one drops the training
      # samples past their window. Quarter hourly and six hourly respectively,
      # since a lapse has a deadline and a prune does not.
      def register_topic_move_proposal_jobs
        return if @durable_scheduler.nil? || @topic_move_proposals.nil?

        store = ControlPlane::TopicMoveProposals
        @durable_scheduler.register(store::LAPSE_KIND) do |_job|
          closed = @topic_move_proposals.lapse(pending_hours: topic_proposal_pending_hours)
          logger&.info { "topic routing: #{closed} proposal(s) lapsed unanswered" } if closed.positive?
        end
        @durable_scheduler.register(store::PRUNE_KIND) do |_job|
          dropped = @topic_move_proposals.prune(window_days: topic_proposal_window_days)
          logger&.info { "topic routing: pruned #{dropped} lapsed training sample(s)" } if dropped.positive?
        end
        schedule_recurring(store::LAPSE_KIND, store::LAPSE_INTERVAL)
        schedule_recurring(store::PRUNE_KIND, store::PRUNE_INTERVAL)
      end

      def schedule_recurring(kind, interval)
        @durable_scheduler.forget(kind: kind, every_community: true)
        @durable_scheduler.schedule(kind: kind, run_at: Time.now + interval,
                                    recurrence: interval, payload: {})
      end

      # The most generous setting any community asked for, so one job serves
      # every tenant without reading a window per row.
      def topic_proposal_pending_hours
        hours = communities_config(SemanticAnalysis::TopicRouter::MOVE_FEATURE).map do |config|
          ControlPlane::TopicMoveProposals.pending_hours(config[:confirm_within_hours])
        end
        hours.max || ControlPlane::TopicMoveProposals::DEFAULT_PENDING_HOURS
      end

      def topic_proposal_window_days
        windows = communities_config(SemanticAnalysis::TopicRouter::MOVE_FEATURE).map do |config|
          ControlPlane::TopicMoveProposals.window_days(config[:training_retention_days])
        end
        windows.max || ControlPlane::TopicMoveProposals::DEFAULT_WINDOW_DAYS
      end

      def communities_config(feature)
        @registry&.current&.communities.to_a.map { |community| community.feature_config(nil, feature) || {} }
      end

      def content_policy_misfire_window_days
        windows = @registry&.current&.communities.to_a.map do |community|
          config = community.feature_config(nil, ContentPolicy::Service::FEATURE)
          ControlPlane::ContentPolicyMisfires.window_days(config[Features::ContentPolicy::MISFIRE_WINDOW_FIELD])
        end
        windows.max || ControlPlane::ContentPolicyMisfires::DEFAULT_WINDOW_DAYS
      end

      def register_identity_directory_prune
        return if @durable_scheduler.nil? || @identity_directory.nil?

        @durable_scheduler.register(ControlPlane::IdentityDirectory::PRUNE_KIND) do |_job|
          dropped = @identity_directory.prune_expired
          logger&.info { "identity: pruned #{dropped} stale directory entries" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::IdentityDirectory::PRUNE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::IdentityDirectory::PRUNE_KIND,
          run_at: Time.now + IDENTITY_DIRECTORY_FIRST_PRUNE,
          recurrence: ControlPlane::IdentityDirectory::PRUNE_INTERVAL, payload: {}
        )
      end

      # Prune closed identity_history name rows daily, same shape as
      # {#register_identity_directory_prune} right above.
      def register_identity_history_prune
        return if @durable_scheduler.nil? || @identity_directory.nil?

        @durable_scheduler.register(ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND) do |_job|
          dropped = @identity_directory.prune_expired_name_history
          logger&.info { "identity: pruned #{dropped} expired name-history row(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND,
                                  every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::IdentityDirectory::NAME_HISTORY_PRUNE_KIND,
          run_at: Time.now + IDENTITY_DIRECTORY_FIRST_PRUNE,
          recurrence: ControlPlane::IdentityDirectory::PRUNE_INTERVAL, payload: {}
        )
      end

      # Prune closed bridged_nickname_history rows daily, same shape as
      # {#register_identity_history_prune} right above.
      def register_bridged_nickname_history_prune
        return if @durable_scheduler.nil? || @bridged_nicknames.nil?

        @durable_scheduler.register(ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND) do |_job|
          dropped = @bridged_nicknames.prune_expired_nickname_history
          logger&.info { "nickname: pruned #{dropped} expired name-history row(s)" } if dropped.positive?
        end
        @durable_scheduler.forget(kind: ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND,
                                  every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::BridgedNicknames::NAME_HISTORY_PRUNE_KIND,
          run_at: Time.now + IDENTITY_DIRECTORY_FIRST_PRUNE,
          recurrence: ControlPlane::IdentityDirectory::PRUNE_INTERVAL, payload: {}
        )
      end

      # Build a sealed object store only when its configured directory is ready.
      # Fail closed to avoid writing a failed mount's root filesystem.
      def build_object_store
        return nil unless @registry

        store = Storage::ObjectStore.new(root: config.file_store_path, logger: Log.tagged(logger, "files"))
        store.ready!
        store
      rescue Storage::ObjectStore::Unavailable => e
        logger.error { "file store unavailable, so file rehosting is off this session: #{e.message}" }
        nil
      end

      def build_rehosted_files
        return nil if @object_store.nil?

        # @adapters is handed over by reference, not a snapshot: it is still
        # being filled in when this runs, and a new file's ceiling is only
        # ever sized at #store_file time, well after boot finishes.
        ControlPlane::RehostedFiles.new(
          models: control_plane_models, store: @object_store, adapters: @adapters,
          logger: Log.tagged(logger, "files")
        )
      end

      def build_upload_tickets
        return nil if @object_store.nil?

        ControlPlane::UploadTickets.new(models: control_plane_models, logger: Log.tagged(logger, "files"))
      end

      # Deliver completed `/upload` records through live adapters. Register its
      # durable handler before recovery and retain the adapter map.
      def build_upload_announcer
        return nil unless @registry

        ControlPlane::UploadAnnouncer.new(
          models: control_plane_models, registry: @registry, adapters: @adapters,
          scheduler: @durable_scheduler, logger: Log.tagged(logger, "files")
        )
      end

      def build_rehoster
        return nil if @rehosted_files.nil?

        Core::AttachmentRehoster.new(files: @rehosted_files, shrinker: build_image_shrinker,
                                     video: build_video_rehost_relay, logger: Log.tagged(logger, "files"))
      end

      # Return nil without ImageMagick, leaving oversized images as links.
      def build_image_shrinker
        log = Log.tagged(logger, "files")
        if Util::ImageShrinker.available?
          log.info { "images can be shrunk to fit a platform limit, using #{Util::ImageShrinker.binary}" }
          return Util::ImageShrinker.new(logger: log)
        end

        log.warn do
          "no #{Util::ImageShrinker::BINARIES.join(" or ")} on PATH, so file_rehosting will link " \
            "an oversized image rather than shrink it. Install ImageMagick to have the picture cross."
        end
        nil
      end

      # Deliver transcoded videos through durable jobs and retained adapters.
      # Return nil without an object store, leaving videos as links.
      def build_video_rehost_relay
        return nil if @rehosted_files.nil?

        Core::VideoRehostRelay.new(
          scheduler: @durable_scheduler, transcoder: build_video_transcoder, files: @rehosted_files,
          storage: @storage, topology: routing_topology, adapters: @adapters, loop_guard: @loop_guard,
          logger: Log.tagged(logger, "files")
        )
      end

      # Return nil without ffmpeg, leaving oversized videos as links.
      def build_video_transcoder
        log = Log.tagged(logger, "files")
        if Util::VideoTranscoder.available?
          ffmpeg = Util::VideoTranscoder.binary(Util::VideoTranscoder::FFMPEG)
          log.info { "video can be shrunk to fit a platform limit, using #{ffmpeg}" }
          return Util::VideoTranscoder.new(logger: log)
        end

        log.warn do
          "no #{Util::VideoTranscoder.missing.join(" or ")} on PATH, so file_rehosting will link " \
            "an oversized video rather than shrink it. Install ffmpeg to have the video cross smaller."
        end
        nil
      end

      def register_script_jobs
        return if @durable_scheduler.nil?

        @durable_scheduler.register(Features::Scripts::LATER_KIND) do |job|
          run_scheduled_script(job)
        end
        @durable_scheduler.register(Features::Scripts::RECURRING_KIND) do |job|
          run_scheduled_script(job)
        end
        sync_recurring_scripts
      end

      # Watches the scripts table so a live dashboard edit resyncs recurring
      # wakes without a restart. Nil without a control plane or durable
      # scheduling, same guard {#sync_recurring_scripts} itself uses.
      def build_script_recurrence_watch
        return nil if @durable_scheduler.nil? || @scripts.nil?

        ControlPlane::ScriptRecurrenceWatch.new(
          models: control_plane_models, sync: method(:sync_recurring_scripts),
          logger: Log.tagged(logger, "scripts")
        )
      end

      # Rebuild recurring wakes from live scripts to avoid drift. Their separate
      # kind does not disturb script-booked schedules.
      def sync_recurring_scripts(now: Time.now.utc)
        return if @durable_scheduler.nil? || @scripts.nil?

        @durable_scheduler.forget(kind: Features::Scripts::RECURRING_KIND, every_community: true)
        Array(@registry&.current&.communities).each do |community|
          @scripts.active(community).each do |row|
            # Inspect every trigger because a clock trigger may follow a command.
            next unless recurring_trigger(row)

            # Isolate bad scripts so one row does not block every recurring wake.
            begin
              schedule_recurring_script(community, row, now)
            rescue StandardError => e
              logger&.warn do
                "scripts: could not schedule #{row.name.inspect} in #{community.slug}: #{e.class}: #{e.message}"
              end
            end
          end
        end
      rescue StandardError => e
        logger&.warn { "scripts: could not sync the recurring wakes: #{e.class}: #{e.message}" }
      end

      def schedule_recurring_script(community, row, now)
        # A recurring wake needs a real target room. Use the banner's room
        # selection rule for the same question.
        room = announce_room_for(community)
        if room.nil?
          logger&.info { "scripts: #{row.name.inspect} has no room to wake in yet" }
          return
        end

        trigger = recurring_trigger(row)
        @durable_scheduler.schedule(
          kind: Features::Scripts::RECURRING_KIND,
          run_at: trigger.next_run(now), community: community.slug.to_s,
          recurrence: trigger.interval,
          payload: { "community" => community.slug.to_s, "script" => row.name.to_s,
                     "room_key" => room.id.to_s, "generation" => 0 }
        )
        logger&.info { "scripts: #{row.name.inspect} wakes every #{trigger.interval}s in #{room.id}" }
      end

      # Return a row's recurring trigger, or nil for absent or invalid triggers.
      def recurring_trigger(row)
        Scripting::Triggers.build_all(row.trigger_type, @scripts.trigger_config(row))
                           .find { |trigger| trigger.class.type_name == "recurring" }
      rescue Scripting::Error
        nil
      end

      # Resolve scheduled targets at fire time, dropping jobs whose community or
      # script is no longer live.
      def run_scheduled_script(job)
        payload = job.payload || {}
        slug = payload["community"].to_s
        return unless script_job_agrees?(job, slug)

        community = @registry&.current&.communities&.find { |c| c.slug.to_s == slug }
        return if community.nil? || @scripts.nil? || @router.nil?

        reason = payload["reason"]
        return if reason == ControlPlane::Participation::ROUND_CLOSE_REASON && !round_still_open?(community, payload)

        name = payload["script"].to_s
        row = @scripts.active(community).find { |candidate| candidate.name.to_s == name }
        if row.nil?
          logger&.info { "scripts: a scheduled wake for #{name.inspect} was dropped, it is no longer live" }
          return
        end

        @router.wake_script(community: community, row: row, room_key: payload["room_key"].to_s,
                            kind: Scripting::Context::SCHEDULED, data: payload["data"],
                            generation: payload["generation"].to_i, wake_reason: reason)
      rescue StandardError => e
        logger&.warn { "scripts: a scheduled wake failed: #{e.class}: #{e.message}" }
      end

      # The job's own column and its payload each name a community, and a wake
      # runs only when they agree. A booking made before either was written
      # carries no column, which is the one case with nothing to compare.
      def script_job_agrees?(job, slug)
        return true if job.community.nil? || job.community.to_s == slug

        logger&.error do
          "scripts REFUSED: job #{job.id} is booked to community #{job.community.inspect} " \
            "but its payload names #{slug.inspect}"
        end
        false
      end

      # An open_round{close_after:} booking that arrives after the round it
      # named has already moved on, closed by hand or replaced by a later
      # open_round, wakes nobody: the round it would report on is gone.
      def round_still_open?(community, payload)
        return false if @participation.nil?

        round = @participation.round(community: community, room_key: payload["room_key"].to_s)
        !round.nil? && round["id"] == payload["round_id"]
      end

      # Build durable keyword-watch expiry before recovery. Memory and pstore
      # leave `/watch` inert.
      def build_keyword_watches
        service = KeywordWatches::Service.new(
          store: KeywordWatchStore.for(@storage, logger: Log.tagged(logger, "keyword_watch")),
          scheduler: @durable_scheduler,
          adapters: @adapters,
          ephemeral: @ephemeral,
          identity_directory: @identity_directory,
          logger: Log.tagged(logger, "keyword_watch")
        )
        @durable_scheduler.register(KeywordWatches::EXPIRE_KIND) { |job| service.expire(job) }
        service
      end

      # Build a Sequel moderation audit log or a Null store on memory and pstore.
      # Wrapped so an operator's own actions reach the other operators. Every
      # one of them already records an audit event, so the sink is the one seam
      # that catches every verb, including a verb added later.
      def build_audit_log
        sink = AuditLog.for(@storage, logger: Log.tagged(logger, "audit"))
        return sink if @admin_notifier.nil? || @registry.nil?

        ControlPlane::OperatorAnnouncer.new(
          audit: sink, notifier: @admin_notifier, registry: @registry,
          logger: Log.tagged(logger, "audit")
        )
      end

      # Reclaim prior-session jobs, run due work, then start durable polling.
      def recover_durable_scheduler
        return if @durable_scheduler.nil?

        @durable_scheduler.recover
        # Arm one recurring overdue sweep before polling begins.
        @ephemeral&.arm_periodic_reap
        @durable_scheduler.start
      rescue StandardError => e
        logger.warn { "durable scheduler boot recovery failed: #{e.class}: #{e.message}" }
      end

      # Build scheduled announcements on durable jobs and shared ephemeral posts.
      def build_announcement_scheduler
        AnnouncementScheduler.new(
          scheduler: @durable_scheduler,
          ephemeral: @ephemeral,
          topology: routing_topology,
          registry: @registry,
          logger: Log.tagged(logger, "announce")
        )
      end

      # Build link annotation fetch-and-reply work on durable workers.
      def build_link_annotator
        LinkAnnotation::Annotator.new(
          scheduler: @durable_scheduler,
          ephemeral: @ephemeral,
          topology: routing_topology,
          registry: @registry,
          logger: Log.tagged(logger, "annotate")
        )
      end

      # Build translation delivery on durable workers with retained adapters.
      def build_translation_relay
        Translation::Relay.new(
          scheduler: @durable_scheduler,
          storage: @storage,
          topology: routing_topology,
          adapters: @adapters,
          loop_guard: @loop_guard,
          registry: @registry,
          people: routing_people,
          logger: Log.tagged(logger, "translate"),
          settings: translation_settings
        )
      end

      # Room summaries need the control plane for room-scoped retained input and
      # the durable scheduler for all external requests. Without either, the
      # feature is absent rather than storing an incomplete local buffer.
      def build_room_summaries
        return nil if @registry.nil? || @durable_scheduler.nil?

        RoomSummaries::Service.new(
          models: control_plane_models, registry: @registry, scheduler: @durable_scheduler,
          adapters: @adapters, ephemeral: @ephemeral,
          settings: open_arc_settings, stats: @model_call_stats,
          logger: Log.tagged(logger, "room-summaries")
        )
      end

      def build_semantic_analysis
        return nil if @registry.nil? || @durable_scheduler.nil?

        SemanticAnalysis::Service.new(
          registry: @registry, scheduler: @durable_scheduler, adapters: @adapters, ephemeral: @ephemeral,
          settings: open_arc_settings, stats: @model_call_stats,
          logger: Log.tagged(logger, "semantic-analysis")
        )
      end

      # Nil redirection rows leave classification working and moves refused,
      # which is the same way redirection itself degrades. Announcing a finding
      # borrows content policy's own two: the admin notifier for the operator
      # DM, the in-process scheduler for an in-room notice's self-delete.
      def build_topic_router
        return nil if @registry.nil? || @durable_scheduler.nil?

        SemanticAnalysis::TopicRouter.new(
          registry: @registry, scheduler: @durable_scheduler, adapters: @adapters, ephemeral: @ephemeral,
          settings: open_arc_settings, redirections: @redirections, audit: @audit_log,
          admin_notifier: @admin_notifier, cleanup: @scheduler,
          # Confirm mode writes its proposal here before announcing it.
          proposals: @topic_move_proposals,
          stats: @model_call_stats, logger: Log.tagged(logger, "topic-routing")
        )
      end

      # Deleting an already-relayed copy needs the live topology and message
      # map, exactly what Watchdog::Removal uses everywhere else; DMing
      # operators on a flag needs the admin notifier built earlier.
      def build_content_policy
        return nil if @registry.nil? || @durable_scheduler.nil?

        ContentPolicy::Service.new(
          registry: @registry, scheduler: @durable_scheduler, adapters: @adapters, ephemeral: @ephemeral,
          settings: open_arc_settings, topology: routing_topology, storage: @storage,
          admin_notifier: @admin_notifier, audit: @audit_log, cleanup: @scheduler,
          actions: @content_policy_actions, misfires: @content_policy_misfires,
          revisions: ContentPolicy::Revisions.new(db: control_plane_models.db,
                                                  retention: ContentPolicy::Service::MAX_AGE),
          stats: @model_call_stats,
          # warn_and_delete issues a real strike, so its name is true and the
          # community's own ladder escalates a repeat offender.
          warnings: @warnings,
          logger: Log.tagged(logger, "content-policy")
        )
      end

      # The record a flag alert is answered by. Nil without a control plane,
      # which leaves the alert carrying no code and the command inert, exactly
      # the way the rest of the operator surface degrades.
      def build_content_policy_actions
        return nil unless @registry && control_plane_models

        ControlPlane::ContentPolicyActions.new(
          models: control_plane_models, logger: Log.tagged(logger, "content-policy")
        )
      end

      # A warning's in-room notice paired with the message it was about. Nil
      # without a control plane, like every store beside it.
      def build_warning_announcements
        return nil unless @registry && control_plane_models

        ControlPlane::WarningAnnouncements.new(
          models: control_plane_models, logger: Log.tagged(logger, "warnings")
        )
      end

      # DMs a member could not be sent, kept until they write in. Nil without a
      # control plane, like every store beside it.
      def build_undelivered_dms
        # @registry first, and the short circuit is the point: control_plane_models
        # raises rather than answering nil on a deployment with no control plane.
        return nil unless @registry && control_plane_models

        ControlPlane::UndeliveredDms.new(
          models: control_plane_models, logger: Log.tagged(logger, "warnings")
        )
      end

      # What `vindicate` in the operator console runs. Holds the same record
      # store the alert's code came from, so a reversal reaches exactly the
      # action that alert described.
      def build_content_policy_vindication
        return nil if @content_policy_actions.nil?

        ContentPolicy::Vindication.new(
          adapters: @adapters, ephemeral: @ephemeral, actions: @content_policy_actions,
          misfires: @content_policy_misfires, audit: @audit_log, cleanup: @scheduler,
          # Reversing a warn_and_delete clears the strike it issued and lifts
          # whatever the ladder escalated that strike to.
          moderation: build_content_policy_moderation, warnings_store: warnings_store,
          reposts: @content_policy_reposts,
          # The console hands in its control-plane row, and only the snapshot
          # carries rooms that know their endpoints.
          registry: @registry,
          logger: Log.tagged(logger, "content-policy")
        )
      end

      # Moves waiting on an operator, and the answered ones kept as training
      # samples. Nil without a control plane, like every store beside it.
      def build_topic_move_proposals
        return nil unless @registry && control_plane_models

        ControlPlane::TopicMoveProposals.new(
          models: control_plane_models, logger: Log.tagged(logger, "topic-routing")
        )
      end

      # What an operator's answer does: replay the move, or keep the reason.
      def build_move_decisions
        return nil if @topic_move_proposals.nil?

        SemanticAnalysis::MoveDecisions.new(
          proposals: @topic_move_proposals, registry: @registry, redirections: @redirections,
          scheduler: @durable_scheduler, audit: @audit_log,
          logger: Log.tagged(logger, "topic-routing")
        )
      end

      # The allowlist that lets one member take down one restored message.
      def build_content_policy_reposts
        return nil unless @registry && control_plane_models

        ControlPlane::ContentPolicyReposts.new(
          models: control_plane_models, logger: Log.tagged(logger, "content-policy")
        )
      end

      # The samples a reversal leaves behind. Nil without a control plane, the
      # same way the record store it copies from is.
      def build_content_policy_misfires
        return nil unless @registry && control_plane_models

        ControlPlane::ContentPolicyMisfires.new(
          models: control_plane_models, logger: Log.tagged(logger, "content-policy")
        )
      end

      def open_arc_settings
        return OpenArc::Settings.new unless @registry

        store = ControlPlane::Integrations::OpenArcSettings.new(
          ControlPlane::Integrations.new(models: control_plane_models, logger: logger)
        )
        OpenArc::Settings.new(store: store)
      end

      # Load dashboard translation settings when available, otherwise use the
      # environment defaults.
      def translation_settings
        return Translation::Settings.new(env: @env) unless @registry

        store = ControlPlane::Integrations::LibreTranslateSettings.new(
          ControlPlane::Integrations.new(models: control_plane_models, logger: logger)
        )
        Translation::Settings.new(env: @env, store: store)
      end

      # Watches feature_settings so switching scheduled announcements on or off
      # from the dashboard reaches the running bot, rather than waiting for a
      # restart. Nil without a control plane, the same guard the reconcile
      # itself uses.
      def build_announcement_settings_watch
        return nil if @registry.nil? || @announcements.nil?

        ControlPlane::TableWatch.new(
          models: control_plane_models, table: :feature_settings,
          sync: method(:reconcile_announcements), logger: Log.tagged(logger, "announce")
        )
      end

      # Reconcile community announcement settings into durable jobs. Failure must
      # not prevent boot.
      def reconcile_announcements
        return if @registry.nil? || @announcements.nil?

        reconciled = @announcements.reconcile_snapshot(@registry.current)
        logger.info { "scheduled announcements: reconciled #{reconciled} community(ies)" } if reconciled.positive?
      rescue StandardError => e
        logger.warn { "could not reconcile scheduled announcements: #{e.class}: #{e.message}" }
      end

      def reconcile_room_summaries
        return if @room_summaries.nil?

        reconciled = @room_summaries.reconcile
        logger.info { "room summaries: scheduled #{reconciled} daily room(s)" } if reconciled.positive?
      rescue StandardError => e
        logger.warn { "could not reconcile room summaries: #{e.class}: #{e.message}" }
      end

      # Start paced, idempotent, feature-gated downtime backfill. Failure must
      # not prevent boot.
      def start_backfill
        return unless @registry

        sweep_backfill(@adapters)
      rescue StandardError => e
        logger.warn { "backfill did not start: #{e.class}: #{e.message}" }
      end

      # The paced resync, over +adapters+ and on its own thread. Boot passes every
      # adapter; the nightly cycle passes just the ones it reconnected.
      def sweep_backfill(adapters)
        tagged = Log.tagged(logger, "backfill")
        proposals = ControlPlane::BackfillProposals.new(models: control_plane_models, logger: tagged)
        Core::Backfill.new(storage: @storage, logger: tagged, proposals: proposals, outcomes: @relay_outcomes)
                      .start(adapters: adapters, snapshot: @registry.current)
      end

      # The nightly drop and reconnect. Builds nothing when the operator turned it
      # off, and starts no thread when no adapter here holds a gateway open.
      def start_gateway_cycle
        return unless config.gateway_cycle?

        @gateway_cycle = GatewayCycle.new(
          adapters: @adapters,
          at: config.gateway_cycle_at,
          logger: Log.tagged(logger, "gateway-cycle"),
          after_cycle: method(:backfill_after_cycle)
        )
        @gateway_cycle.start
      rescue StandardError => e
        @gateway_cycle = nil
        logger.warn { "the gateway cycle did not start: #{e.class}: #{e.message}" }
      end

      # Detect receiving endpoint stalls and reconnect through the gateway cycle.
      def start_quiet_gateway_watchdog
        return unless config.quiet_gateway_watchdog?

        cycle = @gateway_cycle
        @quiet_gateway_watchdog = QuietGatewayWatchdog.new(
          topology: routing_topology,
          activity: @inbound_activity,
          adapters: @adapters,
          logger: Log.tagged(logger, "quiet-gateway"),
          threshold: config.quiet_gateway_threshold,
          interval: config.quiet_gateway_interval,
          # Without a cycle, keep detection and logs but skip automatic reconnect.
          reconnect: cycle && ->(adapters, reason:) { cycle.reconnect(adapters, reason: reason) }
        )
        @quiet_gateway_watchdog.start
      rescue StandardError => e
        @quiet_gateway_watchdog = nil
        logger.warn { "the quiet gateway watchdog did not start: #{e.class}: #{e.message}" }
      end

      # Backfill only adapters recovered by this gateway cycle.
      def backfill_after_cycle(recovered)
        return if @registry.nil?

        cycled = @adapters.select { |_key, adapter| recovered.include?(adapter) }
        sweep_backfill(cycled)
      end

      # Return watchdog-stalled endpoints for the internal bot source.
      def quiet_gateway_stats
        return {} if @quiet_gateway_watchdog.nil?

        @quiet_gateway_watchdog.stalled.each_with_object({}) do |(adapter_key, verdict), out|
          out[adapter_key.join("/")] = {
            "endpoint_id" => verdict.endpoint.id,
            "quiet_for" => verdict.quiet_for.round,
            "corroborated_by" => verdict.corroborated_by.map(&:id)
          }
        end
      end

      # Whether this deployment reads moderation verbs at all, a separate question
      # from who may run one. Config::Model#moderation_enabled? answers from the
      # STATIC operator directory, right only where that also is the directory
      # authorisation uses; with a control plane it's {LiveOperators} instead, so
      # asking the static one left @commands nil wherever operators live only in
      # the database, answering every verb with "not available on this bridge".
      # Nothing is loosened: an issuer who resolves to no operator is still
      # refused, as :not_permitted.
      def commands_enabled?
        return config.moderation_enabled? unless @registry

        config.commands.fetch(:enabled, true)
      end

      # Whether an accepted command acknowledges back to the issuer.
      # Config::Model answers this through #moderation_enabled? as well, so a
      # database-only deployment ran every verb and then said nothing at all.
      # False outright once commands are switched off, rather than still
      # reading a config value nothing will ever act on.
      def command_acknowledge?
        return false unless commands_enabled?
        return config.command_acknowledge? unless @registry

        config.commands.fetch(:acknowledge) { global_command_default(:acknowledge, true) }
      end

      # The bridge-wide grace period, and the default a scope's own
      # `ack_ttl_seconds` falls back to. Gated on the same static directory,
      # which pinned it to 0 wherever operators live only in the database.
      def command_cleanup_after
        return 0 unless commands_enabled?
        return config.command_cleanup_after unless @registry

        config.commands.fetch(:cleanup_after) { global_command_default(:ack_ttl_seconds, 0) }.to_i
      end

      # The deployment-wide default for one moderation command key, read from
      # the "moderation" feature's own community-less, room-less
      # feature_settings row: the live, database-backed equivalent of the
      # static config's commands block this used to fall back to, which stays
      # permanently empty on a database-only deployment. +default+ only
      # matters where that row itself does not exist yet either.
      def global_command_default(key, default)
        @registry.current.feature_config_default(Features::Moderation.feature_name).fetch(key, default)
      end

      # The verbs the parser recognises at all. The schema default is :delete
      # alone, so the other seven came back "not available on this bridge" on a
      # deployment whose operator rows in the database grant them. An explicit
      # `commands.actions` is still the operator's own decision and wins.
      def command_actions
        return config.commands[:actions] if config.commands.key?(:actions)
        return Moderation::TYPED_ACTIONS if @registry

        %i[delete]
      end

      # The parser recognises verbs; who may run one is settled per message,
      # against that message's own community.
      def build_commands
        return nil unless commands_enabled?

        # No directory: the parser resolves each issuer in that message's own
        # community, which Features::Moderation hands it per message.
        Commands.new(
          prefixes: config.command_prefixes,
          enabled: true,
          actions: command_actions,
          # The one thing that lets a non-operator delete a message that is not
          # theirs by authorship: a restoration posted on their behalf.
          reposts: @content_policy_reposts,
          logger: Log.tagged(logger, "commands")
        )
      end

      # ------------------------------------------------------------------
      # control plane
      # ------------------------------------------------------------------

      # Seed and open the control plane over the message-map database. A failure
      # logs and retains config-only routing.
      def build_control_plane
        return unless ControlPlane::Boot.available?(@storage)

        slug = ControlPlane::Boot.slug_for(config, env: @env, override: @community_slug)
        @registry = ControlPlane::Boot.prepare(
          storage: @storage, config: config, slug: slug, logger: logger, env: @env
        )
        reconcile_protected_community_connections if @registry
        @channel_resolver = ControlPlane::ChannelResolver.new(@registry) if @registry
        logger.info { "control plane active: routing from the snapshot (community #{slug.inspect})" } if @registry
      rescue StorageError => e
        logger.error { "control plane unavailable (#{e.message}); routing from static config" }
        @registry = nil
        @channel_resolver = nil
      end

      # Reconcile protected community connections in production at every boot.
      # Failures log without preventing startup.
      def reconcile_protected_community_connections
        return unless ControlPlane::Environment.production?(@env)

        ControlPlane::ProtectedCommunityConnections.reconcile!(models: control_plane_models, logger: logger)
        @registry.reload
      rescue StandardError => e
        logger.warn { "protected community connections: reconcile failed: #{e.message}" }
      end

      # Expose live Registry topology so reloads reach routing without restart.
      # Use config topology without a control plane.
      def routing_topology
        @routing_topology ||= @registry ? LiveTopology.new(@registry) : config.topology
      end

      # Expose live Registry operators so grants apply without restart. Use the
      # config directory without a control plane.
      def routing_operators
        @routing_operators ||= @registry ? LiveOperators.new(@registry) : config.operators
      end

      # The mentionable-people directory. Same reasoning as {#routing_operators},
      # via {LivePeople}.
      def routing_people
        @routing_people ||= @registry ? LivePeople.new(@registry) : config.people
      end

      # Replace seeded Discord guild sentinels and reload the Snapshot. Routing
      # stays valid because the id belongs to the platform connection.
      def resolve_discord_guilds
        return unless @registry

        resolved = ControlPlane::GuildResolver.resolve(
          models: control_plane_models,
          adapters: @adapters,
          logger: Log.tagged(logger, "control-plane")
        )
        @registry.reload if resolved.positive?
      rescue StandardError => e
        logger.warn { "could not resolve Discord guild ids: #{e.message}" }
      end

      # Memoise schema-introspecting Sequel models for this runtime's storage.
      def control_plane_models
        @control_plane_models ||= ControlPlane.models(ControlPlane::Boot.db_of(@storage))
      end

      def resume_redirections
        @router&.redirection&.resume_all
      rescue StandardError => e
        logger.warn { "could not resume redirections left in flight: #{e.message}" }
      end

      # Persist redirections only with a control plane, otherwise refuse moves.
      def build_redirections
        return nil unless @registry

        ControlPlane::Redirections.new(
          models: control_plane_models,
          logger: Log.tagged(logger, "redirection")
        )
      end

      # Keep bounded redirection history for `/end`, written at relay fan-out.
      def build_redirection_window
        return nil unless @registry

        ControlPlane::RedirectionWindow.new(
          models: control_plane_models,
          logger: Log.tagged(logger, "redirection")
        )
      end

      # Track per-endpoint arrival and post digests for accurate relay decisions.
      def build_relay_fingerprints
        return nil unless @registry

        ControlPlane::RelayFingerprints.new(
          models: control_plane_models,
          logger: Log.tagged(logger, "relay-fingerprints")
        )
      end

      # Operator grants update the live Registry without restart. Return nil
      # without a control plane.
      def build_operator_flow
        return nil unless @registry

        ControlPlane::OperatorFlow.new(
          models: control_plane_models,
          registry: @registry,
          logger: Log.tagged(logger, "operators")
        )
      end

      # Deployment viewers combine the YAML floor and granted rows. Build before
      # DM lanes so all paths resolve the same roster.
      def build_dashboard_viewers
        return Security::DashboardViewers.default unless @registry

        ControlPlane::DashboardViewers.new(
          models: control_plane_models,
          registry: @registry,
          audit: AuditLog.for(@storage, logger: Log.tagged(logger, "audit")),
          logger: Log.tagged(logger, "dashboard-viewers")
        )
      end

      # Deployment administrators combine the YAML floor and granted rows.
      def build_dashboard_administrators
        return Security::DashboardAdministrators.default unless @registry

        ControlPlane::DashboardAdministrators.new(
          models: control_plane_models,
          registry: @registry,
          audit: AuditLog.for(@storage, logger: Log.tagged(logger, "audit")),
          logger: Log.tagged(logger, "dashboard-administrators")
        )
      end

      # Community viewers require control-plane persistence; otherwise `/role
      # viewer` remains unrecognised.
      def build_community_viewers
        return nil unless @registry

        ControlPlane::CommunityViewers.new(
          models: control_plane_models,
          registry: @registry,
          audit: AuditLog.for(@storage, logger: Log.tagged(logger, "audit")),
          logger: Log.tagged(logger, "community-viewers")
        )
      end

      # The tokens somebody is handed so they can be granted a role by DM. Real
      # only with a control plane, since a token is a durable row; nil
      # otherwise, which leaves `/auth` declining rather than swallowing one.
      def build_auth_tokens
        return nil unless @registry

        ControlPlane::AuthTokens.new(
          models: control_plane_models,
          # A redeemed token grants through the same services as dashboard and API.
          operator_flow: @operator_flow,
          community_viewers: @community_viewers,
          dashboard_viewers: @dashboard_viewers,
          dashboard_administrators: @dashboard_administrators,
          audit: AuditLog.for(@storage, logger: Log.tagged(logger, "audit")),
          logger: Log.tagged(logger, "auth-tokens")
        )
      end

      # Both DM lanes share `/auth`, including the standard web-login link.
      def build_auth_command
        return nil if @auth_tokens.nil?

        ControlPlane::AuthCommand.new(
          tokens: @auth_tokens,
          web_login: build_web_login_tokens,
          reach: @admin_reach,
          viewers: @dashboard_viewers,
          administrators: @dashboard_administrators,
          community_viewers: @community_viewers,
          dashboard_url: @env["DASHBOARD_URL"],
          logger: Log.tagged(logger, "auth")
        )
      end

      # Event scheduling is a shared control-plane writer. Lifecycle performs
      # announcements and reminders; nil keeps `/event` inert without control.
      def build_event_scheduling
        return nil unless @registry

        ControlPlane::EventScheduling.new(
          models: control_plane_models,
          logger: Log.tagged(logger, "events")
        )
      end

      # Event lifecycle observes writes, then announces, retracts and rebuilds
      # reminders. It needs control-plane rows and durable state.
      def build_event_lifecycle
        return nil unless @registry && @event_announcer && @event_reminders
        return nil unless @storage.respond_to?(:get_state) && @storage.respond_to?(:put_state)

        Events::Lifecycle.new(
          models: control_plane_models,
          announcer: @event_announcer,
          reminders: @event_reminders,
          store: @storage,
          logger: Log.tagged(logger, "events")
        )
      end

      # Advance overdue Rubotty recurring events through scheduling; lifecycle
      # handles their notices and reminders.
      def build_event_recurrence
        return nil unless @registry && @event_scheduling

        Events::Recurrence.new(
          models: control_plane_models,
          event_scheduling: @event_scheduling,
          logger: Log.tagged(logger, "events")
        )
      end

      # Mirror Discord native events through event scheduling for lifecycle
      # broadcast to other platforms.
      def build_native_mirror
        return nil unless @registry && @event_scheduling

        Events::NativeMirror.new(
          models: control_plane_models,
          event_scheduling: @event_scheduling,
          logger: Log.tagged(logger, "events")
        )
      end

      # Fan event cards, native mirrors, reminders and cancellations to rooms.
      def build_event_announcer
        return nil unless @registry

        Events::Announcer.new(
          registry: @registry,
          models: control_plane_models,
          adapters: @adapters,
          logger: Log.tagged(logger, "events"),
          storage: @storage
        )
      end

      # Register durable event reminders before recovery. Event policy resolves
      # the configured interval ladder and the announcer posts each rung.
      def build_event_reminders
        return nil unless @registry

        policy = ControlPlane::EventPolicy.new(models: control_plane_models)
        Events::Reminders.new(
          scheduler: @durable_scheduler,
          default_intervals: lambda { |event|
            policy.reminder_intervals_for(community_id: event.community_id, room_id: event.room_id)
          },
          on_fire: ->(event, interval) { @event_announcer&.announce_reminder(event, interval) },
          logger: Log.tagged(logger, "events")
        )
      end

      # Persist event RSVPs through the control plane; nil leaves reactions and
      # `/rsvp` inert.
      def build_event_rsvp_ledger
        return nil unless @registry

        Events::RsvpLedger.new(models: control_plane_models, logger: Log.tagged(logger, "events"))
      end

      # Built in one pass because the pieces reference each other. The
      # timekeeper's seams close over the ivar rather than the local, the shape
      # {#build_event_reminders} uses, so nothing is half built when handed on.
      def build_polls
        return nil unless @registry

        log = Log.tagged(logger, "polls")
        @polls = ControlPlane::Polls.new(models: control_plane_models, logger: log)
        @poll_ballot = Polls::Ballot.new(models: control_plane_models, logger: log)
        @poll_activity = Polls::RoomActivity.new
        @poll_board = Polls::Board.new(
          registry: @registry, models: control_plane_models, adapters: @adapters,
          polls: @polls, ballot: @poll_ballot, activity: @poll_activity, logger: log,
          storage: @storage
        )
        @poll_timekeeper = Polls::Timekeeper.new(
          scheduler: @durable_scheduler,
          on_close: ->(poll_id) { @poll_lifecycle&.close(poll_id) },
          on_repost: ->(poll_id) { @poll_lifecycle&.repost(poll_id) },
          logger: log
        )
        @poll_lifecycle = Polls::Lifecycle.new(
          polls: @polls, board: @poll_board, timekeeper: @poll_timekeeper, logger: log
        )
      end

      # Record passive identities through the control plane, or no-op without it.
      def build_identity_recorder
        return nil unless @registry

        # Keep one directory so mention resolution sees the recorder's current
        # sightings.
        @identity_directory = ControlPlane::IdentityDirectory.new(models: control_plane_models)
        @bridged_nicknames = ControlPlane::BridgedNicknames.new(
          models: control_plane_models, logger: Log.tagged(logger, "nickname")
        )
        ControlPlane::IdentityRecorder.new(
          directory: @identity_directory,
          logger: Log.tagged(logger, "identity"),
          # Handed the live map so the recorder can ask each connection how
          # durable its ids are, rather than assuming every platform's are.
          adapters: @adapters
        )
      end

      # Reclaim guest-session messages and uploads with durable expiry recovery.
      # Return nil without a control plane.
      def build_guest_retention
        return nil unless @registry

        ControlPlane::GuestRetention.new(
          models: control_plane_models,
          scheduler: @durable_scheduler,
          grace: config.guest_retention,
          logger: Log.tagged(logger, "guest"),
          announcer: @guest_announcer,
          uploads: @guest_uploads
        )
      end

      # Guest retention uses this store to unlink expired attachment bytes.
      def build_guest_uploads
        return nil if @registry.nil? || @object_store.nil?

        ControlPlane::GuestUploads.new(
          models: control_plane_models, store: @object_store, logger: Log.tagged(logger, "guest")
        )
      end

      # See the note beside its call site in #build for why this is built
      # before #build_guest_retention.
      def build_guest_announcer
        return nil unless @registry

        ControlPlane::GuestAnnouncer.new(
          registry: @registry,
          models: control_plane_models,
          adapters: @adapters,
          scheduler: @durable_scheduler,
          logger: Log.tagged(logger, "guest")
        )
      end

      # Guest link issuance, authentication and revocation share one control-plane
      # service with `/guest` and the guest adapter.
      def build_guest_invites
        return nil unless @registry

        ControlPlane::GuestInvites.new(
          models: control_plane_models, logger: Log.tagged(logger, "guest"),
          retention: @guest_retention, announcer: @guest_announcer
        )
      end

      # The guest adapter runs sends through the pipeline and writes relays to its
      # feed. It requires a live control-plane Snapshot.
      def build_guest_adapter
        return nil unless @registry

        Adapters::Guest::Adapter.new(
          dispatcher: @dispatcher,
          feed: ControlPlane::GuestFeed.new(models: control_plane_models),
          invites: @guest_invites,
          models: control_plane_models,
          registry: @registry,
          logger: Log.tagged(logger, "guest")
        )
      end

      # The queue behind the REST API's message endpoint, shared by the
      # API process (which writes) and the adapter below (which drains).
      def build_api_messages
        return nil unless @registry

        ControlPlane::ApiMessages.new(models: control_plane_models)
      end

      # API-wrapper account adapters drain their account-scoped inbound queue.
      # Inject it after construction because adapter initializers are fixed.
      def build_api_wrapper_events
        return nil unless @registry

        ControlPlane::ApiWrapperEvents.new(models: control_plane_models)
      end

      # API room-level reaction, edit and delete requests queue for its adapter.
      def build_api_message_actions
        return nil unless @registry

        ControlPlane::ApiMessageActions.new(models: control_plane_models)
      end

      # The API live-stream buffer is bridge-written and promptly pruned.
      def build_live_room_feed
        return nil unless @registry

        ControlPlane::LiveRoomFeed.new(models: control_plane_models)
      end

      def build_api_rate_limiter
        return nil unless @registry

        ControlPlane::ApiRateLimiter.new(models: control_plane_models)
      end

      # Queue bridge events for webhook subscribers; durable jobs send them off
      # the relay path.
      def build_webhooks
        return nil unless @registry

        ControlPlane::Webhooks.new(models: control_plane_models,
                                   logger: Log.tagged(logger, "webhooks"))
      end

      # Durable per-subscription pumps preserve delivery order. A recurring job
      # reconciles pumps created by API or dashboard changes.
      def register_webhook_jobs
        return if @durable_scheduler.nil? || @webhooks.nil?

        pump = ControlPlane::WebhookPump.new(webhooks: @webhooks, models: control_plane_models,
                                             logger: Log.tagged(logger, "webhooks"))
        @durable_scheduler.register(ControlPlane::Webhooks::PUMP_KIND) { |job| pump.call(job) }
        @durable_scheduler.register(ControlPlane::Webhooks::RECONCILE_KIND) do |_job|
          @webhooks.reconcile_pumps(scheduler: @durable_scheduler)
        end
        # Reconciliation owns pump creation, avoiding competing boot and tick paths.
        @durable_scheduler.forget(kind: ControlPlane::Webhooks::RECONCILE_KIND, every_community: true)
        @durable_scheduler.schedule(
          kind: ControlPlane::Webhooks::RECONCILE_KIND,
          run_at: Time.now + ControlPlane::Webhooks::FIRST_RECONCILE,
          recurrence: ControlPlane::Webhooks::RECONCILE_INTERVAL, payload: {}
        )
      end

      # The API adapter posts through the normal pipeline for moderation. It
      # requires control-plane routing.
      def build_api_adapter
        return nil unless @registry

        Adapters::Api::Adapter.new(
          dispatcher: @dispatcher,
          messages: @api_messages,
          actions: @api_message_actions,
          models: control_plane_models,
          registry: @registry,
          logger: Log.tagged(logger, "api")
        )
      end

      # Handle DM operator requests and deduplicate unsolicited notices through
      # durable state when available.
      def build_control_lane
        return nil unless @operator_flow

        ControlPlane::ControlLane.new(
          operator_flow: @operator_flow,
          # Share community candidates with the console and retain the question's
          # cooldown.
          reach: @admin_reach,
          cooldown_store: notice_cooldown_store,
          # Let a non-operator request read-only access to one community.
          community_viewers: @community_viewers,
          # Handle a token before its holder has console access.
          auth: @auth_command,
          # The one branch a member with no standing anywhere may reach.
          reports: build_report_lane,
          logger: Log.tagged(logger, "control-lane")
        )
      end

      # Resolve DM communities consistently for both lanes and web login.
      def build_admin_reach
        return nil unless @operator_flow

        ControlPlane::AdminReach.new(
          operator_flow: @operator_flow,
          # Announce first account bindings for handle-only operators.
          notifier: @admin_notifier,
          logger: Log.tagged(logger, "admin-reach")
        )
      end

      # Use durable state to deduplicate unsolicited DM notices when available.
      def notice_cooldown_store
        return @storage if @storage.respond_to?(:get_state) && @storage.respond_to?(:put_state)

        nil
      end

      # Build the stateful operator console over the request lane. Sessions use
      # durable state when available.
      def build_operator_console
        return nil unless @operator_flow

        ControlPlane::OperatorConsole.new(
          operator_flow: @operator_flow,
          # Use one stable cross-platform community resolution for console and
          # web-login scope.
          reach: @admin_reach,
          request_lane: @control_lane,
          # Host the control-plane mapping wizard as the `map` command.
          mapper: build_channel_mapper,
          # `web-login` needs durable state or it declines instead of minting an
          # unusable link.
          web_login: build_web_login_tokens,
          dashboard_url: @env["DASHBOARD_URL"],
          # Console config and analytics use the same services as dashboard pages.
          feature_controls: build_console_feature_controls,
          analytics: build_console_analytics,
          # `vindicate` answers a content policy alert by the code it carried.
          vindication: @content_policy_vindication,
          # `approve` and `reject` answer a topic move proposal the same way.
          proposals: build_move_decisions,
          # Recognise both shipped and recently granted viewers.
          viewers: @dashboard_viewers,
          # Recognise granted administrators when minting `web-login` links.
          administrators: @dashboard_administrators,
          community_viewers: @community_viewers,
          # Share token redemption with the request lane.
          auth: @auth_command,
          # A DM is the first chance to hand over a notice written while this
          # member was unreachable, so the console carries both the kept rows
          # and the adapters that can finally send them.
          undelivered: @undelivered_dms,
          adapters: @adapters,
          sessions: console_sessions,
          logger: Log.tagged(logger, "operator-console")
        )
      end

      # Console feature changes update the live Registry for immediate effect.
      def build_console_feature_controls
        ControlPlane::FeatureControls.new(
          models: control_plane_models, registry: @registry,
          logger: Log.tagged(logger, "feature-controls"), relay_claim_ttl: config.relay_claim_ttl
        )
      end

      # Console analytics remain available without Lua and independently of
      # scripting services.
      def build_console_analytics
        ControlPlane::Analytics.new(db: ControlPlane::Boot.db_of(@storage), models: control_plane_models)
      end

      # Channel mapping updates the live Registry without restart.
      def build_channel_mapper
        return nil unless @registry

        ControlPlane::ChannelMapper.new(
          models: control_plane_models,
          registry: @registry,
          logger: Log.tagged(logger, "channel-mapper")
        )
      end

      # Dashboard login tokens require durable message-map state.
      def build_web_login_tokens
        return nil unless @storage.respond_to?(:get_state) && @storage.respond_to?(:put_state)

        ControlPlane::WebLoginTokens.new(store: @storage, logger: Log.tagged(logger, "web-login"))
      end

      # Discover live channels for mapping and watches, including Discord guild
      # resolution. It requires control-plane state.
      def build_channel_discovery
        return nil unless @registry
        return nil unless @storage.respond_to?(:get_state) && @storage.respond_to?(:put_state)

        ControlPlane::ChannelDiscovery.new(
          models: control_plane_models,
          watch: ControlPlane::NewChannelWatch.new(
            models: control_plane_models, store: @storage,
            logger: Log.tagged(logger, "new-channel")
          ),
          notifier: build_discovery_notifier,
          # Resolve `/identify-topic` operator status through the shared flow.
          operators: @operator_flow,
          # Discovery covers spaces added while the bot was down, not only join
          # event adapters.
          pending_spaces: @pending_spaces,
          logger: Log.tagged(logger, "discovery")
        )
      end

      # Move a community's channels onto the new id a platform gives a replaced
      # space, reloading the live Registry so the next send uses it.
      def build_space_migration
        return nil unless @registry

        ControlPlane::SpaceMigration.new(
          models: control_plane_models, registry: @registry, audit: @audit_log,
          logger: Log.tagged(logger, "space-migration")
        )
      end

      # Send discovery prompts to the operator room. Without control, discovery
      # still logs sightings.
      def build_discovery_notifier
        return nil unless @registry

        ControlPlane::DiscoveryNotifier.new(
          registry: @registry,
          ephemeral: @ephemeral,
          logger: Log.tagged(logger, "discovery")
        )
      end

      # Use durable console sessions when the message map exposes state.
      def console_sessions
        if @storage.respond_to?(:get_state) && @storage.respond_to?(:put_state)
          ControlPlane::OperatorConsole::KvSessions.new(@storage)
        else
          ControlPlane::OperatorConsole::MemorySessions.new
        end
      end

      # Retain onboarding activity so auto-leave waits while a space is mapped.
      def build_onboarding
        return nil unless @registry
        return nil unless @storage.respond_to?(:get_state) && @storage.respond_to?(:put_state)

        ControlPlane::OnboardingRegistry.new(store: @storage)
      end

      # Decide auto-leave from authorisation, onboarding and inert notices. Both
      # Telegram and Discord use this platform-neutral guard.
      def build_join_guard
        return nil unless @registry

        ControlPlane::JoinGuard.new(
          authorization: ControlPlane::AuthorizationDirectory.new(models: control_plane_models),
          onboarding: @onboarding,
          # Retain once-only inert notices when durable state exists.
          inert_notices: ControlPlane::InertNotices.new(store: notice_cooldown_store),
          logger: Log.tagged(logger, "join-guard")
        )
      end

      # See @admin_notifier's build-site comment above for why the adapter map
      # is passed by reference before it is populated.
      def build_admin_notifier
        return nil unless @registry

        ControlPlane::AdminNotifier.new(
          models: control_plane_models, adapters: @adapters, logger: Log.tagged(logger, "admin-notify"),
          # For resolving a community's nominated alert room; without it every
          # alert stays the DM fan-out it has always been.
          registry: @registry
        )
      end

      # See @pending_spaces's build-site comment above for the durable-timer
      # ordering this depends on.
      def build_pending_spaces
        return nil unless @registry

        service = ControlPlane::PendingSpaces.new(
          models: control_plane_models,
          authorization: ControlPlane::AuthorizationDirectory.new(models: control_plane_models),
          scheduler: @durable_scheduler,
          adapters: @adapters,
          registry: @registry,
          admin_notifier: @admin_notifier,
          logger: Log.tagged(logger, "pending-spaces")
        )
        @durable_scheduler&.register(ControlPlane::PendingSpaces::EXPIRE_KIND) { |job| service.expire(job) }
        # Register enumeration here, where the live adapter map can list channels.
        @durable_scheduler&.register(ControlPlane::PendingSpaces::ENUMERATE_KIND) { |job| service.enumerate(job) }
        service
      end

      # Register room provisioning handlers in the adapter-owning process.
      def build_room_provisioning
        return nil unless @registry

        service = ControlPlane::RoomProvisioning.new(
          models: control_plane_models, scheduler: @durable_scheduler, adapters: @adapters,
          registry: @registry, audit: @audit_log, logger: Log.tagged(logger, "room-provisioning")
        )
        @durable_scheduler&.register(ControlPlane::RoomProvisioning::CREATE_KIND) { |job| service.create(job) }
        @durable_scheduler&.register(ControlPlane::RoomProvisioning::DELETE_KIND) { |job| service.delete(job) }
        service
      end

      # One shared timer for command cleanup, banner deletion, every feature's
      # fast ephemeral self-delete and the IRC and XMPP live channel re-sync.
      # It used to be built only when the static command_cleanup_after or
      # announce_delete_after was positive, which on a database-only deployment
      # is never, so the re-sync never re-armed and a scope's own
      # acknowledgement window was read and then dropped. One thread on a
      # one-second tick, so building it always costs less than gating it.
      def build_scheduler
        Scheduler.new(logger: Log.tagged(logger, "cleanup"))
      end

      # Ask the adapter's explicit pending-space capability, not its initializer.
      def accepts_pending_spaces?(adapter_class) = adapter_class.accepts_pending_spaces?

      def build_adapters
        active_accounts.each do |account|
          # Skip dormant accounts without constructing clients; healthy gateways
          # continue booting.
          if account.dormant?
            logger.info { "gateway #{account.name}: #{account.dormant_reason}, staying dormant" }
            next
          end

          endpoints = config.endpoints_for(account.name)
          options = {
            account: account.name,
            settings: account.settings,
            dispatcher: @dispatcher,
            logger: Log.tagged(logger, account.adapter_name.to_s),
            endpoints: endpoints,
            # Live control-plane adapters resolve inbound events through Snapshot;
            # endpoints remain the fallback index.
            endpoint_resolver: @channel_resolver,
            # Route unresolved DMs to console or request lane; use nil without
            # a control plane to retain dropped-DM behaviour.
            control_lane: @operator_console || @control_lane,
            # Use the shared join guard to leave unauthorised spaces.
            join_guard: @join_guard,
            # Feed discovered channels and resolve Discord guild sentinels here.
            discovery: @channel_discovery
          }
          # Pass pending review only to adapters that explicitly accept it.
          options[:pending_spaces] = @pending_spaces if accepts_pending_spaces?(account.adapter_class)
          adapter = account.adapter_class.new(**options)
          # Inject storage after construction for Telegram's durable offset.
          adapter.storage = @storage
          adapter.delivery_state_ttl = config.message_ttl
          # Inject ephemeral replies for adapter-level `/identify-topic` cleanup.
          adapter.ephemeral = @ephemeral
          adapter.cleanup = @scheduler
          # Same reason again, for the store Telegram copies a sender's profile
          # photo into. Nil without a control plane or a usable object store.
          adapter.rehoster = @rehoster
          # Same reason again, so a reaction on a bridge-authored post (an
          # event card, a poll card) can still recover its endpoint once the
          # message map comes up empty. Empty without a control plane.
          adapter.card_lookup = Core::CardLookup.new([@event_announcer, @poll_board])
          # So an upgraded Telegram group's channel follows it to the new chat id.
          adapter.space_migration = @space_migration
          # Inject the account-scoped API wrapper queue after construction.
          adapter.inbound_events = @api_wrapper_events
          @adapters[[account.adapter_name, account.name]] = adapter
        end
        # Add the fixed guest adapter separately from YAML accounts.
        guest = build_guest_adapter
        @adapters[[Adapters::Guest::NAME, Adapters::Guest::ACCOUNT]] = guest if guest
        # Add the fixed API adapter for lifecycle management, not relay targets.
        api = build_api_adapter
        @adapters[[Adapters::Api::NAME, Adapters::Api::ACCOUNT]] = api if api
      end

      # Start one supervised watcher for snapshots, events, polls and script
      # schedules. A failure logs without stopping relay, while health
      # reports the loss.
      def start_control_watcher
        @change_detector = ControlPlane::ChangeDetector.for(
          storage: @storage, registry: @registry,
          logger: Log.tagged(logger, "control-plane")
        )
        @script_recurrence_watch = build_script_recurrence_watch
        @announcement_settings_watch = build_announcement_settings_watch
        if @change_detector.nil? && @event_lifecycle.nil? && @event_recurrence.nil? && @poll_lifecycle.nil? &&
           @script_recurrence_watch.nil? && @announcement_settings_watch.nil?
          return
        end

        @control_watcher = ControlPlane::Watcher.new(
          logger: Log.tagged(logger, "control-plane"), storage: @storage
        )
        @control_watcher.subscribe("snapshot", @change_detector)
        # Advance recurring events before lifecycle observes their changes.
        @control_watcher.subscribe("events_recurrence", @event_recurrence)
        @control_watcher.subscribe("events", @event_lifecycle)
        @control_watcher.subscribe("polls", @poll_lifecycle)
        @control_watcher.subscribe("script_recurrence", @script_recurrence_watch)
        # After "snapshot", so the rebuild reads the reloaded feature settings.
        @control_watcher.subscribe("announcement_settings", @announcement_settings_watch)
        @control_watcher.start
      rescue StandardError => e
        logger.warn { "could not start the control-plane watcher: #{e.class}: #{e.message}" }
        @control_watcher = nil
      end

      # Subscribe the native mirror to all adapters; only Discord emits changes.
      def register_native_event_mirror
        return if @native_mirror.nil?

        @adapters.each_value do |adapter|
          adapter.on_native_event_change { |change| @native_mirror.handle(change) }
        end
      end

      # Reclaim ended guest sessions and re-arm live expiry jobs. Failures log
      # without stopping boot.
      def reconcile_guest_retention
        return if @guest_retention.nil?

        reclaimed = @guest_retention.reconcile
        if reclaimed.any?
          logger.info do
            "boot reclaim of ended guest sessions: #{reclaimed.messages} feed row(s), " \
              "#{reclaimed.uploads} upload(s)"
          end
        end
      rescue StandardError => e
        logger.warn { "guest retention boot reconcile failed: #{e.class}: #{e.message}" }
      end

      # Flush the coalesced rollups on their own shorter timer: script
      # statistics, script run counts and the model call statistics. One thread
      # for all three, since they share an interval and a second thread would
      # only cost a thin host another stack.
      def start_script_stats_thread
        return if @script_stats.nil? && @scripts.nil? && @model_call_stats.nil?

        @script_stats_thread = Thread.new do
          Thread.current.name = "script-stats-flush"
          loop do
            sleep(ControlPlane::ScriptStats::FLUSH_AFTER_SECONDS)
            begin
              @script_stats&.flush_if_due
              @scripts&.flush_runs_if_due
              @model_call_stats&.flush_if_due
            rescue StandardError => e
              logger.warn { "could not write out the pending script stats: #{e.class}: #{e.message}" }
            end
          end
        end
      end

      # Re-run the straggler banner sweep daily rather than at boot only, so a
      # banner left behind by a restart goes away on its own.
      def start_banner_sweep_thread
        @banner_sweep_thread = Thread.new do
          Thread.current.name = "banner-sweep"
          loop do
            sleep(BANNER_SWEEP_INTERVAL)
            sweep_stray_banners
          end
        end
      end

      # Purge expired message rows on a timer and piggyback retention sweeps.
      # Failures retry next tick without stopping the bridge.
      def start_purge_thread
        interval = config.purge_interval
        return if interval.nil? || interval <= 0

        @purge_thread = Thread.new do
          Thread.current.name = "message-map-purge"
          loop do
            sleep(interval)
            begin
              removed = @storage.purge
              logger.debug { "purged #{removed} expired message map rows" } if removed.to_i.positive?
            rescue StorageError => e
              logger.warn { "message map purge failed: #{e.message}" }
            end
            sweep_guest_retention
            prune_live_room_feed
            prune_relay_fingerprints
            prune_alerts
            prune_webhooks
            prune_api_request_log
            prune_puppet_status
            @content_policy&.prune_revisions
          end
        end
      end

      # The hard upper bound on guest-session content, run from the
      # purge tick above. Never raises: a retention failure must not kill the
      # thread that also purges the message map, and the next tick tries again.
      def sweep_guest_retention
        return if @guest_retention.nil?

        @guest_retention.sweep
      rescue StandardError => e
        logger.warn { "guest retention sweep failed: #{e.class}: #{e.message}" }
      end

      # Start the guest adapter and register its loop identity. Failure logs
      # without stopping relay.
      def start_guest_adapter
        adapter = @adapters[[Adapters::Guest::NAME, Adapters::Guest::ACCOUNT]]
        return if adapter.nil?

        adapter.start
        @loop_guard.register_identity(Adapters::Guest::NAME, Adapters::Guest::ACCOUNT, adapter.own_account_ids)
      rescue StandardError => e
        logger.error { "guest adapter failed to start: #{e.class}: #{e.message}" }
      end

      # Start the API adapter; failure logs without stopping relay.
      def start_api_adapter
        adapter = @adapters[[Adapters::Api::NAME, Adapters::Api::ACCOUNT]]
        return if adapter.nil?

        adapter.start
        @loop_guard.register_identity(Adapters::Api::NAME, Adapters::Api::ACCOUNT, adapter.own_account_ids)
      rescue StandardError => e
        logger.error { "api adapter failed to start: #{e.class}: #{e.message}" }
      end

      # The REST API's rate limiter counts durable rows, so every API
      # request leaves one behind and nothing was ever deleting them: the
      # table grew without bound on any deployment serving the API.
      # Pruned from the same tick as the buffers above, keeping far more
      # than the limiter's own window needs so a prune can never refund a
      # caller's budget mid window.
      API_REQUEST_LOG_RETENTION = 24 * 60 * 60

      def prune_api_request_log
        return if @api_rate_limiter.nil?

        @api_rate_limiter.prune(older_than: Time.now - API_REQUEST_LOG_RETENTION)
      rescue StandardError => e
        logger.warn { "api request log prune failed: #{e.class}: #{e.message}" }
      end

      # Prune the live-stream buffer at boot and on the purge tick; failures must
      # not stop that thread.
      def prune_live_room_feed
        return if @live_room_feed.nil?

        @live_room_feed.prune
      rescue StandardError => e
        logger.warn { "live room buffer prune failed: #{e.class}: #{e.message}" }
      end

      # Drop everything past redirection's retained window, on the same
      # terms as the buffer above: at boot and from the purge tick, never
      # on a thread of its own, and never raising.
      def prune_redirection_window
        return if @redirection_window.nil?

        removed = @redirection_window.prune
        logger.debug { "dropped #{removed} retained message(s) past the redirection window" } if removed.to_i.positive?
      rescue StandardError => e
        logger.warn { "redirection window prune failed: #{e.class}: #{e.message}" }
      end

      # Drop everything past the content ledger's own window (migration 053),
      # on the same terms as the buffer and the window above: at boot and from
      # the purge tick, never on a thread of its own, and never raising.
      def prune_relay_fingerprints
        return if @relay_fingerprints.nil?

        removed = @relay_fingerprints.prune
        logger.debug { "dropped #{removed} relay fingerprint(s) past the window" } if removed.to_i.positive?
      rescue StandardError => e
        logger.warn { "relay fingerprints prune failed: #{e.class}: #{e.message}" }
      end

      # Drop what scripts raised past the alerts retention (migration 041), on
      # the same terms as the two above: at boot and from the purge tick, never
      # on a thread of its own, and never raising.
      def prune_alerts
        return if @alerts.nil?

        removed = @alerts.prune
        logger.debug { "dropped #{removed} alert(s) past their retention" } if removed.to_i.positive?
      rescue StandardError => e
        logger.warn { "alerts prune failed: #{e.class}: #{e.message}" }
      end

      # A room stuck failing its summary run otherwise keeps pending message
      # bodies forever; {RoomSummaries::Archive#complete} only deletes on success.
      def prune_room_summary_transcripts
        return if @room_summaries.nil?

        removed = @room_summaries.archive.prune
        logger.debug { "dropped #{removed} room summary transcript row(s) past retention" } if removed.to_i.positive?
      rescue StandardError => e
        logger.warn { "room summary transcript prune failed: #{e.class}: #{e.message}" }
      end

      def prune_webhooks
        return if @webhooks.nil?

        removed = @webhooks.prune
        logger.debug { "dropped #{removed} webhook delivery/deliveries past their retention" } if removed.to_i.positive?
      rescue StandardError => e
        logger.warn { "webhook delivery prune failed: #{e.class}: #{e.message}" }
      end

      # Write each live Discord/Fluxer adapter's own puppeting cache onto the
      # channel it belongs to, so the dashboard's Connections page can say
      # whether a channel is actually posting under the sender's own name
      # instead of an operator having to guess from silence (#1700). A no-op
      # without a control plane to write into.
      def prune_puppet_status
        return unless control_plane?

        Core::PuppetStatusSweep.new(models: control_plane_models, logger: Log.tagged(logger, "puppet-status"))
                               .run(@adapters)
      rescue StandardError => e
        logger.warn { "puppet status sweep failed: #{e.class}: #{e.message}" }
      end

      def install_signal_handlers
        %w[INT TERM].each do |signal|
          Signal.trap(signal) do
            # Signal handlers run in a restricted context, so the real work is
            # pushed onto another thread rather than done here.
            Thread.new { @waiter&.raise(Interrupt) }
          end
        end
      end

      # Start liveness unless Telegram webhooks already own `$PORT` and `/healthz`.
      # A bind failure logs without stopping relay.
      def start_health_server
        if webhook_transport_active?
          logger.info do
            "health endpoint is served by the Telegram webhook transport on $PORT; " \
              "not starting a second server"
          end
          return
        end

        @health = HealthServer.new(
          liveness: method(:healthy?),
          logger: Log.tagged(logger, "health"),
          port: health_port,
          reload: method(:reload_control_plane),
          reload_secret: internal_secret,
          log_buffer: @log_buffer,
          # Compute stranded and quiet endpoint data for each health request.
          # `endpoints` and `queues` are the outbound half of the same picture:
          # which destinations are failing, and how far behind each room's
          # worker is. Both are read per request rather than sampled.
          stats: lambda {
            {
              "stranded_endpoints" => @dispatcher&.stranded_endpoints || {},
              "quiet_gateways" => quiet_gateway_stats,
              "endpoints" => @endpoint_health&.report || [],
              "queues" => @dispatcher&.queue_depths || {}
            }
          },
          # Build the read-only gap report per request; no Snapshot yields empty.
          gap_report: lambda {
            Core::GapReport.new(storage: @storage, logger: Log.tagged(logger, "gap-report"))
                           .run(adapters: @adapters, snapshot: @registry&.current)
          },
          # The dashboard's Accept button, relayed over the same internal
          # hop the reload nudge and the gap report already use.
          relay_proposal: method(:relay_backfill_proposal)
        ).start
      rescue StandardError => e
        logger.warn { "could not start the health endpoint: #{e.message}" }
        @health = nil
      end

      # The optional dashboard reload secret is never derived from public values.
      def internal_secret = @env["RUBOTTY_INTERNAL_SECRET"]

      # Active Telegram webhooks own `$PORT` and `/healthz`; dormant accounts do
      # not.
      def webhook_transport_active?
        active_accounts.any? do |account|
          !account.dormant? && account.adapter_name == :telegram && account.settings[:transport] == :webhook
        end
      end

      # $PORT is supplied by the platform on both Heroku and Coolify, and is the
      # same variable the webhook transport binds, so the health server answers
      # on the port the platform will probe. Falls back to the shared default.
      def health_port = (@env["PORT"] || HealthServer::DEFAULT_PORT).to_i

      # Seconds an adapter's most recent connect/reconnect failure keeps
      # {#healthy?} false. See {AdapterHealth}.
      def adapter_health_window = (@env["ADAPTER_HEALTH_WINDOW"] || AdapterHealth::DEFAULT_WINDOW).to_i
    end
  end
end
