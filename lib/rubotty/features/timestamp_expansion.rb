# frozen_string_literal: true

require "tzinfo"
require "tzinfo/data"

module Rubotty
  module Features
    # Expands a Discord `<t:UNIX:FORMAT>` token into multi-timezone plain
    # text where Discord's own client won't render it live. Discord resolves
    # the token per viewer, in whatever zone that viewer's client is set to;
    # nothing on the relay side can reproduce that, so this renders one fixed
    # text against a community's ordered zone list instead.
    #
    # Every format code (t/T/d/D/f/F/R) expands the same way: none of
    # Discord's styles are reproducible in plain text, so {TOKEN} accepts and ignores the code.
    module TimestampExpansion
      TOKEN = /<t:(-?\d+)(?::[tTdDfFR])?>/

      # One configured zone: a short human label ("Pacific") and the IANA
      # identifier tzinfo resolves it against ("America/Los_Angeles").
      Zone = Struct.new(:label, :iana_timezone, keyword_init: true)

      # British-style month abbreviations: three letters for every month
      # except September, which keeps its familiar four-letter short form
      # ("Sept") rather than Ruby's own three-letter %b ("Sep").
      MONTH_ABBREVIATIONS = %w[Jan Feb Mar Apr May Jun Jul Aug Sept Oct Nov Dec].freeze

      WEEKDAYS = %w[Sunday Monday Tuesday Wednesday Thursday Friday Saturday].freeze

      # What a scope renders with until it configures its own list. Pacific
      # leads deliberately: the first pair is the home zone {.day_label} judges
      # Today/Tomorrow against and {Features::RoomTimezone} anchors a bare
      # wall-clock time on. String keys match the JSON a configured scope
      # stores, and keep a symbol out of what the schema publishes.
      DEFAULT_ZONES = [
        { "label" => "Pacific", "iana_timezone" => "America/Los_Angeles" },
        { "label" => "Eastern", "iana_timezone" => "America/New_York" },
        { "label" => "Western Europe", "iana_timezone" => "Europe/London" },
        { "label" => "Central Europe", "iana_timezone" => "Europe/Berlin" }
      ].freeze

      module_function

      # The ordered zones a resolved feature config asks for: what it
      # configured, or {DEFAULT_ZONES} where the key was never set. A stored
      # empty list is somebody asking for no expansion, so it stays empty.
      #
      # @param config [Hash, nil] one scope's resolved feature config
      # @param key [Symbol] the config key holding the pairs
      # @param logger [#warn, nil]
      # @return [Array<Zone>]
      def zones_for_config(config, key = :timestamp_timezones, logger: nil)
        raw = stored_value(config, key)
        parse_zones(raw.nil? ? DEFAULT_ZONES : raw, logger: logger)
      end

      # The raw value under +key+, tolerating symbol or string keys: the
      # control plane stores strings, a hand-built config in a spec may use
      # either. Nil for a key that is absent or explicitly null.
      def stored_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      # Parse a scope's raw `timestamp_timezones` config array into an ordered
      # list of {Zone}. Defensive the way ScheduledAnnouncements::Entry.parse
      # is: an entry missing a label or iana_timezone, or naming a zone
      # tzinfo doesn't recognise, is dropped with a log line instead of breaking the rest.
      #
      # @param raw [Array, nil]
      # @param logger [#warn, nil]
      # @return [Array<Zone>]
      def parse_zones(raw, logger: nil)
        Array(raw).filter_map { |entry| parse_zone(entry, logger) }
      end

      def parse_zone(entry, logger)
        unless entry.is_a?(Hash)
          logger&.warn { "timestamp_expansion: ignoring a zone entry that is not a mapping: #{entry.inspect}" }
          return nil
        end

        symbolized = entry.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
        label = symbolized[:label].to_s.strip
        iana = symbolized[:iana_timezone].to_s.strip
        if label.empty? || iana.empty?
          logger&.warn do
            "timestamp_expansion: ignoring a zone entry missing label or iana_timezone: #{entry.inspect}"
          end
          return nil
        end

        TZInfo::Timezone.get(iana)
        Zone.new(label: label, iana_timezone: iana)
      rescue TZInfo::InvalidTimezoneIdentifier
        logger&.warn { "timestamp_expansion: ignoring zone #{iana.inspect}, tzinfo does not recognise it" }
        nil
      end

      # Replaces every `<t:UNIX:FORMAT>` token in +text+ with its expansion.
      # Nil or empty +zones+, or text with no token, is a no-op; a token
      # whose number can't become a real instant is left exactly as it
      # arrived rather than raising.
      #
      # @param now [Time] the reference instant "today" is judged against;
      #   injected so callers (and tests) get a deterministic answer
      # @return [String]
      def expand(text, zones, now: Time.now)
        return text if zones.nil? || zones.empty?
        return text if text.nil? || !text.include?("<t:")

        text.gsub(TOKEN) do
          render_token(Regexp.last_match(1), zones, now) || Regexp.last_match(0)
        end
      end

      # The rendering for one raw `<t:UNIX...>` capture, or nil when the
      # number cannot become a real Time (out of range, or too large for a
      # Time to represent at all).
      def render_token(raw_unix, zones, now = Time.now)
        time = Time.at(Integer(raw_unix, 10)).utc
        render(time, zones, now)
      rescue ArgumentError, RangeError, TypeError
        nil
      end

      # "<day label> <time1> <label1>, <time2> <label2>, ..." for one instant,
      # across every configured zone in the order they were configured.
      def render(time, zones, now)
        "#{day_label(time, zones.first.iana_timezone, now)} " \
          "#{zones.map { |zone| clock_for(time, zone) }.join(", ")}"
      end

      def clock_for(time, zone)
        "#{clock(time, zone.iana_timezone)} #{zone.label}"
      end

      # The Today / Tomorrow / weekday / Next weekday / absolute date label
      # for +time+, judged against the FIRST configured zone's calendar day:
      # the same UTC instant falls on a different calendar day per zone (an
      # 11pm UTC message is already "tomorrow" in India while still "today"
      # in California), and a plain text rendering shown once to every reader
      # has no single "the reader's own day" the way Discord's live,
      # per-viewer client does. The first configured zone stands in as the
      # community's home zone for this reason, same as it heads the clock list.
      def day_label(time, reference_tz, now)
        today = local_midnight(now, reference_tz)
        target = local_midnight(time, reference_tz)
        diff = ((target - today) / 86_400).round

        case diff
        when 0 then "Today"
        when 1 then "Tomorrow"
        when 2..6 then WEEKDAYS[target.wday]
        when 7..13 then "Next #{WEEKDAYS[target.wday]}"
        else "#{WEEKDAYS[target.wday]} #{target.day} #{MONTH_ABBREVIATIONS[target.month - 1]}"
        end
      end

      # Midnight of the calendar day +time+ falls on in +tz+, itself
      # re-anchored to a UTC-tagged Time. Two such stand-ins always differ by
      # an exact multiple of 86,400 seconds regardless of a DST transition
      # sitting between them, which a pair of REAL local midnights (23 or 25
      # real hours apart across a transition) would not.
      def local_midnight(time, tz)
        local = TZInfo::Timezone.get(tz).utc_to_local(time.utc)
        Time.utc(local.year, local.month, local.day)
      end

      # The compact 12-hour clock reading for +time+ in +tz+: minutes are
      # dropped on the hour ("3PM", not "3:00PM"), and the two instants with
      # a word of their own stand in for the number ("Midnight", "Noon") the
      # way a person would actually say either one aloud, rather than
      # "12AM"/"12PM".
      def clock(time, tz)
        local = TZInfo::Timezone.get(tz).utc_to_local(time.utc)
        hour, minute = local.hour, local.min
        return "Midnight" if hour.zero? && minute.zero?
        return "Noon" if hour == 12 && minute.zero?

        twelve = hour % 12
        twelve = 12 if twelve.zero?
        meridiem = hour < 12 ? "AM" : "PM"
        minute.zero? ? "#{twelve}#{meridiem}" : format("%d:%02d%s", twelve, minute, meridiem)
      end
    end
  end
end
