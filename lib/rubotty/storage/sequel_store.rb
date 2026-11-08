# frozen_string_literal: true

module Rubotty
  module Storage
    # Message map on any database Sequel can reach: one class serves every
    # Sequel backend (SQLite, PostgreSQL, MariaDB), with the driver chosen
    # by {Factory}, which requires the right library before connecting. The
    # handful of places the dialects genuinely differ (the upsert spelling)
    # are delegated to {Dialect}.
    class SequelStore < Base
      TABLE = :message_map
      REACTION_TABLE = :reaction_state
      STATE_TABLE = :bridge_state
      CLAIM_TABLE = :relay_claims
      MULTIPOST_TABLE = :multipost_fingerprints

      # @param db [Sequel::Database] already connected
      # @param logger [#info]
      def initialize(db:, logger: nil, description: nil)
        super()
        @db = db
        @logger = logger
        @description = description
        @dialect = Dialect.for(db)
      end

      attr_reader :db

      def migrate!
        Schema.apply(@db)
        self
      rescue StandardError => e
        raise StorageError, "could not create the message map schema: #{e.message}"
      end

      def record(source:, destination:, room_id:, expires_at: nil)
        row = {
          source_endpoint: source.endpoint_id,
          source_native_id: source.native_id,
          destination_endpoint: destination.endpoint_id,
          destination_native_id: destination.native_id,
          room_id: room_id.to_s,
          expires_at: expires_at,
          created_at: Time.now
        }

        # Idempotent by the unique index on the four id columns; the dialect
        # picks the right upsert spelling.
        @dialect.upsert(
          dataset,
          target: %i[source_endpoint source_native_id destination_endpoint destination_native_id],
          update: %i[expires_at]
        ).insert(row)
        nil
      rescue Sequel::Error => e
        raise StorageError, "could not record message map entry: #{e.message}"
      end

      def counterparts(source, endpoint_id: nil)
        scope = live
                .where(source_endpoint: source.endpoint_id, source_native_id: source.native_id)
        scope = scope.where(destination_endpoint: endpoint_id.to_s) if endpoint_id
        scope.select(:destination_endpoint, :destination_native_id).map do |row|
          Core::MessageRef.new(row[:destination_endpoint], row[:destination_native_id])
        end
      rescue Sequel::Error => e
        raise StorageError, "message map lookup failed: #{e.message}"
      end

      def origins(destination)
        live
          .where(destination_endpoint: destination.endpoint_id, destination_native_id: destination.native_id)
          .select(:source_endpoint, :source_native_id)
          .map { |row| Core::MessageRef.new(row[:source_endpoint], row[:source_native_id]) }
      rescue Sequel::Error => e
        raise StorageError, "message map reverse lookup failed: #{e.message}"
      end

      def destination?(ref)
        live.where(destination_endpoint: ref.endpoint_id, destination_native_id: ref.native_id).count.positive?
      rescue Sequel::Error => e
        raise StorageError, "message map echo check failed: #{e.message}"
      end

      def map_expiry(ref)
        expiries = live.where(mentions(ref)).select_map(:expires_at)
        return nil if expiries.empty? || expiries.any?(&:nil?)

        expiries.max
      rescue Sequel::Error => e
        raise StorageError, "message map expiry lookup failed: #{e.message}"
      end

      def forget(ref)
        dataset.where(mentions(ref)).delete
        reactions.where(endpoint_id: ref.endpoint_id, native_id: ref.native_id).delete
        nil
      rescue Sequel::Error => e
        raise StorageError, "message map delete failed: #{e.message}"
      end

      def add_reaction(ref, reaction:, actor_id:, expires_at: nil)
        @dialect.upsert(
          reactions,
          target: %i[endpoint_id native_id reaction_key actor_id],
          update: %i[expires_at]
        ).insert(
          endpoint_id: ref.endpoint_id,
          native_id: ref.native_id,
          reaction_key: reaction.key,
          emoji: reaction.emoji,
          custom_id: reaction.custom_id,
          custom_name: reaction.custom_name,
          actor_id: actor_id.to_s,
          expires_at: expires_at,
          created_at: Time.now
        )
        actor_count(ref, reaction)
      rescue Sequel::Error => e
        raise StorageError, "could not record reaction: #{e.message}"
      end

      def remove_reaction(ref, reaction:, actor_id:)
        reactions.where(
          endpoint_id: ref.endpoint_id, native_id: ref.native_id,
          reaction_key: reaction.key, actor_id: actor_id.to_s
        ).delete
        actor_count(ref, reaction)
      rescue Sequel::Error => e
        raise StorageError, "could not remove reaction: #{e.message}"
      end

      def reactions_on(ref)
        rows = live_reactions
               .where(endpoint_id: ref.endpoint_id, native_id: ref.native_id)
               .order(:id)
               .all
        rows.uniq { |row| row[:reaction_key] }.map do |row|
          Core::Reaction.new(
            emoji: row[:emoji], custom_id: row[:custom_id], custom_name: row[:custom_name]
          )
        end
      rescue Sequel::Error => e
        raise StorageError, "reaction lookup failed: #{e.message}"
      end

      def reactions_by(ref, actor_id:)
        live_reactions
          .where(endpoint_id: ref.endpoint_id, native_id: ref.native_id, actor_id: actor_id.to_s)
          .order(:id)
          .all
          .map do |row|
            Core::Reaction.new(
              emoji: row[:emoji], custom_id: row[:custom_id], custom_name: row[:custom_name]
            )
          end
      rescue Sequel::Error => e
        raise StorageError, "reaction lookup failed: #{e.message}"
      end

      def clear_reactions(ref, reaction: nil)
        scope = reactions.where(endpoint_id: ref.endpoint_id, native_id: ref.native_id)
        scope = scope.where(reaction_key: reaction.key) if reaction
        scope.delete
        nil
      rescue Sequel::Error => e
        raise StorageError, "could not clear reactions: #{e.message}"
      end

      # The atomic claim: a plain INSERT guarded by the unique index on
      # (community, source, operation), with no read-then-write, so two
      # overlapping instances can never both see the event as unclaimed.
      def claim_relay(source:, operation:, community: nil, expires_at: nil)
        claims.insert(
          community: community.to_s,
          source_endpoint: source.endpoint_id,
          source_native_id: source.native_id,
          operation: operation.to_s,
          expires_at: expires_at,
          claimed_at: Time.now
        )
        true
      rescue Sequel::UniqueConstraintViolation
        # Another instance already claimed this exact source event and operation.
        false
      rescue Sequel::Error => e
        raise StorageError, "could not claim relay for #{source}/#{operation}: #{e.message}"
      end

      def release_relay(source:, operation:, community: nil)
        claims.where(
          community: community.to_s,
          source_endpoint: source.endpoint_id,
          source_native_id: source.native_id,
          operation: operation.to_s
        ).delete
        nil
      rescue Sequel::Error => e
        raise StorageError, "could not release relay claim for #{source}/#{operation}: #{e.message}"
      end

      # Existence check on the same unique key #claim_relay writes. No expiry
      # filter: while a row is present a #claim_relay would trip the unique
      # index and lose, so "a row exists" is exactly "already claimed".
      def relay_claimed?(source:, operation:, community: nil)
        claims.where(
          community: community.to_s,
          source_endpoint: source.endpoint_id,
          source_native_id: source.native_id,
          operation: operation.to_s
        ).count.positive?
      rescue Sequel::Error => e
        raise StorageError, "relay claim lookup failed for #{source}/#{operation}: #{e.message}"
      end

      # The newest claim from this endpoint, on the leftmost prefix of the
      # same unique index #claim_relay writes against. Reads as nil once the
      # ledger has been pruned past the message TTL; an ordered fetch rather
      # than max(), since that comes back off SQLite as the raw string the
      # column holds instead of a Time.
      def last_relay_at(endpoint:, community: nil)
        claims.where(community: community.to_s, source_endpoint: endpoint.to_s)
              .order(::Sequel.desc(:claimed_at)).get(:claimed_at)
      rescue Sequel::Error => e
        raise StorageError, "last relay lookup failed for #{endpoint}: #{e.message}"
      end

      # Record one sighting and return how many distinct channels have carried
      # the fingerprint inside the window. The write is an upsert on the whole
      # key, so a repeat in a channel already seen refreshes its expiry.
      def record_multipost(community:, author:, fingerprint:, channel:, now:, window_seconds:)
        # A distinct local name: inside the virtual-row block below `expires_at`
        # must resolve to the COLUMN, so a local must not shadow it.
        expiry = now + window_seconds
        @dialect.upsert(
          multiposts,
          target: %i[community author fingerprint channel],
          update: %i[expires_at recorded_at]
        ).insert(
          community: community.to_s,
          author: author.to_s,
          fingerprint: fingerprint.to_s,
          channel: channel.to_s,
          expires_at: expiry,
          recorded_at: now
        )
        multiposts
          .where(community: community.to_s, author: author.to_s, fingerprint: fingerprint.to_s)
          .where { expires_at > now }
          .count
      rescue Sequel::Error => e
        raise StorageError, "could not record multipost fingerprint: #{e.message}"
      end

      # Delegates to the dialect, which is where the real per-backend SQL lives.
      def with_advisory_lock(name, timeout: Dialect::APP_LOCK_TIMEOUT, &block)
        @dialect.with_advisory_lock(name, timeout: timeout, &block)
      end

      def get_state(key)
        now = Time.now
        row = state_rows.where(key: key.to_s)
                        .where { (expires_at > now) | { expires_at => nil } }
                        .first
        row && row[:value]
      rescue Sequel::Error => e
        raise StorageError, "state lookup failed: #{e.message}"
      end

      def put_state(key, value, expires_at: nil)
        @dialect.upsert(
          state_rows,
          target: [:key],
          update: %i[value expires_at]
        ).insert(key: key.to_s, value: value.to_s, expires_at: expires_at, updated_at: Time.now)
        nil
      rescue Sequel::Error => e
        raise StorageError, "state write failed: #{e.message}"
      end

      def purge(now: Time.now)
        removed = dataset.where { expires_at <= now }.exclude(expires_at: nil).delete
        removed += reactions.where { expires_at <= now }.exclude(expires_at: nil).delete
        removed += claims.where { expires_at <= now }.exclude(expires_at: nil).delete
        removed += multiposts.where { expires_at <= now }.exclude(expires_at: nil).delete
        removed + state_rows.where { expires_at <= now }.exclude(expires_at: nil).delete
      rescue Sequel::Error => e
        raise StorageError, "message map purge failed: #{e.message}"
      end

      def size
        live.count
      rescue Sequel::Error => e
        raise StorageError, "message map count failed: #{e.message}"
      end

      def close
        @db.disconnect
      rescue StandardError
        nil
      end

      def describe = @description || "sequel message map on #{@db.database_type}"

      private

      def dataset = @db[TABLE]

      def reactions = @db[REACTION_TABLE]

      def state_rows = @db[STATE_TABLE]

      def claims = @db[CLAIM_TABLE]

      def multiposts = @db[MULTIPOST_TABLE]

      # Expired rows are filtered on read as well as purged on a timer, so a
      # late purge never resurrects a message that should no longer be editable.
      def live
        now = Time.now
        dataset.where { (expires_at > now) | { expires_at => nil } }
      end

      def live_reactions
        now = Time.now
        reactions.where { (expires_at > now) | { expires_at => nil } }
      end

      # A row naming +ref+ on either side, the map being directional while a
      # delete or a reaction arrives on whichever copy the person was looking at.
      def mentions(ref)
        Sequel.|(
          { source_endpoint: ref.endpoint_id, source_native_id: ref.native_id },
          { destination_endpoint: ref.endpoint_id, destination_native_id: ref.native_id }
        )
      end

      def actor_count(ref, reaction)
        live_reactions.where(
          endpoint_id: ref.endpoint_id, native_id: ref.native_id, reaction_key: reaction.key
        ).count
      end
    end
  end
end
