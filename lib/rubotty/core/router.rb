# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Core
    # Wires the feature chain (moderation, then the bridge) and hands it to a
    # {Features::Pipeline} to run. Moderation runs first so a command is
    # swallowed before anything could relay it; the bridge runs last as the
    # terminal, default-on feature. With a control-plane +registry+, each
    # feature is additionally gated per (community, channel) by
    # feature_settings.
    class Router
      def initialize(topology:, adapters:, storage:, loop_guard:, logger:,
                     default_display_name: DisplayName.new, ttl: nil,
                     claim_ttl: nil,
                     reply_preview_chars: 100, reply_preview_lines: 2,
                     operators: Moderation::Directory.new, commands: nil, retry_policy: nil,
                     people: Directory.new, suppress_notices: false,
                     cleanup: nil, cleanup_after: 0, acknowledge: false, registry: nil,
                     ephemeral: nil, operator_flow: nil, identity_recorder: nil,
                     identity_directory: nil, warnings: nil, audit: nil, event_scheduling: nil,
                     event_announcer: nil, event_rsvp_ledger: nil, polls: nil, poll_board: nil,
                     poll_ballot: nil, poll_lifecycle: nil, poll_activity: nil,
                     channel_discovery: nil, keyword_watches: nil,
                     guest_invites: nil, scripts: nil, script_pool: nil, script_endpoints: nil,
                     script_memory: nil, script_stats: nil, participation: nil,
                     analytics: nil, durable_scheduler: nil,
                     live_feed: nil, redirections: nil, pending_operations: nil,
                     redirection_window: nil, alerts: nil, admin_notifier: nil,
                     rehoster: nil, upload_tickets: nil, webhooks: nil, link_annotator: nil,
                     participants: nil, bridged_nicknames: nil, relay_fingerprints: nil,
                     translation_relay: nil, room_summaries: nil, semantic_analysis: nil,
                     topic_router: nil, content_policy: nil, relay_outcomes: nil, feature_controls: nil,
                     warning_announcements: nil, member_reports: nil, bot_messages: nil,
                     endpoint_health: nil)
        @topology = topology
        @logger = logger
        # Retained so a reload is observable from the runtime and from specs.
        # NOT handed to any feature: an authorisation check reads the message's
        # own community directory through Features::Context instead.
        @operators = operators
        @people = people

        @pipeline = Features::Pipeline.new(
          features: build_features(
            topology: topology, adapters: adapters, storage: storage, loop_guard: loop_guard,
            logger: logger, default_display_name: default_display_name, ttl: ttl, claim_ttl: claim_ttl,
            reply_preview_chars: reply_preview_chars, reply_preview_lines: reply_preview_lines,
            commands: commands, retry_policy: retry_policy, people: people,
            suppress_notices: suppress_notices, cleanup: cleanup, cleanup_after: cleanup_after,
            acknowledge: acknowledge, ephemeral: ephemeral, operator_flow: operator_flow,
            identity_directory: identity_directory, warnings: warnings, audit: audit,
            event_scheduling: event_scheduling, event_announcer: event_announcer,
            event_rsvp_ledger: event_rsvp_ledger, polls: polls, poll_board: poll_board,
            poll_ballot: poll_ballot, poll_lifecycle: poll_lifecycle, poll_activity: poll_activity,
            channel_discovery: channel_discovery,
            keyword_watches: keyword_watches, guest_invites: guest_invites,
            scripts: scripts, script_pool: script_pool, script_endpoints: script_endpoints,
            script_memory: script_memory, script_stats: script_stats, participation: participation,
            analytics: analytics,
            durable_scheduler: durable_scheduler, live_feed: live_feed, registry: registry,
            redirections: redirections, pending_operations: pending_operations,
            redirection_window: redirection_window, alerts: alerts, admin_notifier: admin_notifier,
            rehoster: rehoster, upload_tickets: upload_tickets, webhooks: webhooks,
            bridged_nicknames: bridged_nicknames,
            link_annotator: link_annotator, participants: participants,
            relay_fingerprints: relay_fingerprints,
            translation_relay: translation_relay,
            room_summaries: room_summaries,
            semantic_analysis: semantic_analysis,
            topic_router: topic_router,
            content_policy: content_policy,
            relay_outcomes: relay_outcomes,
            feature_controls: feature_controls,
            warning_announcements: warning_announcements, member_reports: member_reports,
            bot_messages: bot_messages, endpoint_health: endpoint_health
          ),
          loop_guard: loop_guard,
          logger: logger,
          registry: registry,
          # Without a control plane there is one community, and this is its
          # directory. With one, every message resolves its own instead, so
          # nothing deployment-wide is handed down.
          operators: registry ? nil : operators,
          # Record passive identities when the control plane supplies a recorder.
          identity_recorder: identity_recorder,
          content_policy_observer: content_policy
        )
      end

      attr_reader :topology, :logger, :operators, :people, :redirection

      # Wake one script outside the message pipeline. Called by the runtime when
      # a rubotty.schedule job fires or an async_http answer arrives.
      def wake_script(community:, row:, room_key:, kind:, data: nil, response: nil, generation: 0, wake_reason: nil)
        feature = @pipeline.features.find { |candidate| candidate.is_a?(Features::Scripts) }
        return false if feature.nil?

        feature.wake(community: community, row: row, room_key: room_key, kind: kind,
                     data: data, response: response, generation: generation, wake_reason: wake_reason)
        true
      end

      # Run the pipeline for an inbound platform event.
      # @param message [Message]
      # @return [Array] delivery receipts or moderation results
      def handle(message)
        @pipeline.handle(message)
      end

      private

      # Build moderation first and the terminal bridge last. Scoped settings gate
      # every optional feature.
      def build_features(topology:, adapters:, storage:, loop_guard:, logger:,
                         default_display_name:, ttl:, claim_ttl: nil, reply_preview_chars:, reply_preview_lines:,
                         commands:, retry_policy:, people:, suppress_notices:,
                         cleanup:, cleanup_after:, acknowledge:, ephemeral:, operator_flow: nil,
                         identity_directory: nil, warnings: nil, audit: nil, event_scheduling: nil,
                         event_announcer: nil, event_rsvp_ledger: nil, polls: nil, poll_board: nil,
                         poll_ballot: nil, poll_lifecycle: nil, poll_activity: nil, channel_discovery: nil,
                         keyword_watches: nil, guest_invites: nil, scripts: nil, script_pool: nil,
                         script_endpoints: nil, script_memory: nil, script_stats: nil,
                         participation: nil,
                         analytics: nil, durable_scheduler: nil, live_feed: nil, registry: nil,
                         redirections: nil, pending_operations: nil, redirection_window: nil,
                         alerts: nil, admin_notifier: nil, rehoster: nil, upload_tickets: nil,
                         webhooks: nil, link_annotator: nil, participants: nil, bridged_nicknames: nil,
                         relay_fingerprints: nil, translation_relay: nil, room_summaries: nil, semantic_analysis: nil,
                         topic_router: nil, content_policy: nil, relay_outcomes: nil, feature_controls: nil,
                         warning_announcements: nil, member_reports: nil, bot_messages: nil,
                         endpoint_health: nil)
        features = []

        # Keep recognised moderation verbs refused rather than relayed without a
        # command service. /lock and /unlock need feature_controls to write
        # moderated_room's own config back; nil (no control plane) leaves
        # both refused as unavailable, same as /whitelist below.
        features << Features::Moderation.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          commands: commands, people: people, cleanup: cleanup,
          cleanup_after: cleanup_after, acknowledge: acknowledge, ephemeral: ephemeral,
          audit: audit, feature_controls: feature_controls,
          # A delete through the bot retracts the warning notice paired with
          # that message, which is the only removal a bot is ever told about.
          announcements: warning_announcements,
          # Books a /delete that named a time. Durable rather than in-process,
          # since the times this is for are hours or days out.
          deferrals: durable_scheduler,
          # What /clean sweeps. Nil (no control plane) leaves the verb refused
          # as unavailable: nothing else can find a bot message again.
          bot_messages: bot_messages
        )

        # Gate non-moderator room posts before content features and bridging.
        # /whitelist and /unwhitelist need feature_controls to write back;
        # nil (no control plane) leaves both commands refused as unavailable.
        features << Features::ModeratedRoom.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, audit: audit, feature_controls: feature_controls,
          identity_directory: identity_directory
        )

        # Add warning commands only with the shared service; they remain scoped
        # and operator-gated.
        if warnings
          features << Features::Warnings.new(
            topology: topology, adapters: adapters, logger: logger, storage: storage,
            service: warnings, ephemeral: ephemeral, cleanup: cleanup,
            announcements: warning_announcements
          )
        end

        # A report has nowhere to be kept and nobody to reach without a control
        # plane, so the verb is left unhandled there rather than swallowing a
        # member's report into nothing.
        if member_reports
          features << Features::Reports.new(
            topology: topology, adapters: adapters, logger: logger,
            reports: member_reports, notifier: admin_notifier
          )
        end

        # /identity has nothing to read without a directory: only meaningful
        # with a control plane, same gate identity_directory itself is built
        # behind.
        if identity_directory
          features << Features::IdentityHistory.new(
            topology: topology, adapters: adapters, logger: logger,
            identity_directory: identity_directory, bridged_nicknames: bridged_nicknames,
            ephemeral: ephemeral, cleanup: cleanup
          )
        end

        features << Features::WordFilter.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, warnings: warnings,
          audit: audit, admin_notifier: admin_notifier
        )

        # Only enqueues a background check here; its delete, warning or flag
        # lands later through its own durable job. Sits beside the word
        # filter, the other message-content filter, ahead of spam/link guards.
        features << Features::ContentPolicy.new(
          logger: logger, service: content_policy, ephemeral: ephemeral, cleanup: cleanup,
          adapters: adapters
        )

        # Remove mention spam before relay, using shared filter actions and
        # warnings.
        features << Features::MentionSpam.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, warnings: warnings,
          audit: audit
        )

        # Remove filtered links and invites before relay using shared actions.
        features << Features::LinkFilter.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, warnings: warnings,
          audit: audit, admin_notifier: admin_notifier
        )

        # Remove flood and duplicate spam before relay using shared actions.
        features << Features::AntiSpam.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, warnings: warnings,
          audit: audit
        )

        # Remove later cross-posts through the shared removal flow.
        features << Features::Multipost.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, audit: audit
        )

        # A command typed bare asks for its fields one at a time instead of
        # printing usage, and hands the finished line back to #handle the way a
        # native slash command already arrives. Ahead of every command feature,
        # so a bare invocation is intercepted rather than answered twice.
        features << Features::CommandBuilder.new(
          topology: topology, adapters: adapters, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, run: method(:handle)
        )

        features << Features::Faq.new(
          topology: topology, adapters: adapters, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup
        )

        features << Features::SemanticAnalysis.new(logger: logger, service: semantic_analysis)

        features << Features::TopicRouting.new(logger: logger, service: topic_router)

        # Annotate surviving foreign-language links through durable work.
        features << Features::LinkAnnotation.new(logger: logger, annotator: link_annotator)

        features << Features::OperatorRequests.new(
          topology: topology, adapters: adapters, logger: logger,
          operator_flow: operator_flow, ephemeral: ephemeral, cleanup: cleanup
        )

        # Add scoped greetings for membership events without halting their relay.
        features << Features::Greetings.new(
          topology: topology, adapters: adapters, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup
        )

        # Add scoped public commands with a durable help pointer.
        features << Features::UtilityCommands.new(
          topology: topology, adapters: adapters, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, identity_directory: identity_directory,
          help_pointer: HelpPointer.new(store: storage)
        )

        # Add `/watch` only with the service that persists subscriptions.
        if keyword_watches
          features << Features::KeywordWatch.new(
            topology: topology, adapters: adapters, logger: logger,
            service: keyword_watches, ephemeral: ephemeral, cleanup: cleanup
          )
        end

        # Keep `/nickname` refused rather than relayed when it cannot persist.
        features << Features::Nickname.new(
          topology: topology, adapters: adapters, logger: logger,
          nicknames: bridged_nicknames, registry: registry, ephemeral: ephemeral, cleanup: cleanup
        )

        # Redirections use scoped durable pacing and retain the feature for
        # runtime resume after restart.
        @redirection = Features::Redirection.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          registry: registry, redirections: redirections, durable_scheduler: durable_scheduler,
          pending: pending_operations, ephemeral: ephemeral, cleanup: cleanup,
          loop_guard: loop_guard, window: redirection_window, admin_notifier: admin_notifier,
          people: people
        )
        features << @redirection

        # Always permit `/identify-topic` for channels discovery missed.
        features << Features::IdentifyTopic.new(
          topology: topology, adapters: adapters, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, channel_discovery: channel_discovery
        )

        # `/guest` shares the Guest Portal scope setting and invite service.
        features << Features::GuestCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          guest_invites: guest_invites, ephemeral: ephemeral, cleanup: cleanup
        )

        # `/upload` shares File Rehosting scope settings and issues one-time
        # portal links.
        features << Features::UploadCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          tickets: upload_tickets, ephemeral: ephemeral, cleanup: cleanup
        )

        # The /event command. Shares Features::Events' feature_name, so the
        # same "events" row the reminder engine and EventPolicy read gates
        # this too; a no-op without a control plane.
        features << Features::EventCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          event_scheduling: event_scheduling, ephemeral: ephemeral, cleanup: cleanup
        )

        # Capture event-card reactions and `/rsvp` before reaction bridging.
        features << Features::EventRsvp.new(
          topology: topology, adapters: adapters, logger: logger,
          event_scheduling: event_scheduling, announcer: event_announcer, ledger: event_rsvp_ledger,
          ephemeral: ephemeral, cleanup: cleanup
        )

        # The /events command: bare, lists this room's upcoming events;
        # pointed at an id, shows its roster. Shares Features::Events' own
        # feature_name, everyone's to run; a no-op without a control plane.
        features << Features::EventsCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          event_scheduling: event_scheduling, announcer: event_announcer,
          ephemeral: ephemeral, cleanup: cleanup
        )

        # Let operators send an Event-scoped manual reminder.
        features << Features::EventRemindCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          event_scheduling: event_scheduling, announcer: event_announcer,
          ephemeral: ephemeral, cleanup: cleanup
        )

        # /reschedule edits an event's own row; Events::Lifecycle, not this
        # command, posts the "Event updated" card once it sees the change.
        features << Features::RescheduleCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          event_scheduling: event_scheduling, ephemeral: ephemeral, cleanup: cleanup
        )

        # The /schedule command, behind Features::Events' own
        # allow_schedule_polling checkbox rather than a toggle of its own.
        features << Features::ScheduleCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          polls: polls, board: poll_board, ballot: poll_ballot, lifecycle: poll_lifecycle,
          activity: poll_activity, ephemeral: ephemeral, cleanup: cleanup
        )

        # The /poll command and its reaction and reply capture. Runs before the
        # bridge, so a keycap on the bot's own card never reaches its mirror.
        features << Features::PollCommand.new(
          topology: topology, adapters: adapters, logger: logger,
          polls: polls, board: poll_board, ballot: poll_ballot, lifecycle: poll_lifecycle,
          activity: poll_activity, ephemeral: ephemeral, cleanup: cleanup
        )

        # Detect join bursts and apply a scoped reversible anti-raid lockdown.
        features << Features::AntiRaid.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup, audit: audit
        )

        # Room summaries retain only opted-in room text and enqueue their slow
        # work before terminal Bridge relays the original message.
        features << Features::RoomSummaries.new(
          topology: topology, adapters: adapters, logger: logger,
          summaries: room_summaries, ephemeral: ephemeral, cleanup: cleanup
        )

        # Run scripts after built-in filters and before terminal Bridge, but only
        # when scripting services exist.
        if scripts && script_pool
          # Shared by the three ways a script's words reach a room, so a ping
          # from a rule resolves the same however it was posted.
          script_mentions = script_mention_annotator(people: people,
                                                     identity_directory: identity_directory)
          features << Features::Scripts.new(
            scripts: scripts, pool: script_pool, logger: logger,
            removal: Watchdog::Removal.new(
              topology: topology, adapters: adapters, storage: storage, logger: logger,
              source: "scripts", ephemeral: ephemeral, cleanup: cleanup, audit: audit
            ),
            # The shared primitive as well as the room poster: /debug-lua answers
            # its issuer the way every other command does, not the whole room.
            ephemeral: ephemeral, cleanup: cleanup,
            poster: script_poster(topology: topology, ephemeral: ephemeral, logger: logger,
                                  mentions: script_mentions),
            room_poster: script_room_poster(ephemeral: ephemeral, logger: logger,
                                            mentions: script_mentions),
            endpoint_runner: script_endpoint_runner(scripts: scripts, endpoints: script_endpoints,
                                                    logger: logger),
            registry_for: script_registry_builder(
              logger: logger, scripts: scripts, topology: topology, adapters: adapters,
              ephemeral: ephemeral, audit: audit,
              warnings: warnings, event_scheduling: event_scheduling,
              script_endpoints: script_endpoints, durable_scheduler: durable_scheduler,
              script_memory: script_memory, script_stats: script_stats, analytics: analytics,
              participation: participation, alerts: alerts, admin_notifier: admin_notifier,
              # Provide participant functions only when a directory exists.
              participants: participants, people: people,
              identity_directory: identity_directory
            )
          )
        end

        # Queue scoped translation before terminal Bridge after filters and
        # rewrites.
        features << Features::Translation.new(logger: logger, adapters: adapters, storage: storage,
                                              relay: translation_relay)

        # The last step before Bridge, so every command feature above has had its
        # turn: answer whatever recognised command none of them served, and keep
        # it off the relay.
        features << Features::DisabledCommandNotice.new(
          topology: topology, adapters: adapters, logger: logger,
          ephemeral: ephemeral, cleanup: cleanup
        )

        features << Features::Bridge.new(
          topology: topology, adapters: adapters, storage: storage, loop_guard: loop_guard,
          logger: logger, default_display_name: default_display_name, ttl: ttl, claim_ttl: claim_ttl,
          reply_preview_chars: reply_preview_chars, reply_preview_lines: reply_preview_lines,
          people: people, suppress_notices: suppress_notices, retry_policy: retry_policy,
          ephemeral: ephemeral, cleanup: cleanup,
          identity_directory: identity_directory, live_feed: live_feed,
          redirection_window: redirection_window,
          # File rehosting. Nil without a control plane or a usable object
          # store, which leaves the relay exactly as it was.
          rehoster: rehoster,
          # Webhooks, nil without a control plane. The bridge only ever
          # writes a queued row through this; sending is a durable job in
          # another thread entirely.
          webhooks: webhooks,
          # The per-endpoint content ledger (migration 053): written on arrival
          # and on every successful post. Nil without a control plane, which
          # leaves the relay exactly as it was.
          relay_fingerprints: relay_fingerprints,
          # Where a paced backfill relay reads back what actually arrived. Nil
          # outside a runtime that sweeps, which leaves the relay as it was.
          relay_outcomes: relay_outcomes,
          # Per-destination delivery health, written for EVERY live delivery
          # rather than only a watched one, so a platform that has stopped
          # accepting posts is visible. Nil outside a runtime.
          endpoint_health: endpoint_health, durable_scheduler: durable_scheduler,
          # The warnings ladder service, so an active mute stops the relay
          # regardless of what the platform itself managed. Nil without a
          # control plane, which leaves the relay exactly as it was.
          warnings: warnings
        )

        features
      end

      # Repost rewrites under the source author to every room endpoint, including
      # the deleted source, using loop-safe ephemeral delivery.
      def script_poster(topology:, ephemeral:, logger:, mentions: nil)
        return nil if ephemeral.nil?

        lambda do |context, text|
          endpoints = script_room_endpoints(context, topology)
          return false if endpoints.empty?

          ephemeral.post(endpoints: endpoints,
                         body: script_body(text, mentions: mentions, community: context.community),
                         name: script_post_name(context), delete_after: 0)
          logger&.info { "scripts: reposted a rewritten message to #{endpoints.length} endpoint(s)" }
        end
      end

      # Resolve target endpoints from the invocation room or the woken room.
      def script_room_endpoints(context, topology)
        message = context.respond_to?(:message) ? context.message : nil
        room = message ? script_message_room(context, message, topology) : script_woken_room(context, topology)
        room ? room.endpoints : Array(message&.origin)
      end

      # Resolve message rooms with the Snapshot's room-key rule, falling back to
      # the endpoint index.
      def script_message_room(context, message, topology)
        community = context.respond_to?(:community) ? context.community : nil
        channel = context.respond_to?(:channel) ? context.channel : nil
        key = Scripting::RoomKey.for(channel: channel, community: community)
        if community.respond_to?(:rooms) && !key.empty?
          found = community.rooms.find { |candidate| candidate.id.to_s == key }
          return found if found
        end

        topology&.rooms_for(message.origin.id)&.first
      end

      # Resolve a woken room key inside its OWN community, where a room key is
      # unique; it is not unique across the deployment, and three live
      # communities each own a room keyed "general". Without a community there
      # is nothing that says which one was meant, so this resolves no room at
      # all rather than the first same-named one in the merged topology, which
      # is what a script's post, edit, delete and react all address through.
      def script_woken_room(context, _topology)
        key = context.channel.to_s
        community = context.respond_to?(:community) ? context.community : nil
        return script_woken_room_unscoped(key) unless community.respond_to?(:rooms)

        community.rooms.find { |candidate| candidate.id.to_s == key }
      end

      def script_woken_room_unscoped(key)
        logger&.error do
          "scripts: REFUSED to wake into room #{key.inspect} with no community to scope it by"
        end
        nil
      end

      # Who a script's post appears to be from: whoever wrote the message that
      # triggered it, which is what a rewrite is for and what notify has always
      # done, and the bot when no message caused the run at all.
      def script_post_name(context)
        message = context.respond_to?(:message) ? context.message : nil
        name = message&.author&.display_name.to_s
        name.empty? ? "rubotty" : name
      end

      # Convert script styling sentinels to adapter-renderable rich text only
      # when present.
      def script_body(text, mentions: nil, community: nil)
        string = text.to_s
        return Core::RichText.plain(string) unless Scripting::Markup.styled?(string)

        rich = Scripting::Markup.to_rich_text(string)
        mentions.nil? ? rich : mentions.call(rich, community)
      end

      # Attach trusted per-platform mention ids to script rich text, because
      # script posts bypass Bridge.
      def script_mention_annotator(people: nil, identity_directory: nil)
        return nil if people.nil? && identity_directory.nil?

        lambda do |rich, community|
          spans = rich.spans.select { |span| span.kind == :mention }
          next rich if spans.empty?

          platforms = script_platforms(community)
          next rich if platforms.empty?

          resolved = {}
          Core::RichText.new(rich.text, rich.spans.map do |span|
            next span unless span.kind == :mention

            script_mention_span(span, platforms, resolved, community, people, identity_directory)
          end)
        end
      end

      def script_mention_span(span, platforms, resolved, community, people, directory)
        handle = span.attributes[:username].to_s
        return span if handle.empty?

        ids = platforms.each_with_object({}) do |platform, out|
          native = resolved.fetch([platform, handle]) do
            resolved[[platform, handle]] =
              script_mention_id(platform, handle, community, people, directory)
          end
          out[:"#{platform}_id_for_target"] = native.to_s unless native.nil?
        end
        return span if ids.empty?

        Core::Span.new(kind: span.kind, begin_index: span.begin_index,
                       end_index: span.end_index, attributes: span.attributes.merge(ids))
      end

      # Resolve mentions inside one community so scripts cannot ping foreign
      # handles.
      def script_mention_id(platform, handle, community, people, directory)
        person = scoped_people(people, community)&.by_handle(platform, handle)
        found = person&.id_on(platform)
        return found unless found.nil?
        return nil if directory.nil? || community&.id.nil?

        directory.resolve_unique(community_id: community.id, adapter: platform, handle: handle)
      rescue StandardError
        nil
      end

      # Narrow the router's directory to this community when supported.
      def scoped_people(people, community)
        return people unless people.respond_to?(:for_community)

        people.for_community(community)
      end

      def script_room_key(context)
        Scripting::RoomKey.for(channel: context.channel,
                               community: context.respond_to?(:community) ? context.community : nil)
      end

      # Queue script endpoints off the pipeline, then wake the named callback.
      def script_endpoint_runner(scripts:, endpoints:, logger:)
        return nil if endpoints.nil? || scripts.nil?

        lambda do |community, room_key, request|
          endpoints.enqueue(community, request["endpoint"], request["query"] || {},
                            body: request["body"]) do |job|
            answer = begin
              job.call.to_lua
            rescue StandardError => e
              logger&.warn { "scripts: an endpoint call failed: #{e.class}: #{e.message}" }
              { "ok" => false, "status" => 0, "body" => "", "format" => "text" }
            end
            wake_callback(community, room_key, request, answer, scripts: scripts, logger: logger)
          end
        end
      end

      # Resolved when the answer arrives rather than when it was asked for: the
      # callback may have been switched off while the request was in flight.
      def wake_callback(community, room_key, request, answer, scripts:, logger:)
        name = request["then_call"].to_s
        return if name.empty?

        row = scripts.active(community).find { |candidate| candidate.name.to_s == name }
        if row.nil?
          logger&.info { "scripts: an answer for #{name.inspect} was dropped, it is no longer live" }
          return
        end

        wake_script(community: community, row: row, room_key: room_key,
                    kind: Scripting::Context::HTTP_CALLBACK,
                    data: request["data"], response: answer, generation: request["generation"].to_i)
      end

      # Post a woken script into the room resolved from its durable room key.
      def script_room_poster(ephemeral:, logger:, mentions: nil)
        return nil if ephemeral.nil?

        lambda do |community, room_key, text|
          rooms = community.respond_to?(:rooms) ? community.rooms : []
          room = rooms.find { |candidate| candidate.id.to_s == room_key.to_s }
          if room.nil?
            logger&.info { "scripts: a woken script had nowhere to post, room #{room_key.inspect} is gone" }
            next false
          end

          ephemeral.post(endpoints: room.endpoints,
                         body: script_body(text, mentions: mentions, community: community),
                         name: "rubotty", delete_after: 0)
          true
        end
      end

      # Room labels, not keys: a script is showing these to a person.
      def script_room_labels(community)
        return [] if community.nil? || !community.respond_to?(:rooms)

        community.rooms.map { |room| room.label.to_s.empty? ? room.id.to_s : room.label.to_s }
      rescue StandardError
        []
      end

      def script_platforms(community)
        return [] if community.nil? || !community.respond_to?(:rooms)

        community.rooms.flat_map { |room| room.endpoints.map { |e| e.adapter_name.to_s } }.uniq.sort
      rescue StandardError
        []
      end

      # Return this room's platforms for safe message limits, falling back to the
      # community when it cannot be located.
      def script_room_platforms(community, channel)
        return script_platforms(community) if community.nil? || channel.nil?

        key = Scripting::RoomKey.for(channel: channel, community: community)
        room = community.rooms.find { |candidate| candidate.id.to_s == key }
        return script_platforms(community) if room.nil?

        room.endpoints.map { |endpoint| endpoint.adapter_name.to_s }.uniq.sort
      rescue StandardError
        script_platforms(community)
      end

      # Fold room capabilities so the weakest platform wins; no reachable
      # adapter yields false capabilities.
      def script_room_capabilities(community, channel, adapters)
        found = script_endpoints_of(community, channel).filter_map do |endpoint|
          adapter = adapters&.[]([endpoint.adapter_name, endpoint.account])
          adapter && [adapter, adapter.capabilities_for(endpoint)]
        end
        capability_table(found, script_room_platforms(community, channel))
      rescue StandardError
        capability_table([], [])
      end

      # Resolve room endpoints from community and channel, separately from the
      # invocation-based helper.
      def script_endpoints_of(community, channel)
        return [] if community.nil? || channel.nil? || !community.respond_to?(:rooms)

        key = Scripting::RoomKey.for(channel: channel, community: community)
        room = community.rooms.find { |candidate| candidate.id.to_s == key }
        room ? room.endpoints : []
      end

      # Fold platform capabilities and obtain message limits from Scripting::Markup.
      # @param found [Array<Array(Adapters::Base, Adapters::Capabilities)>]
      def capability_table(found, platforms)
        { "reactions" => everywhere(found) { |_adapter, able| able.reactions? },
          "edit" => everywhere(found) { |_adapter, able| able.edits? },
          "delete" => everywhere(found) { |_adapter, able| able.deletes? },
          "reply" => everywhere(found) { |_adapter, able| able.replies? },
          "threads" => everywhere(found) { |_adapter, able| able.threads? },
          "private_message" => everywhere(found) { |adapter, _able| adapter.supports_admin_dm? },
          "longest_message" => Scripting::Markup.limit_for(platforms) }
      end

      # True only when every platform in the room can do it, and false for a
      # room with no reachable adapter at all.
      def everywhere(found)
        found.any? && found.all? { |adapter, capabilities| yield(adapter, capabilities) }
      end

      def script_features(community, channel)
        return [] if community.nil?

        Features::Catalog.names.select { |name| community.feature_enabled?(channel, name) }
      rescue StandardError
        []
      end

      # `notify` uses the standard bot-post path for the invocation's room.
      def script_notify_handler(context, topology:, ephemeral:, logger:, mentions: nil)
        return nil if ephemeral.nil?

        poster = script_poster(topology: topology, ephemeral: ephemeral, logger: logger, mentions: mentions)
        ->(text) { poster.call(context, text.to_s) }
      end

      # `post` returns all copies of one logical post as an opaque handle.
      def script_post_handler(context, topology:, ephemeral:, logger:, mentions: nil)
        return nil if ephemeral.nil?

        lambda do |request|
          spec = request.is_a?(Hash) ? request : {}
          text = presence(spec["text"])
          return Scripting::Answer.refuse("a post needs something to say") if text.nil?

          endpoints = script_room_endpoints(context, topology)
          return Scripting::Answer.refuse("there is no room to post into") if endpoints.empty?

          group = ephemeral.post(
            endpoints: endpoints, body: script_body(text, mentions: mentions, community: context.community),
            name: script_post_name(context), delete_after: 0,
            reply_to: script_refs_in(spec["reply_to"], endpoints).map(&:last)
          )
          return Scripting::Answer.refuse("no platform in this room took it") unless group.any?

          logger&.info { "scripts: posted to #{group.copies.length} endpoint(s)" }
          Scripting::Handle.of(group.copies.map { |copy| MessageRef.new(copy.endpoint.id, copy.native_id) })
        end
      end

      # Restrict handles to copies in this invocation's own endpoints.
      def script_refs_in(handle, endpoints)
        known = Array(endpoints).to_h { |endpoint| [endpoint.id.to_s, endpoint] }
        Scripting::Handle.refs(handle).filter_map do |ref|
          endpoint = known[ref.endpoint_id]
          endpoint && [endpoint, MessageRef.new(endpoint.id, ref.native_id)]
        end
      end

      # Refuse script edits when no target platform supports them.
      def script_edit_handler(context, topology:, ephemeral:, mentions: nil)
        return nil if ephemeral.nil?

        lambda do |handle, text|
          body = presence(text)
          return Scripting::Answer.refuse("an edit needs the new text") if body.nil?

          targets = script_refs_in(handle, script_room_endpoints(context, topology))
          return Scripting::Answer.refuse("that handle names nothing in this room") if targets.empty?

          rich = script_body(body, mentions: mentions, community: context.community)
          changed = targets.count do |endpoint, ref|
            ephemeral.edit_one(endpoint: endpoint, native_id: ref.native_id, body: rich,
                               name: script_post_name(context))
          end
          changed.positive? ? Scripting::Answer.ok : Scripting::Answer.refuse("nothing here can edit a message")
        end
      end

      def script_delete_handler(context, topology:, ephemeral:)
        return nil if ephemeral.nil?

        lambda do |handle|
          targets = script_refs_in(handle, script_room_endpoints(context, topology))
          return Scripting::Answer.refuse("that handle names nothing in this room") if targets.empty?

          removed = targets.count do |endpoint, ref|
            ephemeral.delete_one(endpoint: endpoint, native_id: ref.native_id)
          end
          removed.positive? ? Scripting::Answer.ok : Scripting::Answer.refuse("nothing here could remove it")
        end
      end

      # Set the bot's desired reaction where room platforms support one.
      def script_react_handler(context, topology:, adapters:, logger:)
        return nil if adapters.nil?

        lambda do |handle, name|
          emoji = presence(name)
          return Scripting::Answer.refuse("a reaction needs an emoji") if emoji.nil?

          targets = script_refs_in(handle, script_room_endpoints(context, topology))
          return Scripting::Answer.refuse("that handle names nothing in this room") if targets.empty?

          placed = targets.count do |endpoint, ref|
            script_place_reaction(adapters, endpoint, ref.native_id, emoji, logger)
          end
          placed.positive? ? Scripting::Answer.ok : Scripting::Answer.refuse("nothing here holds reactions")
        end
      end

      def script_place_reaction(adapters, endpoint, native_id, emoji, logger)
        adapter = adapters[[endpoint.adapter_name, endpoint.account]]
        return false if adapter.nil? || !adapter.capabilities_for(endpoint).reactions?

        adapter.sync_reactions(endpoint, native_id, desired: [Reaction.new(emoji: emoji)], previous: [])
        true
      rescue StandardError => e
        logger&.warn { "scripts: could not react on #{endpoint.id}: #{e.class}: #{e.message}" }
        false
      end

      # Answer recognised moderation permissions from the router's shared
      # directory. Woken runs have no author and return false.
      def script_may_handler(context)
        lambda do |action|
          verb = action.to_s.strip.downcase
          return false unless Moderation::ACTIONS.include?(verb.to_sym)

          message = context.respond_to?(:message) ? context.message : nil
          author = message&.author
          directory = context.operators
          return false if author.nil? || directory.nil? || context.community.nil?

          operator = directory.resolve(message.origin.adapter_name, author.native_id,
                                       username: author.username)
          return false if operator.nil?

          community_id = context.community.id
          rooms_holding(context, message).any? { |room| operator.may?(verb.to_sym, room.id, community_id: community_id) }
        end
      rescue StandardError => e
        logger.warn { "router: script_may_handler failed: #{e.class}: #{e.message}" }
        ->(_action) { false }
      end

      # Return the room scopes holding this message endpoint.
      def rooms_holding(context, message)
        community = context.community
        return [] unless community.respond_to?(:rooms)

        community.rooms.select { |room| room.include?(message.origin.id) }
      rescue StandardError
        []
      end

      def script_warn_handler(context, warnings:, logger:)
        return nil if warnings.nil?

        lambda do |reason|
          # Woken scripts have no author to warn.
          message = context.respond_to?(:message) ? context.message : nil
          author = message&.author
          return false if author.nil?

          warnings.warn(community: context.community, subject: author,
                        origin: message.origin, reason: reason.to_s,
                        issued_by: "operator script")
          logger&.info { "scripts: warned #{author.display_name}: #{reason}" }
          true
        end
      end

      # Record quiet alerts or notify operators for loud ones; records precede
      # any DM attempt.
      def script_alert_handler(context, audit:, alerts: nil, admin_notifier: nil,
                               script_name: nil, room_key: "", logger: nil)
        return nil if audit.nil?

        lambda do |text, mode = nil|
          requested = mode.nil? ? ControlPlane::Alerts::QUIET : mode.to_s
          unless ControlPlane::Alerts::MODES.include?(requested)
            return Scripting::Answer.refuse(
              %(an alert is "#{ControlPlane::Alerts::QUIET}" or "#{ControlPlane::Alerts::LOUD}")
            )
          end

          raise_alert(context, text.to_s, requested, audit: audit, alerts: alerts,
                                                     admin_notifier: admin_notifier,
                                                     script_name: script_name, room_key: room_key,
                                                     logger: logger)
          true
        end
      end

      # Alert failures must not block the message relay path.
      def raise_alert(context, text, mode, audit:, alerts:, admin_notifier:, script_name:, room_key:, logger:)
        community = context.community
        row = alerts&.record(community_id: community&.id, text: text, mode: mode,
                             room_key: room_key.to_s, script: script_name.to_s)
        record_alert_audit(context, text, mode, audit: audit, logger: logger)
        logger&.info { "scripts: #{mode} alert raised: #{text}" }
        return unless mode == ControlPlane::Alerts::LOUD

        alerts&.delivered(row, notify_operators_of(community, text, admin_notifier: admin_notifier, logger: logger))
      rescue StandardError => e
        logger&.warn { "scripts: could not raise an alert: #{e.class}: #{e.message}" }
      end

      def record_alert_audit(context, text, mode, audit:, logger:)
        audit.record(community: context.community&.slug, source: "scripts", action: "alert",
                     channel: context.channel.to_s, reason: text, outcome: mode,
                     actor: "operator script")
      rescue StandardError => e
        logger&.warn { "scripts: could not record the alert in the audit log: #{e.message}" }
      end

      # Reuse AdminNotifier for loud alert DMs and its reachability rules.
      def notify_operators_of(community, text, admin_notifier:, logger:)
        return 0 if admin_notifier.nil? || community.nil?

        delivery = admin_notifier.notify_operators!(
          community_id: community.id, text: "#{community.name}: #{text}"
        )
        logger&.warn { "scripts: loud alert reached no operator of #{community.slug} by DM" } if delivery.none?
        delivery.reached
      rescue StandardError => e
        logger&.warn { "scripts: could not DM the operators about an alert: #{e.message}" }
        0
      end

      # Bound batched whispers to prevent a room-wide unsolicited DM run.
      MAX_WHISPER_RECIPIENTS = 25

      # Public whisper fallbacks self-delete because they may carry private data.
      WHISPER_ROOM_SECONDS = 60

      # Send a private message only through supported platform DM routes.
      # @param community [#id] whose directory the ids are resolved against
      def script_whisper_handler(context, participants:, adapters:, topology:, ephemeral:,
                                 community:, logger: nil)
        return nil if participants.nil? || adapters.nil? || community.nil?

        lambda do |request|
          spec = request.is_a?(Hash) ? request : {}
          # DMs are plain text, so remove styling sentinels before delivery.
          text = presence(Scripting::Markup.strip(spec["text"].to_s))
          return Scripting::Answer.refuse("a whisper needs something to say") if text.nil?

          recipients = script_whisper_recipients(spec["to"])
          return Scripting::Answer.refuse("a whisper needs somebody to say it to") if recipients.empty?
          return Scripting::Answer.refuse("a whisper reaches #{MAX_WHISPER_RECIPIENTS} people at most") if
            recipients.length > MAX_WHISPER_RECIPIENTS

          endpoints = script_room_endpoints(context, topology)
          missed = recipients.reject do |id|
            script_whisper_one(community, id, text, participants: participants, adapters: adapters,
                                                    endpoints: endpoints, logger: logger)
          end
          return Scripting::Answer.ok if missed.empty?

          script_whisper_fallback(missed, recipients.length, text, spec["fallback"],
                                  participants: participants, community: community,
                                  endpoints: endpoints, ephemeral: ephemeral, logger: logger)
        end
      end

      # Accept one id, a list, or participant tables uniformly.
      def script_whisper_recipients(value)
        list = value.is_a?(Array) ? value : [value]
        list.filter_map { |entry| presence(entry.is_a?(Hash) ? entry["id"] : entry) }.uniq
      end

      # Try each identity until one private delivery succeeds.
      def script_whisper_one(community, id, text, participants:, adapters:, endpoints:, logger:)
        participants.identities(community_id: community.id, id: id).any? do |identity|
          # Only use platforms that this room bridges.
          endpoint = endpoints.find { |candidate| candidate.adapter_name.to_s == identity.adapter }
          next false if endpoint.nil?

          script_direct_message(adapters, endpoint, identity.native_id, text, logger)
        end
      rescue StandardError => e
        logger&.warn { "scripts: could not whisper to #{id}: #{e.class}: #{e.message}" }
        false
      end

      def script_direct_message(adapters, endpoint, native_id, text, logger)
        adapter = adapters[[endpoint.adapter_name, endpoint.account]]
        return false if adapter.nil? || !adapter.supports_admin_dm?

        !!adapter.send_admin_dm(native_id, text)
      rescue StandardError => e
        logger&.warn { "scripts: a whisper on #{endpoint.adapter_name} failed: #{e.class}: #{e.message}" }
        false
      end

      # Failed whispers return false with a reason, even after room fallback.
      def script_whisper_fallback(missed, total, text, mode, participants:, community:,
                                  endpoints:, ephemeral:, logger:)
        short = "no private route to #{missed.length} of #{total}"
        return Scripting::Answer.refuse(short) unless mode.to_s == "room"
        return Scripting::Answer.refuse("#{short}, and no room to say it in") if
          ephemeral.nil? || endpoints.empty?

        named = missed.map { |id| script_whisper_label(participants, community, id) }.join(", ")
        ephemeral.post(endpoints: endpoints, body: Core::RichText.plain("#{named}: #{text}"),
                       name: "rubotty", delete_after: WHISPER_ROOM_SECONDS)
        logger&.info { "scripts: a whisper fell back to the room for #{missed.length} recipient(s)" }
        Scripting::Answer.refuse("#{short}, said in the room instead")
      end

      # A name for somebody the fallback is addressing. Plain text rather than a
      # ping: it is going into the room because nothing private could be found,
      # and pinging somebody to tell them so twice over is not an improvement.
      def script_whisper_label(participants, community, id)
        found = participants.identities(community_id: community.id, id: id).first
        Scripting::Markup.strip(found&.display || found&.username || id.to_s)
      end

      # Who sent this, as something a rule can recognise again. Nil on a
      # woken run, where nobody sent anything, the same honesty warn
      # already keeps.
      def script_participant_handler(context, participants:, community:)
        return nil if participants.nil? || community.nil?

        lambda do
          message = context.respond_to?(:message) ? context.message : nil
          author = message&.author
          next nil if author.nil? || author.native_id.to_s.empty?

          found = participants.describe(community_id: community.id,
                                        adapter: message.origin&.adapter_name,
                                        native_id: author.native_id, display: author.any_name)
          next nil if found.nil?

          { "id" => found.id, "display" => Scripting::Markup.strip(found.display.to_s),
            "platform" => found.platform,
            "is_operator" => script_author_is_operator?(context, message) }
        end
      end

      # The same fail closed reading Features::Scripts uses for the payload
      # field, so one invocation cannot be told two different things about the
      # same person.
      def script_author_is_operator?(context, message)
        directory = context.respond_to?(:operators) ? context.operators : nil
        return false if directory.nil? || message.author.nil?

        !directory.resolve(message.origin.adapter_name, message.author.native_id,
                           username: message.author.username).nil?
      rescue StandardError => e
        logger.warn { "router: script_author_is_operator? failed: #{e.class}: #{e.message}" }
        false
      end

      # Resolve typed participant names only when exactly one person matches.
      def script_resolve_participant_handler(participants:, community:)
        return nil if participants.nil? || community.nil?

        lambda do |name|
          found = participants.resolve(community_id: community.id, name: name)
          next nil if found.nil?

          { "id" => found.id, "display" => Scripting::Markup.strip(found.display.to_s) }
        end
      end

      # Return a participant mention span, or empty text when unknown here.
      def script_mention_participant_handler(context, participants:, community:)
        return nil if participants.nil? || community.nil?

        lambda do |id|
          found = participants.identities(community_id: community.id, id: id)
          next "" if found.empty?

          preferred = script_mention_preference(context, found)
          handle = preferred&.username
          next Scripting::Markup.mention(handle) unless handle.nil?

          Scripting::Markup.strip(preferred&.display.to_s)
        end
      end

      # Prefer a handle from the source platform, then any handle.
      def script_mention_preference(context, identities)
        message = context.respond_to?(:message) ? context.message : nil
        here = message&.origin&.adapter_name.to_s
        identities.find { |identity| identity.adapter == here && identity.username } ||
          identities.find(&:username) || identities.first
      end

      # Deferred work, and only ever an endpoint call. Scheduling a script
      # re-run would let a rule schedule itself with no good bound on the
      # recursion, so "call this whitelisted endpoint in N seconds" is the same
      # trust as enqueue with a clock on it.
      MAX_SCHEDULE_DELAY = 30 * 24 * 60 * 60

      # Nothing useful needs to come back sooner, and a floor is what stops a
      # script scheduling itself into a busy loop.
      MIN_SCHEDULE_DELAY = 10

      # How many times a chain may wake another. Deep enough for "ask, wait,
      # reveal, wait, next question", shallow enough that a runaway stops on
      # its own rather than on somebody noticing.
      MAX_GENERATIONS = 5

      # Most wakes one repeat books. A ten round game needs ten and an
      # hourly reminder for a day needs twenty four, so this is generous
      # for what a repeat is for and still a number of rows somebody can
      # look at.
      MAX_REPEAT_BOOKINGS = 100

      # What a made up tag looks like. Long enough that two scripts booking at
      # the same instant do not collide, short enough to read in a log line.
      TAG_BYTES = 6

      # Schedule bounded script wakes. Repeats book sibling jobs rather than a
      # recursive chain.
      def script_schedule_handler(community, scripts, scheduler, options)
        return nil if scripts.nil? || scheduler.nil? || community.nil?

        lambda do |request|
          spec = request.is_a?(Hash) ? request : {}
          # Return refusals so scripts need not catch exceptions.
          return Scripting::Answer.refuse("a scheduled chain stops after #{MAX_GENERATIONS} hops") if
            options[:generation] >= MAX_GENERATIONS

          name = presence(spec["script"]) || options[:script_name]
          return Scripting::Answer.refuse("schedule needs a script to wake") if name.nil?

          # Validate now, then revalidate when the job fires.
          return Scripting::Answer.refuse("no script called #{name}") unless scripts.find_by_name(community, name.to_s)

          tag = schedule_tag(spec)
          return Scripting::Answer.refuse("that is not a tag name") if tag.nil?

          times = schedule_times(spec)
          return Scripting::Answer.refuse(times) if times.is_a?(String)

          times.each do |run_at|
            scheduler.schedule(kind: Features::Scripts::LATER_KIND, run_at: run_at,
                               community: community.slug.to_s,
                               payload: schedule_payload(community, name, tag, spec, options))
          end
          tag
        end
      end

      # Cancel only this script's tagged bookings in this room.
      def script_unschedule_handler(community, scheduler, options)
        return nil if scheduler.nil? || community.nil?

        lambda do |tag|
          wanted = presence(tag)
          return 0 if wanted.nil?

          scheduler.cancel(kind: Features::Scripts::LATER_KIND, community: community.slug.to_s) do |payload|
            payload["tag"].to_s == wanted &&
              payload["booked_by"].to_s == options[:script_name].to_s &&
              payload["room_key"].to_s == options[:room_key].to_s
          end.to_i
        end
      end

      def schedule_payload(community, name, tag, spec, options)
        { "community" => community.slug.to_s, "script" => name.to_s,
          "room_key" => options[:room_key].to_s,
          "data" => spec["data"],
          # Retain the booking script separately from the script being woken.
          "booked_by" => options[:script_name].to_s, "tag" => tag,
          "generation" => options[:generation] + 1 }
      end

      # A tag the script chose, or one made up. The same name shape a memo
      # bucket takes, for the same reason: it is a name a script writes down and
      # later looks up, so it may not be arbitrary text.
      def schedule_tag(spec)
        wanted = presence(spec["tag"])
        return SecureRandom.hex(TAG_BYTES) if wanted.nil?

        wanted.match?(Scripting::Memory::BUCKET_PATTERN) ? wanted.downcase : nil
      end

      # Every time this booking fires, or a sentence saying why it will not.
      def schedule_times(spec)
        return [schedule_at(spec)] if spec["every"].nil?

        every = Integer(spec["every"], exception: false) || 0
        return "a repeat needs until_at, so it stops on its own" if spec["until_at"].nil?
        return "a repeat cannot be more often than every #{MIN_SCHEDULE_DELAY} seconds" if
          every < MIN_SCHEDULE_DELAY

        repeat_times(spec, every)
      end

      def repeat_times(spec, every)
        first = schedule_at(spec)
        stop = Time.at(Integer(spec["until_at"], exception: false).to_i)
        latest = Time.now + MAX_SCHEDULE_DELAY
        stop = latest if stop > latest
        return "that repeat would have finished before it started" if stop < first

        wanted = (((stop - first) / every).floor + 1)
        return "that repeat asks for #{wanted} wakes, and #{MAX_REPEAT_BOOKINGS} is the most. " \
               "Raise every, or bring until_at closer." if wanted > MAX_REPEAT_BOOKINGS

        Array.new(wanted) { |index| first + (index * every) }
      end

      # after: seconds from now, at: an absolute epoch. Two keys rather than one
      # that has to guess, because a bare 30 is indistinguishable from an epoch
      # of 30 and the wrong reading is months out.
      def schedule_at(spec)
        now = Time.now
        seconds = if spec["at"]
                    Integer(spec["at"], exception: false).to_i - now.to_i
                  else
                    Integer(spec["after"], exception: false) || 0
                  end
        now + seconds.clamp(MIN_SCHEDULE_DELAY, MAX_SCHEDULE_DELAY)
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      # Bind remembered values to the script and room, with private or shared
      # buckets supplied in one table.
      def script_remember_handler(memory, row, room_key)
        return nil if memory.nil? || row.nil?

        lambda do |*args|
          spec = script_memo_spec(args)
          script_answer(memory.remember(row, room_key, bucket: spec["bucket"], key: spec["key"],
                                                       value: spec["value"], ttl: spec["ttl"]))
        end
      end

      def script_recall_handler(memory, row, room_key)
        return nil if memory.nil? || row.nil?

        lambda do |*args|
          spec = script_memo_spec(args)
          memory.recall(row, room_key, bucket: spec["bucket"], key: spec["key"])
        end
      end

      def script_forget_handler(memory, row, room_key)
        return nil if memory.nil? || row.nil?

        lambda do |*args|
          spec = script_memo_spec(args)
          memory.forget(row, room_key, bucket: spec["bucket"], key: spec["key"])
        end
      end

      # Change community-scoped totals atomically in the database.
      def script_add_handler(memory, row)
        return nil if memory.nil? || row.nil?

        lambda do |*args|
          spec = script_memo_spec(args)
          # A missing increment means one.
          by = spec.key?("by") ? spec["by"] : 1
          if by.is_a?(Hash)
            script_answer(memory.add_many(row, bucket: spec["bucket"], by: by,
                                               floor: spec["floor"], ceiling: spec["ceiling"]))
          else
            script_answer(memory.add(row, bucket: spec["bucket"], key: spec["key"], by: by,
                                          floor: spec["floor"], ceiling: spec["ceiling"]))
          end
        end
      end

      def script_move_handler(memory, row)
        return nil if memory.nil? || row.nil?

        lambda do |*args|
          spec = script_memo_spec(args)
          floor = spec.key?("floor") ? spec["floor"] : 0
          script_answer(memory.move(row, bucket: spec["bucket"], from: spec["from"], to: spec["to"],
                                         amount: spec["amount"], floor: floor))
        end
      end

      # Reading a kept bucket whole. `top` sorts in the database, so a
      # leaderboard is one call rather than fetching every key and sorting in
      # Lua, which is what an invocation's budget cannot afford.
      def script_top_handler(memory, row)
        return nil if memory.nil? || row.nil?

        lambda do |bucket, limit = nil|
          memory.top(row, bucket, limit || Scripting::Memory::DEFAULT_TOP_LIMIT)
        end
      end

      def script_keys_handler(memory, row)
        return nil if memory.nil? || row.nil?

        lambda do |bucket, prefix = nil|
          memory.keys(row, bucket, prefix.to_s)
        end
      end

      def script_entries_handler(memory, row)
        return nil if memory.nil? || row.nil?

        lambda do |bucket, prefix = nil, limit = nil|
          memory.entries(row, bucket, prefix.to_s, limit || Scripting::Memory::DEFAULT_KEYS_LIMIT)
        end
      end

      # Report progress toward the durable key cap before storage refuses writes.
      def script_count_keys_handler(memory, row)
        return nil if memory.nil? || row.nil?

        lambda do |bucket = nil|
          memory.count_keys(row, presence(bucket))
        end
      end

      # Record script statistics for analytics, separate from dashboard
      # aggregates.
      def script_increment_stat_handler(stats, community, room_key)
        return nil if stats.nil? || community.nil?

        lambda do |stat, row, step = 1|
          script_answer(stats.increment(community: community, stat: stat, row: row,
                                        step: step, room_key: room_key))
        end
      end

      # A table, so naming which of three things you meant is never positional.
      def script_record_stat_handler(stats, community, room_key)
        return nil if stats.nil? || community.nil?

        lambda do |spec|
          table = spec.is_a?(Hash) ? spec : {}
          script_answer(stats.record(community: community, stat: table["stat"], row: table["row"],
                                     value: table["value"], room_key: room_key))
        end
      end

      # Read only, and only the aggregate numbers the dashboard already shows.
      # Anything per person would hand a script a profiling surface nothing else
      # in this design gives it.
      def script_community_stats_handler(analytics, community)
        return nil if analytics.nil? || community.nil?

        lambda do
          report = analytics.overview(community: community)
          next {} unless report.is_a?(Hash)

          # Flatten numeric section values into one script-readable table.
          report.each_with_object({}) do |(section, body), out|
            next unless body.is_a?(Hash)

            body.each do |key, value|
              out["#{section}_#{key}"] = value if value.is_a?(Numeric)
            end
          end
        rescue StandardError
          {}
        end
      end

      # Memory answers in plain Ruby, since Ruby calls it too. This is the
      # boundary, so this is where "false and a reason" becomes two Lua return
      # values rather than one truthy table.
      def script_answer(result)
        return Scripting::Answer.ok if result == true
        return Scripting::Answer.refuse(result[1]) if result.is_a?(Array) && result[0] == false

        result
      end

      # Normalise memo arguments to a table for the store's own validation.
      def script_memo_spec(args)
        table = args.first
        table.is_a?(Hash) ? table : {}
      end

      # Queue whitelisted HTTP off-pipeline and wake callbacks for either
      # success or failure.
      def script_async_http_handler(community, scripts, endpoints, options)
        return nil if endpoints.nil? || scripts.nil? || community.nil?

        lambda do |request|
          spec = request.is_a?(Hash) ? request : {}
          return Scripting::Answer.refuse("a callback chain stops after #{MAX_GENERATIONS} hops") if
            options[:generation] >= MAX_GENERATIONS

          name = presence(spec["endpoint"])
          return Scripting::Answer.refuse("async_http needs an endpoint") if name.nil?

          row = endpoints.find(community, name)
          return Scripting::Answer.refuse("no endpoint called #{name}") if row.nil?
          return Scripting::Answer.refuse("#{name} is a GET endpoint, so it takes no body") if
            spec["body"] && row.http_method.to_s.upcase != "POST"

          callback = presence(spec["then_call"])
          return Scripting::Answer.refuse("no script called #{callback}") if
            callback && scripts.find_by_name(community, callback).nil?

          options[:requests] << { "endpoint" => name, "query" => spec["query"] || {},
                                  "body" => spec["body"], "then_call" => callback,
                                  "data" => spec["data"], "generation" => options[:generation] + 1 }
          true
        end
      end

      # Upcoming events, with starts_in seconds so a rule can say "within the
      # hour" without a clock, and rsvp counts rather than attendee lists.
      def script_events(event_scheduling, community)
        return [] if event_scheduling.nil? || community.nil?

        Scripting::Context.new.events_payload(event_scheduling.upcoming(community: community))
      rescue StandardError
        []
      end

      # Build community-scoped host functions. Omit functions lacking services.
      def script_registry_builder(logger:, scripts: nil, topology: nil, adapters: nil, ephemeral: nil,
                                  warnings: nil, audit: nil, event_scheduling: nil, script_endpoints: nil,
                                  durable_scheduler: nil, script_memory: nil, script_stats: nil,
                                  analytics: nil, alerts: nil, admin_notifier: nil,
                                  participants: nil, people: nil,
                                  identity_directory: nil, participation: nil)
        # Build mention annotation once; it receives a community per invocation.
        mentions = script_mention_annotator(people: people, identity_directory: identity_directory)
        lambda do |context, script_row = nil|
          config = context.community&.feature_config(context.channel, "word_filter") || {}
          classifier = Scripting::Classifier.new(config: config, logger: logger)
          community = context.community
          channel = context.channel
          # Bind memo handlers to the invocation's own room.
          memo_room = script_room_key(context)
          # Always expose styling helpers because they require no services.
          handlers = Scripting::HostFunctions.markup_handlers
          Scripting::HostFunctions.registry(handlers: handlers.merge({
            "classify" => ->(text) { classifier.classify(text) },
            "offending_spans" => ->(text) { classifier.spans(text) },
            "link_verdict" => lambda { |text|
              Features::LinkFilter.verdict_for(text, community&.feature_config(channel, "link_filter") || {})
            },
            "feature_enabled" => lambda { |name|
              !community.nil? && !!community.feature_enabled?(channel, name.to_s)
            },
            "rooms" => -> { script_room_labels(community) },
            "platforms" => -> { script_platforms(community) },
            "room_capabilities" => -> { script_room_capabilities(community, channel, adapters) },
            "features" => -> { script_features(community, channel) },
            # Fold script text with the same rule as word filtering.
            "fold" => Scripting::HostFunctions.fold_handler,
            "chars" => Scripting::HostFunctions.chars_handler,
            "notify" => script_notify_handler(context, topology: topology, ephemeral: ephemeral,
                                              logger: logger, mentions: mentions),
            "post" => script_post_handler(context, topology: topology, ephemeral: ephemeral,
                                          logger: logger, mentions: mentions),
            "edit" => script_edit_handler(context, topology: topology, ephemeral: ephemeral,
                                          mentions: mentions),
            "delete" => script_delete_handler(context, topology: topology, ephemeral: ephemeral),
            "react" => script_react_handler(context, topology: topology, adapters: adapters, logger: logger),
            "whisper" => script_whisper_handler(context, participants: participants, adapters: adapters,
                                                topology: topology, ephemeral: ephemeral,
                                                community: community, logger: logger),
            "participant" => script_participant_handler(context, participants: participants,
                                                        community: community),
            "resolve_participant" => script_resolve_participant_handler(participants: participants,
                                                                        community: community),
            "mention_participant" => script_mention_participant_handler(context, participants: participants,
                                                                        community: community),
            "name_participants" => script_name_participants_handler(context, participants: participants,
                                                                     community: community),
            "may" => script_may_handler(context),
            "warn" => script_warn_handler(context, warnings: warnings, logger: logger),
            "alert" => script_alert_handler(context, audit: audit, alerts: alerts,
                                            admin_notifier: admin_notifier,
                                            script_name: script_row&.name, room_key: memo_room,
                                            logger: logger),
            "events" => -> { script_events(event_scheduling, community) },
            "async_http" => script_async_http_handler(
              community, scripts, script_endpoints,
              { generation: context.respond_to?(:script_generation) ? context.script_generation.to_i : 0,
                requests: (context.respond_to?(:script_requests) ? context.script_requests : []) }
            ),
            "schedule" => script_schedule_handler(
              community, scripts, durable_scheduler,
              { room_key: memo_room, script_name: script_row&.name,
                generation: context.respond_to?(:script_generation) ? context.script_generation.to_i : 0 }
            ),
            "unschedule" => script_unschedule_handler(
              community, durable_scheduler,
              { room_key: memo_room, script_name: script_row&.name }
            ),
            "truncate" => lambda { |text|
              Scripting::Markup.truncate(text, script_room_platforms(community, channel))
            },
            "escape" => ->(text) { Scripting::Markup.strip(text) },
            "increment_stat" => script_increment_stat_handler(script_stats, community, memo_room),
            "record_stat" => script_record_stat_handler(script_stats, community, memo_room),
            "community_stats" => script_community_stats_handler(analytics, community),
            "remember" => script_remember_handler(script_memory, script_row, memo_room),
            "recall" => script_recall_handler(script_memory, script_row, memo_room),
            "forget" => script_forget_handler(script_memory, script_row, memo_room),
            # Kept values are community scoped, not room scoped.
            "add" => script_add_handler(script_memory, script_row),
            "move" => script_move_handler(script_memory, script_row),
            "top" => script_top_handler(script_memory, script_row),
            "keys" => script_keys_handler(script_memory, script_row),
            "entries" => script_entries_handler(script_memory, script_row),
            "count_keys" => script_count_keys_handler(script_memory, script_row),
            # A script reads only the YAML data bound to its own row.
            "yaml_data" => -> { scripts&.yaml_data(script_row) },
            "random" => Scripting::HostFunctions.random_handler,
            "shuffle" => Scripting::HostFunctions.shuffle_handler,
            "log" => Scripting::HostFunctions.log_handler(logger: logger, script_name: "operator script"),
            "build" => -> { { "version" => Rubotty::VERSION, "commit" => Core::BuildInfo.commit.to_s } }
          }.merge(script_participation_handlers(participation, community, memo_room, script_row,
                                                scripts, durable_scheduler)).compact))
        end
      end

      # Share bounded game rounds by room, leaving prompts and answers to scripts.
      def script_participation_handlers(participation, community, room_key, script_row, scripts,
                                        durable_scheduler)
        return {} if participation.nil? || community.nil?

        room = { community: community, room_key: room_key }
        {
          "session" => -> { participation.session(**room) },
          "round" => -> { participation.round(**room) },
          "close_session" => -> { script_answer(participation.close_session(**room)) },
          "open_session" => lambda { |spec = nil|
            table = spec.is_a?(Hash) ? spec : {}
            script_answer(participation.open_session(**room, kind: table["kind"],
                                                     label: table["label"].to_s))
          },
          "open_round" => script_open_round_handler(participation, community, room_key, script_row,
                                                     scripts, durable_scheduler),
          "close_round" => lambda { |spec = nil|
            table = spec.is_a?(Hash) ? spec : {}
            script_answer(participation.close_round(**room, data: table["data"]))
          }
        }
      end

      # Open a round, then schedule and validate its durable close callback.
      def script_open_round_handler(participation, community, room_key, script_row, scripts, durable_scheduler)
        lambda do |spec = nil|
          table = spec.is_a?(Hash) ? spec : {}
          close_after = table["close_after"]
          on_close = table["on_close"]
          if !close_after.nil? && scripts && !scripts.find_by_name(community, on_close.to_s)
            next Scripting::Answer.refuse("no script called #{on_close}")
          end

          result = participation.open_round(community: community, room_key: room_key,
                                            close_after: close_after, on_close: on_close,
                                            data: table["data"])
          next script_answer(result) if result.is_a?(Array)

          book_round_close(participation, community, room_key, script_row, durable_scheduler,
                           result, close_after, on_close, table["data"]) unless close_after.nil?
          script_answer(true)
        end
      end

      def book_round_close(participation, community, room_key, script_row, durable_scheduler,
                           round_id, close_after, on_close, data)
        return if durable_scheduler.nil?

        fresh = participation.round(community: community, room_key: room_key)
        run_at = fresh && fresh["closes_at"] ? Time.at(fresh["closes_at"]) : (Time.now + close_after.to_i)
        durable_scheduler.schedule(
          kind: Features::Scripts::LATER_KIND, run_at: run_at, community: community.slug.to_s,
          payload: { "community" => community.slug.to_s, "script" => on_close.to_s,
                    "room_key" => room_key.to_s, "data" => data,
                    "booked_by" => script_row&.name.to_s, "tag" => "round-#{round_id}",
                    "generation" => 0, "reason" => ControlPlane::Participation::ROUND_CLOSE_REASON,
                    "round_id" => round_id }
        )
      end

      # Display names for a batch of participant ids in one call, the same
      # preference a mention uses to pick which of several accounts to name:
      # the platform this message arrived on first, then whichever account
      # has a name at all. An id naming nobody here is left out rather than
      # answered with something misleading.
      NAME_PARTICIPANTS_LIMIT = 50

      def script_name_participants_handler(context, participants:, community:)
        return nil if participants.nil? || community.nil?

        lambda do |ids|
          list = ids.is_a?(Hash) ? ids.values : Array(ids)
          list.first(NAME_PARTICIPANTS_LIMIT).each_with_object({}) do |id, out|
            found = participants.identities(community_id: community.id, id: id.to_s)
            next if found.empty?

            preferred = script_mention_preference(context, found)
            out[id.to_s] = Scripting::Markup.strip(preferred&.display.to_s)
          end
        end
      end
    end
  end
end
