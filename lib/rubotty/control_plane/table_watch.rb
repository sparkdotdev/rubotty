# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # Notices an edit to ONE control-plane table between watcher ticks and
    # reruns +sync+, for work that would otherwise only run at boot: a
    # setting changed from the dashboard or the admin CLI while the bot keeps
    # running has to reach the running process somehow. Probes the same shape
    # {ChangeDetector} does, scoped to the single table the caller names.
    class TableWatch
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param sync [#call] rebuilds whatever that table drives
      # @param table [Symbol] the table to watch
      # @param stamp [Symbol] its "last written" column
      # @param logger [#warn, nil]
      def initialize(models:, sync:, table:, stamp: :updated_at, logger: nil)
        @models = models
        @sync = sync
        @table = table
        @stamp = stamp
        @logger = logger
        @marker = read_marker
      end

      # Rerun +sync+ when the watched table has moved since the last check.
      # Returns whether it did.
      def check
        marker = read_marker
        return false if marker == @marker

        @marker = marker
        @sync.call
        true
      end

      private

      # Never raises out: a transient read failure keeps the last known
      # marker and the next tick retries, same as {ChangeDetector#read_marker}.
      def read_marker
        probe
      rescue Sequel::Error => e
        @logger&.warn { "could not read the #{@table} table: #{e.message}" }
        @marker
      end

      # [row count, max id, max stamp]: one row, three indexed aggregates, no scan.
      def probe
        row = @models.db[@table]
                     .select(Sequel.function(:count).*.as(:row_count),
                             Sequel.function(:max, :id).as(:max_id),
                             Sequel.function(:max, @stamp).as(:max_stamp))
                     .first
        [row[:row_count].to_i, row[:max_id].to_i, row[:max_stamp].to_s]
      end
    end
  end
end
