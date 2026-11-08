# frozen_string_literal: true

require "json"
require "time"

module Rubotty
  module Events
    # A thin read wrapper over one events row: is this a gaming or a general
    # event, what is starts_at in UTC regardless of what the database handed
    # back, what does the reminder_intervals/native_refs JSON actually hold.
    #
    # @param row [#[]] anything answering the events columns by symbol key,
    #   in practice a Rubotty::ControlPlane::Models::Event instance
    class Event
      KIND_GAMING = "gaming"
      KIND_GENERAL = "general"
      KINDS = [KIND_GAMING, KIND_GENERAL].freeze

      RSVP_NONE = "none"
      RSVP_AFFIRM = "affirm"
      RSVP_FULL = "full"
      RSVP_MODES = [RSVP_NONE, RSVP_AFFIRM, RSVP_FULL].freeze

      STATUS_SCHEDULED = "scheduled"
      STATUS_CANCELLED = "cancelled"
      STATUS_COMPLETED = "completed"
      STATUSES = [STATUS_SCHEDULED, STATUS_CANCELLED, STATUS_COMPLETED].freeze

      attr_reader :row

      def initialize(row)
        @row = row
      end

      def id = row[:id]
      def community_id = row[:community_id]
      def room_id = row[:room_id]
      def title = row[:title]
      def description = row[:description]
      def timezone = row[:timezone]
      def kind = row[:kind]
      def game_title = row[:game_title]
      def server_address = row[:server_address]
      def url = row[:url]
      def rsvp_mode = row[:rsvp_mode]
      def status = row[:status]
      def created_by = row[:created_by]

      def gaming? = kind == KIND_GAMING

      def general? = kind == KIND_GENERAL

      def scheduled? = status == STATUS_SCHEDULED

      def cancelled? = status == STATUS_CANCELLED

      def completed? = status == STATUS_COMPLETED

      def rsvp_none? = rsvp_mode == RSVP_NONE

      def rsvp_affirm? = rsvp_mode == RSVP_AFFIRM

      def rsvp_full? = rsvp_mode == RSVP_FULL

      # starts_at is stored UTC; normalised to a Time in UTC regardless of what
      # Sequel handed back.
      def starts_at
        to_utc(row[:starts_at])
      end

      # ends_at is optional: nil when the event has no announced end.
      def ends_at
        value = row[:ends_at]
        value && to_utc(value)
      end

      # The reminder ladder as second offsets before starts_at, or nil to mean
      # "use the community/feature default". A corrupt blob reads back as nil,
      # the same behaviour as a genuinely absent override.
      def reminder_intervals
        raw = row[:reminder_intervals]
        return nil if raw.nil? || raw == ""

        JSON.parse(raw)
      rescue JSON::ParserError
        nil
      end

      # Seconds between occurrences, or nil for an event that does not repeat.
      # Rubotty's own recurrence only: a native Discord event's own recurrence
      # is Discord's to advance, reported back to us as an ordinary update
      # (see {Events::NativeMirror}), so this is never set on one of those.
      def recurrence_interval = row[:recurrence_interval]

      def recurring? = !recurrence_interval.nil? && recurrence_interval.positive?

      # platform => that platform's native event id. Empty hash, never nil, for
      # a row with no native mirror yet.
      def native_refs
        raw = row[:native_refs]
        return {} if raw.nil? || raw == ""

        JSON.parse(raw)
      rescue JSON::ParserError
        {}
      end

      # The native event id on one platform, or nil when there is no mirror yet.
      def native_ref(platform)
        native_refs[platform.to_s]
      end

      def to_s = "#{title} (#{kind}, #{status})"

      def inspect = "#<Rubotty::Events::Event #{self}>"

      private

      # Time.parse on a naive "2026-08-13 20:00:00" string (no offset, what a
      # driver can hand back for a datetime column) assumes the system's local
      # zone, so a deployment observing DST parses it an hour off from the UTC
      # the column actually holds. Appending " UTC" pins the zone explicitly
      # before parsing, rather than parsing local and hoping #utc fixes it.
      def to_utc(value)
        return value.to_time.utc if value.respond_to?(:to_time)

        Time.parse("#{value} UTC").utc
      end
    end
  end
end
