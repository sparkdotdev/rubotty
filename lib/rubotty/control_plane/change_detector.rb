# frozen_string_literal: true

require "sequel"
require "time"

module Rubotty
  module ControlPlane
    # Notices external edits to the control plane, since the admin CLI and
    # dashboard write from another process with no Registry handle, and
    # reloads the Snapshot live. Each tick compares [row count, MAX(id),
    # MAX(timestamp) as a float epoch] per watched table: count catches an
    # insert or delete, MAX(id) catches a same-second insert (MariaDB
    # DATETIME has whole-second resolution), MAX(timestamp) catches an
    # in-place UPDATE. An UPDATE stamped at or below the current max stays
    # invisible until a later write lifts it; {Watcher#reload_now} covers it.
    class ChangeDetector
      # The tables {SnapshotBuilder} projects, mapped to the timestamp column each
      # carries. people and person_identities are absent on their own: an operator
      # grant moves them in the same transaction operators already watches, and a
      # nickname write (the other way a person row is minted) always writes a
      # bridged_nicknames row in the same call, so watching operators and
      # bridged_nicknames between them covers every way a person changes.
      WATCHED = {
        communities: :updated_at,
        rooms: :updated_at,
        channels: :updated_at,
        room_channels: :created_at,
        feature_settings: :updated_at,
        operators: :granted_at,
        bridged_nicknames: :updated_at
      }.freeze

      # Nil when the backend cannot host the control plane or no Registry is
      # active, since reloading the Registry is the detector's whole job.
      #
      # @param storage [Storage::Base]
      # @param registry [Registry, nil]
      # @return [ChangeDetector, nil]
      def self.for(storage:, registry:, logger: nil)
        return nil if registry.nil?

        db = Boot.db_of(storage)
        return nil unless db.is_a?(Sequel::Database)

        new(models: ControlPlane.models(db), registry: registry, logger: logger)
      end

      # @param models [ControlPlane::Models]
      # @param registry [Registry]
      # @param logger [#info, #warn, nil]
      def initialize(models:, registry:, logger: nil)
        @models = models
        @registry = registry
        @logger = logger
        # Only the tables this database has: querying one a pending migration has
        # not created would raise on every tick forever.
        @watched = WATCHED.select { |table, _| @models.db.table_exists?(table) }.freeze
        # Baseline: the state the Registry's current Snapshot was built from.
        @marker = read_marker
      end

      attr_reader :marker

      # The tables actually being watched on this database. Diagnostics and tests.
      def watched_tables = @watched.keys

      # { table => [count, max_id, max_stamp_epoch] }. Never raises out: a transient
      # read failure returns the last known marker and the next tick retries.
      def read_marker
        @watched.to_h { |table, stamp| [table, probe(table, stamp)] }
      rescue Sequel::Error => e
        @logger&.warn { "change detector: could not read the change marker: #{e.message}" }
        @marker
      end

      # Reload the Snapshot when the marker has moved, returning whether it
      # reloaded. Safe to call directly, which is how {Watcher#reload_now}
      # drives it.
      def check
        marker = read_marker
        moved = changed_tables(marker)
        return false if moved.empty?

        snapshot = @registry.reload
        @marker = marker
        @logger&.info do
          "control-plane change detected in #{moved.join(", ")}, snapshot reloaded: #{describe(snapshot)}"
        end
        true
      rescue StandardError => e
        # A failed reload leaves the marker unadvanced, so the next tick retries.
        @logger&.warn { "change detector: snapshot reload failed: #{e.class}: #{e.message}" }
        false
      end

      private

      # Which watched tables differ from the marker in hand. Named rather than
      # reduced to a boolean so the log line can say what moved.
      def changed_tables(marker)
        return [] if marker.equal?(@marker)

        marker.filter_map { |table, probe| table if @marker&.[](table) != probe }
      end

      # One table's [count, max_id, max_stamp_epoch]: one row, three indexed
      # aggregates, no scan.
      def probe(table, stamp)
        row = @models.db[table]
                     .select(Sequel.function(:count).*.as(:row_count),
                             Sequel.function(:max, :id).as(:max_id),
                             Sequel.function(:max, stamp).as(:max_stamp))
                     .first
        [row[:row_count].to_i, row[:max_id].to_i, epoch_of(row[:max_stamp])]
      end

      # A timestamp as a float epoch, whatever the dialect returned. Numbers avoid
      # the timezone and precision round trips that differ between backends.
      def epoch_of(value)
        case value
        when nil then 0.0
        when Time then value.to_f
        when DateTime then value.to_time.to_f
        when Numeric then value.to_f
        else parse_epoch(value.to_s)
        end
      end

      def parse_epoch(text)
        Time.parse(text).to_f
      rescue ArgumentError
        0.0
      end

      # The reloaded snapshot's shape, for the log line.
      def describe(snapshot)
        rooms = snapshot.topology.rooms
        "#{rooms.size} room(s), #{snapshot.topology.endpoints.size} endpoint(s)"
      rescue StandardError
        "snapshot rebuilt"
      end
    end
  end
end
