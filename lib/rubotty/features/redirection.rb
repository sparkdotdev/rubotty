# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Redirection: an operator replies to the first message of a run with
    # "/redirect <channel>" and the last with "/end"; everything between is
    # reposted into the target room, and only once every repost has landed
    # are the originals deleted, so a move that dies never destroys a
    # conversation, only ever duplicates one that somebody can tidy up. It
    # runs as a chain of durable jobs, one step each, so nothing holds a
    # room's worker thread for the minutes a move takes.
    class Redirection < Base
      include AdapterLookup

      NOTICE_NAME = "rubotty"

      # One name for the pending-operation kind, the durable job kind and the
      # feature itself.
      KIND = "redirection"

      # One message the target would not take, as opposed to a target that is
      # not there at all. Only this one is worth skipping past: a room with no
      # reachable endpoint would swallow the entire run a message at a time.
      class Unrelayable < Rubotty::Error; end

      # The per-operator capability an administrator hands out. Deliberately not a
      # member of Core::Moderation::ACTIONS: an entry there would put redirect in
      # every adapter's Capabilities#moderates? and in the moderation parser.
      GRANT = :redirect

      # What each answer from {#refusal_for} says back. Every one of them is
      # spoken, and none of them confirms that a room, a channel or an operator
      # exists, so the same words reach somebody who may act and somebody who may
      # not.
      REFUSALS = {
        no_standing: "You don't have permission to use that command: it needs operator standing.",
        no_grant: "You don't have permission to use that command here: it needs the redirect grant in this room.",
        not_in_room: "I can't move messages from here: this channel isn't in a room yet. " \
                     "Map it on the dashboard, then say /redirect again.",
        no_snapshot: "I can't check that right now: I can't reach the control plane. Try again in a moment.",
        faulted: "Something broke while I was checking whether you can do that, so I haven't moved anything. " \
                 "That is a fault on my side and worth reporting."
      }.freeze

      DEFAULT_INTERVAL_MS = 1_000

      # Most messages one move will carry. A run longer than this is almost
      # certainly a mis-aimed reply rather than a conversation.
      DEFAULT_MAX_MESSAGES = 200

      # How far back to read a platform's own history. Held under the message map's
      # own day so a moved message's relayed copies can still be resolved.
      DEFAULT_HISTORY_LOOKBACK = 20 * 60 * 60

      # Messages to fetch when reading history. The window has to be found INSIDE
      # one contiguous fetch for the run to be provably complete.
      DEFAULT_HISTORY_LIMIT = 500

      def self.feature_name = "redirection"

      def self.description = "/redirect <channel> then /end: move a run of messages into another room."

      def self.default_enabled? = false

      # The shared closing word, claimed here because this is the feature whose
      # own description tells a member to type it.
      def self.command_words = [Core::PendingOperations::SENTINEL]

      # What switching this on for a room actually costs, shown on the dashboard
      # page where an operator ticks it. The duration is read from the retention
      # contract so the disclosure cannot drift from the implementation.
      def self.retention_notice
        "Switching this on for a room makes rubotty keep the text of that room's messages for " \
          "#{ControlPlane::RedirectionWindow::TTL_SECONDS / 86_400} days, which is what a redirect reposts " \
          "from: off Discord there is no other way to move a conversation that came in from another " \
          "platform. A message somebody deletes is dropped from it at once. Switching the feature off " \
          "stops the keeping, and anything already held ages out within the same " \
          "#{ControlPlane::RedirectionWindow::TTL_SECONDS / 86_400} days. PRIVACY.md sets out the rest."
      end

      # A command can only ride a chat message, and the run this collects is chat.
      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                        desc: "seconds a command reply lives before it " \
                                                              "self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the command message itself is removed together " \
                      "with its reply, so the exchange leaves no trace"
          field :interval_ms, :integer, default: DEFAULT_INTERVAL_MS,
                              desc: "milliseconds between two moved messages, in both the " \
                                    "reposting and the deleting pass"
          field :max_messages, :integer, default: DEFAULT_MAX_MESSAGES,
                               desc: "most messages one redirect will move before it refuses"
          field :history_lookback_seconds, :integer, default: DEFAULT_HISTORY_LOOKBACK,
                                           desc: "how far back to read a platform's own history when the " \
                                                 "run predates this session. Only used on a platform that " \
                                                 "can read its history at all."
        end
      end

      # @param registry [ControlPlane::Registry, nil] the live snapshot, read to resolve rooms INSIDE one community
      # @param redirections [ControlPlane::Redirections, nil] the row store
      # @param durable_scheduler [Core::DurableScheduler, nil] runs the paced move
      # @param pending [Core::PendingOperations, nil] the shared /end sentinel
      # @param removal [Watchdog::Removal, nil] the one deletion engine; a move never calls adapter delete directly
      # @param recent [Core::RecentMessages, nil] the window this feature fills as it watches, read back at /end
      # @param window [ControlPlane::RedirectionWindow, nil] the kept record of what this room said
      # @param admin_notifier [ControlPlane::AdminNotifier, nil] where a skipped message is reported
      def initialize(topology:, adapters:, storage:, logger:, registry: nil,
                     redirections: nil, durable_scheduler: nil, pending: nil,
                     ephemeral: nil, cleanup: nil, removal: nil, recent: nil,
                     loop_guard: nil, window: nil, admin_notifier: nil, people: nil)
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @registry = registry
        @people = people
        @admin_notifier = admin_notifier
        @loop_guard = loop_guard
        @redirections = redirections
        @durable = durable_scheduler
        @cleanup = cleanup
        @window = window
        @recent = recent || Core::RecentMessages.new
        @pending = pending || Core::PendingOperations.new(logger: logger)
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
        @removal = removal || Watchdog::Removal.new(
          topology: topology, adapters: adapters, storage: storage, logger: logger,
          source: KIND, ephemeral: ephemeral, cleanup: cleanup
        )
        # Registered on the SHARED sentinel rather than handled inline, so /end
        # closes whatever kind the operator has open here.
        @pending.register(KIND) { |operation, context| close_window(operation, context) }
        @durable&.register(KIND) { |job| run_job(job) }
      end

      attr_reader :logger, :pending

      def call(context)
        word, arguments = command_of(context)
        if word.nil?
          remember(context.message)
          return Outcome.continue([])
        end

        case word
        when "redirect" then handle_redirect(context, arguments)
        when Core::PendingOperations::SENTINEL then handle_end(context)
        else
          # Somebody else's command. Not remembered: a command is never relayed, so
          # moving one would move something that was never in the conversation.
          Outcome.continue([])
        end
      end

      # Re-arm the paced worker for every move left in flight by a previous session:
      # one that died between taking a step and scheduling the next has a live row
      # with no job behind it, and would sit posted-but-not-deleted forever.
      #
      # @return [Integer] moves re-armed
      def resume_all
        return 0 if @redirections.nil? || @durable.nil?

        rows = @redirections.live_everywhere
        rows.each { |row| schedule_next(row) }
        logger.info { "redirection: re-armed #{rows.length} move(s) left in flight" } unless rows.empty?
        rows.length
      rescue StandardError => e
        logger.warn { "redirection: could not re-arm moves in flight: #{e.class}: #{e.message}" }
        0
      end

      # One tick of a move: repost the next message, or delete the next original, or
      # turn the phase over. Raises on a step that did not happen, so the scheduler
      # retries it, the cursor stays where it is, and the deleting phase is not
      # reached. +last_attempt+ says the ladder is spent, which is when a message
      # the target will not take is skipped rather than raised over again.
      #
      # @return [Symbol] what this tick did
      def step(id:, community_id:, last_attempt: false)
        row = @redirections.live(id: id, community_id: community_id)
        return :gone if row.nil?

        plan = @redirections.plan_of(row)
        index = row.step_index.to_i
        outcome = advance(row, plan, index, last_attempt: last_attempt)
        schedule_next(row) unless outcome == :finished
        outcome
      end

      private

      # The phase machine. Posting consumes the whole plan, then the closing line
      # goes in and only THEN does the status become deleting; there is no other
      # transition into it.
      def advance(row, plan, index, last_attempt: false)
        if row.status == ControlPlane::Redirections::POSTING
          return post_step(row, plan, index, last_attempt: last_attempt) if index < plan.length

          post_closing_line(row)
          @redirections.start_deleting(row)
          :deleting
        elsif index < plan.length
          delete_one(row, plan[index])
          @redirections.advance(row, step_index: index + 1)
          :deleted
        else
          @redirections.finish(row)
          logger.info { "redirection #{row.id}: moved #{row.message_count} message(s) to #{row.target_room_id}" }
          :finished
        end
      end

      # A message the target refuses costs that message and nothing more, once
      # the ladder is spent: it is marked in the plan so its original survives
      # the deleting phase, the operators are told which one it was, and the run
      # carries on. Raising here instead is what let one un-relayable photo end
      # a whole move and leave the room half copied.
      def post_step(row, plan, index, last_attempt: false)
        post_one(row, plan[index])
        @redirections.advance(row, step_index: index + 1)
        :posted
      rescue Unrelayable => e
        raise unless last_attempt

        skip_one(row, plan[index], index, e)
        :skipped
      end

      def skip_one(row, item, index, error)
        @redirections.skip(row, index: index)
        logger.warn do
          "redirection #{row.id}: skipped #{item[:native_id]}, it landed nowhere (#{error.message}). " \
            "Its original stays where it is"
        end
        report_skip(row, item)
      end

      # The operators hear about it because nobody else can: the run carries on
      # without the message, and the only other sign is one original left behind
      # in a room everything else has just left.
      def report_skip(row, item)
        return if @admin_notifier.nil?

        @admin_notifier.notify_operators!(
          community_id: row.community_id,
          text: "Redirection #{row.id}: I could not move one message into #{row.target_room_id}, " \
                "so I left it where it was and moved the rest. #{skipped_label(item)} " \
                "My log says what the platform refused."
        )
      rescue StandardError => e
        logger.warn { "redirection #{row.id}: could not tell the operators about a skipped message: #{e.message}" }
      end

      # Enough to find the message that stayed behind, without quoting what it
      # said into an alert that may reach a room rather than a DM.
      def skipped_label(item)
        who = item[:handle] || item[:name] || "someone"
        "It was #{who}'s, id #{item[:native_id]}, and carried " \
          "#{Array(item[:attachments]).length} attachment(s)."
      end

      # Mark the start of a run. Always answers, whether it ran, refused or broke,
      # and a refusal says nothing beyond the fact that the asker may not act.
      def handle_redirect(context, arguments)
        refusal = refusal_for(context)
        return reply(context, REFUSALS.fetch(refusal)) if refusal

        blocked = unavailable_reason
        return reply(context, blocked) if blocked

        target = arguments.join(" ").strip
        return reply(context, "Usage: /redirect <channel>, replying to the first message you want moved.") if target.empty?

        first = reply_ref(context)
        return reply(context, "Reply to the first message of the run, then say /redirect <channel>.") if first.nil?

        unavailable_start = unavailable_start_reason(context, first)
        return reply(context, unavailable_start) if unavailable_start

        room = target_room(context, target)
        return reply(context, "I can't find a room called #{target.inspect} in this community.") if room.nil?
        return reply(context, "Those messages are already in that room.") if room.include?(context.message.origin.id)

        @pending.open(
          kind: KIND, community_id: context.community.id, endpoint_id: context.message.origin.id,
          actor_id: context.message.author&.native_id,
          payload: {
            first_native_id: first.native_id, target_room_id: room.id, target_label: room.label,
            # The /redirect message itself, so the plan can drop it rather than
            # moving the instruction along with the conversation.
            command_native_id: context.message.ref&.native_id
          }
        )
        reply(context, "Marked. Now reply to the last message of the run and say /end.")
      end

      # The sentinel. Nothing about redirection is decided here: the registry runs
      # whichever kind this operator has open in this room.
      def handle_end(context)
        return reply(context, "Only an operator can finish a redirection.") unless authorised?(context)

        result = @pending.close(
          community_id: context.community&.id, endpoint_id: context.message.origin.id,
          actor_id: context.message.author&.native_id, context: context
        )
        case result
        when :none then acknowledge(context, "Nothing here is waiting for /end.")
        when :unhandled
          acknowledge(context, "Something here was waiting for /end, but I can no longer finish it. Start again.")
        end
        Outcome.halt([])
      end

      # The closer registered for this kind: turn the two ends of the window
      # into a plan, persist it, and set the paced worker going.
      def close_window(operation, context)
        last = reply_ref(context)
        return acknowledge(context, "Reply to the last message of the run when you say /end.") if last.nil?

        result = run_window(context, operation.payload[:first_native_id], last.native_id)
        return acknowledge(context, result.reason) if result.reason

        plan = build_plan(context, result.entries, exclude: [operation.payload[:command_native_id]])
        return acknowledge(context, "There is nothing between those two messages to move.") if plan.empty?

        limit = max_messages(context.config)
        if plan.length > limit
          return acknowledge(context, "That run is #{plan.length} messages, and I move at most #{limit} at once.")
        end

        start_move(context, operation, plan, result.note)
      end

      def start_move(context, operation, plan, note)
        row = @redirections.open(
          community_id: context.community.id,
          source_endpoint_id: context.message.origin.id,
          target_room_id: operation.payload[:target_room_id],
          operator: operator_label(context),
          operator_native_id: context.message.author&.native_id,
          plan: plan
        )
        schedule_next(row, delay: 0)
        target = operation.payload[:target_label] || operation.payload[:target_room_id]
        acknowledge(context, "Moving #{plan.length} message(s) to #{target}, one a second. " \
                             "Nothing is deleted here until every one of them has landed.#{note}")
      rescue StandardError => e
        logger.error { "redirection: could not start a move: #{e.class}: #{e.message}" }
        acknowledge(context, "Sorry, I couldn't start that move. Nothing has been touched.")
      end

      # What sits between the two ends of the window, or why it cannot be known,
      # tried across three sources in order of how much each can prove: the
      # platform's own history, the kept {ControlPlane::RedirectionWindow}, then
      # the in-memory ring. Only the kept record covers a conversation relayed in
      # from another platform, so where it exists and cannot cover the run this
      # REFUSES rather than falling back to the ring, which would report a
      # partial move as a complete one.
      Window = Struct.new(:entries, :note, :reason, keyword_init: true)

      def run_window(context, from_native_id, to_native_id)
        history = history_window(context, from_native_id, to_native_id)
        return Window.new(entries: history, note: "") if history

        retained = retained_window(context, from_native_id, to_native_id)
        return retained if retained

        observed = @recent.between(
          endpoint_id: context.message.origin.id,
          from_native_id: from_native_id, to_native_id: to_native_id
        )
        return Window.new(entries: observed, note: observed_note(context)) if observed

        Window.new(reason: no_window_reason(context))
      end

      # The run as the kept record has it, or nil when there is no record to read
      # here at all, which is the only case that falls through to the ring below it.
      # A Window carrying a reason is a REFUSAL.
      def retained_window(context, from_native_id, to_native_id)
        return nil if @window.nil? || context.community.nil?

        room = room_of(context)
        return nil if room.nil?

        entries = @window.for_room(community_id: context.community.id, room_key: room.id)
        return Window.new(reason: nothing_retained_reason) if entries.empty?

        first = retained_index(context, entries, from_native_id)
        last = retained_index(context, entries, to_native_id, last: true)
        if first.nil? || last.nil? || last < first
          return Window.new(reason: retained_gap_reason(first, last))
        end

        Window.new(entries: entries[first..last].map { |entry| entry_of_retained(entry) }, note: "")
      rescue StandardError => e
        logger.warn { "redirection: could not read the kept window on #{context.message.origin.id}: #{e.message}" }
        nil
      end

      # A platform without history cannot recover an unkept starting message at
      # /end. Check it before opening the pending operation, so "Marked" means
      # the first reply is genuinely available to move rather than leading an
      # operator through a run that must later be refused.
      def unavailable_start_reason(context, first)
        return nil if history_capable?(context)
        return nil if @window.nil? || context.community.nil?

        room = room_of(context)
        return nil if room.nil?

        entries = @window.for_room(community_id: context.community.id, room_key: room.id)
        return nothing_retained_reason if entries.empty?

        return nil unless retained_index(context, entries, first.native_id).nil?

        first_missing_reason
      rescue StandardError => e
        logger.warn { "redirection: could not check the marked start on #{context.message.origin.id}: #{e.message}" }
        nil
      end

      # Where one end of the run sits in the kept record, or nil.
      def retained_index(context, entries, native_id, last: false)
        keys = message_keys(context, native_id)
        finder = last ? :rindex : :index
        entries.public_send(finder) do |entry|
          keys.include?([entry.endpoint_id.to_s, entry.native_id.to_s])
        end
      end

      # Every (endpoint, id) pair one message goes by, from the operator's side: the
      # record holds one row per message under the endpoint it was POSTED on, and the
      # message map turns one into the other. Map rows outlive the window by a day.
      def message_keys(context, native_id)
        endpoint_id = context.message.origin.id.to_s
        mine = [endpoint_id, native_id.to_s]
        origins = @storage.origins(Core::MessageRef.new(endpoint_id, native_id.to_s))
        [mine] + origins.map { |ref| [ref.endpoint_id.to_s, ref.native_id.to_s] }
      rescue StandardError
        [[context.message.origin.id.to_s, native_id.to_s]]
      end

      # A kept row in the same shape the watched ring records, so the plan
      # builder never has to know which source it came from.
      def entry_of_retained(entry)
        Core::RecentMessages::Entry.new(
          native_id: entry.native_id, endpoint_id: entry.endpoint_id, author_id: entry.author_id,
          text: entry.body&.text, author_handle: entry.author_handle, author_name: entry.author_name,
          body: entry.body, attachments: entry.attachments, timestamp: entry.created_at
        )
      end

      def room_of(context)
        rooms_of(context.community.id).find { |room| room.include?(context.message.origin.id) }
      end

      def retention_label
        "#{ControlPlane::RedirectionWindow::TTL_SECONDS / 86_400} days"
      end

      # Nothing at all is kept here. The two things that produce it cannot be told
      # apart after the fact, so both are named rather than one being guessed at.
      def nothing_retained_reason
        "There is nothing kept for this room right now. I hold its messages for " \
          "#{retention_label}, and only from the point redirection was switched on, so either this room " \
          "has been quiet that whole time or the feature was only just enabled here. Nothing has been touched."
      end

      # Which of the ways the kept record can fail to cover a run actually happened.
      def retained_gap_reason(first, last)
        if first && last
          "Those two are the wrong way round: the message you said /end on came before the one you marked."
        elsif first.nil? && last.nil?
          "Neither end of that run is in what I still keep for this room. I hold this room's messages for " \
            "#{retention_label}, and both of those are outside it, so " \
            "I would be guessing at what sits between them. Nothing has been touched."
        elsif first.nil?
          first_missing_reason
        else
          "I don't have the message you said /end on. Anything that never left this room is not kept: a " \
            "command, a message a filter removed, or one somebody has since deleted. Nothing has been touched."
        end
      end

      def first_missing_reason
        "The first message of that run is not in what I keep. I hold this room's messages for " \
          "#{retention_label}, so either it is older than that or it was posted before redirection was " \
          "switched on here. Nothing has been touched."
      end

      def observed_note(context)
        return "" if history_capable?(context)

        " I am moving what I watched go past in this room, so anything relayed in from " \
          "another platform stays where it is."
      end

      def no_window_reason(context)
        if history_capable?(context)
          "I can't see both ends of that run in this channel's recent history. " \
            "Either the first message is too far back, or one of the two replies pointed somewhere else."
        else
          "I don't have that run. #{context.message.origin.adapter_name} can't hand me its own history, " \
            "so I can only move messages I watched go past since I last started, and the first one is not " \
            "among them. Nothing has been touched."
        end
      end

      def history_capable?(context)
        adapter = adapter_for(context.message.origin)
        !adapter.nil? && adapter.supports_backfill?
      rescue StandardError
        false
      end

      # The run read straight off the platform, or nil when it cannot be read or does
      # not contain both ends. One bounded call: this runs on the room's worker
      # thread, which is exactly what the paced move must never do.
      def history_window(context, from_native_id, to_native_id)
        endpoint = context.message.origin
        adapter = adapter_for(endpoint)
        return nil if adapter.nil? || !adapter.supports_backfill?

        since = Time.now - history_lookback(context.config)
        messages = adapter.backfill_messages(endpoint, since: since, limit: DEFAULT_HISTORY_LIMIT)
        first = messages.index { |message| message.ref&.native_id.to_s == from_native_id.to_s }
        last = messages.rindex { |message| message.ref&.native_id.to_s == to_native_id.to_s }
        return nil if first.nil? || last.nil? || last < first

        messages[first..last].map { |message| entry_of(message) }
      rescue StandardError => e
        logger.warn { "redirection: could not read history on #{endpoint.id}: #{e.class}: #{e.message}" }
        nil
      end

      # A history message in the same shape the watched window records, so the
      # plan builder never has to know which source it came from.
      def entry_of(message)
        Core::RecentMessages::Entry.new(
          native_id: message.ref&.native_id, endpoint_id: message.ref&.endpoint_id,
          author_id: message.author&.native_id,
          text: message.body.text, author_handle: message.author&.username,
          author_name: message.author&.profile_name, body: message.body,
          attachments: message.attachments, timestamp: message.timestamp
        )
      end

      # Turn the window into the JSON plan a durable job can pick up after a
      # restart: both ends are INSIDE the run, and dropped are the two command
      # messages and anything with neither text nor a file. Each item names the
      # endpoint the message was POSTED on, since the repost wears the author's
      # own platform while the delete goes to the copy that actually exists.
      def build_plan(context, entries, exclude: [])
        skip = exclude.compact.map(&:to_s) + [context.message.ref&.native_id.to_s]
        entries.filter_map do |entry|
          next if skip.include?(entry.native_id.to_s)

          body = entry.body || Core::RichText.plain(entry.text.to_s)
          attachments = Array(entry.attachments)
          next if body.blank? && attachments.empty?

          endpoint_id = (entry.endpoint_id || context.message.origin.id).to_s
          {
            native_id: entry.native_id.to_s,
            endpoint_id: endpoint_id,
            handle: entry.author_handle,
            name: entry.author_name,
            fallback: entry.author_handle || entry.author_name || entry.author_id.to_s,
            author_id: entry.author_id&.to_s,
            platform: platform_of(context, endpoint_id),
            text: body.text,
            spans: body.spans.map { |span| dump_span(span) },
            attachments: attachments.map(&:to_h)
          }
        end
      end

      # The platform a moved message was said on, resolved through this community's
      # own rooms, so it can only ever name an endpoint this community owns. An
      # unmapped endpoint falls back to the platform the operator is on.
      def platform_of(context, endpoint_id)
        endpoint = endpoint_by_id(context.community&.id, endpoint_id)
        (endpoint&.adapter_name || context.message.origin.adapter_name).to_s
      end

      def dump_span(span)
        { kind: span.kind.to_s, from: span.begin_index, to: span.end_index, attributes: span.attributes }
      end

      def load_span(raw)
        Core::Span.new(
          kind: raw[:kind].to_s, begin_index: raw[:from].to_i, end_index: raw[:to].to_i,
          attributes: symbolize(raw[:attributes])
        )
      rescue StandardError
        nil
      end

      # The styled body, rebuilt. Going through Core::RichText rather than emitting
      # the platform's markup is the point of that class: one plan is posted into a
      # Telegram topic, a Discord channel and an IRC channel at the same time.
      def body_of(item)
        spans = Array(item[:spans]).filter_map { |raw| load_span(raw) }
        Core::RichText.new(item[:text].to_s, spans)
      end

      # +endpoint+ decides how a file is named on the way out. Moving within one
      # platform, the platform's own reference is dropped in place of the url:
      # Telegram hands out a getFile link good for about an hour and then cannot
      # fetch it back ("failed to get HTTP URL content"), which is what killed a
      # move carrying a photo, while the file_id beside it never expires and
      # needs no fetch at all. A crossing keeps the url, since a file_id means
      # nothing to the platform on the other side.
      def attachments_of(item, endpoint = nil)
        native = same_platform?(item, endpoint)
        Array(item[:attachments]).filter_map do |raw|
          attachment = Core::Attachment.new(**symbolize(raw))
          native && !attachment.native_ref.to_s.strip.empty? ? attachment.with(url: nil) : attachment
        rescue StandardError
          nil
        end
      end

      def same_platform?(item, endpoint)
        return false if endpoint.nil?

        item[:platform].to_s == endpoint.adapter_name.to_s
      end

      def run_job(job)
        payload = job.payload || {}
        step(id: value_of(payload, :redirection_id), community_id: value_of(payload, :community_id),
             last_attempt: last_attempt?(job))
      end

      # Whether this run is the last the scheduler will give a failing step. The
      # ladder is left to do its work first: a rate limit or a blip clears on a
      # retry, and skipping on the first refusal would drop a message that would
      # have gone through moments later. A scheduler that counts neither keeps
      # the behaviour this replaced: raise, and never skip.
      def last_attempt?(job)
        return false unless job.respond_to?(:attempts) && @durable.respond_to?(:max_attempts)

        max = @durable.max_attempts.to_i
        max.positive? && job.attempts.to_i + 1 >= max
      end

      # Exactly one pending step per move, always. The durable scheduler is
      # at-least-once, so cancelling this move's own pending jobs first is what stops
      # two chains pacing the same move and posting everything twice.
      def schedule_next(row, delay: nil)
        return if @durable.nil?

        interval = delay || interval_seconds(row)
        @durable.cancel(kind: KIND, community: row.community_id.to_s) do |payload|
          value_of(payload, :redirection_id).to_s == row.id.to_s
        end
        @durable.schedule(
          kind: KIND, run_at: Time.now + interval, community: row.community_id.to_s,
          payload: { redirection_id: row.id, community_id: row.community_id }
        )
      end

      # Post one moved message into every endpoint of the target room that can take
      # it. A single endpoint refusing is logged and skipped; only a message that
      # landed NOWHERE raises, because advancing would lose it from the run.
      def post_one(row, item)
        endpoints = target_endpoints(row)
        raise Rubotty::Error, "redirection #{row.id}: no reachable endpoint in #{row.target_room_id}" if endpoints.empty?

        people = people_for(row.community_id)
        landed = endpoints.count { |endpoint| deliver(endpoint, item, people) }
        raise Unrelayable, "redirection #{row.id}: #{item[:native_id]} landed nowhere" if landed.zero?

        landed
      end

      def deliver(endpoint, item, people)
        adapter = adapter_for(endpoint)
        return false if adapter.nil?

        receipt = adapter.deliver(repost_message(endpoint, item, people), endpoint)
        return false if receipt.nil?

        # Noted so the copy coming back off the gateway is recognised as ours
        # and not relayed onward as fresh chat.
        @loop_guard&.note_delivery(endpoint.id, receipt.native_id)
        carry_reactions(adapter, endpoint, item, receipt.native_id)
        true
      rescue StandardError => e
        logger.warn { "redirection: could not post #{item[:native_id]} to #{endpoint.id}: #{e.message}" }
        false
      end

      # What the room said with a reaction rather than a reply, put back on the
      # copy. Placed as the bot, because a reaction carries no author once it
      # is placed: the count and the names cannot cross either way, and the
      # mark itself is what says the room responded at all.
      #
      # Best effort throughout. A redirect that moved the message has done its
      # job, so nothing here is allowed to undo that.
      def carry_reactions(adapter, endpoint, item, native_id)
        return if native_id.to_s.empty?
        return unless adapter.capabilities_for(endpoint).reactions?

        desired = origin_reactions(item)
        return if desired.empty?

        adapter.sync_reactions(endpoint, native_id, desired: desired, previous: [])
      rescue StandardError => e
        logger.debug { "redirection: could not carry reactions onto #{native_id} in #{endpoint.id}: #{e.message}" }
      end

      # Oldest first, which is how Storage#reactions_on answers and what an
      # adapter's own ceiling then reads: Telegram keeps a bot to one, so the
      # first mark the message drew is the one that travels.
      def origin_reactions(item)
        endpoint_id = item[:endpoint_id].to_s
        native_id = item[:native_id].to_s
        return [] if endpoint_id.empty? || native_id.empty?

        @storage.reactions_on(Core::MessageRef.new(endpoint_id, native_id))
      rescue StandardError => e
        logger.debug { "redirection: could not read the reactions on #{item[:native_id]}: #{e.message}" }
        []
      end

      # The moved message as it will be posted on one endpoint. Deliberately not
      # recorded in the message map (the original's coming deletion would
      # propagate into this copy), carries no reply pointer (the parent has a
      # different id in the target room), and puts the whole "wear the author's
      # face" mechanism into the sender label.
      def repost_message(endpoint, item, people)
        Core::Message.new(
          kind: :chat,
          ref: Core::MessageRef.new(endpoint.id, "redirection-#{SecureRandom.hex(4)}"),
          origin: endpoint,
          author: Core::Author.new(username: item[:handle], display_name: item[:name]),
          body: body_of(item),
          attachments: attachments_of(item, endpoint),
          trace: [endpoint.id],
          sender_label: nickname_label(endpoint, item, people) || Core::SenderLabel.new(
            username: item[:handle], platform: item[:platform],
            display_name: item[:name], name: item[:fallback]
          )
        )
      end

      # The author's bridged nickname on +endpoint+'s platform, handle following, the
      # way a relayed copy names them. Nil when they chose none, or for a plan item
      # written before the author's id was kept in it.
      def nickname_label(endpoint, item, people)
        return nil if people.nil? || item[:author_id].to_s.empty? || item[:platform].to_s.empty?

        person = people.by_identity(item[:platform], item[:author_id])
        nickname = person&.nickname_on(endpoint.adapter_name)
        return nil if nickname.nil?

        Core::SenderLabel.nickname(nickname: nickname, username: item[:handle], platform: item[:platform])
      end

      # The moving community's own people, never the deployment-wide union, so a
      # nickname chosen in one community never names the same account in another.
      def people_for(community_id)
        return @people unless @people.respond_to?(:for_community)

        @people.for_community(community_id)
      end

      # The one line that says what happened, in italics, as the bot. Posted through
      # the shared ephemeral primitive with no TTL, which already notes the loop
      # guard, so the line is not re-ingested as chat.
      def post_closing_line(row)
        endpoints = target_endpoints(row)
        return if endpoints.empty?

        @ephemeral.post(endpoints: endpoints, name: NOTICE_NAME, delete_after: 0, body: closing_body(row))
      rescue StandardError => e
        # A lost closing line must not stop the deletes: refusing to advance would
        # leave the run in both rooms because of a cosmetic failure.
        logger.warn { "redirection #{row.id}: could not post the closing line: #{e.message}" }
      end

      # Delete one original, through the one removal engine, which takes the relayed
      # cross-platform copies with it and forgets the map rows, so the run leaves the
      # WHOLE source room.
      #
      # Deleted where it was POSTED, which for a run read out of the kept record is
      # not always where the operator marked it: asking the operator's endpoint to
      # delete it would fail while leaving the real one in place.
      def delete_one(row, item)
        # Never reposted, so this original is the only copy of it anywhere and
        # deleting it would destroy the message rather than move it.
        return if item[:skipped]

        endpoint = endpoint_by_id(row.community_id, item[:endpoint_id]) || source_endpoint(row)
        return if endpoint.nil?

        @removal.remove_everywhere(
          Core::Message.new(
            kind: :delete, origin: endpoint,
            ref: Core::MessageRef.new(endpoint.id, item[:native_id])
          )
        )
      end

      # The rooms of ONE community. Every room lookup in this feature starts here, so
      # a target room id can only ever resolve inside the community that opened the
      # move: there is no fetch-then-check step to forget.
      def rooms_of(community_id)
        snapshot = @registry&.current
        return [] if snapshot.nil?

        snapshot.community_by_id(community_id)&.rooms || []
      rescue StandardError => e
        logger.warn { "redirection: could not resolve rooms for community #{community_id}: #{e.message}" }
        []
      end

      # The room an operator named, matched against the room's own id and label and
      # against each of its endpoints', because "general" is as likely to be the
      # channel's name as the room's.
      def target_room(context, name)
        needle = name.to_s.strip.sub(/\A#/, "").downcase
        return nil if needle.empty?

        rooms_of(context.community.id).find do |room|
          next true if match?(room.id, needle) || match?(room.label, needle)

          room.endpoints.any? { |endpoint| match?(endpoint.id, needle) || match?(endpoint.label, needle) }
        end
      end

      def match?(value, needle) = value.to_s.strip.downcase == needle

      def target_endpoints(row)
        room = rooms_of(row.community_id).find { |candidate| candidate.id == row.target_room_id.to_s }
        room ? room.endpoints.select(&:sends?) : []
      end

      def source_endpoint(row)
        endpoint_by_id(row.community_id, row.source_endpoint_id)
      end

      # One endpoint of ONE community, by id, so a plan cannot name its way out of
      # the community that made it.
      def endpoint_by_id(community_id, endpoint_id)
        return nil if community_id.nil? || endpoint_id.nil?

        rooms_of(community_id).each do |room|
          found = room.endpoint(endpoint_id.to_s)
          return found if found
        end
        nil
      end

      # The closing line itself, italic throughout, with the source room's name
      # carrying a link to that room wherever the platform publishes one: a bare
      # name is something the reader has to go and find, and the same name as a
      # link is one tap back to where the run came from.
      def closing_body(row)
        endpoint = source_endpoint(row)
        name = "##{endpoint&.label || row.source_endpoint_id}"
        text = "(Moved from #{name} by @#{row.operator}.)"
        spans = [Core::Span.new(kind: :italic, begin_index: 0, end_index: text.length)]
        url = room_permalink(endpoint)
        at = text.index(name)
        if url && at
          spans << Core::Span.new(kind: :link, begin_index: at, end_index: at + name.length,
                                  attributes: { url: url })
        end
        Core::RichText.new(text, spans)
      end

      # Where the source room lives on its own platform, for the name in the
      # closing line to point at. Nil wherever the platform publishes no room
      # address, which leaves the name as the plain text it has always been.
      def room_permalink(endpoint)
        return nil if endpoint.nil?

        adapter = adapter_for(endpoint)
        adapter.respond_to?(:room_permalink) ? adapter.room_permalink(endpoint) : nil
      rescue StandardError
        nil
      end

      # Whether the asker may redirect here, for a caller that only needs the yes
      # or no. {#refusal_for} carries the reason.
      def authorised?(context) = refusal_for(context).nil?

      # Why the asker may not redirect here, or nil when they may. Fails closed at
      # every step, and every answer is one {REFUSALS} speaks out loud.
      def refusal_for(context)
        directory = context.operators
        author = context.message.author
        return :no_standing if directory.nil? || author.nil? || context.community.nil?

        operator = directory.resolve(context.message.origin.adapter_name, author.native_id,
                                     username: author.username)
        return :no_standing if operator.nil?
        return :no_snapshot if @registry&.current.nil?

        here = rooms_of(context.community.id).select { |room| room.include?(context.message.origin.id) }
        return :not_in_room if here.empty?

        community_id = context.community.id
        here.any? { |room| operator.may?(GRANT, room.id, community_id: community_id) } ? nil : :no_grant
      rescue StandardError => e
        logger.warn { "redirection: could not check authorisation: #{e.class}: #{e.message}" }
        :faulted
      end

      # Why this feature cannot act at all, or nil when it can. Without a control
      # plane there is nowhere to persist a move; without a durable scheduler nothing
      # to pace it, and a move posted and never deleted is worse than none at all.
      def unavailable_reason
        return "I can't move messages here: there is no control plane connected." if @redirections.nil?
        return "I can't move messages here: this deployment has no durable scheduler to pace them." if @durable.nil?

        nil
      end

      def reply_ref(context)
        ref = context.message.reply_to
        return nil if ref.nil? || ref.native_id.to_s.empty?
        return nil unless ref.endpoint_id == context.message.origin.id

        ref
      end

      def operator_label(context)
        author = context.message.author
        author&.username || author&.any_name || "an operator"
      end

      # Remember one ordinary message, so a later /end has a run to read back.
      def remember(message)
        @recent.record(
          endpoint_id: message.origin.id,
          native_id: message.ref&.native_id,
          author_id: message.author&.native_id,
          text: message.body&.text,
          author_handle: message.author&.username,
          author_name: message.author&.profile_name,
          body: message.body,
          attachments: message.attachments,
          timestamp: message.timestamp
        )
      rescue StandardError => e
        logger.debug { "redirection: could not remember #{message.ref}: #{e.message}" }
      end

      def command_of(context) = CommandWord.parse(context)

      # Say something and swallow the command. Every reply goes through here, so the
      # whole surface obeys one TTL and one rule about taking the invocation with it.
      def reply(context, text)
        acknowledge(context, text)
        Outcome.halt([])
      end

      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "redirection: could not post a reply: #{e.message}" }
        nil
      end

      def interval_seconds(row)
        config = feature_config_for(row)
        value = Integer(config_value(config, :interval_ms).to_s, exception: false)
        (value.nil? || value <= 0 ? DEFAULT_INTERVAL_MS : value) / 1000.0
      end

      # The move's own scope config, read fresh each tick, so an operator who slows
      # the pace down mid-move gets the new pace on the next step.
      def feature_config_for(row)
        snapshot = @registry&.current
        community = snapshot&.community_by_id(row.community_id)
        community&.feature_config(row.source_endpoint_id, self.class.feature_name) || {}
      rescue StandardError
        {}
      end

      def max_messages(config)
        value = Integer(config_value(config, :max_messages).to_s, exception: false)
        value.nil? || value <= 0 ? DEFAULT_MAX_MESSAGES : value
      end

      def history_lookback(config)
        value = Integer(config_value(config, :history_lookback_seconds).to_s, exception: false)
        value.nil? || value <= 0 ? DEFAULT_HISTORY_LOOKBACK : value
      end

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def value_of(payload, key)
        return nil unless payload.is_a?(Hash)

        payload[key.to_s].nil? ? payload[key] : payload[key.to_s]
      end

      def symbolize(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end
    end
  end
end
