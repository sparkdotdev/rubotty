# frozen_string_literal: true

module Rubotty
  module Scripting
    # Ambient facts every script gets alongside whatever its trigger matched: only what
    # describes this message and this moment (clock, sender, operator status, backfill,
    # room). Anything about the deployment, community, participants, or events is a
    # separate rubotty.*() call instead, since riding the payload costs an encode (and
    # often a query) on every message regardless of whether a script reads it. `now` is
    # read once per invocation and frozen to UTC so two checks in one rule can't disagree.
    class Context
      # @param clock [#call] returns the Time this invocation reads. Injected so
      #   the smoke test can freeze it.
      def initialize(room_key: nil, clock: -> { Time.now.utc })
        @room_key = room_key
        @clock = clock
      end

      # Every kind of invocation there is; rubotty.kind() reads one of these and it's
      # always present, never inferred from absence. EDIT is separate from MESSAGE
      # because a script that opted into edits almost always wants different handling:
      # the text it scored a minute ago has changed.
      MESSAGE = "message"
      EDIT = "message_edit"
      COMMAND = "command_invocation"
      SCHEDULED = "scheduled_function"
      HTTP_CALLBACK = "http_callback"

      KINDS = [MESSAGE, EDIT, COMMAND, SCHEDULED, HTTP_CALLBACK].freeze

      # Merges the ambient fields into a trigger's payload; the trigger's own keys win
      # on collision, since what a rule matched on is the more specific truth. +trigger+
      # names which of a script's own conditions matched (there may be several) and is
      # absent when there was none, same as every other field here that can't be
      # answered honestly.
      def decorate(payload, message: nil, kind: MESSAGE, trigger: nil)
        base = { "kind" => kind }
        base["trigger"] = trigger.to_s unless trigger.nil?
        base.merge(ambient).merge(message_fields(message)).merge(payload || {})
      end

      def ambient
        now = @clock.call.utc
        {
          "now" => {
            "epoch" => now.to_i, "hour" => now.hour, "minute" => now.min,
            "wday" => now.wday, "day" => now.day, "month" => now.month, "year" => now.year,
            "iso" => now.iso8601, "tz" => "UTC"
          },
          "room_key" => @room_key.to_s
        }
      end

      # Upcoming events, each carrying how long until it starts so a rule can
      # say "within the hour" without a clock; RSVP counts only, since who is
      # coming is people data no rule needs to enumerate. Reached through
      # rubotty.events() rather than shipped on every message, since this is a
      # list of objects that almost no invocation reads.
      def events_payload(events, now = @clock.call.utc)
        Array(events).filter_map do |event|
          starts = event_time(event)
          next if starts.nil?

          {
            "title" => event.title.to_s,
            "starts_at" => starts.utc.iso8601,
            "starts_in" => (starts - now).to_i,
            "room" => event.respond_to?(:room_key) ? event.room_key.to_s : "",
            "rsvp_count" => event.respond_to?(:rsvp_count) ? event.rsvp_count.to_i : 0
          }
        end
      end

      def event_time(event)
        value = event.respond_to?(:starts_at) ? event.starts_at : nil
        value.is_a?(Time) ? value : (value && Time.parse(value.to_s))
      rescue StandardError
        nil
      end

      # What is true of this particular message, kept apart from {#ambient} so a caller
      # with no message (a dashboard dry run) still gets the rest; only fields the Event
      # actually carries, never padded with an always-false default a script could branch
      # on wrongly. `attachments` is empty rather than absent so a rule can check
      # `#rubotty.attachments() > 0` with no nil guard; `reply_to` is genuinely absent when
      # there is none, since that absence IS the answer to "is this a reply".
      def message_fields(event)
        return {} if event.nil?

        fields = {
          "author" => event.author_name.to_s,
          "author_is_operator" => !!event.author_is_operator,
          "origin_platform" => event.origin_platform.to_s,
          "attachments" => Array(event.attachments),
          "handle" => event.handle.to_s
        }
        reply = event.reply_to
        fields["reply_to"] = reply if reply.is_a?(Hash) && !reply.empty?
        fields
      end
    end
  end
end
