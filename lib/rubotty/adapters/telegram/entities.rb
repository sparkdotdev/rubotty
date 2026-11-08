# frozen_string_literal: true

module Rubotty
  module Adapters
    module Telegram
      # Translation between Telegram message entities and canonical spans.
      #
      # Telegram entity `offset` and `length` are counted in UTF-16 CODE UNITS, where
      # a Ruby String is a sequence of characters, so indexing the text directly is
      # wrong the moment somebody uses an emoji:
      #
      #     text[entity["offset"], entity["length"]]     # WRONG
      # Build a character boundary table once per message and look every offset up in it (see {Rubotty::Util::Utf16}).
      module Entities
        # Telegram entity type to canonical span kind. Types absent from this map
        # carry no formatting we can represent and are ignored: `bot_command`,
        # `hashtag`, `cashtag`, `email` and `phone_number` are UI affordances.
        TYPE_MAP = {
          "bold" => :bold,
          "italic" => :italic,
          "underline" => :underline,
          "strikethrough" => :strikethrough,
          "spoiler" => :spoiler,
          "code" => :code,
          "pre" => :pre,
          "text_link" => :link,
          "url" => :link,
          "text_mention" => :mention,
          "mention" => :mention,
          "blockquote" => :blockquote,
          "expandable_blockquote" => :blockquote
        }.freeze

        module_function

        # Build canonical rich text from a Telegram text plus its entities.
        #
        # @param text [String, nil]
        # @param entities [Array<Hash>, nil] raw Bot API entity hashes
        # @return [Core::RichText]
        def to_rich_text(text, entities)
          text = text.to_s
          return Core::RichText.plain(text) if entities.nil? || entities.empty?

          table = Util::Utf16.boundaries(text)
          spans = Array(entities).filter_map { |entity| to_span(entity, text, table) }
          Core::RichText.new(text, spans)
        end

        # @return [Core::Span, nil]
        def to_span(entity, text, table)
          kind = TYPE_MAP[entity["type"]]
          return nil if kind.nil?

          offset = entity["offset"].to_i
          length = entity["length"].to_i
          return nil if length <= 0

          begin_index = Util::Utf16.char_index(offset, table)
          end_index = Util::Utf16.char_index(offset + length, table)
          return nil if end_index <= begin_index

          Core::Span.new(
            kind: kind,
            begin_index: begin_index,
            end_index: end_index,
            attributes: attributes_for(entity, kind, text, begin_index, end_index)
          )
        end

        def attributes_for(entity, kind, text, begin_index, end_index)
          case kind
          when :link then link_attributes(entity, text, begin_index, end_index)
          when :pre then entity["language"] ? { language: entity["language"] } : {}
          when :mention then mention_attributes(entity, text, begin_index, end_index)
          else {}
          end
        end

        # A `text_link` carries its target in `url`. A bare `url` entity does
        # not: the covered text IS the target.
        def link_attributes(entity, text, begin_index, end_index)
          url = entity["url"] || text[begin_index...end_index]
          { url: url.to_s.strip }
        end

        # `text_mention` carries a full user object, so a real mention can be
        # rendered. A plain `mention` is only "@handle" text, so the handle is
        # kept and resolution left to whoever can do it.
        def mention_attributes(entity, text, begin_index, end_index)
          user = entity["user"]
          if user
            {
              tg_user_id: user["id"].to_s,
              display: user["first_name"],
              username: user["username"]
            }.compact
          else
            { username: text[begin_index...end_index].to_s.delete_prefix("@") }
          end
        end

        # Convert canonical spans back into Telegram entities. Unused on the
        # normal outbound path, which sends `parse_mode: HTML`; this is where the
        # reverse UTF-16 conversion lives for anyone who needs byte exact control.
        #
        # @param rich [Core::RichText]
        # @return [Array<Hash>]
        def from_rich_text(rich)
          table = Util::Utf16.boundaries(rich.text)
          rich.spans.filter_map do |span|
            type = TYPE_MAP.key(span.kind)
            next nil if type.nil?

            offset = Util::Utf16.unit_offset(span.begin_index, table)
            finish = Util::Utf16.unit_offset(span.end_index, table)
            entity = { "type" => type, "offset" => offset, "length" => finish - offset }
            entity["url"] = span.attributes[:url] if span.kind == :link
            entity["language"] = span.attributes[:language] if span.kind == :pre && span.attributes[:language]
            entity
          end
        end
      end
    end
  end
end
