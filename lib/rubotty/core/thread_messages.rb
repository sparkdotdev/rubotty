require "digest"

module Rubotty
  module Core
    # A durable map from a message's native id to the channel it actually lives
    # in, for platforms where the endpoint a message resolved to is not the
    # channel it physically sits in (a Discord thread message, whose ref
    # carries the parent channel's endpoint id). Learned once from the
    # {ThreadRef} a message carries on arrival, then read back for later
    # actions like edits or deletes. No-op when no durable store is wired;
    # entries never expire, since a thread message can be acted on long after
    # it was posted.
    class ThreadMessages
      KEY_PREFIX = "thread_message"

      # How many hex characters of the scope/native_id digest the key keeps.
      # Short enough that KEY_PREFIX plus the digest always clears the
      # bridge_state.key column's 128 character bound, however long the
      # platform's own scope or message id runs.
      DIGEST_LENGTH = 40

      # @param store [#get_state, #put_state, nil] a durable KV store (a
      #   {Storage::Base}); nil disables the feature, so every method is a no-op
      # @param ttl [Numeric, nil] optional seconds a learned mapping survives;
      #   nil (the default) never expires it
      # @param logger [#warn, nil] where a swallowed write or read failure is reported
      def initialize(store:, ttl: nil, logger: nil)
        @store = store
        @ttl = ttl
        @logger = logger
      end

      # Remember that the message +native_id+ in +scope+ lives in +channel_id+.
      #
      # @param scope [String, Integer] the adapter's namespace (an account)
      # @param native_id [String, Integer] the platform's message id
      # @param channel_id [String, Integer] the channel the message lives in
      # @return [void]
      def learn(scope:, native_id:, channel_id:)
        return if @store.nil?

        native_id = presence(native_id)
        channel_id = presence(channel_id)
        return if native_id.nil? || channel_id.nil?

        @store.put_state(key(scope, native_id), channel_id, expires_at: expiry)
        nil
      rescue StandardError => e
        @logger&.warn { "thread_messages: could not learn #{scope}/#{native_id}'s channel: #{e.class}: #{e.message}" }
        nil
      end

      # The channel the message +native_id+ in +scope+ was learned to live in,
      # or nil when it was never learned.
      #
      # @return [String, nil]
      def channel_for(scope:, native_id:)
        return nil if @store.nil?

        native_id = presence(native_id)
        return nil if native_id.nil?

        presence(@store.get_state(key(scope, native_id)))
      rescue StandardError => e
        @logger&.warn { "thread_messages: could not read #{scope}/#{native_id}'s channel: #{e.class}: #{e.message}" }
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
