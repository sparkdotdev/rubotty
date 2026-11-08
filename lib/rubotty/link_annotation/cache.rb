# frozen_string_literal: true

require "monitor"

module Rubotty
  module LinkAnnotation
    # What a URL turned out to be, remembered so it is read only once. A MISS
    # is cached too (a consent wall answers with a consent wall every time)
    # but retried sooner than a hit, which is effectively permanent. In
    # memory, bounded and not durable: writing every URL a community pastes
    # into a table would be a browsing history rubotty has no business keeping.
    class Cache
      DEFAULT_LIMIT = 2000
      HIT_TTL = 7 * 24 * 60 * 60
      MISS_TTL = 60 * 60

      Entry = Struct.new(:language, :expires_at, keyword_init: true)

      def initialize(limit: DEFAULT_LIMIT, clock: -> { Time.now })
        @limit = limit
        @clock = clock
        @entries = {}
        @monitor = Monitor.new
      end

      # The remembered answer for +key+, or nil when there is none. An {Entry}
      # whose +language+ is nil is a remembered "could not tell", which a caller
      # tells from a miss by asking for the entry rather than for the language.
      def get(key)
        @monitor.synchronize do
          entry = @entries[key.to_s]
          next nil if entry.nil?

          if entry.expires_at <= @clock.call
            @entries.delete(key.to_s)
            next nil
          end

          # Reinsert so the eviction below drops the least recently USED entry.
          @entries.delete(key.to_s)
          @entries[key.to_s] = entry
          entry
        end
      end

      # Remember that +key+ is written in +language+, or could not be told (nil).
      def put(key, language)
        ttl = language.nil? ? MISS_TTL : HIT_TTL
        @monitor.synchronize do
          @entries.delete(key.to_s)
          @entries[key.to_s] = Entry.new(language: language, expires_at: @clock.call + ttl)
          @entries.shift while @entries.size > @limit
        end
        language
      end

      # The cached answer, or the block's, which is then remembered.
      def fetch(key)
        entry = get(key)
        return entry.language if entry

        put(key, yield)
      end

      def size = @monitor.synchronize { @entries.size }

      def clear = @monitor.synchronize { @entries.clear }
    end
  end
end
