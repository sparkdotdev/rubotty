# frozen_string_literal: true

module Rubotty
  module Storage
    # The storage contract. The domain is the message map: a row ties a
    # source message's id to the ids created when it was relayed, so a later
    # edit or delete can find the copies. No message content is held, rows
    # expire on the configured TTL, and every method may be called
    # concurrently from several room worker threads.
    class Base
      # Create or update the schema. Idempotent.
      def migrate!
        raise NotImplementedError, "#{self.class} must implement #migrate!"
      end

      # Record that +source+ was relayed to +destination+. Must be idempotent on
      # (source, destination): a redelivery after a partial failure must not
      # create a duplicate row.
      #
      # @param expires_at [Time, nil] nil means never expire
      def record(source:, destination:, room_id:, expires_at: nil)
        raise NotImplementedError, "#{self.class} must implement #record"
      end

      # Every message we created as a result of +source+.
      #
      # @param source [Core::MessageRef]
      # @param endpoint_id [String, nil] restrict to one endpoint
      # @return [Array<Core::MessageRef>]
      def counterparts(source, endpoint_id: nil)
        raise NotImplementedError, "#{self.class} must implement #counterparts"
      end

      # The reverse lookup: given a message we created, what caused it.
      #
      # @param destination [Core::MessageRef]
      # @return [Array<Core::MessageRef>]
      def origins(destination)
        raise NotImplementedError, "#{self.class} must implement #origins"
      end

      # Is this ref something WE wrote? Used by {Core::LoopGuard} as the restart
      # safe echo check, so it must be fast and must not raise on a miss.
      #
      # @param ref [Core::MessageRef]
      # @return [Boolean]
      def destination?(ref)
        raise NotImplementedError, "#{self.class} must implement #destination?"
      end

      # When the map stops knowing about +ref+: the latest expiry among the live
      # rows naming it on either side. Reaction state rides this rather than a
      # fresh TTL of its own, so it cannot outlive the map row it belongs to.
      #
      # @param ref [Core::MessageRef]
      # @return [Time, nil] nil when no live row names +ref+, and also when one
      #   of them never expires; a caller reads nil as "no expiry to inherit"
      def map_expiry(ref)
        raise NotImplementedError, "#{self.class} must implement #map_expiry"
      end

      # Drop every row mentioning +ref+ on either side. Called after a delete
      # has been propagated.
      def forget(ref)
        raise NotImplementedError, "#{self.class} must implement #forget"
      end

      # Reaction aggregate state is per message, per emoji, per actor, because a
      # mirrored reaction must survive until the LAST person who added it takes
      # it away. A row holds identity only and expires on the message map's TTL.

      # Record that +actor_id+ now has +reaction+ on +ref+. Must be idempotent: a
      # platform may redeliver the same reaction event.
      #
      # @param ref [Core::MessageRef] the message reacted to
      # @param reaction [Core::Reaction]
      # @param actor_id [String] native id of the person reacting
      # @param expires_at [Time, nil]
      # @return [Integer] how many distinct actors now hold this reaction
      def add_reaction(ref, reaction:, actor_id:, expires_at: nil)
        raise NotImplementedError, "#{self.class} must implement #add_reaction"
      end

      # Record that +actor_id+ no longer has +reaction+ on +ref+.
      #
      # @return [Integer] how many distinct actors still hold it; zero means
      #   the mirror should be removed
      def remove_reaction(ref, reaction:, actor_id:)
        raise NotImplementedError, "#{self.class} must implement #remove_reaction"
      end

      # Drop every actor's row for +ref+, or just the ones for +reaction+ when
      # given. For a bulk clear a platform reports with no author: unlike
      # {#add_reaction}/{#remove_reaction}, which only ever move ONE actor's
      # claim, this takes the whole aggregate down at once, named actors
      # included, because that is what actually happened on the platform.
      #
      # @param reaction [Core::Reaction, nil] one emoji, or nil for every emoji
      def clear_reactions(ref, reaction: nil)
        raise NotImplementedError, "#{self.class} must implement #clear_reactions"
      end

      # Exactly-once relay claims: a zero-downtime deploy briefly runs two
      # containers on one bot token, and a gateway RESUME can redeliver, so
      # the same source event can reach the relay path twice. Atomic and
      # cross-instance on a shared database, single process elsewhere.

      # Atomically claim +source+ for +operation+. The check and the claim MUST be
      # one atomic operation: two callers racing the same key must never both win.
      #
      # @param community [String, nil] owning community, "" when none (never NULL,
      #   so distinct-NULL semantics cannot defeat the unique key)
      # @param expires_at [Time, nil] when the claim may be pruned
      # @return [Boolean] true if THIS caller won the claim and should relay,
      #   false if it was already claimed (a duplicate; relay is a no-op)
      def claim_relay(source:, operation:, community: nil, expires_at: nil)
        raise NotImplementedError, "#{self.class} must implement #claim_relay"
      end

      # Release a claim so a complementary later event can re-claim it: only
      # the reaction path uses this, where a removal releases the add's
      # claim so a genuine re-add is relayed again. A no-op when the claim
      # is absent.
      #
      # @return [void]
      def release_relay(source:, operation:, community: nil)
        raise NotImplementedError, "#{self.class} must implement #release_relay"
      end

      # True when a claim already exists for +source+/+operation+, WITHOUT taking
      # one, for the paced backfill sweep. Mirrors #claim_relay's key exactly, so
      # true here means a #claim_relay would lose the race.
      #
      # @param source [Core::MessageRef]
      # @param operation [String]
      # @param community [String, nil]
      # @return [Boolean]
      def relay_claimed?(source:, operation:, community: nil)
        raise NotImplementedError, "#{self.class} must implement #relay_claimed?"
      end

      # When +endpoint+ last claimed a relay in +community+, or nil. nil
      # means UNKNOWN, never "never": the ledger is pruned at the message
      # TTL and the in-process backends record no claim time at all, so a
      # caller should read nil as "fall back to your own window".
      #
      # @param community [String, nil]
      # @return [Time, nil]
      def last_relay_at(endpoint:, community: nil) = nil

      # A named lock any caller can take, for the things only one process may
      # do at a time when several share this store: Telegram's getUpdates
      # long poll, a due durable-scheduler job, a control-plane change. Real
      # and cross-process on a shared database, in-process on Memory/PStore.

      # Run +block+ while holding the named lock, releasing it even if +block+
      # raises.
      #
      # @param name [String] the lock's identity, shared across every caller
      # @param timeout [Numeric] seconds to wait for the lock before raising
      # @yield runs while the lock is held
      # @return the block's return value
      # @raise [LockUnavailable] the lock was not free within +timeout+
      def with_advisory_lock(name, timeout: 5, &block)
        raise NotImplementedError, "#{self.class} must implement #with_advisory_lock"
      end

      # Cross-channel duplicate (multipost) fingerprints: one TTL'd row per
      # (community, author, fingerprint, channel). The fingerprint is a digest
      # of the normalised text, so no message content is held.

      # Record that +author+ posted +fingerprint+ in +channel+ at +now+, and
      # return the number of DISTINCT channels that have carried that
      # fingerprint within the last +window_seconds+. Idempotent per channel.
      #
      # @param community [String, nil] owning community, "" when none (never
      #   NULL, so distinct-NULL semantics cannot defeat the unique key)
      # @return [Integer] distinct channels within the window, this one included
      def record_multipost(community:, author:, fingerprint:, channel:, now:, window_seconds:)
        raise NotImplementedError, "#{self.class} must implement #record_multipost"
      end

      # Every reaction currently held by at least one actor on +ref+, oldest
      # first. Telegram permits a bot exactly ONE reaction per message, and
      # oldest first keeps the mirror from flickering.
      #
      # @return [Array<Core::Reaction>]
      def reactions_on(ref)
        raise NotImplementedError, "#{self.class} must implement #reactions_on"
      end

      # Every reaction +actor_id+ still holds on +ref+, oldest first. The
      # per-person view of the same rows {#reactions_on} aggregates, which is
      # what decides whether a notice line about that person still has anything
      # to say.
      #
      # @return [Array<Core::Reaction>]
      def reactions_by(ref, actor_id:)
        raise NotImplementedError, "#{self.class} must implement #reactions_by"
      end

# Small durable key value state: get, put and an expiry, nothing more.

# @param key [String]
# @return [String, nil] nil when absent or expired
def get_state(key)
  raise NotImplementedError, "#{self.class} must implement #get_state"
end

# @param key [String]
# @param value [String]
# @param expires_at [Time, nil]
# @return [void]
def put_state(key, value, expires_at: nil)
  raise NotImplementedError, "#{self.class} must implement #put_state"
end

# Remove expired rows, from the message map, reaction state and key value state.

      # @param now [Time]
      # @return [Integer] number of rows removed
      def purge(now: Time.now)
        raise NotImplementedError, "#{self.class} must implement #purge"
      end

      # Total live rows. Diagnostics only.
      def size
        raise NotImplementedError, "#{self.class} must implement #size"
      end

      # Release connections. Safe to call more than once.
      def close; end

      # A one line description for the boot log, without credentials.
      def describe = self.class.name
    end
  end
end
