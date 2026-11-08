# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The /reschedule chat command: edit fields on an event that already
    # exists rather than cancelling and recreating it. Authorization matches
    # {CardCancellation}'s own "cancel" rule: the event's creator, or anyone
    # this room recognises as an operator. EventScheduling#update has no
    # write path for kind, game_title, server_address or rsvp_mode yet, so a
    # field naming one of those is refused by name instead of dropped.
    # {Events::Lifecycle} posts the "Event updated" card and re-syncs the
    # native mirror on its own poll; this command only writes the row.
    class RescheduleCommand < Base
      include CardCancellation

      COMMAND = "reschedule"
      NOTICE_NAME = "rubotty"
      USAGE = "Usage: /reschedule <event id> [title=...] [start=...] [tz=...] [end=...] " \
              "[description=...] [url=...] [repeat=...] [reminders=...]"

      # The same long-form aliases {EventCommand} accepts on a key a person
      # might type; only timezone= (tz) resolves to a field this command
      # actually reads, the rest land on a field refused by name below.
      FIELD_ALIASES = EventCommand::FIELD_ALIASES

      REPEAT_KEYWORDS = EventCommand::REPEAT_KEYWORDS

      ALLOWED_FIELDS = %w[title start tz end description url repeat reminders].freeze

      # Fields EventScheduling#update has no write path for at all today, so a
      # person naming one is told why instead of getting a generic refusal.
      NOT_YET_EDITABLE = %w[kind game server rsvp].freeze

      # The word a confirmation credits for each field key, in {ALLOWED_FIELDS} order.
      CHANGED_LABELS = {
        "title" => "title", "start" => "start", "tz" => "timezone", "end" => "end time",
        "description" => "description", "url" => "url", "repeat" => "repeat cadence",
        "reminders" => "reminders"
      }.freeze

      def self.feature_name = Features::Events.feature_name

      def self.default_enabled? = false

      def self.observes = %i[chat]

      # @param topology [Core::Topology] only to construct the standalone
      #   default ephemeral; the runtime injects a shared one
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param event_scheduling [ControlPlane::EventScheduling, nil] resolves
      #   and writes the event; nil (no control plane) makes the feature a no-op
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on
      #   time; without one the durable backstop row is swept on the next boot
      def initialize(topology:, adapters:, logger:, event_scheduling: nil, ephemeral: nil, cleanup: nil)
        super()
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
        # deployment refuses a real /reschedule invocation instead of relaying it.
        raw = command_fields(context)
        return Outcome.continue([]) if raw.nil?

        return refuse_unconfigured(context) if @event_scheduling.nil? || context.community.nil?

        handle_reschedule(context, raw)
        Outcome.halt([])
      end

      private

      # Recognised as /reschedule but nothing here can act on it: no
      # operations service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      def command_fields(context)
        word, arguments = CommandWord.parse(context)
        return nil unless word == COMMAND

        arguments.join(" ")
      end

      def handle_reschedule(context, raw)
        parsed = parse(raw)
        if parsed == :invalid
          acknowledge(context, "Could not parse that; check your quoting. #{USAGE}")
          return
        end

        id_text, fields = parsed
        event = event_by_id(context, id_text)
        if event.nil?
          acknowledge(context, "Could not find that event here. #{USAGE}")
          return
        end

        unless may_cancel?(context, event)
          acknowledge(context, "Only event ##{event.id}'s creator or a room operator can reschedule it.")
          return
        end

        apply(context, event, fields)
      end

      def apply(context, event, fields)
        unsupported = fields.keys - ALLOWED_FIELDS
        if unsupported.any?
          acknowledge(context, unsupported_field_message(unsupported.first))
          return
        end

        if fields.empty?
          acknowledge(context, "Nothing to change. #{USAGE}")
          return
        end

        updates = build_updates(context, fields)
        return if updates.nil?

        updated = @event_scheduling.update(event: event, **updates)
        acknowledge(context, confirmation(updated, fields))
      rescue ControlPlane::EventScheduling::Invalid => e
        acknowledge(context, "Could not reschedule that event: #{e.message}")
      end

      # The keyword hash for EventScheduling#update: only a field actually
      # given reaches it at all, so an untouched one keeps UNSET, update's own
      # default. nil (an acknowledgement already posted) means repeat= or
      # reminders= failed to parse.
      def build_updates(context, fields)
        updates = {}
        updates[:title] = fields["title"] if fields.key?("title")
        updates[:starts_at] = fields["start"] if fields.key?("start")
        updates[:timezone] = fields["tz"] if fields.key?("tz")
        updates[:ends_at] = fields["end"] if fields.key?("end")
        updates[:description] = fields["description"] if fields.key?("description")
        updates[:url] = fields["url"] if fields.key?("url")

        if fields.key?("repeat")
          repeat = parse_repeat(fields)
          if repeat == :invalid
            acknowledge(context, "Could not understand repeat=#{fields["repeat"]}; use daily, weekly, " \
                                  "biweekly, monthly, none, or a number of seconds.")
            return nil
          end
          updates[:recurrence_interval] = repeat
        end

        if fields.key?("reminders")
          reminders = parse_reminders(fields)
          if reminders == :invalid
            acknowledge(context, "Could not understand reminders=#{fields["reminders"]}; use a comma " \
                                  "separated list of whole seconds, none, or default.")
            return nil
          end
          updates[:reminder_intervals] = reminders
        end

        updates
      end

      def unsupported_field_message(key)
        if NOT_YET_EDITABLE.include?(key)
          "#{key}= cannot be changed by /reschedule yet: EventScheduling#update has no write path for " \
            "it. #{USAGE}"
        else
          "#{key}= is not a field /reschedule can change. #{USAGE}"
        end
      end

      # Seconds between occurrences from a repeat= field, called only when
      # one was given: nil for "none" (clear any recurrence), a
      # {REPEAT_KEYWORDS} lookup, a bare number of seconds, or :invalid.
      def parse_repeat(fields)
        raw = presence(fields["repeat"])
        return nil if raw.nil?

        text = raw.downcase
        return nil if text == "none"
        return REPEAT_KEYWORDS[text] if REPEAT_KEYWORDS.key?(text)

        Integer(text, exception: false) || :invalid
      end

      # This event's own reminder ladder from a reminders= field, called only
      # when one was given: nil for "default" (use the community/room
      # default), an empty array for "none", an explicit ladder, or :invalid.
      def parse_reminders(fields)
        raw = presence(fields["reminders"])
        return nil if raw.nil?

        text = raw.downcase
        return nil if text == "default"
        return [] if text == "none"

        parts = raw.split(",").map { |part| Integer(part.strip, exception: false) }
        parts.any?(&:nil?) ? :invalid : parts
      end

      # The event id (bare, first word) and its key=value fields via the
      # shared {Core::KeyedArguments} reader, a long-form alias resolved to
      # the short field name it stands for; :invalid for field text that
      # does not read as a run of key=value pairs at all.
      def parse(raw)
        id_text, _sep, remainder = raw.to_s.strip.partition(/\s+/)
        fields = Core::KeyedArguments.parse(remainder)
        return :invalid if fields.nil?

        [id_text, fields.transform_keys { |key| FIELD_ALIASES.fetch(key, key) }]
      end

      def event_by_id(context, id_text)
        id = Integer(id_text.to_s, exception: false)
        return nil if id.nil?

        @event_scheduling.find(community: context.community, id: id)
      end

      def confirmation(event, fields)
        zone = presence(event.timezone) || "UTC"
        start = Util::EventTimestamps.full(event.starts_at, zone)
        parts = ["Rescheduled ##{event.id}: #{event.title}, now at #{start}"]
        if fields.key?("repeat") && event.recurring?
          parts << "| repeats every #{duration_phrase(event.recurrence_interval)}"
        end
        parts << "| updated: #{changed_field_labels(fields).join(", ")}"
        parts.join(" ")
      end

      def changed_field_labels(fields)
        ALLOWED_FIELDS.select { |key| fields.key?(key) }.map { |key| CHANGED_LABELS.fetch(key, key) }
      end

      def duration_phrase(seconds)
        amount, unit = Util::EventTimestamps.largest_unit(seconds)
        "#{amount} #{unit}#{"s" unless amount == 1}"
      end

      # The same "adapter:handle" shape EventCommand stamps created_by with,
      # so CardCancellation's creator check means the same thing at both ends.
      def issuer_label(context)
        author = context.message.author
        return context.message.origin.adapter_name.to_s if author.nil?

        handle = presence(author.username) || author.native_id.to_s
        "#{context.message.origin.adapter_name}:#{handle}"
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
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
        logger.warn { "reschedule: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
