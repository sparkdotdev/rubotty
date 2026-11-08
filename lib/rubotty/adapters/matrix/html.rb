# frozen_string_literal: true

module Rubotty
  module Adapters
    module Matrix
      # Renders canonical rich text as the HTML subset Matrix accepts in a
      # message's `formatted_body`, inheriting Telegram's whitelist with
      # three overrides: `<br/>` for a newline, `<span data-mx-spoiler>`, and
      # `<del>`. A mention wraps in an `<a>` to a matrix.to permalink, the
      # pill anchor a Matrix client resolves to a real, pinging mention, once
      # the target's Matrix user id is known; otherwise it stays plain text.
      class Html < Rendering::TelegramHtml
        SUPPORTED = %i[bold italic underline strikethrough spoiler code pre link mention blockquote].freeze

        def initialize
          super()
          @supported = SUPPORTED
        end

        protected

        def open_tag(span)
          case span.kind
          when :spoiler then "<span data-mx-spoiler>"
          when :strikethrough then "<del>"
          when :mention then mention_open(span)
          else super
          end
        end

        def close_tag(span)
          case span.kind
          when :spoiler then "</span>"
          when :strikethrough then "</del>"
          when :mention then mention_close(span)
          else super
          end
        end

        # HTML escape as the parent does, then turn ordinary text newlines into
        # explicit line breaks. escape_opaque is left to the parent, so newlines
        # inside a code block stay literal.
        def escape(text) = super.gsub("\n", "<br/>")

        private

        # A matrix.to permalink, the pill format MSC3952's own example uses
        # unencoded ("https://matrix.to/#/@ada:example.org"). Bare text, same
        # as an unresolved Telegram mention, until the bridge has annotated
        # the span with the target's own Matrix user id.
        def mention_open(span)
          id = span.attributes[:matrix_id_for_target]
          return "" if id.nil?

          %(<a href="https://matrix.to/#/#{attribute_escape(id)}">)
        end

        def mention_close(span)
          span.attributes[:matrix_id_for_target] ? "</a>" : ""
        end
      end
    end
  end
end
