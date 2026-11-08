# frozen_string_literal: true

require "rexml/document"
require "uri"

module Rubotty
  module Adapters
    module Matrix
      # Parses a Matrix formatted_body back into Core::Span values, the reverse
      # of Html. Only the tags Html itself emits are recognised; anything else
      # is dropped and its text kept. A formatted_body that is not well formed
      # XML (a client sent something Html would never write) yields nil, and
      # the caller falls back to the plain body.
      class RichTextParser
        TAGS = {
          "b" => :bold, "strong" => :bold,
          "i" => :italic, "em" => :italic,
          "u" => :underline,
          "del" => :strikethrough, "s" => :strikethrough, "strike" => :strikethrough,
          "code" => :code,
          "blockquote" => :blockquote
        }.freeze

        # A matrix.to permalink whose identifier is a user id, the pill any
        # Matrix client (Element included) renders for a mention. The sigil
        # may or may not be percent-encoded: MSC3952's own example leaves it
        # bare ("https://matrix.to/#/@ada:example.org"), which is what real
        # clients send, but the matrix.to appendix allows the escaped form
        # too, so both are matched.
        MATRIX_TO_USER = %r{\Ahttps://matrix\.to/#/(?:@|%40)[^/?]+\z}.freeze

        def self.parse(html) = new.parse(html)

        # data-mx-spoiler is valid Matrix markup with no value at all (Html
        # itself writes it bare), which XML has no syntax for; a bare value is
        # given one so REXML can parse the rest of the document around it.
        BARE_SPOILER_ATTRIBUTE = /\bdata-mx-spoiler(?!=)/

        # A lone "&" outside any real entity reference: valid in the HTML
        # subset real clients actually write (a URL's query string, "Fish &
        # Chips"), but not in XML, which requires every one escaped.
        BARE_AMPERSAND = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)/.freeze

        # The handful of void elements a client is liable to leave open
        # ("<br>") rather than self-close ("<br/>"), the other common way
        # real, valid HTML fails to also be valid XML. Matched with an
        # optional trailing "/" already there so this stays idempotent
        # against a client that already self-closed it correctly.
        VOID_ELEMENTS = %r{<(br|hr|img)((?:\s[^<>]*)?)/?>}i.freeze

        def parse(html)
          return nil if html.to_s.strip.empty?

          normalized = normalize(html.to_s)
          root = REXML::Document.new("<rubotty-root>#{normalized}</rubotty-root>").root
          return nil if root.nil?

          @text = +""
          @spans = []
          walk(root)
          Core::RichText.new(@text, @spans)
        rescue REXML::ParseException, RuntimeError
          nil
        end

        private

        # Repairs the two most common ways a real client's HTML (valid HTML,
        # invalid XML) fails REXML outright and silently degrades the whole
        # message to plain text, rather than just the one malformed span a
        # stricter reader would still recover the rest of the message around.
        def normalize(html)
          html.gsub(BARE_SPOILER_ATTRIBUTE, 'data-mx-spoiler=""')
              .gsub(BARE_AMPERSAND, "&amp;")
              .gsub(VOID_ELEMENTS) { "<#{Regexp.last_match(1)}#{Regexp.last_match(2)}/>" }
        end

        def walk(node)
          node.children.each { |child| visit(child) }
        end

        def visit(node)
          case node
          when REXML::Text then @text << node.value.to_s
          when REXML::Element then visit_element(node)
          end
        end

        def visit_element(node)
          case node.name
          when "mx-reply" then nil # the quoted parent, reconstructed by the router
          when "br" then @text << "\n"
          when "a" then link(node)
          when "pre" then pre(node)
          when "span" then spoiler(node)
          else
            kind = TAGS[node.name]
            kind ? span_for(node, kind) : walk(node)
          end
        end

        def link(node)
          href = node.attributes["href"]
          return walk(node) if href.to_s.empty?

          mxid = mentioned_user_id(href)
          return span_for(node, :mention, attributes: { matrix_id: mxid, username: localpart(mxid) }) if mxid

          span_for(node, :link, attributes: { url: href })
        end

        # The user id a matrix.to link names, or nil for a link to a room, an
        # event, or anywhere else. #resolve_mention on the receiving side
        # matches Discord and Telegram's own mention attributes, keyed the
        # same way (see Core::Directory#resolve_mention).
        def mentioned_user_id(href)
          return nil unless MATRIX_TO_USER.match?(href.to_s)

          mxid = URI::DEFAULT_PARSER.unescape(href.to_s.delete_prefix("https://matrix.to/#/"))
          mxid.match?(/\A@[^:@]+:.+\z/) ? mxid : nil
        end

        def localpart(mxid) = mxid[1...mxid.index(":")]

        def spoiler(node)
          return span_for(node, :spoiler) if node.attributes["data-mx-spoiler"]

          walk(node)
        end

        def pre(node)
          code = node.elements["code"]
          language = code&.attributes&.[]("class")&.to_s&.delete_prefix("language-")
          begin_index = @text.length
          walk(code || node)
          add_span(:pre, begin_index, attributes: language.to_s.empty? ? {} : { language: language })
        end

        def span_for(node, kind, attributes: {})
          begin_index = @text.length
          walk(node)
          add_span(kind, begin_index, attributes: attributes)
        end

        def add_span(kind, begin_index, attributes: {})
          end_index = @text.length
          return if end_index <= begin_index

          @spans << Core::Span.new(kind: kind, begin_index: begin_index, end_index: end_index, attributes: attributes)
        end
      end
    end
  end
end
