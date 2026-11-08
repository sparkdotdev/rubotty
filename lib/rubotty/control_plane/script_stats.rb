# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Numbers a script records for itself, shared across a community like a
    # memo bucket: one rule counts, another reads the total. Row names are
    # free text a script fills in, so rows are capped and age out at
    # {RETENTION}, or an unbounded per-author table would grow forever.
    class ScriptStats
      class Invalid < Rubotty::Error; end

      RETENTION = 90 * 24 * 60 * 60

      # The durable job kind that ages them out, run once a day.
      PRUNE_KIND = "script_stats_prune"

      PRUNE_INTERVAL = 24 * 60 * 60

      # Rows per stat per community. Reached, further rows are refused rather
      # than evicting something older, so a script can see it hit the ceiling.
      MAX_ROWS = 500

      MAX_NAME = 64
      MAX_ROW_NAME = 120

      # Bounded so one call cannot stand in for a thousand.
      MAX_STEP = 1_000_000

      NAME_PATTERN = /\A[a-z0-9][a-z0-9 _-]{0,63}\z/i

      # How many pending increments to hold before writing them out, counted as
      # increments rather than as distinct rows: a room hammering ONE row is
      # exactly the case that needs coalescing. Pending counts die with the process.
      FLUSH_AFTER = 25

      # And a ceiling in time, so a quiet room's numbers still land. Only ever
      # reached by {#flush_if_due}, called on a timer by whoever owns this.
      FLUSH_AFTER_SECONDS = 30

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
        @pending = Hash.new(0)
        @pending_count = 0
        @pending_since = nil
        @lock = Mutex.new
      end

      # Add +step+ to one row, creating it at that value if it is new.
      #
      # @return [true, Array(false, String)] true, or false and why not, the
      #   same shape the memo store answers in
      def increment(community:, stat:, row:, step: 1, room_key: "")
        amount = Integer(step, exception: false)
        return [false, "a step has to be a whole number"] if amount.nil?
        return [false, "a step has to be a whole number under #{MAX_STEP}"] if amount.abs > MAX_STEP

        name = clean(stat, MAX_NAME, NAME_PATTERN)
        return [false, "that is not a stat name"] if name.nil?

        row_name = clean_row(row)
        return [false, "a stat row needs a name under #{MAX_ROW_NAME} characters"] if row_name.nil?

        # Answered here rather than at flush, where a refusal is a debug line
        # nobody reads.
        full = at_capacity?(community.id, name, row_name, room_key.to_s)
        return [false, "#{name} already has #{MAX_ROWS} rows, which is the limit"] if full

        coalesce(community.id, name, row_name, room_key.to_s, amount)
        true
      end

      # Write out if the time ceiling has passed. Called on a timer, since
      # nothing else can make a bound in time mean anything on a quiet room.
      def flush_if_due(now: @clock.call)
        due = @lock.synchronize do
          !@pending_since.nil? && (now - @pending_since) >= FLUSH_AFTER_SECONDS
        end
        due ? flush : 0
      end

      # Write out whatever has been counted since the last flush. Called on the
      # thresholds above, and by anything that needs the numbers current.
      def flush
        batch = @lock.synchronize do
          held = @pending
          @pending = Hash.new(0)
          @pending_count = 0
          @pending_since = nil
          held
        end
        return 0 if batch.empty?

        # Rows really written. apply swallows a database error rather than losing
        # the rest of the batch with it, so the size of the batch is only a count
        # of what was attempted.
        batch.count do |(community_id, stat, row_name, room_key), amount|
          apply(community_id, stat, row_name, room_key, amount)
        end
      end

      # Set one row outright, for a gauge rather than a counter.
      def record(community:, stat:, row:, value:, room_key: "")
        # Anything counted but not yet written has to land first, or setting a
        # gauge would be overtaken by increments that were already in flight.
        flush
        write(community: community, stat: stat, row: row, room_key: room_key) do |_existing|
          amount = Integer(value, exception: false)
          return [false, "a stat value has to be a whole number"] if amount.nil?
          return [false, "a stat value has to be under #{MAX_STEP}"] if amount.abs > MAX_STEP

          amount
        end
      end

      # Every stat for a community, as { stat => [{row:, value:, room_key:}] },
      # highest first within each stat. Expired rows are left out even if the
      # prune has not run yet.
      def report(community, now: @clock.call)
        flush
        rows = live(community, now: now).order(Sequel.desc(:value), :row_name).all
        rows.group_by { |row| row.stat.to_s }.transform_values do |group|
          group.map { |row| { row: row.row_name.to_s, value: row.value.to_i, room_key: row.room_key.to_s } }
        end
      end

      def any?(community, now: @clock.call)
        flush
        !live(community, now: now).first.nil?
      end

      # Drop everything past the retention, anywhere. Run daily.
      def prune(now: @clock.call)
        flush
        cutoff = now - RETENTION
        @models.script_stat.where { updated_at < cutoff }.delete
      end

      private

      # Held in memory until a threshold, keyed by everything that identifies a
      # row, so repeated counting of the same thing is one write.
      def coalesce(community_id, stat, row_name, room_key, amount)
        due = @lock.synchronize do
          @pending[[community_id, stat, row_name, room_key]] += amount
          @pending_count += 1
          @pending_since ||= @clock.call
          @pending_count >= FLUSH_AFTER || (@clock.call - @pending_since) >= FLUSH_AFTER_SECONDS
        end
        flush if due
      end

      # True when this would be a new row and the stat is already full. A row that
      # exists, or one already counted and waiting to be written, is always allowed.
      def at_capacity?(community_id, stat, row_name, room_key)
        return false if @lock.synchronize { @pending.key?([community_id, stat, row_name, room_key]) }
        return false unless @models.script_stat.where(community_id: community_id, stat: stat,
                                                      row_name: row_name, room_key: room_key).first.nil?

        count_by_id(community_id, stat) >= MAX_ROWS
      rescue StandardError
        false
      end

      # One coalesced count, written against whatever is in the table now.
      # Answers whether a row was really written.
      def apply(community_id, stat, row_name, room_key, amount)
        now = @clock.call
        # Added in the database rather than read, added in Ruby and written back:
        # two threads inside flush with the same key would each read the same
        # total and write it, losing one count.
        row = @models.script_stat.where(community_id: community_id, stat: stat,
                                        row_name: row_name, room_key: room_key)
        updated = row.update(value: Sequel[:value] + amount, updated_at: now)
        if updated.positive?
          true
        elsif count_by_id(community_id, stat) < MAX_ROWS
          create_or_add(row, community_id, stat, row_name, room_key, amount, now)
        else
          @logger&.debug { "script stats: #{stat} is at its row limit, dropped #{row_name}" }
          return false
        end
        true
      rescue StandardError => e
        @logger&.warn { "script stats: could not write #{stat}: #{e.class}: #{e.message}" }
        false
      end

      # A row this thread has just decided is missing, which another may be
      # creating at the same moment. Losing that race means the row exists now, so
      # the count is added to it rather than dropped.
      def create_or_add(row, community_id, stat, row_name, room_key, amount, now)
        @models.script_stat.create(community_id: community_id, stat: stat, row_name: row_name,
                                   room_key: room_key, value: amount, created_at: now, updated_at: now)
        true
      rescue Sequel::UniqueConstraintViolation
        row.update(value: Sequel[:value] + amount, updated_at: now).positive?
      end

      def count_by_id(community_id, stat)
        @models.script_stat.where(community_id: community_id, stat: stat).count
      end

      def live(community, now:)
        cutoff = now - RETENTION
        @models.script_stat.where(community_id: community.id).where { updated_at >= cutoff }
      end

      def write(community:, stat:, row:, room_key:)
        name = clean(stat, MAX_NAME, NAME_PATTERN)
        return [false, "that is not a stat name"] if name.nil?

        row_name = clean_row(row)
        return [false, "a stat row needs a name under #{MAX_ROW_NAME} characters"] if row_name.nil?

        now = @clock.call
        existing = find(community, name, row_name, room_key)
        if existing.nil? && count(community, name) >= MAX_ROWS
          return [false, "#{name} already has #{MAX_ROWS} rows, which is the limit"]
        end

        store(community, name, row_name, room_key, yield(existing), existing, now)
        true
      end

      def store(community, stat, row_name, room_key, value, existing, now)
        if existing
          existing.update(value: value, updated_at: now)
        else
          @models.script_stat.create(
            community_id: community.id, stat: stat, row_name: row_name,
            room_key: room_key.to_s, value: value, created_at: now, updated_at: now
          )
        end
      end

      def find(community, stat, row_name, room_key)
        @models.script_stat.where(community_id: community.id, stat: stat,
                                  row_name: row_name, room_key: room_key.to_s).first
      end

      def count(community, stat)
        @models.script_stat.where(community_id: community.id, stat: stat).count
      end

      def clean(value, limit, pattern)
        text = value.to_s.strip
        return nil if text.length > limit || !text.match?(pattern)

        text.downcase
      end

      # A row name is deliberately looser than a stat name, since it is often
      # somebody's display name, but it is still bounded and single line.
      def clean_row(value)
        text = value.to_s.strip.gsub(/\s+/, " ")
        return nil if text.empty? || text.length > MAX_ROW_NAME

        text
      end
    end
  end
end
