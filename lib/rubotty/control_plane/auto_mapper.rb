# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Proposes room bindings for discovered channels by comparing normalized
    # names (lowercased, punctuation and {STOPWORDS} stripped); it only
    # proposes, never writes, and the dashboard or API applies the approved
    # subset through {ChannelMapper#resolve_selection}. A room is a candidate
    # when every word of ITS name appears in the channel's, so a short room name
    # can claim a longer, more specific channel name. A channel matching more
    # than one room, or a room matched by more than one channel, is skipped
    # rather than guessed at, with the reason reported.
    class AutoMapper
      # Filler dropped before comparing. Deliberately short: every word removed
      # here is a word that can no longer distinguish two channels.
      STOPWORDS = %w[a an and the of in on for to at is].freeze

      # The stand-in a Telegram forum topic carries until its real name turns
      # up: the parent chat's title plus the topic id. Comparing names against
      # one of these is worthless, since every topic in a forum shares
      # everything but the number.
      PLACEHOLDER_LABEL = /\(topic \d+\)\z/

      # One proposed binding, or one refusal: +action+ is :bind for an existing
      # room, :create for a room that does not exist yet, or :skip when nothing
      # could be decided (the only case +reason+ is set).
      Proposal = Struct.new(:channel, :action, :room_key, :room_label, :reason, keyword_init: true) do
        def skip? = action == :skip

        def bind? = action == :bind

        def create? = action == :create
      end

      def initialize(models:, logger: nil)
        @models = models
        @logger = logger
      end

      # Work out what to propose for every discovered-but-unmapped channel in
      # +community+.
      #
      # @param channels [Array<Models::Channel>] normally
      #   {ChannelDiscovery#unmapped}'s answer, passed in rather than fetched
      #   so a caller can propose for a subset
      # @param rooms [Array<Models::Room>]
      # @return [Array<Proposal>] one per channel, in the order given
      def propose(channels:, rooms:)
        room_words = rooms.to_h { |room| [room, words(room_label(room))] }
        # Every candidate first, then the collision pass: a channel cannot be
        # judged ambiguous until every OTHER channel's candidates are known.
        candidates = channels.to_h { |channel| [channel, matches(channel, room_words)] }
        claimed = claim_counts(candidates)

        channels.map { |channel| proposal_for(channel, candidates[channel], claimed) }
      end

      private

      def proposal_for(channel, matched, claimed)
        if channel.label.to_s.match?(PLACEHOLDER_LABEL)
          return skip(channel, "it has no real name yet, only the stand-in discovery invented. Post in the " \
                               "topic, or run /identify-topic there, and it can be mapped once the name arrives")
        end

        name = words(channel.label.to_s)
        return skip(channel, "its name has no words to match on") if name.empty?
        return skip(channel, "it matches #{matched.size} rooms") if matched.size > 1

        if matched.size == 1
          room = matched.first
          return skip(channel, "another channel matches #{room_label(room).inspect} too") if claimed[room] > 1

          return Proposal.new(channel: channel, action: :bind, room_key: room.room_key,
                              room_label: room_label(room))
        end

        proposed_key = room_key_for(name)
        return skip(channel, "its name reduces to nothing usable as a room key") if proposed_key.empty?

        Proposal.new(channel: channel, action: :create, room_key: proposed_key, room_label: channel.label.to_s)
      end

      # How many channels each room is the sole match for, so a room claimed
      # by two channels can suppress both.
      def claim_counts(candidates)
        counts = Hash.new(0)
        candidates.each_value { |matched| counts[matched.first] += 1 if matched.size == 1 }
        counts
      end

      def matches(channel, room_words)
        channel_words = words(channel.label.to_s)
        return [] if channel_words.empty?

        room_words.filter_map do |room, needed|
          next if needed.empty?

          room if needed.subset?(channel_words)
        end
      end

      def skip(channel, reason)
        Proposal.new(channel: channel, action: :skip, reason: reason)
      end

      # A room's human name, falling back to its key when it has no label.
      def room_label(room) = presence(room.label) || room.room_key.to_s

      # Lowercase, drop anything that is not a letter, digit or space, split, and
      # drop filler. Returns a Set because every comparison here is a subset test.
      def words(text)
        text.to_s.downcase.gsub(/[^\p{Alnum}\s]/, " ").split.reject { |w| STOPWORDS.include?(w) }.to_set
      end

      # A room_key built from a channel's own words, matching the shape keys
      # already have elsewhere (lowercase, hyphen separated).
      def room_key_for(word_set) = word_set.to_a.join("-")

      def presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
