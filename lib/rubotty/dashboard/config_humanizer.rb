# frozen_string_literal: true

module Rubotty
  module Dashboard
    # Turns a feature's raw config hash into small, human-legible rows: a
    # duration in seconds reads as "15s" or "2 days", a boolean as "Yes"/"No", a
    # list as short chips. Rows are unescaped, so the view has to escape them.
    module ConfigHumanizer
      module_function

      # Key-name fragments that mark a numeric field as a duration in seconds,
      # matched as a substring.
      DURATION_HINTS = %w[after ttl duration window timeout cooldown seconds
                           expires_in interval lifetime delay].freeze

      # Excluded from the duration heuristic above, so Backfill's interval_ms is
      # not rendered as 1000x too many seconds.
      MILLISECOND_SUFFIX = "_ms"

      # One row per top-level config key, in the hash's own order. An empty or
      # non-Hash config yields no rows.
      #
      # @return [Array<Hash>] { label:, text: } for a scalar or nested value,
      #   { label:, chips: } for a list
      def rows(config)
        return [] unless config.is_a?(Hash)

        config.map { |key, value| row_for(key, value) }
      end

      # A count of seconds as a short string: "0s", "45s", "1m 30s", "2 days".
      # The largest unit that fits, plus at most one smaller remainder unit.
      def duration(value)
        seconds = value.to_i
        return "0s" if seconds <= 0

        DURATION_UNITS.each_with_index do |(size, abbr, word), index|
          next if seconds < size

          whole, remainder = seconds.divmod(size)
          head = word ? "#{whole} #{word}#{"s" unless whole == 1}" : "#{whole}#{abbr}"
          tail = duration_remainder(remainder, DURATION_UNITS[(index + 1)..])
          return tail.empty? ? head : "#{head} #{tail}"
        end
        "#{seconds}s"
      end

      # size in seconds, short abbreviation, long word for units too coarse to
      # abbreviate legibly.
      DURATION_UNITS = [
        [604_800, "w", "week"],
        [86_400, "d", "day"],
        [3600, "h", nil],
        [60, "m", nil],
        [1, "s", nil]
      ].freeze
      private_constant :DURATION_UNITS

      def duration_remainder(remainder, smaller_units)
        return "" if remainder.zero? || smaller_units.empty?

        size, abbr, = smaller_units.first
        whole = remainder / size
        return "" if whole.zero?

        "#{whole}#{abbr}"
      end

      # A config key as a short label: "cleanup_after" -> "Cleanup after".
      def humanize_key(key)
        key.to_s.tr("_", " ").capitalize
      end

      # Whether a numeric field named +key+ renders as a duration.
      def duration_key?(key)
        name = key.to_s
        return false if name.end_with?(MILLISECOND_SUFFIX)

        DURATION_HINTS.any? { |hint| name.include?(hint) }
      end

      # One row for a config key/value pair, dispatched on the value's shape.
      def row_for(key, value)
        label = humanize_key(key)
        case value
        when true, false
          { label: label, text: value ? "Yes" : "No" }
        when Numeric
          { label: label, text: duration_key?(key) ? duration(value) : value.to_s }
        when Array
          if value.empty?
            { label: label, text: "none" }
          else
            hint = duration_key?(key)
            { label: label, chips: value.map { |item| hint && item.is_a?(Numeric) ? duration(item) : chip_text(item) } }
          end
        when Hash
          { label: label, text: value.empty? ? "none" : scalar_text(value) }
        when nil
          { label: label, text: "not set" }
        else
          { label: label, text: value.to_s }
        end
      end

      # A short label for one list item: a string or number as-is, a boolean as
      # yes/no, a mapping as its first non-empty string value.
      def chip_text(item)
        case item
        when Hash
          item.values.find { |v| v.is_a?(String) && !v.strip.empty? } || "entry"
        when true then "yes"
        when false then "no"
        else item.to_s
        end
      end

      # A nested Hash flattened to one comma-joined "Key: value, ..." line,
      # recursing through the same rules.
      def scalar_text(value)
        case value
        when true then "yes"
        when false then "no"
        when Hash
          value.empty? ? "none" : value.map { |k, v| "#{humanize_key(k)}: #{scalar_text(v)}" }.join(", ")
        when Array
          value.empty? ? "none" : value.map { |item| chip_text(item) }.join(", ")
        when nil
          "not set"
        else
          value.to_s
        end
      end
    end
  end
end
