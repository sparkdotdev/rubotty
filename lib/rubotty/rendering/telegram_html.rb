# frozen_string_literal: true

module Rubotty
  module Rendering
    # Renders canonical rich text as the HTML subset the Telegram Bot API accepts
    # with `parse_mode: HTML`. A tag outside Telegram's fixed whitelist makes the
    # API reject the whole message, so anything else is escaped.
    class TelegramHtml < SpanWalker
      SUPPORTED = %i[bold italic underline strikethrough spoiler code pre link mention blockquote].freeze

      def initialize
        super(supported: SUPPORTED)
      end

      # Escapes the three characters Telegram treats as markup in HTML mode.
      # Three literal gsubs rather than one regex pass on purpose: a literal
      # pattern takes String#gsub's fast substring search, and ordinary chat text
      # contains none of these, so all three passes usually copy and return.
      def self.escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end

      # Telegram has nothing like Discord's `<@id>`, a token the client itself
      # resolves to a display name, so the link text has to already be right:
      # the bridge rewrites a resolved mention's span before this ever runs
      # (see Features::Bridge#resolve_mentions), so #render just wraps it.

      protected

      def open_tag(span)
        case span.kind
        when :bold then "<b>"
        when :italic then "<i>"
        when :underline then "<u>"
        when :strikethrough then "<s>"
        when :spoiler then "<tg-spoiler>"
        when :code then "<code>"
        when :pre then pre_open(span)
        when :blockquote then "<blockquote>"
        when :link then span.attributes[:bare] ? "" : %(<a href="#{attribute_escape(span.attributes[:url])}">)
        when :mention then mention_open(span)
        else ""
        end
      end

      def close_tag(span)
        case span.kind
        when :bold then "</b>"
        when :italic then "</i>"
        when :underline then "</u>"
        when :strikethrough then "</s>"
        when :spoiler then "</tg-spoiler>"
        when :code then "</code>"
        when :pre then span.attributes[:language] ? "</code></pre>" : "</pre>"
        when :blockquote then "</blockquote>"
        when :link then span.attributes[:bare] ? "" : "</a>"
        when :mention then mention_close(span)
        else ""
        end
      end

      def escape(text) = self.class.escape(text)

      # Telegram still parses HTML entities inside <code> and <pre>.
      def escape_opaque(text) = self.class.escape(text)

      private

      def mention_close(span)
        return "</a>" if span.attributes[:telegram_id_for_target] || span.attributes[:tg_user_id]

        ""
      end

      def pre_open(span)
        language = span.attributes[:language]
        return "<pre>" if language.nil? || language.to_s.empty?

        %(<pre><code class="language-#{attribute_escape(language)}">)
      end

      # A mention only becomes a real Telegram mention once the target's Telegram id
      # is known; cross platform resolution happens in the router, not here.
      def mention_open(span)
        # The id the router resolved for THIS platform wins; tg_user_id is the
        # fallback for a mention that started on Telegram.
        id = span.attributes[:telegram_id_for_target] || span.attributes[:tg_user_id]
        return "" if id.nil?

        %(<a href="tg://user?id=#{attribute_escape(id)}">)
      end

      def attribute_escape(value)
        value.to_s.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
    end
  end
end
