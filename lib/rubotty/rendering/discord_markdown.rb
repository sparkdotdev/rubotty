# frozen_string_literal: true

module Rubotty
  module Rendering
    # Renders canonical rich text as Discord flavoured Markdown, the delimiter-pair
    # counterpart to the tag-based targets.
    class DiscordMarkdown < SpanWalker
      SUPPORTED = %i[bold italic underline strikethrough spoiler code pre link blockquote].freeze

      # Characters that would otherwise be interpreted as Discord markup.
      ESCAPE = /([\\*_~`|])/

      # Both Discord clones this bot bridges to, Fluxer and Stoat, render their
      # `<@id>` mention markup exactly this way and share this class to produce
      # it. Each is still its own identity space in the router (see
      # {Bridge#resolve_mentions}, keyed on the TARGET's own adapter name), so
      # the span attribute a resolved mention carries is `fluxer_id_for_target`
      # or `stoat_id_for_target` there, never Discord's own key. +mention_key+
      # is which of those this instance looks for; defaulting to Discord's own
      # keeps every existing caller that builds one with no arguments correct.
      def initialize(mention_key: :discord_id_for_target)
        super(supported: SUPPORTED)
        @mention_key = mention_key
      end

      # Discord expresses a mention as `<@id>`, a token that REPLACES the display
      # name rather than wrapping it, so the substitution happens before walking.
      # An unresolved mention stays as the plain name and simply does not ping.
      def render(rich)
        super(rewrite_mentions(rich))
      end

      def rewrite_mentions(rich)
        edits = rich.spans.filter_map do |span|
          next nil unless span.kind == :mention

          id = span.attributes[@mention_key]
          next nil if id.nil?

          [(span.begin_index...span.end_index), "<@#{id}>"]
        end
        rich.splice(edits)
      end

      protected

      def open_tag(span)
        case span.kind
        when :bold then "**"
        when :italic then "*"
        when :underline then "__"
        when :strikethrough then "~~"
        when :spoiler then "||"
        when :code then "`"
        when :pre then "```#{span.attributes[:language]}\n"
        when :blockquote then ">>> "
        when :link then span.attributes[:bare] ? "" : "["
        else ""
        end
      end

      def close_tag(span)
        case span.kind
        when :bold then "**"
        when :italic then "*"
        when :underline then "__"
        when :strikethrough then "~~"
        when :spoiler then "||"
        when :code then "`"
        when :pre then "\n```"
        when :blockquote then ""
        when :link then span.attributes[:bare] ? "" : "](#{sanitise_url(span.attributes[:url])})"
        else ""
        end
      end

      def escape(text) = text.to_s.gsub(ESCAPE) { "\\#{Regexp.last_match(1)}" }

      # Discord has no escape for a backtick inside a code span, so it is replaced
      # with the visually identical modifier letter.
      def escape_opaque(text) = text.to_s.tr("`", "ˋ")

      private

      # Parentheses inside a Markdown link target break the link. Percent
      # encoding them is valid in a URL and renders identically.
      def sanitise_url(url)
        url.to_s.gsub("(", "%28").gsub(")", "%29").gsub(" ", "%20")
      end
    end
  end
end
