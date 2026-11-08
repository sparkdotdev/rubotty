# frozen_string_literal: true

require "time"
require "tzinfo"

module Rubotty
  module Util
    # The shared fallback renderer behind Adapters::Base#render_timestamp. Every
    # adapter except Discord ends up here and has to pick one rendering to show
    # every reader.
    #
    # TZInfo carries the IANA database, so an event's named timezone renders at
    # its actual wall-clock time instead of a labelled UTC fallback.
    module EventTimestamps
      MINUTE = 60
      HOUR   = 60 * MINUTE
      DAY    = 24 * HOUR
      WEEK   = 7 * DAY

      # Largest to smallest, so a duration reports in its biggest whole unit.
      UNITS = [[WEEK, "week"], [DAY, "day"], [HOUR, "hour"], [MINUTE, "minute"], [1, "second"]].freeze

      module_function

      # @param time [Time]
      # @param style [Symbol] :full a calendar rendering, :relative a
      #   countdown ("in 3 days") or countup ("2 hours ago"), :both both
      # @param tz [String] a fixed offset, "UTC", or an IANA zone name
      # @param now [Time] the instant the countdown is measured from, so a
      #   caller holding its own clock phrases the gap the way it already did
      # @return [String]
      def format(time, style: :full, tz: "UTC", now: Time.now)
        case style.to_sym
        when :relative then relative(time, now: now)
        when :both then "#{full(time, tz)} (#{relative(time, now: now)})"
        else full(time, tz)
        end
      end

      # A calendar rendering in +tz+, degrading to a labelled UTC render for a
      # zone name neither TZInfo nor Ruby can resolve.
      def full(time, tz)
        local, unresolved = localize(time, tz)
        rendered = local.strftime("%a, %d %b %Y %H:%M %z")
        unresolved ? "#{rendered} (#{unresolved})" : rendered
      end

      # "in 3 days" / "2 hours ago" / "just now", relative to +now+ and timezone
      # independent.
      def relative(time, now: Time.now)
        # Floored on both sides, so a store that keeps whole seconds cannot make
        # this and a caller's own interval answer the same question differently.
        diff = time.to_i - now.to_i
        return "just now" if diff.abs < 30

        amount, unit = largest_unit(diff.abs)
        phrase = "#{amount} #{unit}#{"s" unless amount == 1}"
        diff.positive? ? "in #{phrase}" : "#{phrase} ago"
      end

      # The largest whole unit a duration (seconds, always >= 0) fits into.
      def largest_unit(seconds)
        UNITS.each do |threshold, name|
          return [(seconds / threshold).to_i, name] if seconds >= threshold
        end
        [seconds.to_i, "second"]
      end

      # [localized Time, label or nil]. A nil label means +tz+ rendered exactly as
      # asked; a label names the zone that could not be resolved, so nobody mistakes
      # the UTC render for that zone's own time.
      def localize(time, tz)
        zone = tz.to_s.strip
        zone = "UTC" if zone.empty?
        [TZInfo::Timezone.get(zone).utc_to_local(time.utc), nil]
      rescue TZInfo::InvalidTimezoneIdentifier
        fixed_offset(time, zone)
      end

      # @api private
      # Ruby understands a fixed offset even though TZInfo quite reasonably
      # only accepts named zones. Keep that useful legacy form, but label an
      # unrecognised zone rather than pretending the UTC fallback was local.
      def fixed_offset(time, zone)
        [time.getlocal(zone), nil]
      rescue ArgumentError
        [time.getlocal("UTC"), zone]
      end
    end
  end
end
