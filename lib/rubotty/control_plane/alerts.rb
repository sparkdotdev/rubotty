# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # A quiet alert is written to the dashboard only; a loud one is written the
    # same way and DMed to operators too, with the row written FIRST so a failed
    # DM never costs the alert. {#record} runs on the relay's hot path, bounded
    # by {MAX_TEXT}, {COMMUNITY_LIMIT} and {RETENTION}. Every read is scoped to
    # one community.
    class Alerts
      QUIET = "quiet"
      LOUD = "loud"

      MODES = [QUIET, LOUD].freeze

      # How much of a script's text is kept: long enough for a sentence naming
      # somebody and a room, short enough that this is no place for a message body.
      MAX_TEXT = 500

      # How long an alert is readable, and how far back {#prune} keeps.
      RETENTION = 30 * 24 * 60 * 60

      # Most alerts one community keeps.
      COMMUNITY_LIMIT = 500

      # The shortest gap between two retention sweeps on the write path.
      PRUNE_INTERVAL = 60 * 60

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
        @pruned_at = nil
        @prune_mutex = Mutex.new
      end

      # Write one alert down. Never raises: this runs while a script is
      # holding up a message on the relay's path, and must not cost a
      # room its bridging.
      #
      # @param mode [String] {QUIET} or {LOUD}. Validated by the caller, since a
      #   script naming something else has to be told so rather than corrected.
      # @return [Object, nil] the row, or nil when the write failed
      def record(community_id:, text:, mode: QUIET, room_key: "", script: "")
        body = clean(text)
        return nil if community_id.nil? || body.empty?

        now = @clock.call
        row = @models.alert.create(
          community_id: community_id, text: body, mode: mode.to_s,
          room_key: room_key.to_s[0, 128], script: script.to_s[0, 120],
          delivered_to: 0, created_at: now
        )
        evict(community_id)
        prune_if_due(now)
        row
      rescue StandardError => e
        @logger&.warn { "alerts: could not record an alert: #{e.class}: #{e.message}" }
        nil
      end

      # Note how many operators a loud alert's DM actually reached, so the page
      # can say "loud, and nobody was reachable". Never raises: the alert is
      # already recorded and this only decorates it.
      def delivered(row, count)
        return if row.nil?

        row.update(delivered_to: count.to_i)
      rescue StandardError => e
        @logger&.warn { "alerts: could not note the delivery count: #{e.class}: #{e.message}" }
      end

      # This community's alerts, newest first, none past {RETENTION}. The cutoff
      # is in the query, so this holds even on a deployment whose sweep has not run.
      def recent(community_id:, limit: 200, now: @clock.call)
        cutoff = now - RETENTION
        scope(community_id)
          .where { created_at > cutoff }
          .order(Sequel.desc(:created_at), Sequel.desc(:id))
          .limit(limit.to_i.clamp(1, COMMUNITY_LIMIT))
          .all
      end

      # What one script has raised, newest first, none past {RETENTION}. The
      # match is on the name the alert was written with, so anything raised
      # before a rename stays under the old name. No index on the column:
      # {COMMUNITY_LIMIT} already holds a community to 500 rows.
      def for_script(community_id:, script:, limit: 50, now: @clock.call)
        name = script.to_s
        return [] if name.empty?

        cutoff = now - RETENTION
        scope(community_id)
          .where(script: name)
          .where { created_at > cutoff }
          .order(Sequel.desc(:created_at), Sequel.desc(:id))
          .limit(limit.to_i.clamp(1, COMMUNITY_LIMIT))
          .all
      end

      # How many of this community's live alerts nobody has marked seen.
      def unseen_count(community_id:, now: @clock.call)
        cutoff = now - RETENTION
        scope(community_id).where(seen_at: nil).where { created_at > cutoff }.count
      end

      # Mark one alert seen. Scoped in the WHERE clause, so an id belonging to
      # another community matches nothing.
      #
      # @return [Boolean] whether anything changed
      def mark_seen(id:, community_id:)
        scope(community_id).where(id: id, seen_at: nil).update(seen_at: @clock.call).to_i.positive?
      end

      # Mark everything this community has outstanding as seen.
      #
      # @return [Integer] how many rows changed
      def mark_all_seen(community_id:)
        scope(community_id).where(seen_at: nil).update(seen_at: @clock.call).to_i
      end

      # Drop everything past the retention, everywhere. About the bytes on disk:
      # {#recent} already refuses these.
      #
      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - RETENTION
        @models.alert.where { created_at <= cutoff }.delete.to_i
      end

      private

      def scope(community_id) = @models.alert.where(community_id: community_id)

      def clean(text) = text.to_s.strip.gsub(/\s+/, " ")[0, MAX_TEXT].to_s

      # Hold one community to {COMMUNITY_LIMIT} rows, oldest out. Two statements
      # rather than one DELETE with a subquery over the same table, which MySQL
      # and MariaDB refuse.
      def evict(community_id)
        rows = scope(community_id)
        edge = rows.order(Sequel.desc(:id)).limit(1, COMMUNITY_LIMIT).get(:id)
        return 0 if edge.nil?

        rows.where { id <= edge }.delete.to_i
      end

      # Sweep at most once per {PRUNE_INTERVAL}, and never let a sweep failure
      # reach the caller: the row is already written.
      def prune_if_due(now)
        due = @prune_mutex.synchronize do
          next false if @pruned_at && (now - @pruned_at) < PRUNE_INTERVAL

          @pruned_at = now
          true
        end
        prune(now: now) if due
      rescue StandardError
        nil
      end
    end
  end
end
