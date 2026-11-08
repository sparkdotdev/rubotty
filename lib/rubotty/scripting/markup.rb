# frozen_string_literal: true

module Rubotty
  module Scripting
    # Styled text from a script, without a second rendering path.
    # rubotty.bold("foo") and friends return sentinels, not markdown (which
    # would collide with the member's own text), and Ruby turns them into
    # RichText spans so everything downstream is the normal path. They live
    # in the Private Use Area and are stripped from inbound text, so a member
    # cannot type one and forge formatting.
    module Markup
      # U+E000 opens, U+E001 closes. Between the opener and the text sits one
      # character naming the style, so a span costs three characters and needs
      # no escaping.
      OPEN = "\u{E000}"
      CLOSE = "\u{E001}"

      # Style name to its one-character code. Only kinds Core::Span already
      # knows, since anything else has nowhere to render to.
      KINDS = {
        "bold" => "b",
        "italic" => "i",
        "underline" => "u",
        "strikethrough" => "s",
        "spoiler" => "!",
        "code" => "c",
        "pre" => "p",
        "blockquote" => "q",
        "mention" => "@"
      }.freeze

      BY_CODE = KINDS.invert.freeze

      SENTINEL = /[#{OPEN}#{CLOSE}]/

      module_function

      # Wrap +text+ in the sentinel for +kind+, which is what rubotty.bold and
      # friends return.
      def wrap(kind, text)
        code = KINDS[kind.to_s]
        return text.to_s if code.nil?

        "#{OPEN}#{code}#{text}#{CLOSE}"
      end

      # A mention span carries the handle in its own text, so the parser reads
      # the name back out of the slice. The bridge resolves it per platform, and
      # a name nobody matches stays ordinary text that does not ping.
      def mention(name)
        handle = name.to_s.strip.delete_prefix("@")
        return "" if handle.empty?

        wrap("mention", "@#{handle}")
      end

      # Remove every sentinel from text that came from outside. Without it a
      # member could paste a private-use character and have a rule that echoes
      # their message render formatting they chose.
      def strip(text) = text.to_s.gsub(SENTINEL, "")

      # Turn a script's answer into RichText, resolving nested spans. Unbalanced
      # sentinels are tolerated: a script that loses a closer should produce
      # slightly wrong formatting rather than a failed invocation.
      def to_rich_text(source)
        text = +""
        spans = []
        open = []

        chars = source.to_s.chars
        index = 0
        while index < chars.length
          char = chars[index]
          case char
          when OPEN
            kind = BY_CODE[chars[index + 1]]
            open.push([kind, text.length]) if kind
            index += kind ? 2 : 1
          when CLOSE
            kind, from = open.pop
            spans << span_for(kind, from, text) if kind
            index += 1
          else
            text << char
            index += 1
          end
        end

        # Anything still open ran to the end of the string.
        open.reverse_each { |kind, from| spans << span_for(kind, from, text) }

        Core::RichText.new(text, spans.sort_by(&:begin_index))
      end

      # A mention needs the handle it names. Every other kind is pure styling
      # and carries nothing.
      def span_for(kind, from, text)
        attributes = {}
        attributes[:username] = text[from, text.length - from].to_s.delete_prefix("@") if kind == "mention"
        Core::Span.new(kind: kind, begin_index: from, end_index: text.length, attributes: attributes)
      end

      # Whether this string carries any styling, so a caller can skip the parse
      # for the common plain answer.
      def styled?(source) = source.to_s.match?(SENTINEL)

      # The shortest limit among the platforms a room spans, so a reply fits
      # everywhere. Unlisted platforms, Matrix and XMPP included, get DEFAULT_LIMIT.
      LIMITS = { "irc" => 400, "discord" => 2000, "telegram" => 4096,
                 "fluxer" => 2000, "stoat" => 2000 }.freeze
      DEFAULT_LIMIT = 2000

      def limit_for(platforms)
        found = Array(platforms).filter_map { |name| LIMITS[name.to_s] }
        found.empty? ? DEFAULT_LIMIT : found.min
      end

      # Truncate on a word boundary where one is close. Sentinels are stripped
      # first, since a dangling opener would style the rest of the message.
      def truncate(text, platforms)
        limit = limit_for(platforms)
        plain = strip(text.to_s)
        return plain if plain.length <= limit

        cut = plain[0, limit - 1]
        boundary = cut.rindex(/\s/)
        cut = cut[0, boundary] if boundary && boundary > limit - 40
        "#{cut}…"
      end
    end
  end
end
