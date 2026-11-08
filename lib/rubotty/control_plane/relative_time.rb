# frozen_string_literal: true

require "time"
require "tzinfo"

module Rubotty
  module ControlPlane
    # A small, deliberately bounded reader for the relative time vocabulary
    # /event's start= accepts: "now", an offset, "today", "tomorrow" or a
    # weekday, each of the last three plus a 12-hour clock time. Anything
    # else is not this class's problem: {.parse} returns nil and the caller
    # falls back to stdlib Time.parse. WEEKDAY POLICY: a bare weekday always
    # means the NEXT occurrence strictly after today; say "today 11pm" to
    # mean today explicitly. A "today" reading already in the past is left
    # to the caller, the same as any other instant failing its own check.
    module RelativeTime
      WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze

      SECONDS = { "minute" => 60, "hour" => 3600, "day" => 86_400 }.freeze

      OFFSET = /\A(\d+)\s*(minute|minutes|hour|hours|day|days)\z/i
      CLOCK = /\A(\d{1,2})(?::([0-5]\d))?\s*(am|pm)\z/i
      TODAY = /\Atoday\s+(.+)\z/i
      TOMORROW = /\Atomorrow\s+(.+)\z/i
      WEEKDAY = /\A(?:next\s+)?(#{WEEKDAYS.join("|")})\s+(.+)\z/i

      module_function

      # A UTC Time read from +text+ against the vocabulary above, or nil when
      # it matches none of it.
      #
      # @param timezone [String, nil] the IANA zone a bare clock time is read
      #   in; falls back to UTC for a blank or unrecognised one rather than
      #   raising, the same forgiving posture {ControlPlane::TimezoneInference}
      #   takes on its own last resort.
      # @return [Time, nil]
      def parse(text, timezone: nil, now: Time.now)
        word = text.to_s.strip
        return nil if word.empty?

        return now.utc if word.casecmp("now").zero?

        offset = parse_offset(word)
        return (now + offset).utc if offset

        zone = resolve_zone(timezone)

        today_match = TODAY.match(word)
        return at_clock(local_date(now, zone), today_match[1], zone) if today_match

        tomorrow_match = TOMORROW.match(word)
        return at_clock(local_date(now, zone) + SECONDS.fetch("day"), tomorrow_match[1], zone) if tomorrow_match

        weekday_match = WEEKDAY.match(word)
        return at_clock(next_weekday(now, zone, weekday_match[1]), weekday_match[2], zone) if weekday_match

        # A clock time with no day of its own names today, the same as "today <clock>".
        return at_clock(local_date(now, zone), word, zone) if CLOCK.match?(word)

        nil
      end

      # @api private
      def parse_offset(word)
        match = OFFSET.match(word)
        return nil unless match

        SECONDS.fetch(match[2].downcase.sub(/s\z/, "")) * match[1].to_i
      end

      # @api private
      # The calendar date (a UTC-tagged midnight) +now+ falls on in +zone+.
      def local_date(now, zone)
        local = zone.utc_to_local(now.utc)
        Time.utc(local.year, local.month, local.day)
      end

      # @api private
      # The next calendar date +weekday_name+ names, strictly after today in
      # +zone+ (today itself never counts, see the class-level WEEKDAY POLICY
      # note).
      def next_weekday(now, zone, weekday_name)
        today = local_date(now, zone)
        target_wday = WEEKDAYS.index(weekday_name.downcase)
        days_ahead = (target_wday - today.wday) % 7
        days_ahead = 7 if days_ahead.zero?
        today + (days_ahead * SECONDS.fetch("day"))
      end

      # @api private
      # +date+ (a UTC-tagged midnight for a calendar day in +zone+) at the
      # clock time +clock_text+ names, converted to a real UTC instant via
      # +zone+'s offset that day; nil when +clock_text+ doesn't parse or the
      # wall-clock reading doesn't exist in +zone+ (a spring-forward gap). An
      # ambiguous reading (a repeated fall-back hour) resolves to standard time
      # via `dst: false`.
      def at_clock(date, clock_text, zone)
        match = CLOCK.match(clock_text.to_s.strip)
        return nil unless match

        hour = clock_hour(match[1].to_i, match[3])
        return nil if hour.nil?

        minute = match[2].to_i
        local = Time.utc(date.year, date.month, date.day, hour, minute, 0)
        zone.local_to_utc(local, false) { |periods| periods.last }.utc
      rescue TZInfo::PeriodNotFound
        nil
      end

      # @api private
      # 12-hour hour + am/pm to 24-hour, or nil for an hour out of 1..12.
      def clock_hour(hour, meridiem)
        return nil unless hour.between?(1, 12)

        pm = meridiem.casecmp("pm").zero?
        return 0 if hour == 12 && !pm
        return hour if hour == 12 && pm

        pm ? hour + 12 : hour
      end

      # @api private
      # A real TZInfo::Timezone for +iana+, or UTC for a blank, nil, or
      # unrecognised one: a bad zone string must never crash /event, only
      # fall back to the same "no better answer" UTC the whole inference
      # chain ends on.
      def resolve_zone(iana)
        text = iana.to_s.strip
        return TZInfo::Timezone.get("UTC") if text.empty?

        TZInfo::Timezone.get(text)
      rescue TZInfo::InvalidTimezoneIdentifier
        TZInfo::Timezone.get("UTC")
      end
    end
  end
end
