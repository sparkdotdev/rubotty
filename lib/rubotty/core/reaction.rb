# frozen_string_literal: true

module Rubotty
  module Core
    # One reaction, platform neutral: either a unicode emoji or a platform
    # specific custom emoji. Custom emoji do not survive a crossing and are
    # dropped by adapters that cannot express them. A custom emoji may carry
    # an ordinary emoji alongside its id (the one it is drawn from) so a
    # platform that cannot hold the custom one can show that instead; see
    # {#base_emoji}.
    class Reaction
      # What a custom emoji with neither a name nor a base emoji is called. Its
      # id is a long number, and a number in a sentence reads as a fault.
      UNRESOLVED = "a custom emoji"

      attr_reader :emoji, :custom_id, :custom_name

      # @param emoji [String, nil] the unicode emoji, or the one a custom emoji
      #   is drawn from
      # @param custom_id [String, nil] platform id of a custom emoji
      # @param custom_name [String, nil] shortcode of a custom emoji
      def initialize(emoji: nil, custom_id: nil, custom_name: nil)
        @emoji = presence(emoji)
        @custom_id = presence(custom_id)
        @custom_name = presence(custom_name)
        freeze
      end

      def custom? = !custom_id.nil?

      def unicode? = !custom? && !emoji.nil?

      # Stable identity used as the storage key and for set arithmetic. A base
      # emoji is deliberately not part of it: two custom emoji drawn from the
      # same smile are still two different reactions.
      def key = custom? ? "custom:#{custom_id}" : "emoji:#{emoji}"

      # The ordinary emoji a custom one is drawn from, where the platform will
      # say. Telegram answers getCustomEmojiStickers with it; Discord's own
      # custom emoji are pictures with a name and nothing underneath.
      def base_emoji = custom? ? emoji : nil

      # What a reader sees. A custom emoji reads as its shortcode where the
      # platform names one, then as the emoji it is drawn from, and only then in
      # words.
      def label
        return emoji.to_s unless custom?

        custom_name ? ":#{custom_name}:" : (emoji || UNRESOLVED)
      end

      def to_s = label

      def ==(other) = other.is_a?(Reaction) && other.key == key
      alias eql? ==

      def hash = key.hash

      def inspect = "#<Reaction #{key}>"

      # Unicode emoji arrive with and without the U+FE0F variation selector
      # depending on the platform and the client, and comparing or sending the
      # wrong form silently fails.
      def without_variation_selector
        return self unless unicode?

        stripped = emoji.delete("️")
        stripped == emoji ? self : Reaction.new(emoji: stripped)
      end

      def with_variation_selector
        return self unless unicode?
        return self if emoji.include?("️")

        Reaction.new(emoji: "#{emoji}️")
      end

      # The Unicode skin-tone (Fitzpatrick) modifiers, U+1F3FB to U+1F3FF. A
      # toned emoji is a base grapheme immediately followed by one of these.
      SKIN_TONES = "\u{1F3FB}\u{1F3FC}\u{1F3FD}\u{1F3FE}\u{1F3FF}"

      # A skin tone is part of the emoji's identity: two tones are two distinct
      # reactions, and the relay must never normalise it away. This exists
      # only for an adapter whose platform cannot express a tone at all.
      def without_skin_tone
        return self unless unicode?

        stripped = emoji.delete(SKIN_TONES)
        stripped == emoji ? self : Reaction.new(emoji: stripped)
      end

      private

      def presence(value)
        return nil if value.nil?

        string = value.to_s
        string.empty? ? nil : string
      end
    end
  end
end
