# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Telegram
      # The ordinary emoji a Telegram custom emoji is drawn from: a reaction update
      # names a custom emoji by its id and nothing else, an unreadable long number,
      # so getCustomEmojiStickers is used to look up the sticker behind each id and
      # the unicode emoji it is based on. A custom emoji id names one fixed sticker
      # for good, so an answer is kept for the life of the process, misses included,
      # rather than costing a repeat Bot API call for the same result. One call takes
      # a batch, which is what a reaction update with several custom emoji in it needs.
      class CustomEmoji
        # Telegram accepts at most 200 ids per call.
        BATCH = 200

        # The cache ceiling, so a chat full of custom emoji cannot grow it
        # without bound. Oldest written goes first.
        MAX_ENTRIES = 5000

        # @param stickers [#call] given an array of ids, answers
        #   getCustomEmojiStickers
        def initialize(stickers:, logger: nil)
          @stickers = stickers
          @logger = logger
          @cache = {}
          @monitor = Monitor.new
        end

        # The base emoji for each id that has one.
        #
        # @param ids [Array<String>]
        # @return [Hash{String=>String}] id to emoji, with no entry for an id
        #   Telegram would not answer for or answered with no emoji
        def bases_for(ids)
          wanted = Array(ids).map(&:to_s).reject(&:empty?).uniq
          return {} if wanted.empty?

          unknown = @monitor.synchronize { wanted.reject { |id| @cache.key?(id) } }
          unknown.each_slice(BATCH) { |slice| fetch(slice) }
          @monitor.synchronize do
            wanted.each_with_object({}) do |id, out|
              base = @cache[id]
              out[id] = base unless base.nil?
            end
          end
        end

        # @return [String, nil]
        def base_for(id) = bases_for([id])[id.to_s]

        private

        # Ask about one batch and write down every answer, the empty ones
        # included, since an id Telegram has no base emoji for will never grow
        # one. A call that failed is written down as nothing at all, so the next
        # reaction asks again rather than inheriting a network blip for good.
        def fetch(ids)
          answered = resolved(ids)
          return if answered.nil?

          @monitor.synchronize do
            ids.each { |id| remember(id, answered[id]) }
          end
        end

        # @return [Hash, nil] nil when the call itself failed
        def resolved(ids)
          Array(@stickers.call(ids)).each_with_object({}) do |sticker, out|
            next unless sticker.is_a?(Hash)

            id = sticker["custom_emoji_id"].to_s
            next if id.empty?

            emoji = sticker["emoji"].to_s
            out[id] = emoji unless emoji.empty?
          end
        rescue StandardError => e
          @logger&.warn { "could not resolve a Telegram custom emoji: #{e.class}: #{e.message}" }
          nil
        end

        # Deleted first so the key takes a new place in insertion order, which
        # is what makes the oldest entry the one written longest ago.
        def remember(id, emoji)
          @cache.delete(id)
          @cache[id] = emoji
          @cache.delete(@cache.each_key.first) if @cache.size > MAX_ENTRIES
        end
      end
    end
  end
end
