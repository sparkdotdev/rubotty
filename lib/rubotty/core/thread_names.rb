require "digest"

module Rubotty
  module Core
    # A small durable map from a platform thread id to the thread's human name.
    # Telegram sends a forum topic's name only on its creation/edit service
    # messages, not on every message, so each adapter learns it once from that
    # event and looks it back up later. A Telegram +message_thread_id+ is
    # unique only within its chat, so callers supply their own +scope+ (a chat
    # id, an account) to namespace by. No-op when no durable store is wired,
    # and lookups swallow errors to nil, logging a warning when a logger is wired.
    class ThreadNames
      KEY_PREFIX = "thread_name"

      # How many hex characters of the scope/native_id digest the key keeps.
      # Short enough that KEY_PREFIX plus the digest always clears the
      # bridge_state.key column's 128 character bound, however long the
      # platform's own scope or thread id runs.
      DIGEST_LENGTH = 40

      # @param store [#get_state, #put_state, nil] a durable KV store (a
      #   {Storage::Base}); nil disables the feature, so every method is a no-op
      # @param ttl [Numeric, nil] optional seconds a learned name survives; nil
      #   (the default) never expires it
      # @param logger [#warn, nil] where a swallowed write or read failure is reported
      def initialize(store:, ttl: nil, logger: nil)
        @store = store
        @ttl = ttl
        @logger = logger
      end

      # Remember that the thread +native_id+ in +scope+ is called +name+.
      #
      # A blank name or id is ignored, so an edit that changed only a topic's icon
      # leaves the known name in place rather than blanking it.
      #
      # @return [void]
      def learn(scope:, native_id:, name:)
        return if @store.nil?

        native_id = presence(native_id)
        name = presence(name)
        return if native_id.nil? || name.nil?

        @store.put_state(key(scope, native_id), name, expires_at: expiry)
        nil
      rescue StandardError => e
        @logger&.warn { "thread_names: could not learn the name for #{scope}/#{native_id}: #{e.class}: #{e.message}" }
        nil
      end

      # The learned name of the thread +native_id+ in +scope+, or nil when it was
      # never learned.
      #
      # @return [String, nil]
      def name_for(scope:, native_id:)
        return nil if @store.nil?

        native_id = presence(native_id)
        return nil if native_id.nil?

        presence(@store.get_state(key(scope, native_id)))
      rescue StandardError => e
        @logger&.warn { "thread_names: could not read the name for #{scope}/#{native_id}: #{e.class}: #{e.message}" }
        nil
      end

      private

      # Digests scope and native_id together rather than keeping either
      # readable, since either one alone could still be a long platform id.
      def key(scope, native_id) = "#{KEY_PREFIX}:#{Digest::SHA256.hexdigest("#{scope}:#{native_id}")[0, DIGEST_LENGTH]}"

      def expiry = @ttl ? Time.now + @ttl : nil

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
