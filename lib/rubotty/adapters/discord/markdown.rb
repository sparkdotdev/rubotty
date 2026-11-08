# frozen_string_literal: true

require "strscan"

module Rubotty
  module Adapters
    module Discord
      # Parses Discord flavoured Markdown into canonical rich text via
      # recursive descent over an ordered rule list: the first matching
      # rule wins, and a container rule (bold, italic, link) re-parses its
      # own contents to make nesting work. Rule order is load bearing:
      # escapes first, so `\*` never opens emphasis; code next, since its
      # contents are verbatim; `**` before `*` and `__` before `_`, or bold
      # and underline become two adjacent italics. Headings (`# `), lists
      # and horizontal rules pass through as literal text.
      module Markdown
        # A parsed node. `kind` is :text or one of {Core::Span::KINDS}.
        Node = Struct.new(:kind, :text, :children, :attributes, keyword_init: true)

        # A backslash makes the following markup character literal, restricted to
        # characters that actually mean something.
        ESCAPE = /\\([*_~`|\\>\[\]()])/

        CODE_BLOCK = /```(?:([a-zA-Z0-9+#_.-]*)\n)?(.*?)```/m
        # Discord accepts any run of backticks as an inline code delimiter.
        INLINE_CODE = /(`+)([^\n]*?)\1/

        # Custom emoji: <:name:id>, animated <a:name:id>.
        EMOJI = /<(a)?:(\w+):(\d+)>/
        # A Discord or Fluxer id is a snowflake, all digits; a Stoat id is a
        # Crockford base32 ULID, mixing digits and letters. Both parsers share
        # this module (see Stoat::Inbound#parse_markdown), so the id class
        # covers either shape rather than being Discord only.
        MENTION_ID = /[0-9A-Za-z]+/
        USER_MENTION = /<@!?(#{MENTION_ID})>/
        ROLE_MENTION = /<@&(#{MENTION_ID})>/
        CHANNEL_MENTION = /<\#(#{MENTION_ID})>/
        # Rendered client side in the reader's own timezone. Nothing else can
        # reproduce that, so the raw form is preserved.
        TIMESTAMP = /<t:(-?\d+)(?::[tTdDfFR])?>/
        # Angle brackets around a link suppress the embed; they are syntax that
        # never becomes part of the URL.
        SUPPRESSED_LINK = %r{<(https?://[^\s>]+)>}
        # Two forms, and the bracketed one must be tried first: an angle
        # bracketed target may legally contain parentheses.
        MASKED_LINK_BRACKETED = /\[([^\]\n]+)\]\(\s*<([^>\s]+)>\s*\)/
        MASKED_LINK = /\[([^\]\n]+)\]\(\s*([^)\s]+)\s*\)/

        # `***x***` is bold italic, recognised before `**`, which would otherwise
        # consume the opening pair and leave the content unbalanced.
        BOLD_ITALIC = /\*\*\*(.+?)\*\*\*/m
        AUTOLINK = %r{https?://[^\s<>()\[\]]+}

        BLOCK_QUOTE = /\A>>>[ ](.*)\z/m
        LINE_QUOTE = /\A>[ ]?(.*)\z/

        # Longer delimiters must be attempted before shorter ones that prefix
        # them, or `**bold**` parses as two empty italics.
        PAIRED = [
          ["||", :spoiler, false],
          ["**", :bold, false],
          ["__", :underline, false],
          ["~~", :strikethrough, false],
          ["*", :italic, true],
          ["_", :italic, true]
        ].freeze

        MAX_DEPTH = 12

        module_function

        # @param source [String, nil]
        # @param resolver [#call, nil] given (:user | :role | :channel, id)
        #   returns a display string, or nil to fall back to a marker
        # @return [Core::RichText]
        def parse(source, resolver: nil)
          return Core::RichText.new if source.nil? || source.to_s.empty?

          body, quoted = strip_quotes(preprocess(source.to_s))
          rich = flatten(parse_nodes(body, resolver))
          return rich unless quoted && !rich.empty?

          Core::RichText.new(
            rich.text,
            rich.spans + [Core::Span.new(kind: :blockquote, begin_index: 0, end_index: rich.length)]
          )
        end

        # Discord's client inserts a zero width space after @ in some mentions,
        # which would otherwise be relayed as an invisible character.
        def preprocess(source)
          source.gsub("@​", "@")
        end

        # @return [Array(String, Boolean)] the unquoted text, and whether it was
        #   quoted at all
        def strip_quotes(source)
          if (match = BLOCK_QUOTE.match(source))
            return [match[1], true]
          end

          lines = source.split("\n", -1)
          return [source, false] unless lines.any? { |line| line.start_with?(">") }
          return [source, false] unless lines.all? { |line| line.empty? || line.start_with?(">") }

          [lines.map { |line| LINE_QUOTE.match(line)&.[](1) || line }.join("\n"), true]
        end

        def parse_nodes(source, resolver, depth = 0)
          # Guard against pathological input nesting delimiters thousands deep,
          # which would otherwise exhaust the stack.
          return [text_node(source)] if depth > MAX_DEPTH

          nodes = []
          scanner = StringScanner.new(source)
          buffer = +""

          until scanner.eos?
            node = match_construct(scanner, resolver, depth)
            if node
              nodes << text_node(buffer) unless buffer.empty?
              buffer = +""
              nodes << node
            else
              buffer << scanner.getch
            end
          end

          nodes << text_node(buffer) unless buffer.empty?
          nodes
        end

        # Try each rule at the scanner's current position. Returns nil when none
        # matches, meaning this character is literal text.
        def match_construct(scanner, resolver, depth)
          match_escape(scanner) ||
            match_code(scanner) ||
            match_angle_construct(scanner, resolver) ||
            match_link(scanner, resolver, depth) ||
            match_emphasis(scanner, resolver, depth) ||
            match_autolink(scanner)
        end

        def match_escape(scanner)
          return nil unless scanner.scan(ESCAPE)

          text_node(scanner[1])
        end

        def match_code(scanner)
          if scanner.scan(CODE_BLOCK)
            language = presence(scanner[1])
            body = scanner[2].to_s.sub(/\A\n/, "").sub(/\n\z/, "")
            return container(:pre, [text_node(body)], language: language)
          end

          start = scanner.pos
          if scanner.scan(INLINE_CODE)
            body = scanner[2].to_s
            return container(:code, [text_node(body)]) unless body.strip.empty?

            # An empty pair of backticks renders as literal text rather than a code span.
            scanner.pos = start
          end
          nil
        end

        # Everything spelled `<...>`: emoji, mentions, timestamps, and links
        # whose embed has been suppressed.
        def match_angle_construct(scanner, resolver)
          if scanner.scan(EMOJI)
            return emoji_node(scanner[2], scanner[3], animated: !scanner[1].nil?)
          end
          return mention_node(:user, scanner[1], resolver) if scanner.scan(USER_MENTION)
          return mention_node(:role, scanner[1], resolver) if scanner.scan(ROLE_MENTION)
          return mention_node(:channel, scanner[1], resolver) if scanner.scan(CHANNEL_MENTION)
          return text_node(scanner.matched) if scanner.scan(TIMESTAMP)

          if scanner.scan(SUPPRESSED_LINK)
            url = scanner[1]
            return container(:link, [text_node(url)], url: url)
          end
          nil
        end

        # Masked links are matched before emphasis so a label may contain it.
        def match_link(scanner, resolver, depth)
          return nil unless scanner.scan(MASKED_LINK_BRACKETED) || scanner.scan(MASKED_LINK)

          label = scanner[1]
          url = scanner[2]
          container(:link, parse_nodes(label, resolver, depth + 1), url: url)
        end

        def match_emphasis(scanner, resolver, depth)
          if scanner.scan(BOLD_ITALIC)
            inner = parse_nodes(scanner[1], resolver, depth + 1)
            return container(:bold, [container(:italic, inner)])
          end

          PAIRED.each do |delimiter, kind, single|
            node = scan_delimited(scanner, delimiter, kind, resolver, depth, single: single)
            return node if node
          end
          nil
        end

        def match_autolink(scanner)
          return nil unless scanner.scan(AUTOLINK)

          url = scanner.matched
          container(:link, [text_node(url)], url: url)
        end

        # Match `<delimiter>content<delimiter>` at the current position. A single
        # character delimiter may not wrap whitespace (`2 * 3 * 4` stays
        # arithmetic) or sit against a word character (`some_method_name`).
        def scan_delimited(scanner, delimiter, kind, resolver, depth, single: false)
          start = scanner.pos
          return nil if single && delimiter == "_" && word_char?(scanner.string[start - 1]) && start.positive?

          quoted = Regexp.escape(delimiter)
          pattern = if single
                      # Non space at both ends, nothing in between crossing a
                      # newline or containing the delimiter.
                      /#{quoted}([^#{quoted}\s](?:[^#{quoted}\n]*[^#{quoted}\s])?)#{quoted}(?!#{quoted})/
                    else
                      /#{quoted}(.+?)#{quoted}/m
                    end
          return nil unless scanner.scan(pattern)

          inner = scanner[1]
          if inner.nil? || inner.empty? || (single && delimiter == "_" && word_char?(scanner.peek(1)))
            scanner.pos = start
            return nil
          end

          container(kind, parse_nodes(inner, resolver, depth + 1))
        end

        def word_char?(char) = !char.nil? && !char.empty? && char.match?(/\w/)

        def text_node(text) = Node.new(kind: :text, text: text, children: [], attributes: {})

        def container(kind, children, **attributes)
          Node.new(kind: kind, text: nil, children: children, attributes: attributes.compact)
        end

        # A custom emoji has no equivalent anywhere else, so it becomes its
        # shortcode: `:partyparrot:` rather than a dangling numeric id.
        def emoji_node(name, id, animated:)
          Node.new(
            kind: :text, text: ":#{name}:", children: [],
            attributes: { emoji_id: id, animated: animated }
          )
        end

        def mention_node(type, id, resolver)
          display = resolver&.call(type, id) || fallback_mention(type)
          # A channel reference is not a person, so it is plain text rather than
          # a :mention span, which other adapters may try to turn into a ping.
          kind = type == :channel ? :text : :mention
          Node.new(
            kind: kind, text: display, children: [],
            attributes: { discord_id: id, mention_type: type }
          )
        end

        # When a mention cannot be resolved (no cache, or the bot cannot see the
        # member) the numeric form is useless to a human.
        def fallback_mention(type)
          case type
          when :user then "@unknown-user"
          when :role then "@unknown-role"
          else "#unknown-channel"
          end
        end

        def presence(value)
          value = value.to_s.strip
          value.empty? ? nil : value
        end

        # Walk the tree, accumulating text and recording a span for each
        # container over the range its contents ended up occupying.
        def flatten(nodes)
          text = +""
          spans = []
          emit(nodes, text, spans)
          Core::RichText.new(text, spans)
        end

        def emit(nodes, text, spans)
          nodes.each do |node|
            if node.kind == :text
              text << node.text.to_s
              next
            end

            start = text.length
            if node.text
              text << node.text
            else
              emit(node.children, text, spans)
            end
            finish = text.length
            next if finish <= start

            spans << Core::Span.new(
              kind: node.kind, begin_index: start, end_index: finish,
              attributes: node.attributes || {}
            )
          end
        end
      end
    end
  end
end
