# frozen_string_literal: true

module Rubotty
  module Storage
    # Database schema for the message map.
    #
    # Deliberately one table with no foreign keys and no ORM models. If the
    # table is dropped the worst outcome is that edits and deletes stop
    # propagating for messages sent before the drop.
    module Schema
      TABLE = SequelStore::TABLE
      REACTION_TABLE = SequelStore::REACTION_TABLE
      STATE_TABLE = SequelStore::STATE_TABLE
      CLAIM_TABLE = SequelStore::CLAIM_TABLE
      MULTIPOST_TABLE = SequelStore::MULTIPOST_TABLE

      module_function

      # Idempotent. Safe to run on every boot, which is what `auto_migrate`
      # does by default.
      def apply(db)
        create_table(db) unless db.table_exists?(TABLE)
        create_reaction_table(db) unless db.table_exists?(REACTION_TABLE)
        create_state_table(db) unless db.table_exists?(STATE_TABLE)
        create_claim_table(db) unless db.table_exists?(CLAIM_TABLE)
        create_multipost_table(db) unless db.table_exists?(MULTIPOST_TABLE)
        add_indexes(db)
        add_reaction_indexes(db)
        add_claim_indexes(db)
        add_multipost_indexes(db)
        db
      end

      def create_table(db)
        db.create_table?(TABLE) do
          primary_key :id
          # Endpoint and native ids are stored as text: Discord snowflakes do
          # not fit a signed 64 bit integer comfortably in every backend.
          String :source_endpoint, null: false, size: 128
          String :source_native_id, null: false, size: 255
          String :destination_endpoint, null: false, size: 128
          String :destination_native_id, null: false, size: 255
          String :room_id, null: false, size: 128
          DateTime :expires_at, null: true
          DateTime :created_at, null: false
        end
      end

      def add_indexes(db)
        # Unique on the whole relationship: this is what makes {SequelStore#record}
        # idempotent, so a retry after a partial failure cannot duplicate rows.
        create_index(
          db, %i[source_endpoint source_native_id destination_endpoint destination_native_id],
          name: :message_map_pair_idx, unique: true
        )
        # Forward lookup: given a source, find copies. The hot path for edits.
        create_index(db, %i[source_endpoint source_native_id], name: :message_map_source_idx)
        # Reverse lookup, and the loop guard's "did we write this" check.
        create_index(db, %i[destination_endpoint destination_native_id], name: :message_map_destination_idx)
        # Purge scan.
        create_index(db, [:expires_at], name: :message_map_expiry_idx)
      end

      # One row per (message, reaction, person): aggregate state, so a
      # mirrored reaction survives until the last holder removes theirs.
      # `actor_id` is the only personal data in the schema, a platform user
      # id with no name attached, expiring on the message TTL.
      def create_reaction_table(db)
        db.create_table?(REACTION_TABLE) do
          primary_key :id
          String :endpoint_id, null: false, size: 128
          String :native_id, null: false, size: 255
          # Canonical identity of the reaction: "emoji:X" or "custom:ID".
          String :reaction_key, null: false, size: 128
          String :emoji, null: true, size: 64
          String :custom_id, null: true, size: 64
          String :custom_name, null: true, size: 128
          String :actor_id, null: false, size: 128
          DateTime :expires_at, null: true
          DateTime :created_at, null: false
        end
      end

      # A handful of bytes the bridge remembers across restarts. The primary
      # key is the key itself, so put_state is a plain upsert.
      def create_state_table(db)
        db.create_table?(STATE_TABLE) do
          String :key, primary_key: true, size: 128
          String :value, null: false, text: true
          DateTime :expires_at, null: true
          DateTime :updated_at, null: false
        end
      end

      # Exactly-once relay dedupe. One row per claimed source event; the unique
      # index on the whole key IS the guarantee, so two relay attempts racing the
      # same INSERT end with exactly one winner.
      def create_claim_table(db)
        db.create_table?(CLAIM_TABLE) do
          primary_key :id
          # Empty string, never NULL, on the no-control-plane path: NULLs compare
          # as distinct in a unique index, which would silently defeat the dedupe.
          String :community, null: false, size: 128, default: ""
          # The SOURCE event's identity, stable across instances.
          String :source_endpoint, null: false, size: 128
          String :source_native_id, null: false, size: 255
          # The relayed operation, keyed so it names a single EVENT: "new",
          # "delete", "edit:<body-digest>", "react:<actor>:<reaction>" or
          # "react-notice:<target>:<actor>".
          String :operation, null: false, size: 255
          DateTime :expires_at, null: true
          DateTime :claimed_at, null: false
        end
      end

      # Cross-channel duplicate (multipost) fingerprints: one row per
      # (community, author, fingerprint, channel), refreshed on every
      # sighting and expiring when the window passes. Holds a digest, never
      # the message text.
      def create_multipost_table(db)
        db.create_table?(MULTIPOST_TABLE) do
          primary_key :id
          # Empty string, never NULL, on the no-control-plane path: NULLs compare
          # as distinct in a unique index, which would silently split the key.
          String :community, null: false, size: 128, default: ""
          # The platform-stable author identity ("adapter:native_id").
          String :author, null: false, size: 255
          # A digest of the normalised message text (a hex SHA-256, 64 chars),
          # never the text itself.
          String :fingerprint, null: false, size: 128
          # The endpoint id the sighting arrived on: one distinct channel.
          String :channel, null: false, size: 128
          DateTime :expires_at, null: true
          DateTime :recorded_at, null: false
        end
      end

      def add_reaction_indexes(db)
        # Makes add_reaction idempotent under redelivery.
        create_index(
          db, %i[endpoint_id native_id reaction_key actor_id],
          name: :reaction_state_unique_idx, unique: true, table: REACTION_TABLE
        )
        # The hot path: which reactions does this message currently carry.
        create_index(
          db, %i[endpoint_id native_id],
          name: :reaction_state_message_idx, table: REACTION_TABLE
        )
        create_index(db, [:expires_at], name: :reaction_state_expiry_idx, table: REACTION_TABLE)
      end

      def add_claim_indexes(db)
        # The exactly-once guarantee: at most one live claim per source event and
        # operation. A concurrent second INSERT trips this and loses the race.
        create_index(
          db, %i[community source_endpoint source_native_id operation],
          name: :relay_claims_unique_idx, unique: true, table: CLAIM_TABLE
        )
        # Purge scan.
        create_index(db, [:expires_at], name: :relay_claims_expiry_idx, table: CLAIM_TABLE)
      end

      def add_multipost_indexes(db)
        # Makes record_multipost's upsert idempotent per channel, so a repeat in
        # a channel already seen refreshes the row instead of double-counting.
        create_index(
          db, %i[community author fingerprint channel],
          name: :multipost_fingerprints_unique_idx, unique: true, table: MULTIPOST_TABLE
        )
        # The hot path: count the distinct channels carrying one fingerprint.
        create_index(
          db, %i[community author fingerprint],
          name: :multipost_fingerprints_key_idx, table: MULTIPOST_TABLE
        )
        # Purge scan.
        create_index(db, [:expires_at], name: :multipost_fingerprints_expiry_idx, table: MULTIPOST_TABLE)
      end

      def create_index(db, columns, name:, unique: false, table: TABLE)
        return if index_exists?(db, name, table)

        db.add_index(table, columns, name: name, unique: unique)
      rescue Sequel::DatabaseError
        # Another process racing us to the same migration is fine.
        nil
      end

      def index_exists?(db, name, table = TABLE)
        db.indexes(table).key?(name)
      rescue Sequel::Error, NotImplementedError
        false
      end

      def drop(db)
        db.drop_table?(MULTIPOST_TABLE)
        db.drop_table?(CLAIM_TABLE)
        db.drop_table?(STATE_TABLE)
        db.drop_table?(REACTION_TABLE)
        db.drop_table?(TABLE)
      end
    end
  end
end
