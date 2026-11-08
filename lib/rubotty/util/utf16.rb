# frozen_string_literal: true

module Rubotty
  module Util
    # UTF-16 code unit arithmetic. Telegram expresses entity `offset` and `length`
    # in UTF-16 code units, where a character above U+FFFF takes two units to Ruby's
    # one, so a naive `text[offset, length]` corrupts every entity after it.
    #
    # The core is character indexed throughout; this is the only place that knows
    # about UTF-16, used at the Telegram adapter boundary alone.
    module Utf16
      module_function

      # Number of UTF-16 code units a string occupies.
      #
      # @param text [String]
      # @return [Integer]
      def length(text)
        return 0 if text.nil? || text.empty?

        text.encode(Encoding::UTF_16LE).bytesize / 2
      end

      # Cumulative UTF-16 offset for every character boundary in +text+, the last
      # entry being the total length. Build it once per message.
      #
      # @param text [String]
      # @return [Array<Integer>]
      def boundaries(text)
        text = text.to_s
        table = Array.new(text.length + 1)
        units = 0
        index = 0
        text.each_char do |char|
          table[index] = units
          units += char.ord > 0xFFFF ? 2 : 1
          index += 1
        end
        table[text.length] = units
        table
      end

      # Translate a UTF-16 code unit offset into a Ruby character index. An offset
      # landing mid surrogate pair snaps down to the start of its character, so one
      # malformed entity does not discard an otherwise deliverable message.
      #
      # @param unit_offset [Integer]
      # @param table [Array<Integer>] from {boundaries}
      # @return [Integer] character index, clamped into range
      def char_index(unit_offset, table)
        return 0 if unit_offset <= 0
        return table.length - 1 if unit_offset >= table.last

        # table is strictly increasing, so binary search for the last boundary
        # at or below unit_offset.
        low = 0
        high = table.length - 1
        while low < high
          mid = (low + high + 1) / 2
          if table[mid] <= unit_offset
            low = mid
          else
            high = mid - 1
          end
        end
        low
      end

      # Translate a Ruby character index into a UTF-16 code unit offset.
      #
      # @param index [Integer]
      # @param table [Array<Integer>] from {boundaries}
      # @return [Integer]
      def unit_offset(index, table)
        return 0 if index <= 0
        return table.last if index >= table.length - 1

        table[index]
      end

      # Slice a string using UTF-16 offsets. Prefer {boundaries} plus {char_index}
      # when slicing many entities out of one string.
      #
      # @param text [String]
      # @param offset [Integer] in UTF-16 code units
      # @param length [Integer] in UTF-16 code units
      # @return [String]
      def slice(text, offset, length)
        return "" if text.nil? || text.empty? || length <= 0

        units = text.encode(Encoding::UTF_16LE)
        part = units.b.byteslice(offset * 2, length * 2)
        return "" if part.nil? || part.empty?

        part.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        # A slice that severs a surrogate pair cannot be decoded, so widen by one
        # code unit each side and retry once.
        widened = units.b.byteslice([(offset - 1), 0].max * 2, (length + 2) * 2)
        widened.force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end
    end
  end
end
