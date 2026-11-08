# frozen_string_literal: true

module Rubotty
  module Scripting
    # Tells a script what category text falls into without exposing the word
    # list, which would leak the community's slurs and go stale the moment an
    # operator edits the filter. {#spans} returns match offsets instead of
    # list content, since replacing a word needs to know where it is, not
    # what the list holds. Categories are "slur" and "profanity" from the
    # vendored base list plus a "community" bucket for a scope's own
    # additions; precedence runs slur, community, then profanity, so a room's
    # own additions outrank generic vulgarity.
    class Classifier
      CLEAN = "clean"
      SLUR = "slur"
      PROFANITY = "profanity"
      COMMUNITY = "community"

      ORDER = [SLUR, COMMUNITY, PROFANITY].freeze

      # @param config [Hash] the resolved word_filter config for this scope,
      #   which is where the community's own `custom` and `entries` live
      # @param logger [#warn, nil]
      def initialize(config: {}, logger: nil)
        @logger = logger
        @buckets = build_buckets(config || {})
      end

      # @return [String] one of {CLEAN}, {SLUR}, {PROFANITY}, {COMMUNITY}
      def classify(text)
        subject = text.to_s
        folded = Features::TextFold.fold(subject)
        ORDER.find { |category| matches?(category, subject, folded) } || CLEAN
      end

      # Byte offsets of every filter match, so a script can replace what it
      # found without ever being told what the list holds. Each span also
      # carries how the matched word parses, since a rule can then swap in a
      # tamer one and keep the sentence grammatical.
      #
      # @return [Array<Hash>] {"from" => Integer, "to" => Integer,
      #   "category" => String, "part_of_speech" => String}, ordered by
      #   position, non overlapping
      def spans(text)
        subject = text.to_s
        found = ORDER.flat_map { |category| spans_for(category, subject) }
        dedupe(found.sort_by { |span| [span["from"], -span["to"]] })
      end

      private

      def build_buckets(config)
        base = Features::WordFilter.base_terms_by_category
        {
          SLUR => compile(base.fetch("slur", [])),
          PROFANITY => compile(base.fetch("vulgar", [])),
          COMMUNITY => compile(community_terms(config))
        }
      end

      # A scope's own additions: the `custom` list the dashboard edits plus the
      # older `entries` the running filter still honours.
      def community_terms(config)
        %w[custom entries].flat_map do |key|
          Array(config[key] || config[key.to_sym])
        end.filter_map { |term| term.is_a?(Hash) ? term["pattern"] || term[:pattern] : term }
      end

      # Matchers are built here rather than through WordFilter::Ruleset because
      # a Ruleset answers "did anything match" and this needs the offsets, which
      # means holding the compiled Matcher rather than a Rule wrapping one.
      def compile(terms)
        Array(terms).filter_map do |term|
          text = term.to_s.strip
          next if text.empty?

          Features::Matcher.build(pattern: text, mode: "literal", case_sensitive: false,
                                  whole_word: true, logger: @logger)
        end
      end

      # Folded once per call and handed to every matcher, the way
      # Features::WordFilter::Ruleset does it, so ninety patterns cost one fold
      # rather than ninety.
      def matches?(category, text, folded)
        @buckets.fetch(category, []).any? { |matcher| matcher.match?(text, folded: folded) }
      end

      # BYTE offsets into the text the SCRIPT is holding, which is why the
      # matcher works them out rather than this: matching happens on the folded
      # form and folding moves every offset after an accent, so mapping back is
      # part of matching rather than something a caller can do afterwards.
      def spans_for(category, text)
        @buckets.fetch(category, []).flat_map do |matcher|
          matcher.byte_spans(text).map do |from, to, word|
            { "from" => from, "to" => to, "category" => category,
              "part_of_speech" => Features::WordFilter.part_of_speech(word) }
          end
        end
      end

      # Overlapping matches would let a script replace the same span twice and
      # corrupt its own output, so the widest match at each position wins.
      def dedupe(spans)
        spans.each_with_object([]) do |span, kept|
          kept << span if kept.empty? || span["from"] >= kept.last["to"]
        end
      end
    end
  end
end
