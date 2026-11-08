# frozen_string_literal: true

module Rubotty
  module Features
    # One definition of "the same word", shared by {Matcher} and by
    # `rubotty.fold`, so a script and the filter cannot disagree about
    # whether two spellings match. Downcasing alone misses accents, so this
    # decomposes (NFD), drops nonspacing marks, then full Unicode case folds,
    # which is also why `ß` folds to `ss` and a ligature still matches.
    # Spacing combining marks are kept, since in the Indic scripts that use
    # them they carry meaning rather than decoration, and dropping them would
    # produce a different word rather than fold two spellings of one.
    module TextFold
      # Accents, cedillas, tildes and the rest: the marks that sit ON a letter.
      NONSPACING_MARKS = /\p{Mn}/

      module_function

      # Most characters {#chars} will hand back in one answer: the same
      # ceiling {Matcher::MAX_INPUT_CHARS} puts on matching, since the result
      # crosses the pipe as one frame and an unbounded list would take the
      # frame limit out. Read through the matcher on call rather than copied
      # into a constant here, since the matcher requires this file and a
      # constant would make that mutual.
      def max_chars = Matcher::MAX_INPUT_CHARS

      # +text+ casefolded and stripped of its diacritics.
      #
      # @param text [String]
      # @return [String]
      def fold(text)
        clean(text).unicode_normalize(:nfd).gsub(NONSPACING_MARKS, "").downcase(:fold)
      end

      # +text+ as a list of characters, bounded by {#max_chars}.
      #
      # This is what makes "the last character" answerable from Lua: `string.sub`
      # counts bytes, so `string.sub(text, -1)` on a Portuguese word takes half a
      # codepoint and hands back something that is not a character at all.
      #
      # @param text [String]
      # @return [Array<String>]
      def chars(text)
        found = clean(text).chars
        found.length > max_chars ? found.first(max_chars) : found
      end

      # The folded text, plus the map back to each folded byte's origin: folding
      # changes byte offsets (`á` is two bytes, folds to one), so `starts[i]` is
      # the ORIGINAL offset of the character behind folded byte `i` (a trailing
      # entry holds the original's length), turning `[from, to)` into
      # `[starts[from], starts[to])`. A character that folds to nothing gets no
      # entry, falling inside its predecessor's span so a replacement never cuts a grapheme in half.
      #
      # @return [Array(String, Array<Integer>)]
      def fold_with_offsets(text)
        subject = clean(text)
        folded = +""
        starts = []
        origin = 0
        subject.each_char do |char|
          piece = fold(char)
          folded << piece
          piece.bytesize.times { starts << origin }
          origin += char.bytesize
        end
        starts << subject.bytesize
        [folded, starts]
      end

      # UTF-8 and valid, whatever arrived. `unicode_normalize` raises on invalid
      # bytes, and a message that came off a platform with a broken encoding
      # must not take an invocation down.
      def clean(text)
        string = text.to_s
        string = string.dup.force_encoding(Encoding::UTF_8) unless string.encoding == Encoding::UTF_8
        string.valid_encoding? ? string : string.scrub
      end
    end
  end
end
