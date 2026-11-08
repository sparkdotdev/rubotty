# frozen_string_literal: true

module Rubotty
  module Rendering
    # Turns a {Rubotty::Core::RichText} into a markup string. Canonical spans
    # may overlap without nesting while the targets require well nested
    # output, so the active set is recomputed per character and the open
    # stack unwound to match. Subclasses supply the markup through
    # {#open_tag}, {#close_tag} and {#escape}; a style the target cannot
    # express is declared unsupported and dropped rather than leaked as
    # literal markup.
    class SpanWalker
      # @param supported [Array<Symbol>, :all] span kinds this renderer emits
      def initialize(supported: :all)
        @supported = supported == :all ? Core::Span::KINDS : Array(supported).map(&:to_sym)
      end

      attr_reader :supported

      # @param rich [Core::RichText]
      # @return [String]
      def render(rich)
        text = rich.text
        spans = usable_spans(rich).map { |span| mark_bare_link(span, text) }
        return escape(text) if spans.empty?

        out = +""
        stack = []
        # The active set can only change where a span begins or ends, so the
        # text is walked in runs between those offsets rather than character by
        # character. Both the set and the escaping are constant inside a run,
        # which is what lets one escape call cover the whole of it.
        cuts = span_boundaries(spans, text.length)

        cuts.each_cons(2) do |from, to|
          active = spans.select { |span| span.begin_index <= from && from < span.end_index }
          reconcile(out, stack, active)
          next if to <= from

          run = text[from...to]
          # Inside an opaque span (inline code, code block) the target's escape
          # rules differ: markup characters are literal, so escaping them would
          # show the escape sequence to the reader.
          out << (opaque?(stack) ? escape_opaque(run) : escape(run))
        end

        close_all(out, stack)
        out
      end

      protected

      # @return [String] markup that begins +span+
      def open_tag(_span) = ""

      # @return [String] markup that ends +span+
      def close_tag(_span) = ""

      # Escape one character of ordinary text for the target markup.
      def escape(text) = text

      # Escape one character appearing inside an opaque (code) span.
      def escape_opaque(text) = text

      private

      # Every offset where the active set can change, in order, always starting
      # at 0 and ending at +length+ so the first run opens correctly and the last
      # one reaches the end of the text.
      def span_boundaries(spans, length)
        cuts = [0, length]
        spans.each do |span|
          cuts << span.begin_index
          cuts << span.end_index
        end
        cuts.select { |cut| cut >= 0 && cut <= length }.uniq.sort
      end

      # Sorted here, once, rather than inside the render loop: the order is the
      # nesting order the reconciler emits tags in and it never varies by
      # character. The kind is part of the key, matching {RichText#clamp}'s own
      # sort, because #sort_by does not promise to keep two spans that start at
      # the same place and cover the same length in their original order.
      def usable_spans(rich)
        spans = rich.spans.select { |span| @supported.include?(span.kind) }
                    .sort_by { |span| [span.begin_index, -span.length, span.kind.to_s] }
        # An opaque span swallows everything inside it, so any span contained
        # within one is dropped up front rather than being suppressed later.
        opaque = spans.select(&:opaque?)
        return spans if opaque.empty?

        spans.reject do |span|
          !span.opaque? && opaque.any? { |o| span.begin_index >= o.begin_index && span.end_index <= o.end_index }
        end
      end

      def opaque?(stack) = stack.any?(&:opaque?)

      # A link span whose covered text is exactly its own target is already
      # redundant: Telegram auto-links a bare URL this way, so the canonical
      # rich text can carry a link span labelled with its own target. Flagged
      # here, where the covered text is available, so a renderer's own
      # open_tag/close_tag can skip the brackets or anchor it would otherwise
      # wrap a self labelled link in.
      def mark_bare_link(span, text)
        return span unless span.kind == :link
        return span if span.attributes[:bare]
        return span unless text[span.begin_index...span.end_index] == span.attributes[:url]

        Core::Span.new(kind: span.kind, begin_index: span.begin_index, end_index: span.end_index,
                        attributes: span.attributes.merge(bare: true))
      end

      # Bring the open stack in line with the set of styles that should be
      # active, emitting the minimum number of tags.
      def reconcile(out, stack, active)
        active_keys = active.map(&:style_key)

        # Find how much of the current stack is still valid.
        keep = 0
        keep += 1 while keep < stack.size && active_keys.include?(stack[keep].style_key)

        # Unwind everything above that point, innermost first.
        while stack.size > keep
          span = stack.pop
          out << close_tag(span)
        end

        open_keys = stack.map(&:style_key)
        active.each do |span|
          next if open_keys.include?(span.style_key)

          stack << span
          out << open_tag(span)
        end
      end

      def close_all(out, stack)
        out << close_tag(stack.pop) while stack.any?
      end
    end
  end
end
