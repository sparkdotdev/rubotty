# frozen_string_literal: true

module Rubotty
  module Core
    # A "key=value key=value ..." reader shared by /schedule, /event and
    # /reschedule. An unquoted value runs until the next word shaped like
    # key=, recognised or not, so an apostrophe or an unquoted multi-word
    # value never breaks the parse. Double quotes are the escape hatch for
    # a value that must hold literal key=-looking text of its own. Knows
    # nothing about which keys a command accepts; that judgment stays with
    # the caller, same as its own ALLOWED_FIELDS or FIELD_ALIASES already do.
    module KeyedArguments
      KEY = /[A-Za-z][A-Za-z0-9_]*/

      # An opening quote to the closer it pairs with: the ASCII pair, and
      # the curly pair iOS and macOS substitute automatically as someone
      # types, so a value quoted on a phone is still recognised as quoted.
      # A lone curly apostrophe (the closing curly quote doing double duty)
      # is never in here, so it stays an ordinary character, same as "'".
      QUOTE_PAIRS = { '"' => '"', "“" => "”" }.freeze

      module_function

      # The inverse of {.parse} for one field: "name=value", double-quoted
      # (with an internal quote or backslash escaped) whenever the value
      # holds whitespace or a quote of its own, so it survives as one field
      # no matter what it holds. Shared by every surface that rebuilds a
      # command line a person could have typed.
      def field(name, value)
        text = value.to_s
        return "#{name}=#{text}" unless text.match?(/[\s"]/)

        "#{name}=\"#{text.gsub(/["\\]/) { |char| "\\#{char}" }}\""
      end

      # @param text [String]
      # @return [Hash{String=>String}, nil] fields keyed by the lowercased
      #   name as typed, or nil for text that does not read as a run of
      #   key=value pairs: leading text before the first key, an unmatched
      #   quote, or text stuck onto the end of a quoted value.
      def parse(text)
        raw = text.to_s
        match = find_key(raw, 0)
        return nil unless raw[0...(match ? match[:start] : raw.length)].strip.empty?

        fields = {}
        while match
          value, next_match = read_value(raw, match[:value_start])
          return nil if value.nil?

          fields[match[:key]] = value
          match = next_match
        end
        fields
      end

      # @api private
      # The value starting at +value_start+ and the key that follows it (nil
      # at end of input): quoted content up to its matching close, or plain
      # text up to the next key, either way with no gap left unaccounted for.
      def read_value(raw, value_start)
        closer = QUOTE_PAIRS[raw[value_start]]
        if closer
          close = find_close_quote(raw, value_start + 1, closer)
          return [nil, nil] if close.nil?

          following = find_key(raw, close + 1)
          gap = raw[(close + 1)...(following ? following[:start] : raw.length)]
          return [nil, nil] unless gap.strip.empty?

          [unescape(raw[(value_start + 1)...close]), following]
        else
          following = find_key(raw, value_start)
          value_end = following ? following[:start] : raw.length
          [raw[value_start...value_end].strip, following]
        end
      end

      # @api private
      # The next word shaped like key= at a whitespace (or string-start)
      # boundary from +from+ onward, or nil. +from+ itself grants no
      # boundary: a value's own first character never doubles as a key.
      def find_key(raw, from)
        i = from
        while i < raw.length
          if i.zero? || whitespace?(raw[i - 1])
            m = raw.match(/\G(#{KEY})=/, i)
            return { key: m[1].downcase, start: i, value_start: i + m[0].length } if m
          end
          i += 1
        end
        nil
      end

      # @api private
      def find_close_quote(raw, from, closer)
        i = from
        while i < raw.length
          if raw[i] == "\\"
            i += 2
            next
          end
          return i if raw[i] == closer

          i += 1
        end
        nil
      end

      # @api private
      def unescape(text) = text.gsub(/\\(.)/) { Regexp.last_match(1) }

      # @api private
      def whitespace?(char) = !!(char =~ /\s/)
    end
  end
end
