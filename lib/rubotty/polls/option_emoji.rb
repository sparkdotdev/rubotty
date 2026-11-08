# frozen_string_literal: true

module Rubotty
  module Polls
    # The keycap a vote is cast with. NOT on Telegram's reaction whitelist, so
    # they cannot be tapped there at all, which the reply fallback exists for.
    module OptionEmoji
      KEYCAPS = %w[1️⃣ 2️⃣ 3️⃣ 4️⃣ 5️⃣ 6️⃣ 7️⃣ 8️⃣ 9️⃣].freeze

      module_function

      # @param position [Integer] 1-based
      # @return [Core::Reaction, nil]
      def for_position(position)
        keycap = KEYCAPS[position - 1] if position.is_a?(Integer) && position.positive?
        keycap && Core::Reaction.new(emoji: keycap)
      end

      # @param count [Integer]
      # @return [Array<Core::Reaction>] leftmost first
      def for_count(count)
        limit = count.to_i.clamp(0, KEYCAPS.size)
        (1..limit).map { |position| for_position(position) }.freeze
      end

      # @param reaction [Core::Reaction, nil]
      # @return [Integer, nil] the 1-based position, or nil
      def position_for(reaction)
        return nil if reaction.nil? || reaction.custom?

        # The same keycap arrives with and without U+FE0F depending on the platform.
        key = reaction.without_variation_selector
        index = KEYCAPS.index { |keycap| Core::Reaction.new(emoji: keycap).without_variation_selector == key }
        index && index + 1
      end
    end
  end
end
