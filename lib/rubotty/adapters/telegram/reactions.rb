# frozen_string_literal: true

require "set"

module Rubotty
  module Adapters
    module Telegram
      # Telegram's reaction rules are unusually restrictive: ReactionTypeEmoji
      # accepts only a whitelist of about seventy five specific emoji, so the
      # Discord to Telegram direction always needs a mapping decision; a
      # non-premium bot may hold at most one reaction per message; and
      # setMessageReaction REPLACES rather than appends, so removing a
      # reaction means sending an empty list. Telegram does NOT send
      # message_reaction updates for reactions bots set, so there is no
      # reaction loop to prevent.
      module Reactions
        # The complete ReactionTypeEmoji whitelist.
        #
        # Telegram spells several of these WITHOUT the U+FE0F variation
        # selector, while Discord and most clients send them WITH it. {.normalise}
        # exists for that mismatch.
        ALLOWED = [
          "❤", "👍", "👎", "🔥", "🥰", "👏", "😁", "🤔", "🤯", "😱", "🤬", "😢",
          "🎉", "🤩", "🤮", "💩", "🙏", "👌", "🕊", "🤡", "🥱", "🥴", "😍", "🐳",
          "❤‍🔥", "🌚", "🌭", "💯", "🤣", "⚡", "🍌", "🏆", "💔", "🤨", "😐", "🍓",
          "🍾", "💋", "🖕", "😈", "😴", "😭", "🤓", "👻", "👨‍💻", "👀", "🎃", "🙈",
          "😇", "😨", "🤝", "✍", "🤗", "🫡", "🎅", "🎄", "☃", "💅", "🤪", "🗿",
          "🆒", "💘", "🙉", "🦄", "😘", "💊", "🙊", "😎", "👾", "🤷‍♂", "🤷", "🤷‍♀",
          "😡"
        ].freeze

        ALLOWED_SET = ALLOWED.to_set.freeze

        # Best effort equivalents for common emoji Telegram does not accept,
        # kept small and obvious since a large fuzzy table would regularly
        # put words in someone's mouth. Skin-tone variants are NOT listed
        # here: {.map} strips the Fitzpatrick modifier generally, since
        # Telegram's reaction set has no toned variants of anything.
        NEAREST = {
          "❤️" => "❤", "♥" => "❤", "♥️" => "❤", "💛" => "❤", "💚" => "❤",
          "💙" => "❤", "💜" => "❤", "🧡" => "❤", "🖤" => "❤", "🤍" => "❤",
          "😂" => "🤣", "🥹" => "😢", "😊" => "🥰", "🙂" => "😁", "😄" => "😁",
          "😃" => "😁", "😀" => "😁", "😅" => "😁", "🥳" => "🎉", "🎊" => "🎉",
          "😮" => "🤯", "😲" => "😱", "🤦" => "🤷", "💀" => "🗿", "🫠" => "🥴",
          "✅" => "👍", "☑️" => "👍", "✔️" => "👍", "❌" => "👎", "🚀" => "🔥",
          # A caution mark has no equivalent in the whitelist; eyes is the
          # closest "look at this" stand-in Telegram can show.
          "⚠️" => "👀", "⚠" => "👀"
        }.freeze

        # What to do with a reaction Telegram will not accept.
        #
        #   :nearest  substitute an equivalent when one is known, else drop
        #   :drop     drop silently
        #   :log      drop, and say so at info level
        POLICIES = %i[nearest drop log].freeze

        module_function

        def allowed?(emoji) = ALLOWED_SET.include?(emoji.to_s)

        # Canonicalise a reaction into the exact form Telegram's whitelist uses:
        # the emoji as given, then without the variation selector, then with it.
        #
        # @param reaction [Core::Reaction]
        # @return [String, nil] the acceptable emoji, or nil
        def normalise(reaction)
          return nil if reaction.nil? || reaction.custom?

          candidates = [
            reaction.emoji,
            reaction.without_variation_selector.emoji,
            reaction.with_variation_selector.emoji
          ].compact.uniq

          candidates.find { |candidate| allowed?(candidate) }
        end

        # Map a canonical reaction onto something Telegram will accept.
        #
        # @param reaction [Core::Reaction]
        # @param policy [Symbol] one of {POLICIES}
        # @return [Array(String, Symbol)] the emoji (or nil) and why, one of
        #   :direct, :substituted, :custom_dropped, :unmappable
        def map(reaction, policy: :nearest)
          return [nil, :custom_dropped] if reaction&.custom?

          direct = normalise(reaction)
          return [direct, :direct] if direct

          return [nil, :unmappable] unless policy == :nearest

          substitute = substitute_for(reaction)
          return [substitute, :substituted] if substitute && allowed?(substitute)

          [nil, :unmappable]
        end

        # A Telegram-acceptable stand-in for a reaction its whitelist does
        # not carry directly, or nil: first the SAME emoji with its
        # skin-tone modifier removed (👌🏽, 🖕🏾, ✍🏻, 🤷🏽), then the curated
        # {NEAREST} table for emoji Telegram omits ENTIRELY and a DIFFERENT
        # emoji stands in for (❤️ to ❤, 😂 to 🤣, ✅ to 👍).
        def substitute_for(reaction)
          toneless = normalise(reaction.without_skin_tone)
          return toneless if toneless

          NEAREST[reaction.emoji.to_s] ||
            NEAREST[reaction.without_variation_selector.emoji.to_s]
        end

        # Pick what a Telegram message should show, given every reaction on the
        # source, up to +max+ reactions (a non-premium bot may hold exactly one,
        # read from {Adapters::Capabilities#max_reactions}). Oldest survives first,
        # so the mirror does not flicker when somebody adds a different emoji.
        #
        # @param max [Integer] the bot's reaction budget on one message
        # @return [Array(Array<String>, Array<Core::Reaction>)] the chosen
        #   emoji, oldest first, and the reactions that could not be represented
        def choose(reactions, policy: :nearest, max: 1)
          dropped = []
          chosen = []

          reactions.each do |reaction|
            emoji, = map(reaction, policy: policy)
            if emoji && chosen.length < max
              chosen << emoji
            else
              dropped << reaction
            end
          end

          [chosen, dropped]
        end
      end
    end
  end
end
