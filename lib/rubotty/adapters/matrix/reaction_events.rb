# frozen_string_literal: true

require "digest"

module Rubotty
  module Adapters
    module Matrix
      # Durable map from a reaction Adapter placed to the event id that added
      # it, so #remove_reaction can still find what to redact after a
      # restart. Backed by the key/value state every Storage::Base exposes,
      # the same way Core::ThreadNames persists a learned thread name; a
      # no-op when no durable store is wired. Read and write failures swallow
      # to nil, logging a warning when a logger is wired: a reaction the bot
      # placed becomes unredactable after a restart if this is silent.
      class ReactionEvents
        KEY_PREFIX = "matrix_reaction"

        # How many hex characters of the room/target/reaction digest the key
        # keeps. Short enough that KEY_PREFIX plus the digest always clears the
        # bridge_state.key column's 128 character bound, however long a real
        # Matrix room or event id runs.
        DIGEST_LENGTH = 40

        # @param logger [#warn, nil] where a swallowed write or read failure is reported
        def initialize(store:, logger: nil)
          @store = store
          @logger = logger
        end

        # Remember that +event_id+ placed +reaction+ on +target+ in +room+.
        def remember(room, target, reaction, event_id)
          return if @store.nil?

          @store.put_state(key(room, target, reaction), event_id.to_s)
          nil
        rescue StandardError => e
          @logger&.warn { "matrix reactions: could not remember #{reaction.key} on #{target}: #{e.class}: #{e.message}" }
          nil
        end

        # The event id that placed +reaction+ on +target+ in +room+, and clears
        # it: a redact call is expected to follow, and a stale id is worse than
        # a miss.
        def forget(room, target, reaction)
          return nil if @store.nil?

          value = presence(@store.get_state(key(room, target, reaction)))
          @store.put_state(key(room, target, reaction), "") if value
          value
        rescue StandardError => e
          @logger&.warn { "matrix reactions: could not forget #{reaction.key} on #{target}: #{e.class}: #{e.message}" }
          nil
        end

        private

        # Digests room, target and the reaction key together rather than
        # keeping any of them readable, since a real Matrix room or event id
        # alone can already run past the column bound.
        def key(room, target, reaction)
          "#{KEY_PREFIX}:#{Digest::SHA256.hexdigest("#{room}:#{target}:#{reaction.key}")[0, DIGEST_LENGTH]}"
        end

        def presence(value)
          return nil if value.nil?

          value.to_s.empty? ? nil : value.to_s
        end
      end
    end
  end
end
