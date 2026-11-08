# frozen_string_literal: true

module Rubotty
  module Events
    # Advances a Rubotty-native recurring event's occurrence once its start
    # time has passed, through {ControlPlane::EventScheduling#update}: the
    # same write path a manual edit takes, so {Events::Lifecycle}
    # re-announces and reschedules the reminder ladder on its next poll. A
    # native Discord recurring event needs none of this: {Events::NativeMirror}
    # already turns Discord's own update event into the same #update call,
    # so this class only touches an event with its own recurrence_interval,
    # which a mirrored-in event never has.
    class Recurrence
      # How many occurrences one #check may advance a single event through, so
      # a near-zero interval cannot spin forever catching up after a long
      # downtime.
      MAX_CATCH_UP = 1000

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param event_scheduling [ControlPlane::EventScheduling] the write
      #   surface an advance is applied through
      # @param logger [#warn, nil]
      # @param clock [#call] injectable time source, for a deterministic test
      def initialize(models:, event_scheduling:, logger: nil, clock: -> { Time.now })
        @models = models
        @event_scheduling = event_scheduling
        @logger = logger
        @clock = clock
      end

      # Advance every past-due recurring event once. Returns how many rows it
      # advanced.
      def check
        now = @clock.call
        due(now).count { |row| advance(Event.new(row), now) }
      rescue Sequel::Error => e
        @logger&.warn { "events recurrence: could not read the events table: #{e.message}" }
        0
      end

      private

      def due(now)
        @models.event
              .where(status: Events::Event::STATUS_SCHEDULED)
              .exclude(recurrence_interval: nil)
              .where { starts_at <= now }
              .all
      end

      def advance(event, now)
        interval = event.recurrence_interval
        return false unless interval&.positive?

        starts_at = event.starts_at
        duration = event.ends_at && event.ends_at - starts_at
        steps = 0
        while starts_at <= now && steps < MAX_CATCH_UP
          starts_at += interval
          steps += 1
        end
        return false if steps.zero?

        changes = { event: event, starts_at: starts_at }
        changes[:ends_at] = starts_at + duration if duration
        @event_scheduling.update(**changes)
        true
      rescue ControlPlane::EventScheduling::Invalid => e
        @logger&.warn { "events recurrence: could not advance event #{event.id}: #{e.message}" }
        false
      end
    end
  end
end
