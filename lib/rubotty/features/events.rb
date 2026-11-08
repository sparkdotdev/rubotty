# frozen_string_literal: true

module Rubotty
  module Features
    # Room-scoped feature flag and config for event scheduling. Observes nothing,
    # so the pipeline never runs it; who_can_create is resolved per room by
    # {ControlPlane::EventPolicy}.
    class Events < Base
      WHO_OPERATORS = "operators"
      WHO_EVERYONE = "everyone"
      WHO_CAN_CREATE = [WHO_OPERATORS, WHO_EVERYONE].freeze

      # Seconds before starts_at, soonest reminder last.
      DEFAULT_REMINDER_INTERVALS = [
        604_800, # 1 week
        259_200, # 3 days
        172_800, # 2 days
        86_400,  # 1 day
        43_200,  # 12 hours
        21_600,  # 6 hours
        10_800,  # 3 hours
        7_200,   # 2 hours
        3_600,   # 1 hour
        1_800,   # 30 minutes
        900      # 15 minutes
      ].freeze

      # /schedule lives inside this feature rather than carrying a toggle of
      # its own, so a community can have events without scheduling rounds.
      ALLOW_SCHEDULE_POLLING_KEY = :allow_schedule_polling

      def self.feature_name = "events"

      def self.description = "Schedule events with RSVPs, announced and reminded automatically."

      # A fresh community schedules no events until an operator enables a room.
      def self.default_enabled? = false

      def self.observes = [].freeze

      def self.config_schema
        Config::Schema.define do
          field :who_can_create, :string, default: WHO_OPERATORS, one_of: WHO_CAN_CREATE,
                desc: "who may create an event in this room: operators (default) or everyone"
          field :default_reminder_intervals, :array, of: :integer, default: DEFAULT_REMINDER_INTERVALS,
                desc: "reminder ladder, seconds before an event starts, used when an event does not " \
                      "override it"
          field ALLOW_SCHEDULE_POLLING_KEY, :boolean, default: false,
                desc: "allow /schedule, which asks the room which candidate times work before an " \
                      "event is fixed"
        end
      end
    end
  end
end
