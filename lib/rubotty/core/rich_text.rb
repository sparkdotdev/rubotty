# frozen_string_literal: true

module Rubotty
  module Core
    # A formatting span over a range of characters in a {RichText}.
    #
    # Offsets are CHARACTER indices into the associated plain text, half open:
    # the span covers `text[begin_index...end_index]`. Adapters for platforms
    # that use UTF-16 code units (Telegram) convert with {Rubotty::Util::Utf16}.
    class Span
      # Styles every adapter is expected to understand or deliberately drop. An
      # adapter declares which of these it can render through
      # {Rubotty::Adapters::Capabilities#rich_text}; the renderer drops the rest.
      KINDS = %i[
        bold
        italic
        underline
        strikethrough
        spoiler
        code
        pre
        link
        mention
        blockquote
      ].freeze

      # Styles whose contents are verbatim: no nested formatting is rendered
      # inside them, and text escaping rules differ.
      OPAQUE_KINDS = %i[code pre].freeze

      attr_reader :kind, :begin_index, :end_index, :attributes

      # @param kind [Symbol] one of {KINDS}
      # @param begin_index [Integer] character offset, inclusive
      # @param end_index [Integer] character offset, exclusive
      # @param attributes [Hash] style payload. `:url` for :link,
      #   `:language` for :pre, `:user_id` and `:display` for :mention.
      def initialize(kind:, begin_index:, end_index:, attributes: {})
        @kind = kind.to_sym
        @begin_index = Integer(begin_index)
        @end_index = Integer(end_index)
        @attributes = attributes.freeze
        # Built here rather than per call: the walker compares style keys once
        # per character of every body it renders, for every target.
        @style_key = [@kind, @attributes].freeze
        freeze
      end

      def length = end_index - begin_index

      def empty? = length <= 0

      def opaque? = OPAQUE_KINDS.include?(kind)

      def known? = KINDS.include?(kind)

      # Identity used when comparing the set of styles active at a character
      # position. Two link spans with different targets are different styles.
      attr_reader :style_key

      def with_range(begin_index, end_index)
        self.class.new(kind: kind, begin_index: begin_index, end_index: end_index, attributes: attributes)
      end

      def ==(other)
        other.is_a?(Span) &&
          other.kind == kind &&
          other.begin_index == begin_index &&
          other.end_index == end_index &&
          other.attributes == attributes
      end
      alias eql? ==

      def hash = [kind, begin_index, end_index, attributes].hash

      def to_s
        "#<Span #{kind} #{begin_index}...#{end_index}#{attributes.empty? ? "" : " #{attributes.inspect}"}>"
      end
      alias inspect to_s
    end

    # The canonical rich text representation: flat UTF-8 text plus a list of
    # formatting spans. Parsing every platform's own markup into this shared
    # shape and rendering out of it is 2N converters rather than O(N^2).
    #
    # Spans may overlap arbitrarily. Renderers are responsible for producing
    # well nested output; see {Rubotty::Rendering::SpanWalker}.
    class RichText
      attr_reader :text, :spans

      # @param text [String] plain UTF-8 text with no markup
      # @param spans [Array<Span>]
      def initialize(text = "", spans = [])
        @text = text.to_s
        @spans = clamp(spans).freeze
        freeze
      end

      def self.plain(text) = new(text, [])

      def empty? = text.empty?

      def length = text.length

      def to_s = text

      # Character length once trailing and leading whitespace is ignored.
      # Used for "did this message have any content at all" checks.
      def blank? = text.strip.empty?

      # Returns a new RichText with +other+ appended, shifting the other side's
      # span offsets.
      def concat(other)
        other = RichText.plain(other.to_s) unless other.is_a?(RichText)
        shift = length
        shifted = other.spans.map { |s| s.with_range(s.begin_index + shift, s.end_index + shift) }
        RichText.new(text + other.text, spans + shifted)
      end
      alias + concat

      # Prefix the text with +prefix+ (plain, unformatted) and shift all spans.
      def prefix(prefix_text)
        RichText.plain(prefix_text).concat(self)
      end

      # Truncate to +max+ characters, dropping and trimming spans as needed.
      # +ellipsis+ is appended unformatted when truncation happens.
      def truncate(max, ellipsis: "…")
        return self if max.nil? || length <= max

        keep = [max - ellipsis.length, 0].max
        trimmed = spans.filter_map do |span|
          next nil if span.begin_index >= keep

          span.with_range(span.begin_index, [span.end_index, keep].min)
        end.reject(&:empty?)
        RichText.new(text[0, keep].to_s + ellipsis, trimmed)
      end

      # Keep only the first +count+ lines, trimming spans to match. Used for
      # reply quoting, where a multi line parent should not swamp the reply that
      # quotes it.
      def first_lines(count)
        return self if count.nil? || count <= 0

        # Walking the text a character at a time allocated one String per
        # character of the whole parent, which the bridge then paid again for
        # every target it fanned out to. #index stops at the count-th newline.
        cut = nil
        position = 0
        count.times do
          cut = text.index("\n", position)
          break if cut.nil?

          position = cut + 1
        end
        return self if cut.nil?

        truncate(cut, ellipsis: "")
      end

      # Replace ranges of the text, shifting every span to match. Some platforms
      # express a mention as a token that REPLACES the display text rather than
      # wrapping it (Discord wants `<@123>` where the reader sees a name), so the
      # text itself has to change.
      # @param edits [Array<Array(Range, String)>] character ranges (half open,
      #   as begin_index...end_index) and their replacements. Overlapping edits
      #   are not supported; the caller is expected to pass disjoint ranges.
      # @return [RichText]
      def splice(edits)
        return self if edits.nil? || edits.empty?

        ordered = edits.sort_by { |(range, _)| range.first }
        out = +""
        moved = []
        cursor = 0
        shift = 0

        ordered.each do |(range, replacement)|
          next if range.first < cursor

          out << text[cursor...range.first].to_s
          out << replacement
          # Spans that ended before this edit keep their positions; spans
          # covered by it are dropped, since their text no longer exists.
          moved.concat(shift_spans(spans, cursor, range.first, shift))
          shift += replacement.length - (range.last - range.first)
          cursor = range.last
        end

        out << text[cursor..].to_s
        moved.concat(shift_spans(spans, cursor, length, shift))
        RichText.new(out, moved)
      end

      def ==(other)
        other.is_a?(RichText) && other.text == text && other.spans == spans
      end
      alias eql? ==

      def hash = [text, spans].hash

      def inspect = "#<RichText #{text.inspect} spans=#{spans.size}>"

      private

      # Spans wholly inside [from, to) survive a splice, moved by +shift+.
      # Anything straddling an edit boundary is dropped: keeping it would attach
      # formatting to the wrong characters.
      def shift_spans(spans, from, to, shift)
        spans.filter_map do |span|
          next nil unless span.begin_index >= from && span.end_index <= to

          span.with_range(span.begin_index + shift, span.end_index + shift)
        end
      end

      # Drop spans that fall outside the text or are empty, and clip the rest: a
      # platform does send entities that run past the end of a truncated text.
      def clamp(spans)
        limit = @text.length
        Array(spans).filter_map do |span|
          next nil unless span.is_a?(Span)

          from = span.begin_index.clamp(0, limit)
          to = span.end_index.clamp(0, limit)
          next nil if to <= from

          from == span.begin_index && to == span.end_index ? span : span.with_range(from, to)
        end.sort_by { |s| [s.begin_index, -s.length, s.kind.to_s] }
      end
    end
  end
end
