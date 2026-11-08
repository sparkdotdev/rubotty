# frozen_string_literal: true

require "time"

module Rubotty
  module Events
    # The reminder engine: one durable job per rung of an event's ladder, so a
    # member is reminded at 1 week, 3 days and so on down to 15 minutes before
    # an event starts, and the reminders survive a restart.
    class Reminders
      # The durable-scheduler job kind this service registers and enqueues.
      KIND = "event_reminder"

      # The default injected seam, so a caller with nowhere to send a reminder
      # still boots clean.
      NOOP = ->(_event, _interval) {}

      # @param scheduler [Core::DurableScheduler] registers {KIND} on
      #   construction, before boot recovery runs
      # @param default_intervals [Array<Integer>, #call] the ladder used when an
      #   event carries no override. A plain array, or a callable taking the
      #   event, for a caller that resolves a community's configured default.
      # @param on_fire [#call, nil] called with (event, interval_seconds) when a
      #   reminder comes due. Defaults to {NOOP}.
      def initialize(scheduler:, default_intervals: Features::Events::DEFAULT_REMINDER_INTERVALS,
                     on_fire: nil, logger: nil, clock: -> { Time.now })
        @scheduler = scheduler
        @default_intervals = default_intervals
        @on_fire = on_fire || NOOP
        @logger = logger
        @clock = clock
        @scheduler.register(KIND) { |job| deliver(job) }
      end

      # Schedule or reschedule every reminder for +event+, one job per rung at
      # (starts_at - interval), skipping any rung already in the past. Cancels
      # this event's pending jobs first, so it is safe to call again.
      def schedule_for(event)
        cancel_for(event)
        now = @clock.call
        intervals_for(event).count do |interval|
          run_at = event.starts_at - interval
          next false if run_at <= now

          @scheduler.schedule(kind: KIND, run_at: run_at, payload: payload_for(event, interval))
          true
        end
      end

      # Cancel every pending reminder job for +event+, and only that event's.
      # Returns how many were cancelled.
      def cancel_for(event)
        @scheduler.cancel(kind: KIND, every_community: true) { |payload| payload["event_id"] == event.id }
      end

      private

      # The event's own ladder when it has one, the resolved default otherwise.
      # nil is the "use the default" sentinel, so an explicit empty override
      # means this event wants no reminders.
      def intervals_for(event)
        ladder = event.reminder_intervals
        ladder = resolved_default(event) if ladder.nil?
        Array(ladder)
      end

      def resolved_default(event)
        @default_intervals.respond_to?(:call) ? @default_intervals.call(event) : @default_intervals
      end

      # Everything the handler needs to rebuild the event, JSON-serialisable.
      # reminder_intervals and native_refs are left out: neither is read at fire
      # time.
      def payload_for(event, interval)
        {
          "event_id" => event.id, "interval" => interval,
          "community_id" => event.community_id, "room_id" => event.room_id,
          "title" => event.title, "description" => event.description,
          "timezone" => event.timezone, "kind" => event.kind,
          "game_title" => event.game_title, "server_address" => event.server_address,
          "url" => event.url, "rsvp_mode" => event.rsvp_mode, "status" => event.status,
          "created_by" => event.created_by, "starts_at" => event.starts_at.iso8601,
          "ends_at" => event.ends_at&.iso8601
        }
      end

      # The scheduler's handler: rebuild the event from the job's own payload, so
      # recovery after a restart needs no database read. Raising marks the job
      # failed and the scheduler retries.
      def deliver(job)
        payload = job.payload || {}
        event = Event.new(event_row(payload))
        @on_fire.call(event, payload["interval"].to_i)
      end

      def event_row(payload)
        {
          id: payload["event_id"], community_id: payload["community_id"], room_id: payload["room_id"],
          title: payload["title"], description: payload["description"], timezone: payload["timezone"],
          kind: payload["kind"], game_title: payload["game_title"], server_address: payload["server_address"],
          url: payload["url"], rsvp_mode: payload["rsvp_mode"], status: payload["status"],
          created_by: payload["created_by"], starts_at: payload["starts_at"], ends_at: payload["ends_at"]
        }
      end
    end
  end
end
