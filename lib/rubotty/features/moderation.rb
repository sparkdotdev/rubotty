# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Moderation commands, as a feature. A command message is executed across the
    # room and is always consumed here, whether it ran, was refused or found
    # nothing to act on, so a verb never continues to the bridge and shows up on
    # the other platform as chat. Whatever stopped it is said in the room it was
    # typed in. Authorisation is per room, because an operator may be scoped.
    class Moderation < Base
      include AdapterLookup

      Execution = Struct.new(:adapter, :target, :command, :native_id, keyword_init: true)

      # The word that widens a sweep to every room the community owns.
      SWEEP_EVERYWHERE = /\Aall\z/i

      # The verbs that take a room to work on rather than a message: bare they
      # mean the room they were typed in, "all" means every room here, and
      # anything else names one, so a mess can be cleared from wherever the
      # operator happens to be rather than only from inside it.
      SWEEPING_ACTIONS = %i[unpinall clean].freeze

      def self.feature_name = "moderation"

      def self.description = "In-chat moderation commands: delete, pin, ban, kick, mute."

      def self.default_enabled? = true

      def self.observes = %i[chat]

      # Every verb this feature answers in chat. Not the programmatic ones:
      # `unban` and `unpinall` are actions the framework issues, never words.
      def self.command_words = Core::Moderation::TYPED_ACTIONS.map(&:to_s)

      # The per-scope config shape. Unset, the acknowledgement window falls back to
      # the bridge-wide `commands.cleanup_after`.
      def self.config_schema
        Config::Schema.define do
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                        desc: "seconds an accepted command waits before " \
                                                              "acting, and how long its self-deleting " \
                                                              "acknowledgement then lives. 0 acts at once " \
                                                              "and leaves a persistent summary."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the command message itself is removed together " \
                      "with its acknowledgement, so the exchange leaves no trace"
          field ControlPlane::AdminNotifier::ALERT_ROOM_FIELD, :string,
                desc: "room key every operator alert is posted into instead of a DM each: content policy " \
                      "flags, removal alerts, undelivered warnings, loud script alerts and the operator " \
                      "announcements below. One copy, one shared thread, and it reaches an operator the " \
                      "bot cannot open a DM with. The room must be operator only, which cannot be verified " \
                      "here: an alert carries message text, an author's name and sometimes a link, so a " \
                      "room a member can read leaks exactly what the DM keeps narrow. Left unset, or naming " \
                      "a room that no longer exists or cannot be posted to, everything falls back to DMs."
          field ControlPlane::OperatorAnnouncer::FIELD, :boolean, default: true,
                desc: "DM this community's operators when one of them warns, bans, deletes, " \
                      "vindicates or otherwise moderates here, so nobody is surprised by what a " \
                      "colleague did. Covers every operator verb, not just this feature's own."
        end
      end

      # @param commands [Core::Commands] the parser and summariser
      # @param cleanup [Core::Scheduler, nil] the shared grace-period scheduler
      # @param cleanup_after [Integer] grace period in seconds, 0 for immediate
      # @param feature_controls [ControlPlane::FeatureControls, nil] where /lock
      #   and /unlock write moderated_room's own config back; nil (no control
      #   plane) leaves both refused as unavailable
      def initialize(topology:, adapters:, storage:, logger:, commands:,
                     people: Core::Directory.new, cleanup: nil, cleanup_after: 0,
                     acknowledge: false, ephemeral: nil, audit: nil, recent: nil,
                     feature_controls: nil, announcements: nil, deferrals: nil,
                     bot_messages: nil)
        super()
        @topology = topology
        @announcements = announcements
        @adapters = adapters
        @storage = storage
        @logger = logger
        @commands = commands
        @people = people
        @feature_controls = feature_controls
        # What /clean sweeps: every permanent post EphemeralMessage wrote down.
        # Nil (no control plane) leaves the verb refused as unavailable, since
        # there is no other way to find a bot message again.
        @bot_messages = bot_messages
        # The durable scheduler, so a /delete booked for Tuesday survives a
        # restart. Nil leaves the verb immediate, which is what it always was.
        @deferrals = deferrals
        # Every executed command is recorded as a durable, queryable event. A
        # no-op Null sink by default; the runtime injects the real store.
        @audit = audit || Core::AuditLog::Null.new
        # With a scheduler and a positive period, an accepted command acknowledges,
        # waits, acts, then removes both. Without either it acts at once and the
        # acknowledgement persists.
        @cleanup = cleanup
        @cleanup_after = cleanup_after.to_i
        # Off by default, so a feature built without a notice sink stays silent.
        @acknowledge = acknowledge
        # Posts, edits and self-deletes the acknowledgement, and links grouped bot
        # messages so a `/delete` on the startup banner reaches every platform.
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
        # A bounded memory of recent messages per endpoint, so a reply-less
        # /delete can find its target by text or as the issuer's own last message.
        @recent = recent || Core::RecentMessages.new
      end

      attr_reader :logger

      def call(context)
        return handle_unconfigured(context) if @commands.nil?

        # The community's own operator directory, so a grant never crosses a
        # tenant. Nil without a control plane, which keeps the config path as it was.
        command = @commands.parse(context.message, directory: context.operators)
        if command.is_a?(Core::Commands::Refusal)
          # Kept out of the bridge either way: relaying a refused verb told the
          # other platform what somebody tried to do, and saying nothing at all
          # left the issuer unable to tell the bot from a dead one.
          remember(context.message)
          answer(context.message.origin, command.message, resolve_ack_ttl(context),
                 reply_to: Core::CommandAck.reply_to(context.message), also_delete: refusal_pairing(context.message))
          return Outcome.halt([])
        end
        # lock and unlock act on the room itself, not a message or a person, so
        # they skip the per-endpoint adapter dispatch every other verb uses.
        return Outcome.halt(refuse_unknown_room(command, context)) if command && unknown_sweep_target?(command, context)
        return Outcome.halt(handle_clean(command, context)) if command && command.action == :clean
        return Outcome.halt(handle_room_command(command, context)) if command && room_command?(command)

        return Outcome.halt([]) if command && defer_delete(command, context)

        # The community slug rides along so the executed action can be recorded
        # against it in the audit log.
        if command
          return Outcome.halt(
            handle_command(
              command, context.community&.slug, resolve_ack_ttl(context),
              community_id: context.community&.id,
              pair_command: Core::CommandAck.delete_command?(context.config),
              people: people_for(context.community),
              acknowledge: resolve_acknowledge(context)
            )
          )
        end

        remember(context.message)
        Outcome.continue([])
      end

      # A /delete naming a time removes its target then rather than now. Only
      # the reply form: without one, /delete already reads its argument as the
      # TEXT of the message to find, so a time there would silently retarget a
      # command that has always meant something else (#1921).
      #
      # A time that does not parse is not an error either. It falls through to
      # the immediate delete, which is what every argument to /delete did
      # before this existed.
      def defer_delete(command, context)
        return false unless command.action == :delete && !command.target_ref.nil?
        # No durable scheduler, so there is nowhere to book it. Falls through to
        # the immediate delete rather than halting, which would leave the verb
        # doing nothing at all on a deployment without a control plane.
        return false if @deferrals.nil?

        at = deletion_time(command, context)
        return false if at.nil?

        booked = Core::DeferredDeletion.book(
          scheduler: @deferrals, community: context.community&.slug, origin: command.origin,
          ref: command.target_ref, at: at, issuer: command.issuer&.to_s
        )
        answer_deferred(context, at, booked)
        true
      end

      # Nil unless the words after the verb name an instant this feature can
      # book: a future one, read through the same vocabulary /event and
      # /schedule take their start times from.
      def deletion_time(command, context)
        text = Array(command.arguments).join(" ").strip
        return nil if text.empty?

        at = ControlPlane::RelativeTime.parse(text, timezone: deletion_zone(context), now: Time.now)
        return nil if at.nil? || at <= Time.now

        at
      end

      # The same zone /event and /schedule read a bare wall-clock time in, so
      # "tuesday 5pm" means the same hour whichever command an operator types.
      def deletion_zone(context)
        RoomTimezone.infer(context, logger: logger)
      rescue StandardError
        nil
      end

      # The shape handle_immediate_command answers in, since nothing here waits
      # on a grace period either: a self-deleting notice on the standard
      # acknowledgement window, posted while the invocation is still there to
      # hang off, and then the invocation taken away directly. Pairing it with
      # the notice instead left a bare command sitting in the room wherever the
      # window was zero, because nothing reaps the group a pairing rides on.
      def answer_deferred(context, at, booked)
        text = if booked.nil?
                 "I could not book that deletion, so the message is still there."
               else
                 "I will delete that message at #{at.utc.strftime("%Y-%m-%d %H:%M UTC")}."
               end
        answer(context.message.origin, text, Core::CommandAck::DEFAULT_TTL_SECONDS,
               reply_to: Core::CommandAck.reply_to(context.message))
        return unless Core::CommandAck.delete_command?(context.config)

        delete_native(context.message.origin, context.message.ref&.native_id)
      end

      # No commands service at all: recognise the verb anyway, the same word
      # {Core::Commands} would have read, so a real one is refused rather than
      # relayed and anything else is left for {Bridge} to carry as chat.
      def handle_unconfigured(context)
        action = moderation_word(context)
        return Outcome.continue([]) if action.nil?

        remember(context.message)
        refusal = Core::Commands::Refusal.new(reason: :unavailable, action: action)
        answer(context.message.origin, refusal.message, resolve_ack_ttl(context),
               reply_to: Core::CommandAck.reply_to(context.message))
        Outcome.halt([])
      end

      # The moderation verb this message opens with, or nil: not chat, no
      # configured prefix, or a word {Core::Moderation} does not know at all.
      def moderation_word(context)
        return nil unless context.message.kind == :chat

        word, = CommandWord.parse(context)
        return nil if word.nil?

        action = word.to_sym
        Core::Moderation.known?(action) ? action : nil
      end

      def room_command?(command) = Core::Moderation.room_action?(command.action)

      def remember(message)
        @recent.record(
          endpoint_id: message.origin.id,
          native_id: message.ref&.native_id,
          author_id: message.author&.native_id,
          text: message.body&.text
        )
      rescue StandardError => e
        logger.debug { "could not remember #{message.ref}: #{e.message}" }
      end

      # The acknowledgement TTL for this scope: the room or channel's own
      # feature_settings value first, then the issuing community's own commands
      # block, then the bridge-wide grace period.
      def resolve_ack_ttl(context)
        default = commands_setting(context.community, "cleanup_after", @cleanup_after)
        Core::CommandAck.ttl_seconds(context.config, default: default)
      end

      # Whether an accepted command in this scope posts its "done"
      # acknowledgement: the issuing community's own commands block wins over
      # the bridge-wide default computed at boot.
      def resolve_acknowledge(context)
        commands_setting(context.community, "acknowledge", @acknowledge)
      end

      # A community's own commands block, seeded verbatim from static config at
      # creation time, wins over the bridge-wide default when it names the key.
      # community is nil (or a bare id, without a control plane's own Snapshot
      # object) wherever there is nothing to read an override from.
      def commands_setting(community, key, default)
        return default unless community.respond_to?(:settings)

        value = community.settings.dig("commands", key.to_s)
        value.nil? ? default : value
      end

      # The ref to reply to for a refusal raised inside {#handle_command}, which
      # only ever holds the parsed {Moderation::Command} rather than the whole
      # invocation {CommandAck.reply_to} normally checks.
      def reply_ref(command)
        ref = command&.source_ref
        ref && !ref.native_id.to_s.empty? ? ref : nil
      end

      # The people a command issued here may name: the issuing community's own
      # directory, since matching against the deployment-wide union could
      # return another community's row and act on the wrong account. Falls
      # back to the deployment-wide directory only when no community was
      # resolved (no control plane).
      def people_for(community)
        return @people unless @people.respond_to?(:for_community)

        @people.for_community(community)
      end

      # The most messages one /clean removes. A sweep of a whole community can
      # name thousands, and every one is a separate API call on a bot token
      # shared with the relay, so the run is bounded and says what it left.
      CLEAN_LIMIT = 250

      # /clean removes what rubotty itself posted and never took back: the
      # summaries, banners and announcements standing in the room. Only what
      # {ControlPlane::BotMessages} wrote down, because that record is the
      # only way back to them: Telegram lets a bot read none of its own
      # history, so a message missing from there cannot be found at all.
      def handle_clean(command, context)
        ttl = resolve_ack_ttl(context)
        source = reply_ref(command)
        origin = command.origin
        room_key = context.community&.room_key_of(context.channel)
        return refuse_clean(origin, ttl, source) if @bot_messages.nil? || room_key.nil?

        unless command.issuer&.may?(:clean, room_key, community_id: context.community&.id)
          answer(origin, "Sorry, you are not allowed to run /clean here.", ttl, reply_to: source)
          return []
        end

        rooms = sweep_rooms(command, context)
        announce_clean(command, context, rooms, where: sweep_label(command, rooms))
      end

      def refuse_clean(origin, ttl, source)
        answer(origin, "Sorry, /clean is not available on this bridge.", ttl, reply_to: source)
        []
      end

      # The rooms this /clean covers, each already checked against the issuer's
      # own grant, so a scoped operator sweeps only what they were scoped to.
      def sweep_rooms(command, context)
        community_id = context.community&.id
        candidate_rooms(command, community_id)
          .select { |room| command.issuer.may?(:clean, room.id, community_id: community_id) }
      end

      # How the acknowledgement names where it worked: the room it was typed
      # in, one named room, or a count. A count only for "all", since naming
      # thirty five rooms back at somebody tells them nothing.
      def sweep_label(command, rooms)
        target = sweep_target(command)
        return "#{rooms.length} room(s)" if SWEEP_EVERYWHERE.match?(target)
        return "this room" if target.empty?

        rooms.first&.label.to_s.empty? ? target : rooms.first.label
      end

      # Delete every recorded message in +rooms+, stopping at {CLEAN_LIMIT}.
      # @return [Array(Integer, Integer, Integer)] removed, missed and left
      def sweep_bot_messages(rooms, community_id)
        removed = 0
        missed = 0
        left = 0
        rooms.each do |room|
          entries = @bot_messages.for_room(community_id: community_id, room_key: room.id)
          entries.each do |entry|
            if removed + missed >= CLEAN_LIMIT
              left += 1
              next
            end

            delete_recorded(room, entry) ? removed += 1 : missed += 1
          end
        end
        [removed, missed, left]
      end

      # Remove one recorded message and forget it. A message already gone is a
      # success: /clean promises the room is clear, not that it did the
      # deleting, and keeping the row would only have it retried forever.
      def delete_recorded(room, entry)
        endpoint = room.endpoint(entry.endpoint_id) || @topology.endpoint(entry.endpoint_id)
        adapter = endpoint && adapter_for(endpoint)
        return false if adapter.nil? || !adapter.capabilities_for(endpoint).deletes?

        adapter.delete(endpoint, entry.native_id)
        forget_recorded(entry)
        true
      rescue StandardError => e
        logger.debug { "clean: could not delete #{entry.native_id} on #{entry.endpoint_id}: #{e.message}" }
        return false unless gone?(e)

        forget_recorded(entry)
        true
      end

      def forget_recorded(entry)
        @bot_messages.forget(endpoint_id: entry.endpoint_id, native_id: entry.native_id)
      end

      # Whether the platform is saying the message is not there rather than
      # that it would not let us, which is the one failure worth forgetting.
      def gone?(error) = /not found|unknown message|message to delete/i.match?(error.message.to_s)

      def announce_clean(command, context, rooms, where:)
        removed, missed, left = sweep_bot_messages(rooms, context.community&.id)
        text = clean_outcome(removed, missed, left, where)
        ttl = Core::CommandAck::DEFAULT_TTL_SECONDS
        notice = deliver_notice(command.origin, text, delete_after: ttl, reply_to: reply_ref(command),
                                                      acknowledge: resolve_acknowledge(context))
        @cleanup.after(ttl) { notice.delete_now } if @cleanup && notice&.any?
        delete_native(command.origin, command.source_ref&.native_id) if Core::CommandAck.delete_command?(context.config)
        logger.info { "moderation #{command} by #{issuer_label(command)}: #{text}" }
        record_clean_audit(command, removed, context.community&.slug)
        []
      end

      # Says what is left as well as what went, since the two reasons a message
      # stays (the run hit its ceiling, or the platform refused) need different
      # things from the operator: running it again, or fixing a permission.
      def clean_outcome(removed, missed, left, where)
        return "Nothing of mine left to clear in #{where}." if removed.zero? && missed.zero? && left.zero?

        parts = ["Cleared #{removed} of my own message(s) from #{where}."]
        parts << "#{missed} could not be deleted; I may not have permission there." if missed.positive?
        parts << "#{left} still to go, so run /clean again." if left.positive?
        parts.join(" ")
      end

      def record_clean_audit(command, removed, community)
        @audit.record(
          community: community, source: "moderation", action: "clean",
          adapter: command.origin.adapter_name.to_s, channel: command.origin.id,
          actor: issuer_label(command), outcome: removed.to_s, metadata: { removed: removed }
        )
      rescue StandardError => e
        logger.warn { "moderation: could not record the audit event: #{e.message}" }
      end

      # lock and unlock: no reply, no argument, no adapter round trip, just a
      # FeatureControls write over moderated_room's own config for whatever
      # room this message's own channel maps to. The action grant itself was
      # already checked by {Core::Commands#parse}; what is left here is the
      # per-room scoping every other verb gets from {#authorised_rooms}.
      def handle_room_command(command, context)
        ttl = resolve_ack_ttl(context)
        source = reply_ref(command)
        origin = command.origin
        action = command.action

        room_key = context.community&.room_key_of(context.channel)
        if context.community.nil? || @feature_controls.nil? || room_key.nil?
          answer(origin, "Sorry, /#{action} is not available on this bridge.", ttl, reply_to: source)
          return []
        end
        unless command.issuer.may?(action, room_key, community_id: context.community.id)
          answer(origin, "Sorry, you are not allowed to run /#{action} here.", ttl, reply_to: source)
          return []
        end

        ok = action == :lock ? lock_room(context.community, room_key) : unlock_room(context.community, room_key)
        outcome = ok ? "Successfully #{Core::Moderation.past(action)}." : "Could not #{action} this room right now."

        success_ttl = Core::CommandAck::DEFAULT_TTL_SECONDS
        notice = deliver_notice(origin, outcome, delete_after: success_ttl, reply_to: source,
                                                  acknowledge: resolve_acknowledge(context))
        @cleanup.after(success_ttl) { notice.delete_now } if @cleanup && notice&.any?
        delete_native(origin, command.source_ref&.native_id) if Core::CommandAck.delete_command?(context.config)
        logger.info { "moderation #{command} by #{issuer_label(command)}: #{outcome}" }
        record_room_audit(command, room_key, ok, context.community&.slug)
        []
      end

      # /lock enables moderated_room if it was not already and sets locked
      # true, preserving any approved_users already configured.
      def lock_room(community, room_key)
        @feature_controls.enable(community: community, selector: room_key,
                                  feature: Features::ModeratedRoom.feature_name)
        @feature_controls.set(community: community, selector: room_key, feature: Features::ModeratedRoom.feature_name,
                               key: Features::ModeratedRoom::LOCKED_FIELD, value: true)
        true
      rescue StandardError => e
        logger.warn { "moderation: could not lock #{room_key}: #{e.message}" }
        false
      end

      # /unlock always clears locked. A real prior whitelist is left exactly
      # as it was; an empty one means /lock enabled moderated_room fresh with
      # nothing configured underneath, so unlock disables it again rather
      # than leaving the room moderated with nobody on the list at all.
      def unlock_room(community, room_key)
        result = @feature_controls.set(
          community: community, selector: room_key, feature: Features::ModeratedRoom.feature_name,
          key: Features::ModeratedRoom::LOCKED_FIELD, value: false
        )
        approved = Array(result.first&.dig(:config, Features::ModeratedRoom::APPROVED_USERS_FIELD.to_s))
        if approved.empty?
          @feature_controls.disable(community: community, selector: room_key,
                                     feature: Features::ModeratedRoom.feature_name)
        end
        true
      rescue StandardError => e
        logger.warn { "moderation: could not unlock #{room_key}: #{e.message}" }
        false
      end

      def record_room_audit(command, room_key, ok, community)
        @audit.record(
          community: community, source: "moderation", action: command.action.to_s,
          adapter: command.origin.adapter_name.to_s, channel: command.origin.id,
          actor: issuer_label(command), outcome: ok ? "done" : "failed", metadata: { room_key: room_key }
        )
      rescue StandardError => e
        logger.warn { "moderation: could not record the audit event: #{e.message}" }
      end

      # Execute a command on every endpoint in the room that can carry it out and
      # acknowledge it to the issuer. +ttl+ is this scope's acknowledgement
      # window, +people+ the directory a cross-platform target resolves against,
      # captured so the deferred path acts on the view it acknowledged, and
      # +acknowledge+ whether this scope wants the "done" notice at all.
      # @param community [String, nil] the slug, for the audit row
      # @param community_id [Integer, nil] the community the room keys are keyed
      #   in; nil denies every scoped grant rather than matching one
      def handle_command(command, community = nil, ttl = @cleanup_after, community_id: nil,
                         pair_command: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                         people: @people, acknowledge: @acknowledge)
        # A nil result means nothing matched or the asker may not delete it.
        origin = command.origin
        action = command.action
        source = reply_ref(command)
        command = resolve_targeting(command)
        if command.nil?
          answer(origin, "/#{action} found nothing here that you can act on.", ttl, reply_to: source)
          return []
        end

        rooms = authorised_rooms(command, community_id)
        if rooms.empty?
          logger.warn do
            "#{issuer_label(command)} may not #{command.action} in any room reachable from #{command.origin.id}"
          end
          answer(origin, "Sorry, you are not allowed to run /#{action} here.", ttl, reply_to: source)
          return []
        end

        if @cleanup && ttl.positive?
          handle_deferred_command(command, rooms, community, ttl, pair_command: pair_command, people: people,
                                                                    acknowledge: acknowledge)
        else
          handle_immediate_command(command, rooms, community, pair_command: pair_command, people: people,
                                                                acknowledge: acknowledge)
        end
      end

      # Turn a reply-less /delete into one with a concrete target, or nil when
      # there is nothing to act on or the asker is not allowed to. Ownership is
      # checked against the id the buffer recorded, in the origin's own id space.
      def resolve_targeting(command)
        return command unless command.action == :delete && command.target_ref.nil?

        entry = case command.targeting
                when :own_last then @recent.last_by(endpoint_id: command.origin.id, author_id: command.issuer_native_id)
                when :text then @recent.match_text(endpoint_id: command.origin.id, text: command.arguments.join(" ").strip)
                end
        return nil if entry.nil?

        # An operator may delete anyone's; a non-operator only their own.
        own = !entry.author_id.nil? && entry.author_id == command.issuer_native_id
        return nil unless command.issuer || own

        command.with_target_ref(Core::MessageRef.new(command.origin.id, entry.native_id), text: entry.text)
      end

      # The rooms reachable from the origin that this command may act in, checked
      # per room because an operator may be scoped to some of them. A command with
      # no operator issuer is an authorised self delete.
      def authorised_rooms(command, community_id)
        rooms = candidate_rooms(command, community_id)
        if command.issuer
          rooms.select { |room| command.issuer.may?(command.action, room.id, community_id: community_id) }
        elsif command.action == :delete
          rooms
        else
          []
        end
      end

      # Normally the rooms this endpoint is in. `/unpinall all` is the one verb
      # that reaches past them, to every room the community owns, because what
      # it exists to clear was pinned across all of them at once and retyping it
      # in each of dozens of rooms is not a cleanup anybody performs. The
      # per-room grant check in {#authorised_rooms} still applies to each, so a
      # scoped operator sweeps only the rooms they were already scoped to.
      def candidate_rooms(command, community_id)
        target = sweep_target(command)
        return @topology.rooms_for(command.origin.id) if target.empty?
        return community_rooms(community_id) if SWEEP_EVERYWHERE.match?(target)

        [named_room(target, community_id)].compact
      end

      # What the operator typed after the verb, joined back up: a room label
      # can hold spaces, and the parser has already split them apart.
      def sweep_target(command)
        return "" unless SWEEPING_ACTIONS.include?(command.action)

        Array(command.arguments).join(" ").strip
      end

      # A room by its key or its label, matched forgivingly: case, and the
      # difference between "example-travel" and "example travel",
      # are not things somebody typing on a phone should have to get right.
      def named_room(name, community_id)
        wanted = comparable_room_name(name)
        return nil if wanted.empty?

        community_rooms(community_id).find do |room|
          comparable_room_name(room.id) == wanted || comparable_room_name(room.label) == wanted
        end
      end

      def comparable_room_name(value) = value.to_s.downcase.gsub(/[\s_-]+/, " ").strip

      # Named a room, and it is not one. Answered separately from "you may not"
      # so a typo does not read as a permission the operator has lost.
      def unknown_sweep_target?(command, context)
        target = sweep_target(command)
        return false if target.empty? || SWEEP_EVERYWHERE.match?(target)

        named_room(target, context.community&.id).nil?
      end

      def refuse_unknown_room(command, context)
        answer(command.origin, "I do not know a room called \"#{sweep_target(command)}\" here.",
               resolve_ack_ttl(context), reply_to: reply_ref(command))
        []
      end

      # Every room the community owns. nil is the config-file path, where every
      # room's community_id is nil too; a control-plane room always has one, so
      # this never crosses a tenant and an unresolved community matches nothing
      # rather than everything.
      def community_rooms(community_id)
        @topology.rooms.select { |room| room.community_id == community_id }
      end

      # The default path: act now, acknowledge with a self-deleting summary.
      def handle_immediate_command(command, rooms, community = nil,
                                   pair_command: Core::CommandAck::DELETE_COMMAND_DEFAULT, people: @people,
                                   acknowledge: @acknowledge)
        results = execute_rooms(rooms, command, people)
        # Posted before the invocation goes, so the summary still has the message
        # it hangs off. Self-deletes after the standard ack window, same as the
        # grace-period path's edited ack, so the instant-action path leaves no
        # permanent audit trail cluttering the room either.
        ttl = Core::CommandAck::DEFAULT_TTL_SECONDS
        notice = deliver_notice(command.origin, command_outcome(command, results),
                                delete_after: ttl, reply_to: reply_ref(command), acknowledge: acknowledge)
        @cleanup.after(ttl) { notice.delete_now } if @cleanup && notice&.any?
        delete_native(command.origin, command.source_ref&.native_id) if pair_command
        forget_ephemeral_group(command)
        logger.info do
          "moderation #{command} by #{issuer_label(command)}: #{results.map(&:to_s).join(", ")}"
        end
        record_audit(command, results, community)
        results
      end

      # The grace period path: acknowledge, wait, act, edit the acknowledgement
      # with the outcome, then remove both it and the command message.
      def handle_deferred_command(command, rooms, community = nil, ttl = @cleanup_after,
                                  pair_command: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                                  people: @people, acknowledge: @acknowledge)
        ack = deliver_notice(
          command.origin,
          Core::CommandAck.pending("#{Core::Moderation.gerund(command.action)} on all services", ttl),
          # The ack's whole lifetime. Stamping the durable horizon at ttl would fire
          # the crash-safe backstop while the ack is still wanted.
          delete_after: ttl * 2,
          # Linking the invocation to the ack's group means every removal path
          # reaches it when the in-process path below never runs.
          also_delete: pair_command ? command_pairing(command) : [],
          reply_to: reply_ref(command),
          acknowledge: acknowledge
        )
        @cleanup.after(ttl) do
          perform_deferred_command(command, rooms, ack, community, ttl, pair_command: pair_command, people: people)
        end
        # Nothing has happened yet; the outcome is edited into the ack later.
        []
      end

      # The refs to remove alongside a deferred acknowledgement: the command
      # message itself, unless this scope opted out.
      def command_pairing(command)
        return [] if command.source_ref.nil? || command.source_ref.native_id.nil?

        [command.source_ref]
      end

      # A refusal never becomes a {Moderation::Command}, so there is no
      # {#command_pairing} to reuse; the refused message itself is still right
      # there on +message+, which is what the usual accepted-command flow
      # removes alongside its own ack.
      def refusal_pairing(message)
        return [] if message.ref.nil? || message.ref.native_id.nil?

        [message.ref]
      end

      # Runs on the scheduler thread once the grace period has elapsed. +ack+ is
      # the ephemeral acknowledgement group, or nil when acknowledgements are off.
      def perform_deferred_command(command, rooms, ack, community = nil, ttl = @cleanup_after,
                                   pair_command: Core::CommandAck::DELETE_COMMAND_DEFAULT, people: @people)
        results = execute_rooms(rooms, command, people)
        # The command message is removed alongside its ack unless this scope
        # opted out with delete_command_message: false.
        delete_native(command.origin, command.source_ref&.native_id) if pair_command
        # A `/delete` on a grouped bot message already removed every copy, so drop
        # the durable pending-deletion rows too.
        forget_ephemeral_group(command)

        logger.info do
          "moderation #{command} by #{issuer_label(command)}: #{results.map(&:to_s).join(", ")}"
        end

        if ack
          ack.edit(command_outcome(command, results))
          @cleanup.after(ttl) { ack.delete_now }
        end
        record_audit(command, results, community)
        results
      end

      # The command acknowledgement tells an issuer where a copy remains, so a
      # failed delete is visible in the room instead of only in the log.
      def command_outcome(command, results)
        done = completed_count(command, results)
        attempted = attempted_count(results)
        skipped = results.select { |result| result.status == :skipped }
        unsupported = results.select { |result| result.status == :unsupported }
        # Nothing attempted and nothing skipped, only unsupported: no endpoint in
        # the room even implements the action, which reads nothing like success.
        all_unsupported = attempted.zero? && skipped.empty? && !unsupported.empty?

        base = if all_unsupported
                 "No connected service supports #{command.action}."
               elsif skipped.empty?
                 "Successfully #{Core::Moderation.past(command.action)} on #{done}/#{attempted} connected services."
               else
                 "Successfully #{Core::Moderation.past(command.action)} on #{done} connected #{done == 1 ? "service" : "services"}."
               end

        left = results.reject { |result| completed?(command, result) }
                      .reject { |result| %i[unsupported skipped].include?(result.status) }
        details = []
        details << "Still there on #{left.map(&:to_s).join(", ")}." unless left.empty?
        unless skipped.empty?
          label = skipped.length == 1 ? "copy" : "copies"
          details << "No recorded #{label} on #{skipped.map(&:endpoint_id).join(", ")}."
        end
        unless unsupported.empty? || all_unsupported
          details << "Not supported on #{unsupported.map(&:endpoint_id).join(", ")}."
        end
        return base if details.empty?

        return "#{base} #{details.join(" ")}"
      end

      def issuer_label(command) = command.issuer&.to_s || command.target_user&.any_name || "the author"

      # A no-op on the Null sink. Never raises: a lost audit line must not derail
      # command handling.
      def record_audit(command, results, community)
        done = completed_count(command, results)
        attempted = attempted_count(results)
        @audit.record(
          community: community,
          source: "moderation",
          action: command.action.to_s,
          adapter: command.origin.adapter_name.to_s,
          channel: command.origin.id,
          actor: issuer_label(command),
          subject: command.target_user&.any_name,
          subject_native_id: command.target_user&.native_id,
          target_ref: command.target_ref&.to_s,
          reason: command.arguments.empty? ? nil : command.arguments.join(" "),
          outcome: "#{done}/#{attempted}",
          excerpt: audit_excerpt(command),
          metadata: { results: results.map(&:to_s) }
        )
      rescue StandardError => e
        logger.warn { "moderation: could not record the audit event: #{e.message}" }
      end

      # What the acted-on message said, quoted to the operators and never stored.
      # Only for a verb that acts on a message, since the others act on nobody's
      # words, and only where an operator issued it: a member retracting their
      # own message is not a colleague's call anyone has to review, and quoting
      # it would send it straight back out of the room they took it from.
      def audit_excerpt(command)
        return nil unless command.issuer && command.needs_target_message?

        command.target_text
      end

      def execute_rooms(rooms, command, people = @people)
        plans = rooms.flat_map { |room| plan_command(room, command, people) }
        execute_plans(plans)
      end

      def plan_command(room, command, people)
        # Resolve every native id before sending the first action. A delete can
        # echo back immediately and clear the message map, so resolving one
        # target at a time made later copies look unknown mid-command.
        room.endpoints.select(&:sends?).filter_map do |target|
          adapter = adapter_for(target)
          next nil if adapter.nil?

          unless adapter.capabilities_for(target).moderates?(command.action)
            next Core::Moderation::Result.new(endpoint_id: target.id, status: :unsupported)
          end

          native_id = resolve_moderation_target(command, target)
          if command.needs_target_message? && native_id.nil?
            next Core::Moderation::Result.new(endpoint_id: target.id, status: :skipped)
          end

          scoped = command
          if command.needs_target_user?
            user_id = resolve_moderation_user(command, target, people)
            if user_id.nil?
              # Acting on a person needs their id on this platform; guessing would
              # risk banning the wrong account.
              next Core::Moderation::Result.new(
                endpoint_id: target.id, status: :not_found,
                detail: "no known account for that person on this platform"
              )
            end
            scoped = command.with_target_user_id(user_id)
          end

          Execution.new(adapter: adapter, target: target, command: scoped, native_id: native_id)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: target.id, status: :failed, detail: e.message)
        rescue StandardError => e
          # A lookup failure on one endpoint must not cost every other platform
          # its result, so contain and log it rather than crash the whole plan.
          logger.error { "moderation: #{target.id} raised #{e.class}: #{e.message}" }
          Core::Moderation::Result.new(endpoint_id: target.id, status: :failed, detail: e.message)
        end
      end

      def execute_plans(plans)
        plans.filter_map do |plan|
          next plan if plan.is_a?(Core::Moderation::Result)

          plan.adapter.moderate(plan.command, plan.target, plan.native_id)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: plan.target.id, status: :failed, detail: e.message)
        rescue StandardError => e
          logger.error { "moderation: #{plan.target.id} raised #{e.class}: #{e.message}" }
          Core::Moderation::Result.new(endpoint_id: plan.target.id, status: :failed, detail: e.message)
        end
      end

      # Find the target person's id on one endpoint. On the origin endpoint the
      # author's own id is already right; anywhere else the identity map is the
      # only way across, and it is read in the issuing community's scope.
      def resolve_moderation_user(command, target, people = @people)
        author = command.target_user
        return nil if author.nil?

        return author.native_id if target.adapter_name == command.origin.adapter_name
        return nil if people.nil?

        person = people.by_identity(command.origin.adapter_name, author.native_id) ||
                 people.by_handle(command.origin.adapter_name, author.username)
        person&.id_on(target.adapter_name)
      end

      # Find the command's target message on one endpoint: that endpoint's own
      # message, or a relayed copy in either direction.
      def resolve_moderation_target(command, target)
        ref = command.target_ref
        return nil if ref.nil?
        return ref.native_id if ref.endpoint_id == target.id

        forward = @storage.counterparts(ref, endpoint_id: target.id).first
        return forward.native_id if forward

        via_origin = @storage.origins(ref).find { |origin| origin.endpoint_id == target.id }&.native_id
        return via_origin if via_origin

        # Last resort: a bot message linked as an ephemeral group has no counterpart
        # or origin row, so only the group can resolve its id on other platforms.
        @ephemeral.sibling_native_id(ref: ref, endpoint_id: target.id)
      end

      # A delete's promise is that no copy remains, so a platform reporting its copy already absent
      # satisfies it just as a successful delete does. Other moderation actions still surface
      # :not_found normally.
      def completed?(command, result)
        result.ok? || (command.action == :delete && result.status == :not_found)
      end

      def completed_count(command, results)
        results.count { |result| completed?(command, result) }
      end

      def attempted_count(results)
        results.count { |result| !%i[unsupported skipped].include?(result.status) }
      end

      # Tell the room why a command typed in it did nothing, self-deleting after
      # the same window an acknowledgement uses.
      #
      # Separate from {#deliver_notice} because this does not ride the
      # acknowledgement toggle: a deployment that would rather not announce every
      # accepted command still owes an answer to one that could not run.
      def answer(endpoint, text, ttl = 0, reply_to: nil, also_delete: [])
        group = @ephemeral.post(
          endpoints: [endpoint], body: Core::RichText.plain(text), name: "bridge", delete_after: ttl,
          reply_to: reply_to, also_delete: also_delete
        )
        @cleanup.after(ttl) { group.delete_now } if ttl.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "moderation: could not answer on #{endpoint.id}: #{e.message}" }
        nil
      end

      # Post a bridge acknowledgement to one endpoint as the bot, returning the
      # group or nil, and never raising. An empty group is warned about: the
      # message can be sitting in the channel with nothing able to remove it.
      def deliver_notice(endpoint, text, delete_after: 0, also_delete: [], reply_to: nil, acknowledge: @acknowledge)
        return nil unless acknowledge

        group = @ephemeral.post(
          endpoints: [endpoint], body: Core::RichText.plain(text),
          name: "bridge", delete_after: delete_after, also_delete: also_delete, reply_to: reply_to
        )
        return group if group.any?

        logger.warn do
          "moderation: the acknowledgement on #{endpoint.id} came back without an id, " \
            "it cannot be edited or removed"
        end
        nil
      rescue StandardError => e
        logger.warn { "could not post a moderation notice to #{endpoint.id}: #{e.message}" }
        nil
      end

      # Delete one native message, tolerating that it is already gone or that
      # permission was withdrawn. Used for the command message during cleanup.
      def delete_native(endpoint, native_id)
        return if native_id.nil?

        adapter = adapter_for(endpoint)
        return if adapter.nil? || !adapter.capabilities_for(endpoint).deletes?

        adapter.delete(endpoint, native_id)
      rescue StandardError => e
        logger.debug { "cleanup could not delete #{native_id} on #{endpoint.id}: #{e.message}" }
      end

      # Drop the durable pending-deletion rows so a later boot sweep does not
      # chase copies that are already gone.
      def forget_ephemeral_group(command)
        return unless command.action == :delete

        ref = command.target_ref
        return if ref.nil?

        @ephemeral.forget_group_containing(endpoint_id: ref.endpoint_id, native_id: ref.native_id)
        retract_warning_notices(ref)
      rescue StandardError => e
        logger.debug { "could not forget the ephemeral group for #{command}: #{e.message}" }
      end

      # A warning that could not be DMed says so in the room, naming the person
      # and what it cost. Once the message it was about is gone, that notice
      # stands over a blank space, so it goes with it. Each pairing is forgotten
      # whether or not its notice could still be found: a notice already gone is
      # as retracted as one this just removed.
      def retract_warning_notices(ref)
        return if @announcements.nil?

        @announcements.for_message(endpoint_id: ref.endpoint_id, native_id: ref.native_id).each do |row|
          delete_notice(row)
          @announcements.forget(row)
        end
      rescue StandardError => e
        logger.debug { "could not retract the warning notice for #{ref}: #{e.message}" }
      end

      def delete_notice(row)
        endpoint = @topology.endpoint(row.notice_endpoint_id)
        return if endpoint.nil?

        adapter_for(endpoint)&.delete(endpoint, row.notice_native_id)
      rescue StandardError => e
        logger.debug { "could not delete the warning notice #{row.notice_native_id}: #{e.message}" }
      end
    end
  end
end
