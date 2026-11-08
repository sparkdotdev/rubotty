# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Guesses which community a pending space belongs to by comparing its name
    # against every community's name and slug. This only proposes, never
    # writes or decides: a suggestion needs an operator's accept, which runs
    # the same {PendingSpaces#approve} the Onboarding queue runs, and a wrong
    # guess just leaves the space pending. Matching is deliberately strict,
    # word for word against each community's name or slug after dropping
    # filler and platform noise, and a space that matches more than one
    # community is proposed to none.
    class SpaceSuggestions
      # Filler dropped before comparing, as in {AutoMapper::STOPWORDS}. Short on
      # purpose: every word removed here is a word that can no longer tell two
      # names apart.
      STOPWORDS = %w[a an and the of in on for to at is].freeze

      # Words that say which kind of thing the space is rather than which one it
      # is. Dropping these is what lets a community named "Rando" match a Telegram
      # group named "Rando Chat" without letting one word of overlap match
      # anything else.
      GENERIC_WORDS = %w[
        chat chats group groups community server servers channel channels
        room rooms official main general lounge talk hq discord telegram
      ].freeze

      # One proposal: +space+ is a pending_spaces row, +community+ is the
      # community it plausibly belongs to, and +matched+ is the words the two
      # names had in common, shown on the page so the guess can be judged.
      Suggestion = Struct.new(:space, :community, :matched, keyword_init: true)

      def initialize(models:, logger: nil)
        @models = models
        @logger = logger
      end

      # The suggestions for one community.
      #
      # @param community [Models::Community]
      # @param spaces [Array<Models::PendingSpace>] normally
      #   {PendingSpaces#pending}, passed in so the caller decides which states
      #   are eligible
      # @return [Array<Suggestion>]
      def for_community(community:, spaces:)
        # Every community, because a space claimed by two of them is claimed by
        # neither, and this page can only see one.
        propose(spaces: spaces, communities: @models.community.order(:slug).all)
          .select { |suggestion| suggestion.community.id == community.id }
      end

      # Work out the confident matches across a whole set of spaces.
      #
      # @return [Array<Suggestion>] at most one per space
      def propose(spaces:, communities:)
        terms = communities.to_h { |community| [community, community_terms(community)] }
        spaces.filter_map do |space|
          space_words = words(space.name)
          next if space_words.empty?

          matched = terms.select { |_community, sets| sets.any? { |set| confident?(set, space_words) } }.keys
          next unless matched.size == 1

          community = matched.first
          overlap = terms[community].reduce(Set.new, :|) & space_words
          Suggestion.new(space: space, community: community, matched: overlap.to_a.sort)
        end
      end

      private

      # A community is named twice: by its display name and by its slug, and
      # either may be the one the space was named after.
      def community_terms(community)
        [words(community.name), words(community.slug.to_s.tr("-_", " "))].reject(&:empty?).uniq
      end

      def confident?(community_words, space_words)
        return false if community_words.empty?
        return false unless community_words.subset?(space_words)

        community_words.size >= 2 || community_words == space_words
      end

      # Lowercase, drop anything that is not a letter, digit or space, split, and
      # drop the words that cannot distinguish anything. A Set, because every
      # comparison here is a subset test.
      def words(text)
        text.to_s.downcase.gsub(/[^\p{Alnum}\s]/, " ").split
            .reject { |word| STOPWORDS.include?(word) || GENERIC_WORDS.include?(word) }
            .to_set
      end
    end
  end
end
