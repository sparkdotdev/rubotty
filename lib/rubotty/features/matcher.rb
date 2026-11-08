# frozen_string_literal: true

require "rubotty/features/text_fold"

module Rubotty
  module Features
    # Safe, bounded text matching shared by the word filter and the FAQ/
    # custom-command engine, so every bound and guard lives in one place.
    # Compiles a pattern plus mode once into a substring test or bounded,
    # timeout-guarded Regexp, or nil from {.build} when it cannot compile
    # safely. Whole-word matching defaults on to avoid the Scunthorpe
    # problem. A case-insensitive literal or wildcard folds through
    # {TextFold}; a regex, or explicit `case_sensitive: true`, never folds,
    # to avoid rewriting the pattern's own character classes.
    class Matcher
      # Bounds that make matching safe regardless of the patterns configured.
      MAX_PATTERN_LENGTH = 512
      MAX_INPUT_CHARS = 20_000
      # The per-pattern match budget. Ruby's regex engine already defeats most
      # catastrophic backtracking through memoisation; this is the belt-and-
      # braces backstop for anything it does not, so a single message can never
      # wedge a worker thread.
      REGEX_TIMEOUT_SECONDS = 0.25

      MODES = %w[literal wildcard regex].freeze

      # The canonical catastrophic-backtracking shape: a group that contains an
      # unbounded quantifier and is itself unbounded-quantified, e.g. (a+)+,
      # (a*)*, ([a-z]+)*, (.*)+ . Conservative by design; the per-pattern timeout
      # is the real guarantee, this just rejects the obvious offenders before they
      # ever run.
      NESTED_QUANTIFIER =
        /\((?:[^()\\]|\\.)*(?:[*+]|\{\d*,\})(?:[^()\\]|\\.)*\)\s*(?:[*+]|\{\d*,\})/

      # Truncate input to the bound so a pathologically long message cannot become
      # a denial-of-service vector regardless of the pattern. Callers match against
      # the returned string.
      def self.bound_input(text)
        text = text.to_s
        text.length > MAX_INPUT_CHARS ? text[0, MAX_INPUT_CHARS] : text
      end

      # Compile a pattern into a Matcher, or nil when it cannot be compiled
      # safely; every rejection is logged. The only constructor callers should
      # use: {#initialize} is the low-level seam for a pre-built Regexp.
      #
      # @param mode [String] one of {MODES}
      # @param whole_word [Boolean] anchor to word boundaries (literal, wildcard)
      # @param logger [#warn, nil]
      # @return [Matcher, nil]
      def self.build(pattern:, mode: "literal", case_sensitive: false, whole_word: true, logger: nil)
        pattern = pattern.to_s
        if pattern.empty?
          logger&.warn { "matcher: ignoring an empty pattern" }
          return nil
        end

        mode = mode.to_s
        unless MODES.include?(mode)
          logger&.warn { "matcher: ignoring #{pattern.inspect}, unknown mode #{mode.inspect}" }
          return nil
        end

        case mode
        when "literal"
          build_literal(pattern, case_sensitive: case_sensitive, whole_word: whole_word, logger: logger)
        when "wildcard"
          # Folded first, then translated. Folding leaves `*` and `?` alone, so
          # either order produces the same source, and doing it this way round
          # keeps the escaping working on the characters that survive.
          source = wildcard_to_regex_source(fold_pattern(pattern, case_sensitive), whole_word: whole_word)
          build_regex(pattern, mode, source, case_sensitive: case_sensitive,
                      fold: !case_sensitive, logger: logger)
        when "regex"
          build_regex(pattern, mode, pattern, case_sensitive: case_sensitive, logger: logger)
        end
      end

      # What a case-insensitive pattern is really compared as. Held apart so the
      # literal and wildcard paths cannot fold differently from each other.
      def self.fold_pattern(pattern, case_sensitive)
        case_sensitive ? pattern : TextFold.fold(pattern)
      end

      def self.build_literal(pattern, case_sensitive:, whole_word:, logger:)
        needle = fold_pattern(pattern, case_sensitive)
        if whole_word
          source = word_bounded(Regexp.escape(needle), needle)
          build_regex(pattern, "literal", source, case_sensitive: case_sensitive,
                      fold: !case_sensitive, logger: logger)
        else
          new(pattern: pattern, mode: "literal", substring: needle,
              fold: !case_sensitive, logger: logger)
        end
      end

      # Anchor +source+ to word boundaries only at an edge where +text+
      # actually has a word character. \b never matches beside punctuation,
      # an emoji or CJK, so wrapping unconditionally silently made terms
      # like @everyone or #airdrop uncatchable; Ruby's \w is ASCII, so CJK
      # falls back to a plain substring match regardless.
      def self.word_bounded(source, text)
        prefix = text.match?(/\A\w/) ? "\\b" : ""
        suffix = text.match?(/\w\z/) ? "\\b" : ""
        "#{prefix}#{source}#{suffix}"
      end

      def self.build_regex(pattern, mode, source, case_sensitive:, logger:, fold: false)
        if source.length > MAX_PATTERN_LENGTH
          logger&.warn { "matcher: rejecting #{mode} #{pattern.inspect}: pattern too long" }
          return nil
        end
        if source.match?(NESTED_QUANTIFIER)
          logger&.warn do
            "matcher: rejecting #{mode} #{pattern.inspect}: nested unbounded quantifier " \
              "risks catastrophic backtracking (ReDoS)"
          end
          return nil
        end

        options = case_sensitive ? 0 : Regexp::IGNORECASE
        regex = Regexp.new(source, options, timeout: REGEX_TIMEOUT_SECONDS)
        new(pattern: pattern, mode: mode, regex: regex, fold: fold, logger: logger)
      rescue RegexpError => e
        logger&.warn { "matcher: rejecting #{mode} #{pattern.inspect}: #{e.message}" }
        nil
      end

      # Translate a glob into a regex source: `*` matches any run, `?` any
      # single character, and everything else is escaped literal. With
      # whole_word the glob anchors at whichever end really begins or ends on
      # a word character, leaving a leading `*` or trailing `!` unanchored
      # rather than unmatchable.
      def self.wildcard_to_regex_source(pattern, whole_word:)
        body = pattern.each_char.map do |char|
          case char
          when "*" then ".*"
          when "?" then "."
          else Regexp.escape(char)
          end
        end.join
        whole_word ? word_bounded(body, pattern) : body
      end

      # +substring+ is the needle for the one path that carries no regex, already
      # folded when this matcher folds. +fold+ says whether the subject has to be
      # folded to meet it.
      def initialize(pattern:, mode:, regex: nil, substring: nil, fold: false, logger: nil)
        @pattern = pattern
        @mode = mode
        @regex = regex
        @substring = substring
        @fold = fold
        @logger = logger
        freeze
      end

      attr_reader :pattern, :mode, :regex

      def folds? = @fold

      # What this matcher really compares against: the folded text when it
      # folds, and the text itself otherwise.
      #
      # Public so a caller looping over a whole ruleset can fold once and hand
      # the result to every matcher, rather than paying for the same fold on
      # each of ninety patterns.
      def subject(text) = @fold ? TextFold.fold(text) : text.to_s

      # Whether +text+ matches: a regex that times out on this input is treated
      # as no match rather than allowed to wedge the thread (the ReDoS
      # backstop). +folded+ is this matcher's {#subject} when the caller
      # already has it.
      def match?(text, folded: nil)
        against = folded || subject(text)
        @regex ? @regex.match?(against) : against.include?(@substring)
      rescue Regexp::TimeoutError
        @logger&.warn do
          "matcher: #{mode} pattern #{pattern.inspect} exceeded its match budget, " \
            "treated as no match (ReDoS guard)"
        end
        false
      end

      # Where this matcher hits in +text+, as BYTE offsets into the text the
      # caller is holding (each with the word that matched), because the one
      # caller (Scripting::Classifier, serving `offending_spans`) hands them to
      # a Lua script whose `string.sub` counts bytes. Offsets are into the
      # ORIGINAL text rather than the folded form, since a match at folded
      # byte 3 of "olá cariño" is at original byte 4, an off-by-one span cutting a codepoint in half.
      #
      # @return [Array<Array(Integer, Integer, String)>] from, to, matched word
      def byte_spans(text)
        return [] if @regex.nil?

        against, starts = @fold ? TextFold.fold_with_offsets(text) : [text.to_s, nil]
        scan(against).map do |from, to, word|
          starts ? [starts[from], starts[to], word] : [from, to, word]
        end
      rescue StandardError => e
        # Regexp::TimeoutError included, which is the ReDoS backstop: a pattern
        # that ran out of budget finds nothing rather than wedging the thread.
        @logger&.debug { "matcher: span scan failed on #{pattern.inspect}: #{e.class}: #{e.message}" }
        []
      end

      private

      # Every match in +against+, as byte offsets into IT rather than into
      # whatever the caller started with.
      def scan(against)
        found = []
        position = 0
        while (match = @regex.match(against, position))
          from, to = match.byteoffset(0)
          found << [from, to, match[0]]
          # Guard against a zero width match pinning the scan in one place.
          position = match.end(0) > match.begin(0) ? match.end(0) : match.begin(0) + 1
          break if position > against.length
        end
        found
      end
    end
  end
end
