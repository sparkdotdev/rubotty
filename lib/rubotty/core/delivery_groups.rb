# frozen_string_literal: true

require "digest"
require "json"

module Rubotty
  module Core
    # ID-only membership of a logical send that created several native messages.
    # The durable TTL follows the message map; the bounded cache supports callers
    # without a durable store and survives temporary write failures.
    class DeliveryGroups
      LIMIT = 4096

      def initialize(storage:, ttl:, logger: nil)
        @storage = storage
        @ttl = ttl
        @logger = logger
        @groups = {}
        @mutex = Mutex.new
      end

      def remember(key, ids)
        ids = ids.compact.map(&:to_s).uniq
        return if ids.size < 2

        @mutex.synchronize do
          @groups.delete(key)
          @groups[key] = ids
          @groups.shift while @groups.size > LIMIT
        end
        store = @storage.call
        return if store.nil?

        ttl = @ttl.call
        store.put_state(state_key(key), JSON.generate(ids), expires_at: ttl ? Time.now + ttl : nil)
      rescue StorageError => e
        @logger&.error { "could not persist multipart delivery identifiers: #{e.message}" }
      end

      def members(key, fallback:)
        cached = @mutex.synchronize { @groups[key] }
        return cached if cached

        raw = @storage.call&.get_state(state_key(key))
        ids = raw && JSON.parse(raw)
        ids.is_a?(Array) && !ids.empty? ? ids.map(&:to_s) : [fallback.to_s]
      rescue JSON::ParserError
        raise StorageError, "multipart delivery identifiers were invalid"
      end

      # Called only once every native deletion succeeded or was already gone.
      def forget(key)
        @storage.call&.put_state(state_key(key), "[]", expires_at: Time.now)
        @mutex.synchronize { @groups.delete(key) }
      end

      private

      def state_key(key) = "delivery-group:#{Digest::SHA256.hexdigest(JSON.generate(key))}"
    end
  end
end
