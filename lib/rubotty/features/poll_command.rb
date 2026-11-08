# frozen_string_literal: true

module Rubotty
  module Features
    # The /poll chat command, on the shared {PollSurface}. Answers
    # {Features::Poll.feature_name}, so one feature_settings row gates both.
    class PollCommand < Base
      include PollSurface

      COMMAND = "poll"

      USAGE = 'Usage: /poll <question> | <option> | <option> ... (or /poll "question" "option" "option"). ' \
              "Add reply_options=yes, duration=24h or multi_select=yes as their own trailing pipe segments " \
              'to change just this poll. Example: /poll Pizza tonight? | Yes | No | duration=12h'

      # What this command reads off a trailing key=value segment; see
      # PollSurface#split_directives.
      ALLOWED_DIRECTIVES = %i[reply_options duration multi_select].freeze

      def self.feature_name = Features::Poll.feature_name

      def self.default_enabled? = false

      def self.observes = PollSurface::OBSERVES

      def command_word = COMMAND

      def poll_kind = Polls::Poll::KIND_POLL

      private

      def handle_open(context, raw)
        scope = scope_for(context)
        return if scope.nil?

        community, room = scope
        positional, directives = split_directives(split_command_parts(raw))
        validate_directives!(directives, ALLOWED_DIRECTIVES)

        question = positional.first
        options = positional[1..] || []
        if question.nil? || options.size < 2
          acknowledge(context, "A poll needs a question and at least two options. #{USAGE}")
          return
        end

        poll = @polls.open(
          community: community, room: room, kind: poll_kind,
          question: question, options: options.map { |label| { label: label } },
          multi_select: truthy?(directives[:multi_select]),
          reply_votes: boolean_config(context.config, :reply_votes, default: true),
          reply_options: reply_options_for(context, directives),
          duration_hours: duration_for(context, directives), created_by: issuer_label(context)
        )
        @lifecycle&.announce(poll)
        acknowledge(context, "Poll ##{poll.id} is open until #{poll.closes_at.strftime("%Y-%m-%d %H:%M UTC")}.")
      rescue ControlPlane::Polls::Invalid => e
        acknowledge(context, "Could not open that poll: #{e.message}")
      end

      # This poll's own reply_options=, or the room's own default.
      def reply_options_for(context, directives)
        return truthy?(directives[:reply_options]) if directives.key?(:reply_options)

        boolean_config(context.config, :reply_options, default: false)
      end

      # This poll's own duration=, or the room's configured default, or the
      # code default when the room names none.
      def duration_for(context, directives)
        return parse_duration_directive!(directives[:duration]) if directives.key?(:duration)

        Polls::Poll.duration_hours(config_value(context.config, :duration)) || Polls::Poll::DEFAULT_DURATION_HOURS
      end
    end
  end
end
