# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The /event command: create an event from chat, recognised via the
    # shared prefix or, on Discord, a native slash command; both feed the
    # same key=value parser. Discord's slash options are marked `keyed:`, so
    # {Adapters::Discord::Interactions#body_text} rebuilds "title=... start=..."
    # from them for {#parse_fields} to read. `tz` is optional, falling back to
    # {ControlPlane::TimezoneInference}: flag emoji, then room zone, then UTC.
    # Excluded from {Catalog.classes}: shares a feature_name with
    # {Features::Events}.
    class EventCommand < Base
      include AdapterLookup

      COMMAND = "event"
      NOTICE_NAME = "rubotty"

      USAGE = 'Usage: /event title="..." start="YYYY-MM-DD HH:MM"|"tomorrow 4pm"|"6 hours"|"now" ' \
              "kind=gaming|general [tz=Area/City] [game=...] [server=...] [url=...] " \
              "[rsvp=none|affirm|full] [repeat=daily|weekly|biweekly|monthly|<seconds>|none] " \
              "[reminders=<seconds>,<seconds>,...|none|default]"

      # A key a person might type, mapped to the field {ControlPlane::EventScheduling#create}
      # actually names, so both the short and the long forms of a key work.
      FIELD_ALIASES = {
        "timezone" => "tz",
        "game_title" => "game",
        "server_address" => "server",
        "rsvp_mode" => "rsvp"
      }.freeze

      # repeat= keywords, seconds between occurrences. A bare number of
      # seconds is accepted too, for anything this fixed vocabulary does not
      # name.
      REPEAT_KEYWORDS = {
        "daily" => 86_400,
        "weekly" => 604_800,
        "biweekly" => 1_209_600,
        "monthly" => 2_592_000
      }.freeze

      # The key=value fields that must be present (and non-blank) for a create to
      # be attempted; {ControlPlane::EventScheduling#create} defaults the rest.
      # `tz` is deliberately not here: {ControlPlane::TimezoneInference} is the
      # fallback for a blank one, so the command itself never has to insist.
      REQUIRED_FIELDS = %w[title start kind].freeze

      # Every field this command reads, canonical spellings only (a
      # FIELD_ALIASES key resolves to one of these before this list is
      # checked). A key outside both is refused by name.
      ALLOWED_FIELDS = %w[title start kind tz game server url rsvp repeat reminders].freeze

      def self.feature_name = Features::Events.feature_name

      def self.default_enabled? = false

      # A command is something a person just typed, so only fresh chat messages.
      def self.observes = %i[chat]

      # @param topology [Core::Topology] only to construct the standalone
      #   default ephemeral; the runtime injects a shared one
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param event_scheduling [ControlPlane::EventScheduling, nil] the
      #   operations service; nil (no control plane) makes the feature a no-op
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on
      #   time; without one the durable backstop row is swept on the next boot
      def initialize(topology:, adapters:, logger:, event_scheduling: nil, ephemeral: nil, cleanup: nil)
        super()
        @adapters = adapters
        @logger = logger
        @event_scheduling = event_scheduling
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real /event invocation instead of relaying it.
        raw = command_fields(context)
        return Outcome.continue([]) if raw.nil?

        return refuse_unconfigured(context) if @event_scheduling.nil? || context.community.nil?

        handle_create(context, raw)
        # Swallowed either way: a bare /event is never relayed as content.
        Outcome.halt([])
      end

      private

      # Recognised as /event but nothing here can act on it: no operations
      # service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      # The raw text after "/event ", or nil when this message is not the event
      # command. Reads the community's shared command markers, same as every
      # other command surface.
      def command_fields(context)
        word, arguments = CommandWord.parse(context)
        return nil unless word == COMMAND

        arguments.join(" ")
      end

      def handle_create(context, raw)
        community = @event_scheduling.community_by_id(context.community.id)
        room = community && @event_scheduling.room_for_endpoint_key(
          community: community, endpoint_key: context.channel.endpoint_key
        )
        if community.nil? || room.nil?
          logger.warn { "event: could not resolve a room for #{context.message.origin.id}" }
          acknowledge(context, "This room isn't linked to a community yet, so /#{COMMAND} can't run here.")
          return
        end

        fields = parse_fields(raw)
        if fields.nil?
          acknowledge(context, "Could not parse that; check your quoting. #{USAGE}")
          return
        end

        unknown = fields.keys - ALLOWED_FIELDS
        if unknown.any?
          acknowledge(context, "#{unknown.first}= is not a field /#{COMMAND} takes. #{USAGE}")
          return
        end

        missing = REQUIRED_FIELDS.reject { |key| presence(fields[key]) }
        if missing.any?
          acknowledge(context, "Missing #{missing.join(", ")}. #{USAGE}")
          return
        end

        repeat = parse_repeat(fields)
        if repeat == :invalid
          acknowledge(context, "Could not understand repeat=#{fields["repeat"]}; use daily, weekly, " \
                                "biweekly, monthly, none, or a number of seconds.")
          return
        end

        reminders = parse_reminders(fields)
        if reminders == :invalid
          acknowledge(context, "Could not understand reminders=#{fields["reminders"]}; use a comma " \
                                "separated list of whole seconds, none, or default.")
          return
        end

        event = @event_scheduling.create(
          community: community, room: room, as: role_of(context),
          title: fields["title"], starts_at: fields["start"], timezone: effective_timezone(context, fields),
          kind: fields["kind"], game_title: fields["game"], server_address: fields["server"],
          url: fields["url"], rsvp_mode: fields["rsvp"], created_by: issuer_label(context),
          recurrence_interval: repeat, reminder_intervals: reminders
        )
        acknowledge(context, confirmation(event))
      rescue ControlPlane::EventScheduling::Invalid => e
        acknowledge(context, "Could not schedule that event: #{e.message}")
      end

      # Seconds between occurrences from a repeat= field: nil for "not given"
      # or "none" (a one-off event, the default), a REPEAT_KEYWORDS lookup, a
      # bare number of seconds, or :invalid for text that is none of those.
      def parse_repeat(fields)
        raw = presence(fields["repeat"])
        return nil if raw.nil?

        text = raw.downcase
        return nil if text == "none"
        return REPEAT_KEYWORDS[text] if REPEAT_KEYWORDS.key?(text)

        Integer(text, exception: false) || :invalid
      end

      # This event's own reminder ladder from a reminders= field: nil for
      # "not given" or "default" (use the community/room default), an empty
      # array for "none" (no reminders for this event), an explicit ladder
      # parsed from a comma separated list, or :invalid for text that parses
      # as none of those.
      def parse_reminders(fields)
        raw = presence(fields["reminders"])
        return nil if raw.nil?

        text = raw.downcase
        return nil if text == "default"
        return [] if text == "none"

        parts = raw.split(",").map { |part| Integer(part.strip, exception: false) }
        parts.any?(&:nil?) ? :invalid : parts
      end

      # The timezone this event is created under: an explicit tz= field wins
      # outright, otherwise {Features::RoomTimezone}'s own chain (a flag emoji
      # in the poster's nickname or display name, then this room's own
      # configured zone, then UTC). Feeds both the stored display label and,
      # through {ControlPlane::EventScheduling}, a relative `start` like
      # "tomorrow 4pm".
      def effective_timezone(context, fields)
        RoomTimezone.infer(context, explicit: fields["tz"], logger: logger)
      end

      # key=value fields via the shared {Core::KeyedArguments} reader, with a
      # long-form alias resolved to the short field name it stands for. nil
      # for text that does not read as a run of key=value pairs at all.
      def parse_fields(text)
        fields = Core::KeyedArguments.parse(text)
        fields&.transform_keys { |key| FIELD_ALIASES.fetch(key, key) }
      end

      # Whether the asker is an operator in this scope, the permission
      # {ControlPlane::EventScheduling#create} enforces against the room's
      # who_can_create. Fail closed: an unresolvable asker is a regular member.
      def role_of(context)
        directory = context.operators
        author = context.message.author
        return :member if directory.nil? || author.nil?

        resolved = directory.resolve(context.message.origin.adapter_name, author.native_id,
                                     username: author.username)
        resolved ? :operator : :member
      rescue StandardError => e
        logger.warn { "event: role_of failed: #{e.class}: #{e.message}" }
        :member
      end

      def issuer_label(context)
        author = context.message.author
        return context.message.origin.adapter_name.to_s if author.nil?

        handle = presence(author.username) || author.native_id.to_s
        "#{context.message.origin.adapter_name}:#{handle}"
      end

      def confirmation(event)
        zone = presence(event.timezone) || "UTC"
        parts = ["Scheduled ##{event.id}: #{event.title} at #{Util::EventTimestamps.full(event.starts_at, zone)}"]
        parts << "- #{kind_detail(event)}" if presence(kind_detail(event))
        parts << "| RSVP: #{event.rsvp_mode}" unless event.rsvp_none?
        parts << "| repeats every #{duration_phrase(event.recurrence_interval)}" if event.recurring?
        parts.join(" ")
      end

      def kind_detail(event)
        return event.url if event.general?

        [event.game_title, event.server_address].select { |value| presence(value) }.join(" @ ")
      end

      def duration_phrase(seconds)
        amount, unit = Util::EventTimestamps.largest_unit(seconds)
        "#{amount} #{unit}#{"s" unless amount == 1}"
      end

      # A self-deleting acknowledgement to the channel the command came from.
      # Never raises: a lost reply must not derail the pipeline.
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
        logger.warn { "event: could not post a reply: #{e.message}" }
        nil
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
