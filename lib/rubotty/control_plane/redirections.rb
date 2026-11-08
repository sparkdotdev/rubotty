# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # One row per redirection move: while running it is the paced worker's
    # working state, and once finished it is read-only history for the
    # dashboard. The plan is dropped on finish, since it is the only place
    # holding what an operator actually said, and every read is scoped by
    # community.
    class Redirections
      # A move is posting into the target room, or deleting from the source, or
      # over. Deleting is never reached until posting has consumed the whole plan.
      POSTING = "posting"
      DELETING = "deleting"
      DONE = "done"
      CANCELLED = "cancelled"
      FAILED = "failed"

      # Statuses where a paced worker still has something to do. A row outside
      # this set is history and is never touched again.
      LIVE = [POSTING, DELETING].freeze

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Open a move. Returns the new row, already in the posting phase with its
      # cursor at the start.
      #
      # @param community_id [Integer] the owning community, never nil
      # @param plan [Array<Hash>] the run, oldest first, JSON-serialisable
      def open(community_id:, source_endpoint_id:, target_room_id:, operator:,
               plan:, operator_native_id: nil)
        now = @clock.call
        @models.redirection.create(
          community_id: community_id,
          source_endpoint_id: source_endpoint_id.to_s,
          target_room_id: target_room_id.to_s,
          operator: operator.to_s,
          operator_native_id: operator_native_id&.to_s,
          message_count: plan.length,
          status: POSTING,
          step_index: 0,
          plan: JSON.generate(plan),
          created_at: now,
          updated_at: now
        )
      end

      # One live row by id, scoped to its community. nil when it is not there,
      # belongs to somebody else, or has already finished.
      def live(id:, community_id:)
        @models.redirection
               .where(id: id, community_id: community_id, status: LIVE)
               .first
      end

      # The plan a row carries, as an array of hashes with symbol keys. An
      # unreadable plan reads as empty, which stalls the move rather than
      # raising inside a durable job that would then retry forever.
      def plan_of(row)
        raw = row.plan
        return [] if raw.nil? || raw.to_s.empty?

        JSON.parse(raw.to_s, symbolize_names: true)
      rescue JSON::ParserError => e
        @logger&.warn { "redirection #{row.id}: unreadable plan (#{e.message})" }
        []
      end

      # Move the cursor on by one within the current phase.
      def advance(row, step_index:)
        row.update(step_index: step_index, updated_at: @clock.call)
      end

      # Mark one item of the plan as unrelayable and move the cursor past it, so
      # a message the target will not take costs that message rather than the
      # whole move. The mark rides in the plan itself, which needs no column of
      # its own and is read by the deleting phase walking that same plan: a
      # skipped original has to stay where it is, since nothing was reposted to
      # take its place and deleting it would destroy the only copy.
      #
      # @return [Boolean] whether the item was there to mark
      def skip(row, index:)
        plan = plan_of(row)
        return false if index.to_i.negative? || index.to_i >= plan.length

        plan[index.to_i] = plan[index.to_i].merge(skipped: true)
        row.update(plan: JSON.generate(plan), step_index: index.to_i + 1, updated_at: @clock.call)
        true
      end

      # Cross from posting into deleting, cursor back to the start. The only place
      # that transition happens, so "every repost has landed" is a property of one
      # method rather than of every caller.
      def start_deleting(row)
        row.update(status: DELETING, step_index: 0, updated_at: @clock.call)
      end

      # Finish a move: the plan goes, the row stays as history.
      def finish(row, status: DONE)
        now = @clock.call
        row.update(status: status, plan: nil, updated_at: now, completed_at: now)
      end

      # Stop a move an operator no longer wants. Refuses a row that is already
      # history, and one in the deleting phase, where the reposts have all landed
      # and stopping half way would leave the run in both rooms at once.
      #
      # @return [Boolean] whether anything was cancelled
      def cancel(id:, community_id:)
        row = @models.redirection.where(id: id, community_id: community_id, status: POSTING).first
        return false if row.nil?

        finish(row, status: CANCELLED)
        true
      end

      # This community's moves, newest first, for the dashboard page.
      def recent(community_id:, limit: 100)
        @models.redirection
               .where(community_id: community_id)
               .order(Sequel.desc(:created_at), Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 500))
               .all
      end

      # Every live row across every community, for a boot sweep that re-arms the
      # paced worker after a restart. The runtime's own recovery, so it
      # deliberately spans tenants and the caller must keep the rows apart.
      def live_everywhere(limit: 200)
        @models.redirection.where(status: LIVE).order(:id).limit(limit).all
      end
    end
  end
end
