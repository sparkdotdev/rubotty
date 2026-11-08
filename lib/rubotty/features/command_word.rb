# frozen_string_literal: true

module Rubotty
  module Features
    # Recognises a command word off the front of a chat message: strips the
    # room's own configured prefix, takes the first whitespace-separated
    # token, and chops off a Telegram "@botname" suffix (appended when a
    # command is picked from its own menu) before lowercasing it. Replaces
    # what used to be eight separate per-feature copies of this parsing.
    module CommandWord
      # @return [Array(String, Array<String>)] the lowercased command word and
      #   the words after it, or [nil, nil] when the message does not start
      #   with a configured prefix at all, or the prefix is all there is
      def self.parse(context)
        body = context.command_prefixes.strip(context.message.body.text)
        return [nil, nil] if body.nil?

        words = body.to_s.split(/\s+/)
        return [nil, nil] if words.empty?

        word = words.first.split("@").first.to_s.downcase
        word.empty? ? [nil, nil] : [word, words[1..] || []]
      end
    end
  end
end
