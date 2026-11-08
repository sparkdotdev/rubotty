# frozen_string_literal: true

module Rubotty
  module Core
    # The one description of the bot's command surface, platform-neutral:
    # for each command its name, description, audience, target, and
    # arguments, so the Discord slash registration, /help, and the
    # dispatcher all read from one source instead of drifting apart.
    # Nothing here knows about Discord permission bitfields or option
    # types; those are that platform's own translation of the neutral
    # facts recorded here, which is what lets a future platform's native
    # command surface read the same list.
    module CommandRegistry
      # The longest a command or option description may be: Discord caps both
      # at 100 characters and rejects the ENTIRE application command
      # registration with "Invalid Form Body" when any one is longer, which
      # is what took down every slash command on the 1.2.0 deploy over
      # /event's 144-character option description. Recorded here, not the
      # Discord adapter, since the registry is the single source of the
      # command surface and a spec enforces this on every entry so the
      # failure cannot recur unnoticed.
      DESCRIPTION_LIMIT = 100

      # An argument a command accepts after its name, in the order it is
      # typed; +type+ is the neutral kind each platform maps to its own
      # option model. +keyed+ decides how {Adapters::Discord::Interactions
      # #body_text} rebuilds the value into the shared command line: false
      # (the default) joins it in bare with the others, true prefixes it
      # "name=" (quoted if it holds a space), so several Discord options
      # collapse back into "key=value" text.
      Argument = Struct.new(:name, :type, :description, :required, :keyed, keyword_init: true) do
        def required? = required ? true : false

        def keyed? = keyed ? true : false
      end

      # One command, described once.
      class Spec
        attr_reader :name, :description, :audience, :target, :acknowledgement, :arguments, :feature, :surface

        # See {#target_required?}.
        attr_reader :target_required

        # Platform-neutral command surface metadata for slash registration and
        # `/help`, including audience, target, feature and ordered arguments.
        #
        # @param surface [Symbol] :room for a verb typed where people talk,
        #   :direct for one the operator console answers in a DM. A client's
        #   command menu spans both, an in-room dispatcher only the first.
        # @param target_required [Boolean] false for a verb that also has a
        #   form naming no target, which a client offers as an optional picker.
        def initialize(name:, description:, audience: :moderator, target: :none,
                       acknowledgement: nil, arguments: [], feature: nil, surface: :room,
                       target_required: true)
          @name = name.to_s
          @feature = feature&.to_s
          @description = description.to_s
          @audience = audience.to_sym
          @target = target.to_sym
          @surface = surface.to_sym
          @acknowledgement = acknowledgement || "running /#{@name}"
          @arguments = Array(arguments).freeze
          @target_required = target_required ? true : false
          freeze
        end

        def target_required? = @target_required

        def moderator? = @audience == :moderator

        def everyone? = @audience == :everyone

        def targets_message? = @target == :message

        def targets_user? = @target == :user

        # True for a verb the console answers in a DM. Such a command is
        # published in a client's menu but never dispatched in a room, so an
        # in-room surface has to hold it out rather than offer a dead verb.
        # :both is one verb offered in either place, which /report needs: a
        # member replying in the room and a member with no room to reply in are
        # the same person reporting the same thing, and two entries carrying one
        # name is a duplicate in every client's command menu.
        def direct? = %i[direct both].include?(@surface)

        def room? = %i[room both].include?(@surface)
      end

      module_function

      # Return the stable, shared moderation and public command list.
      def all
        @all ||= (moderation_specs + warnings_specs + identity_specs + utility_specs +
                  console_specs + report_specs + condemn_specs).freeze
      end

      # Everything typed in a room, which is what an in-room dispatcher and a
      # room command surface read.
      def room_commands = all.select(&:room?)

      # The public, non-moderation commands any member may run.
      def utility_specs
        [
          Spec.new(
            feature: "utility_commands", name: "find", description: "Find who to @mention: look up a handle or name across platforms.",
            audience: :everyone, target: :none, acknowledgement: "looking that up",
            arguments: [
              Argument.new(name: "query", type: :string, required: true,
                           description: "handle or display name to search for")
            ]
          ),
          Spec.new(
            feature: "utility_commands", name: "platforms", description: "Show this community's other platforms and their join links.",
            audience: :everyone, target: :none, acknowledgement: "fetching the join links"
          ),
          Spec.new(
            feature: "utility_commands", name: "help", description: "List the commands you can use here.",
            audience: :everyone, target: :none, acknowledgement: "showing the help"
          ),
          # Let everyone request version while feature code controls disclosure.
          Spec.new(
            feature: "utility_commands", name: "version", description: "Show what version of rubotty is running here.",
            audience: :everyone, target: :none, acknowledgement: "checking the version"
          ),
          Spec.new(
            feature: "room_summaries", name: "summary", description: "Ask for a short summary of this room's recent conversation.",
            audience: :everyone, target: :none, acknowledgement: "preparing a room summary"
          ),
          # Let anyone identify an undiscovered room; feature code immediately
          # applies operator requests and queues others for review.
          Spec.new(
            feature: "identify_topic",
            name: "identify-topic",
            description: "Name this room/topic here, in case it was never auto-discovered.",
            audience: :everyone, target: :none, acknowledgement: "identifying this topic",
            arguments: [
              Argument.new(name: "name", type: :string, required: true,
                           description: "the name to give this room or topic")
            ]
          ),
          # Restrict redirection to moderators because it moves others' messages.
          Spec.new(
            feature: "redirection", name: "redirect", description: "Move a run of messages into another room, starting here.",
            audience: :moderator, target: :message, acknowledgement: "marking the start of the run",
            arguments: [
              Argument.new(name: "channel", type: :string, required: true,
                           description: "the room or channel to move the run into")
            ]
          ),
          # Share one closing word for multi-message operations.
          Spec.new(
            name: "end", description: "Close whatever multi-message operation you started here.",
            audience: :moderator, target: :message, acknowledgement: "closing that off"
          ),
          # Keep self-service keyword subscriptions as one portable free-text
          # instruction.
          Spec.new(
            feature: "keyword_watch", name: "watch", description: "Get pinged when a keyword is said anywhere, for a bounded time.",
            audience: :everyone, target: :none, acknowledgement: "setting that up",
            arguments: [
              Argument.new(
                name: "instruction", type: :string, required: true,
                description: 'keyword [duration] [mention|dm], or "list" / "stop [keyword]"'
              )
            ]
          ),
          # Event policy remains per-room. Keyed arguments rebuild portable
          # command text, with required Discord options first.
          Spec.new(
            feature: "events", name: "event", description: "Schedule an event in this room: title, start time, timezone and kind.",
            audience: :everyone, target: :none, acknowledgement: "scheduling that event",
            arguments: [
              Argument.new(name: "title", type: :string, required: true, keyed: true,
                           description: "the event's title"),
              Argument.new(name: "start", type: :string, required: true, keyed: true,
                           description: 'when it starts: "2026-08-01 20:00", "tomorrow 4pm", "6 hours", "now"'),
              Argument.new(name: "kind", type: :string, required: true, keyed: true,
                           description: "gaming or general"),
              Argument.new(name: "tz", type: :string, required: false, keyed: true,
                           description: "timezone, e.g. Europe/Lisbon; guessed from your flag or this room if blank"),
              Argument.new(name: "game", type: :string, required: false, keyed: true,
                           description: "game title (gaming events)"),
              Argument.new(name: "server", type: :string, required: false, keyed: true,
                           description: "server address (gaming events)"),
              Argument.new(name: "url", type: :string, required: false, keyed: true,
                           description: "meeting or stream link (general events)"),
              Argument.new(name: "rsvp", type: :string, required: false, keyed: true,
                           description: "RSVP mode: none, affirm or full (default none)"),
              Argument.new(name: "repeat", type: :string, required: false, keyed: true,
                           description: "daily, weekly, biweekly, monthly, a number of seconds, or none"),
              Argument.new(name: "reminders", type: :string, required: false, keyed: true,
                           description: "comma separated seconds before start, none, or default")
            ]
          ),
          # Use explicit, required RSVP arguments because event cards bypass
          # message-map reply lookup.
          Spec.new(
            feature: "events", name: "rsvp", description: "RSVP to an event scheduled in this room.",
            audience: :everyone, target: :none, acknowledgement: "recording your RSVP",
            arguments: [
              Argument.new(name: "id", type: :integer, required: true, description: "the event's id"),
              Argument.new(name: "response", type: :string, required: true,
                           description: "yes, maybe or no (full RSVP) or in (affirm-only events)")
            ]
          ),
          # Bare, lists this room's upcoming events; pointed at one id, shows
          # its roster instead. One optional, unkeyed argument, the same
          # positional shape /rsvp's own id takes.
          Spec.new(
            feature: "events", name: "events", description: "List upcoming events here, or show who's signed up for one.",
            audience: :everyone, target: :none, acknowledgement: "looking that up",
            arguments: [
              Argument.new(name: "id", type: :integer, required: false,
                           description: "an event's id, to see who's signed up (blank lists upcoming events)")
            ]
          ),
          # Let moderators manually post an event reminder using the shared copy.
          Spec.new(
            feature: "events", name: "remind", description: "Manually post an event's reminder into this room right now.",
            audience: :moderator, target: :none, acknowledgement: "posting that reminder",
            arguments: [
              Argument.new(name: "id", type: :integer, required: true, description: "the event's id")
            ]
          ),
          # id stays unkeyed like /rsvp's own, since it is never blank; every
          # other field is optional and keyed like /event's own.
          Spec.new(
            feature: "events", name: "reschedule", description: "Change fields on an event you created or can moderate here.",
            audience: :everyone, target: :none, acknowledgement: "rescheduling that event",
            arguments: [
              Argument.new(name: "id", type: :integer, required: true, description: "the event's id"),
              Argument.new(name: "title", type: :string, required: false, keyed: true,
                           description: "new title for the event"),
              Argument.new(name: "start", type: :string, required: false, keyed: true,
                           description: 'new start time: "2026-08-01 20:00", "tomorrow 4pm", "6 hours", "now"'),
              Argument.new(name: "tz", type: :string, required: false, keyed: true,
                           description: "new timezone, e.g. Europe/Lisbon"),
              Argument.new(name: "end", type: :string, required: false, keyed: true,
                           description: "new end time, same formats as start"),
              Argument.new(name: "description", type: :string, required: false, keyed: true,
                           description: "new description text"),
              Argument.new(name: "url", type: :string, required: false, keyed: true,
                           description: "new meeting or stream link (general events)"),
              Argument.new(name: "repeat", type: :string, required: false, keyed: true,
                           description: "daily, weekly, biweekly, monthly, a number of seconds, or none"),
              Argument.new(name: "reminders", type: :string, required: false, keyed: true,
                           description: "comma separated seconds before start, none, or default")
            ]
          ),
          # Every field keyed, the same shape /event uses, so Discord's own
          # picker gives a separate labelled box per field instead of one
          # free-text box a person has to know to pipe-separate by hand.
          Spec.new(
            feature: "events", name: "schedule", description: "Ask the room which candidate times work for a game.",
            audience: :everyone, target: :none, acknowledgement: "starting that scheduling poll",
            arguments: [
              Argument.new(name: "name", type: :string, required: true, keyed: true,
                           description: "what to call this scheduling poll"),
              Argument.new(name: "game", type: :string, required: true, keyed: true,
                           description: "the game this is scheduling"),
              Argument.new(name: "times", type: :string, required: true, keyed: true,
                           description: 'candidate times separated by |, e.g. "today 7pm | tomorrow 8pm"'),
              Argument.new(name: "duration", type: :string, required: false, keyed: true,
                           description: "how long this poll stays open, one of 1h to 72h (default: 24h)"),
              Argument.new(name: "tz", type: :string, required: false, keyed: true,
                           description: "timezone for the candidate times; guessed from your flag or this room if blank")
            ]
          ),
          # Keep variable poll options free text and room-overriding directives
          # keyed.
          Spec.new(
            feature: "poll", name: "poll", description: "Ask the room a question and let people vote.",
            audience: :everyone, target: :none, acknowledgement: "opening that poll",
            arguments: [
              Argument.new(name: "question", type: :string, required: true,
                           description: "the question, then its options, separated by |"),
              Argument.new(name: "reply_options", type: :boolean, required: false, keyed: true,
                           description: "let a reply add an option to THIS poll (default: this room's setting)"),
              Argument.new(name: "duration", type: :string, required: false, keyed: true,
                           description: "how long THIS poll stays open, one of 1h to 72h (default: this room's setting)"),
              Argument.new(name: "multi_select", type: :boolean, required: false, keyed: true,
                           description: "let a voter pick more than one option (default: single choice)")
            ]
          ),
          # File upload is member-accessible but scope-gated, capped, expiring
          # and single-use.
          Spec.new(
            feature: "file_rehosting", name: "upload", description: "Get a private link to upload a file too big for this platform.",
            audience: :everyone, target: :none, acknowledgement: "setting up an upload link"
          ),
          # Guest invitations apply room policy in feature code and use one
          # portable free-text instruction.
          Spec.new(
            feature: "guest_portal", name: "guest", description: "Invite a guest into this room with a one-time link.",
            audience: :everyone, target: :none, acknowledgement: "issuing that guest invite",
            arguments: [
              Argument.new(
                name: "invite", type: :string, required: true,
                description: 'nickname [duration], e.g. Sam 2h (default 24h)'
              )
            ]
          ),
          # Setting is member-facing; list is gated to operators in feature code,
          # same as /guest's per-room policy check.
          Spec.new(
            feature: "nickname", name: "nickname", description: "Choose the name you're bridged as on each platform, or clear it.",
            audience: :everyone, target: :none, acknowledgement: "updating your nickname",
            arguments: [
              Argument.new(
                name: "instruction", type: :string, required: false,
                description: '<platform> <name>, or "list" / "clear <platform> [name]" (blank shows yours)'
              )
            ]
          ),
          # Requesting is open to anyone; approve, deny and list are gated to
          # operators in feature code, same reason /nickname's own list is.
          Spec.new(
            feature: "operator_requests", name: "operator", description: "Ask to become an operator, or approve/deny requests as one.",
            audience: :everyone, target: :none, acknowledgement: "handling that operator request",
            arguments: [
              Argument.new(
                name: "action", type: :string, required: false,
                description: 'request (default), or "approve <id>" / "deny <id>" / "list" (operators only)'
              )
            ]
          )
        ]
      end

      # The commands a given audience may see: a moderator sees everything,
      # a non-moderator only the everyone-commands. This is exactly the
      # split /help draws between the full list and the suggested actions.
      # @param surface [Symbol, nil] :room to hold back the console's DM verbs,
      #   which is what an in-room surface wants; nil for every surface, which
      #   is what a client's command menu wants since it spans both.
      def for_audience(moderator:, surface: nil)
        specs = moderator ? all : all.select(&:everyone?)
        surface.nil? ? specs : specs.select { |spec| spec.surface == surface.to_sym }
      end

      # The spec for +name+, or nil when it is not a registered command.
      def find(name)
        all.find { |spec| spec.name == canonical(name) }
      end

      # Canonicalise prefixes, Telegram bot suffixes and underscore or hyphen
      # spellings while preserving unknown words.
      def canonical(word)
        text = word.to_s.strip
        # Scope-aware callers already stripped their marker; this handles whole
        # command text convenience calls.
        markers = (@markers ||= CommandPrefix.new)
        bare = (markers.strip(text) || text).split("@").first.to_s.downcase
        return bare if all.any? { |spec| spec.name == bare }

        separated = bare.tr("_", "-")
        all.any? { |spec| spec.name == separated } ? separated : bare
      end

      # True when +name+ is a registered command.
      def known?(name) = !find(name).nil?

      # Expose every typed moderation verb except programmatic `unban`.
      def moderation_specs
        Moderation::TYPED_ACTIONS.map { |action| moderation_spec(action) }
      end

      # @api private
      def moderation_spec(action)
        Spec.new(
          feature: "moderation",
          name: action,
          description: MODERATION_DESCRIPTIONS.fetch(action, "Carry out /#{action} on every connected platform."),
          audience: :moderator,
          target: moderation_target(action),
          # /unpin is the one verb with two forms: a reply, or a room named
          # after it. Its target picker has to be optional or the second form
          # is unreachable wherever a client builds the command from this.
          target_required: action != :unpin,
          acknowledgement: Moderation.gerund(action),
          arguments: MODERATION_ARGUMENTS.fetch(action, [])
        )
      end

      # :message and :user both name a reply target; a room action such as
      # /lock names none at all, resolving the room from context.channel
      # instead, the same way /schedule and /event do.
      def moderation_target(action)
        return :message if Moderation.message_action?(action)
        return :user if Moderation.user_action?(action)

        :none
      end

      # Discord shows these to every member in the "/" picker, so they are worded
      # for a person rather than a log. Kept next to the specs rather than in
      # {Core::Moderation} because they are command-surface copy, distinct from
      # the verb's internal phrasing.
      MODERATION_DESCRIPTIONS = {
        delete: "Delete the target message on every connected platform.",
        ban: "Ban a member on every connected platform.",
        kick: "Kick a member on every connected platform.",
        mute: "Mute (time out) a member on every connected platform.",
        unmute: "Lift a member's mute on every connected platform.",
        pin: "Pin the target message on every connected platform.",
        unpin: "Unpin the message replied to, or name a room to clear every pin in it.",
        clean: "Delete the summaries, banners and notices rubotty left in a room, or in all of them.",
        lock: "Lock this room so only operators may post; everyone else is removed.",
        unlock: "Unlock this room, restoring whatever moderation state it had before."
      }.freeze

      # Only `mute`, `unpin` and `clean` take an extra argument.
      MODERATION_ARGUMENTS = {
        delete: [
          Argument.new(name: "when", type: :string, required: false,
                       description: "Remove it later instead: 25 minutes, tuesday 5pm, tomorrow 9am.")
        ],
        mute: [
          Argument.new(name: "minutes", type: :integer, required: false,
                       description: "How long to mute, in minutes (default 60).")
        ],
        unpin: [
          Argument.new(name: "room", type: :string, required: false,
                       description: "Clear every pin in this room instead. A room name, or \"all\".")
        ],
        clean: [
          Argument.new(name: "room", type: :string, required: false,
                       description: "A room name, or \"all\". Left out, it means the room you are in.")
        ]
      }.freeze

      # {Features::Warnings} parses its own three commands directly rather than
      # through {Moderation}, so they were never in {#all}: real and working,
      # but absent from Telegram's suggested-command menu, Discord's slash
      # registration and /help alike, since every one of those reads only this
      # list.
      def warnings_specs
        [
          Spec.new(
            feature: "warnings", name: "warn",
            description: "Warn a member, in reply to their message, and run the escalation ladder.",
            audience: :moderator, target: :user, acknowledgement: "warning",
            arguments: [
              Argument.new(name: "reason", type: :string, required: false,
                           description: "Why the warning was issued."),
              Argument.new(name: "delete", type: :boolean, required: false, keyed: true,
                           description: "Also delete the replied-to message everywhere it was relayed.")
            ]
          ),
          Spec.new(
            feature: "warnings", name: "warnings",
            description: "List a member's active warnings, in reply to their message.",
            audience: :moderator, target: :user, acknowledgement: "listing warnings"
          ),
          Spec.new(
            feature: "warnings", name: "unwarn",
            description: "Clear a member's most recent warning, or all of them, in reply to their message.",
            audience: :moderator, target: :user, acknowledgement: "clearing warnings",
            arguments: [
              Argument.new(name: "all", type: :boolean, required: false, keyed: true,
                           description: "Clear every active warning instead of just the most recent one.")
            ]
          )
        ]
      end

      # The correlate of /vindicate, and it cannot be a console verb the way
      # that one is: a vindication answers the code an alert advertised, and a
      # miss has no code because nothing ever fired. So it is a reply in the
      # room, on the moderator audience, like every other verb aimed at one
      # message.
      def condemn_specs
        [
          Spec.new(
            feature: "content_policy", name: "condemn", surface: :room, audience: :moderator,
            description: "In reply to a message the policies missed: act on it now, and keep it as a " \
                         "sample for that policy.",
            acknowledgement: "condemning",
            arguments: [
              Argument.new(name: "policy", type: :string, required: false,
                           description: "The policy it should have matched, in quotes. Defaults to the first."),
              Argument.new(name: "why", type: :string, required: false,
                           description: "What the check missed. Kept with the sample."),
              Argument.new(name: "warn", type: :boolean, required: false, keyed: true,
                           description: "Count a strike against the author too. True unless you say no.")
            ]
          )
        ]
      end

      # Reporting is for everybody, and there are two places it would have been
      # gated by accident. A moderator audience publishes to
      # all_chat_administrators, which never covers a private chat and would
      # hide the verb from the very members it exists for, which is exactly how
      # vindicate shipped invisible (issue #1893). And the room surface alone
      # would leave it unoffered in the bot's own DM, which is the route a
      # member with no chat open has to be told about.
      def report_specs
        [
          Spec.new(
            feature: "reports", name: "report", surface: :both, audience: :everyone,
            description: "Report a message to this community's operators, in reply to it or by " \
                         "forwarding it to me here.",
            acknowledgement: "passing that on",
            arguments: [
              Argument.new(name: "link", type: :string, required: false,
                           description: "A link to the message, when you are not replying or forwarding.")
            ]
          )
        ]
      end

      # What the operator console answers in a DM. Registered here rather than
      # left to the console's own `help` so a client's command menu offers them:
      # an operator reading an alert on a phone finds `/vindicate` by typing a
      # slash, which is the whole point of the menu.
      def console_specs
        [
          Spec.new(
            feature: "content_policy", name: "vindicate", surface: :direct,
            description: "Reverse a content policy action, in reply to the alert or by its code.",
            audience: :moderator, acknowledgement: "reversing",
            arguments: [
              Argument.new(name: "code", type: :string, required: false,
                           description: "The code the alert carried; omit it when replying to the alert."),
              Argument.new(name: "why", type: :string, required: false,
                           description: "Why the match was wrong. Shown to the author.")
            ]
          ),
          Spec.new(
            feature: "content_policy", name: "innocent", surface: :direct,
            description: "The same as vindicate: reverse a content policy action and say why.",
            audience: :moderator, acknowledgement: "reversing",
            arguments: [
              Argument.new(name: "code", type: :string, required: false,
                           description: "The code the alert carried; omit it when replying to the alert."),
              Argument.new(name: "why", type: :string, required: false,
                           description: "Why the match was wrong. Shown to the author.")
            ]
          )
        ]
      end

      # {Features::IdentityHistory} parses its own command directly rather
      # than through {Moderation}, the same reason {#warnings_specs} exists.
      def identity_specs
        [
          Spec.new(
            feature: "identity_history", name: "identity",
            description: "Show a member's name history: username, display name and bridged " \
                          "nickname, with dates.",
            audience: :moderator, target: :user, acknowledgement: "looking that up",
            arguments: [
              Argument.new(name: "handle", type: :string, required: false,
                           description: "a handle to look up instead of replying to their message")
            ]
          )
        ]
      end
    end
  end
end
