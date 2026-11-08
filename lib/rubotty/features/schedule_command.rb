# frozen_string_literal: true

module Rubotty
  module Features
    # The /schedule chat command, on the {PollSurface} /poll is built on but
    # multi-select and taking suggested times. Answers
    # {Features::Events.feature_name}, behind its allow_schedule_polling.
    # Fields are key=value, the same shape {EventCommand} reads, so a native
    # Discord slash command gets a labelled box per field instead of one
    # free-text box a person has to know to pipe-separate by hand. times=
    # still holds its own list, pipe-separated within that one value, since
    # Discord's option model has no way to repeat an argument.
    class ScheduleCommand < Base
      include PollSurface

      COMMAND = "schedule"

      # A method because the polls namespace loads after this file.
      def self.usage
        'Usage: /schedule name="..." game="..." times="<time> | <time> ..." Each <time> is read the same way ' \
          'a reply suggesting one is, e.g. "today 3pm", "tomorrow 5pm" or "next friday 11am". duration=24h and ' \
          "tz=Europe/Lisbon are optional; duration defaults to 24h and tz to your own guessed timezone. " \
          'Example: /schedule name="Game night" game=Stellaris times="today 7pm | tomorrow 8pm"'
      end

      REQUIRED_FIELDS = %w[name game times].freeze
      ALLOWED_FIELDS = %w[name game times duration tz].freeze

      def self.feature_name = Features::Events.feature_name

      def self.default_enabled? = false

      def self.observes = PollSurface::OBSERVES

      def command_word = COMMAND

      def poll_kind = Polls::Poll::KIND_SCHEDULE

      private

      def handle_open(context, raw)
        unless boolean_config(context.config, Features::Events::ALLOW_SCHEDULE_POLLING_KEY, default: false)
          acknowledge(context, "Scheduling polls are switched off in this room.")
          return
        end

        scope = scope_for(context)
        return if scope.nil?

        fields = parse_fields(raw)
        if fields.nil?
          acknowledge(context, "Could not read that. #{self.class.usage}")
          return
        end

        unknown = fields.keys - ALLOWED_FIELDS
        raise ControlPlane::Polls::Invalid, "#{unknown.first}= is not an option I take here." if unknown.any?

        missing = REQUIRED_FIELDS - fields.keys
        time_segments = split_times(fields["times"])
        if missing.any? || time_segments.size < 2
          acknowledge(context, "A scheduling poll needs a name, a game, and at least two candidate times. " \
                                "#{self.class.usage}")
          return
        end

        hours = fields.key?("duration") ? parse_duration_directive!(fields["duration"]) :
                  Polls::Poll::DEFAULT_DURATION_HOURS
        open_session(context, scope, name: fields["name"], game: fields["game"], time_segments: time_segments,
                                      hours: hours, tz: fields["tz"])
      rescue ControlPlane::Polls::Invalid => e
        acknowledge(context, "Could not start that scheduling poll: #{e.message}")
      end

      # key=value fields via the shared {Core::KeyedArguments} reader; nil
      # when the text does not read as a run of them at all (the caller
      # falls back to #usage).
      def parse_fields(text) = Core::KeyedArguments.parse(text)

      def split_times(text)
        text.to_s.split("|").map(&:strip).reject(&:empty?)
      end

      def open_session(context, scope, name:, game:, time_segments:, hours:, tz: nil)
        community, room = scope
        timezone = RoomTimezone.infer(context, explicit: tz, logger: logger)
        options = time_segments.map { |segment| parse_slot!(segment, timezone) }

        poll = @polls.open(
          community: community, room: room, kind: poll_kind,
          question: name, detail: game, timezone: timezone,
          options: options,
          multi_select: true, reply_votes: true, reply_options: true,
          duration_hours: hours, created_by: issuer_label(context)
        )
        @lifecycle&.announce(poll)
        acknowledge(
          context,
          "Scheduling poll ##{poll.id} for #{game} is open until " \
          "#{poll.closes_at.strftime("%Y-%m-%d %H:%M UTC")}."
        )
      end

      # A reply here only ever means a time; anything else stays conversation.
      def option_attributes(_context, poll, text)
        slot = Polls::ScheduleSlots.suggested(text, timezone: poll.timezone, now: Time.now)
        return nil if slot.nil?

        slot_option(slot, poll.timezone)
      end

      # The SAME parser #option_attributes uses for a reply suggesting a
      # time, so a candidate given at creation and one added later behave
      # identically.
      #
      # @raise [ControlPlane::Polls::Invalid] naming the segment that would
      #   not parse, rather than dropping it or opening with a bad option
      def parse_slot!(text, timezone)
        slot = Polls::ScheduleSlots.suggested(text, timezone: timezone, now: Time.now)
        raise ControlPlane::Polls::Invalid, "could not work out a time from #{text.inspect}." if slot.nil?

        slot_option(slot, timezone)
      end

      def slot_option(slot, timezone)
        { label: Polls::ScheduleSlots.label(slot, timezone), starts_at: slot }
      end
    end
  end
end
