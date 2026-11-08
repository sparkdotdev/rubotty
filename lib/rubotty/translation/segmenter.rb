# frozen_string_literal: true

module Rubotty
  module Translation
    # Keeps code, URLs, mentions and custom emoji out of what actually gets
    # sent to LibreTranslate, and puts the exact original characters back
    # afterwards, wherever the translated sentence put the marker: each
    # protected run is pulled out, a short placeholder goes in its place,
    # and the placeholder is later swapped back in at whatever position the
    # target language put it. A translator has no business rewording a URL,
    # a mention token or a variable name inside a code fence. A mention
    # keeps the span that made it a native ping, moved to its new position.
    class Segmenter
      # One run of literal text no translation call ever sees.
      Placeholder = Struct.new(:token, :text, :kind, :attributes, keyword_init: true)

      # What to send, and what {#restore} needs to undo it.
      Protected = Struct.new(:text, :placeholders, keyword_init: true) do
        # False when, once every placeholder is set aside, nothing is left to
        # ask a translator about: a bare link, a lone custom emoji, or a
        # blank message.
        def translatable?
          text.gsub(Segmenter::TOKEN_PATTERN, "").strip != ""
        end
      end

      CODE_BLOCK = /```.*?```/m
      INLINE_CODE = /`[^`\n]+`/
      URL = %r{\bhttps?://\S+}i
      # A platform's own custom emoji token, e.g. Discord's `<:name:id>` /
      # `<a:name:id>`.
      CUSTOM_EMOJI = /<a?:\w+:\d+>/

      PATTERN = Regexp.union(CODE_BLOCK, INLINE_CODE, URL, CUSTOM_EMOJI)

      # Private Use Area brackets around a plain digit run: unlikely to occur
      # in real chat text, and shaped like one opaque "word" so a translation
      # engine's own tokenizer has no punctuation of its own to trip over.
      # The brackets matter as much as the digits: a bare number would match
      # an ordinary price or date sitting right next to it in the translated
      # sentence.
      TOKEN_OPEN = ""
      TOKEN_CLOSE = ""
      TOKEN_PATTERN = /#{TOKEN_OPEN}(\d+)#{TOKEN_CLOSE}/

      # @param body [Core::RichText]
      # @return [Protected]
      def protect(body)
        placeholders = []
        out = +""
        cursor = 0
        regions_for(body).each do |region|
          out << body.text[cursor...region[:from]].to_s
          placeholders << Placeholder.new(token: token_for(placeholders.length), text: region[:text],
                                          kind: region[:kind], attributes: region[:attributes])
          out << placeholders.last.token
          cursor = region[:to]
        end
        out << body.text[cursor..].to_s
        Protected.new(text: out, placeholders: placeholders)
      end

      # Put the original text back where each placeholder landed in the
      # translated sentence, and rebuild a span for whichever placeholders
      # came from one.
      #
      # @param translated [String] LibreTranslate's answer for {Protected#text}
      # @param placeholders [Array<Placeholder>]
      # @return [Core::RichText, nil] nil when a placeholder went missing or
      #   was duplicated, which means the reconstruction cannot be trusted
      def restore(translated, placeholders)
        return Core::RichText.plain(translated.to_s) if placeholders.empty?

        remaining = placeholders.each_with_index.to_h { |placeholder, index| [index, placeholder] }
        text = translated.to_s
        out = +""
        spans = []
        cursor = 0

        while (match = TOKEN_PATTERN.match(text, cursor))
          placeholder = remaining.delete(match[1].to_i)
          return nil if placeholder.nil?

          out << text[cursor...match.begin(0)]
          from = out.length
          out << placeholder.text
          spans << Core::Span.new(kind: placeholder.kind, begin_index: from, end_index: out.length,
                                  attributes: placeholder.attributes) if placeholder.kind
          cursor = match.end(0)
        end
        return nil unless remaining.empty?

        out << text[cursor..].to_s
        Core::RichText.new(out, spans)
      end

      private

      def token_for(index) = "#{TOKEN_OPEN}#{index}#{TOKEN_CLOSE}"

      # Every range worth protecting: a message's own :mention spans first
      # (so a mention keeps its native-ping attributes), then a scan for
      # code, URLs and custom emoji, merged so nothing overlaps.
      def regions_for(body)
        from_spans = body.spans.select { |span| span.kind == :mention }.map do |span|
          { from: span.begin_index, to: span.end_index,
            text: body.text[span.begin_index...span.end_index].to_s,
            kind: span.kind, attributes: span.attributes }
        end
        merge(from_spans + scan(body.text))
      end

      def scan(text)
        regions = []
        position = 0
        while (match = PATTERN.match(text, position))
          regions << { from: match.begin(0), to: match.end(0), text: match[0], kind: nil, attributes: {} }
          position = match.end(0)
        end
        regions
      end

      # Sorted, non overlapping. A region that starts before the previous one
      # ended is dropped rather than adjusted: a mention's own span wins over
      # an accidental regex hit inside it, since spans sort first.
      def merge(regions)
        regions.sort_by { |region| [region[:from], -(region[:to] - region[:from])] }
               .each_with_object([]) { |region, kept| kept << region if kept.empty? || region[:from] >= kept.last[:to] }
      end
    end
  end
end
