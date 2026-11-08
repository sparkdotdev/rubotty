# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The policies that got it wrong, written down when an operator reverses
    # one with /vindicate. Every row is a labelled sample: the text a policy
    # matched, the model's own reasoning and confidence, and the operator's
    # stated reason for disagreeing. Together they are what a description gets
    # rewritten against, which is the whole point of keeping them.
    class ContentPolicyMisfires
      # The ceiling the config validator holds callers to, and the fallback a
      # community that names nothing gets. Long enough to gather a corpus
      # across a tuning cycle, short enough that judged text does not live
      # here forever.
      MAX_WINDOW_DAYS = 90
      DEFAULT_WINDOW_DAYS = 90

      # How many rows one page of the dashboard reads.
      DEFAULT_LIMIT = 100

      # The durable job that drops what has lapsed, on the same six hourly
      # shape the action record's own prune uses.
      PRUNE_KIND = "content_policy_misfires_prune"
      PRUNE_INTERVAL = 6 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Copy one reversed action into the corpus. Answers nil rather than
      # raising: the reversal has already happened by the time this runs, and
      # a bookkeeping failure must never look like a failed vindication.
      # A policy that fired when it should not have. The only kind there was,
      # because /vindicate was the only way into the corpus.
      FALSE_POSITIVE = "false_positive"

      # A policy that should have fired and did not, named by an operator with
      # /condemn. The same mistake from the other side, and a description
      # rewritten against only one of the two gets worse at the other.
      MISS = "miss"

      KINDS = [FALSE_POSITIVE, MISS].freeze

      def record(community_id:, action_row:, statement: nil, reversed_by: nil, kind: FALSE_POSITIVE)
        return nil if community_id.nil? || action_row.nil?

        @models.content_policy_misfire.create(
          community_id: community_id, adapter: action_row.adapter.to_s,
          endpoint_id: action_row.endpoint_id.to_s, policy: action_row.policy&.to_s,
          action: action_row.action.to_s, body: action_row.body,
          reasoning: action_row.reasoning, confidence: action_row.confidence,
          context: action_row.context,
          statement: presence(statement), reversed_by: reversed_by&.to_s,
          kind: KINDS.include?(kind.to_s) ? kind.to_s : FALSE_POSITIVE,
          acted_at: action_row.created_at || @clock.call, created_at: @clock.call
        )
      rescue StandardError => e
        @logger&.warn { "content policy misfires: could not record: #{e.class}: #{e.message}" }
        nil
      end

      # Most recently called wrong first, which is the order somebody tuning a
      # description reads them in.
      def recent(community_id:, limit: DEFAULT_LIMIT)
        return [] if community_id.nil?

        @models.content_policy_misfire
               .where(community_id: community_id)
               .order(Sequel.desc(:created_at), Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 500)).all
      rescue StandardError => e
        @logger&.warn { "content policy misfires: could not read: #{e.message}" }
        []
      end

      # How many each policy has drawn, which is the number that says which
      # description is the one worth rewriting.
      def counts_by_policy(community_id:)
        return {} if community_id.nil?

        @models.content_policy_misfire
               .where(community_id: community_id)
               .group_and_count(:policy)
               .to_h { |row| [row[:policy].to_s, row[:count]] }
      rescue StandardError => e
        @logger&.warn { "content policy misfires: could not count: #{e.message}" }
        {}
      end

      def delete(community_id:, id:)
        return false if community_id.nil? || id.nil?

        @models.content_policy_misfire.where(community_id: community_id, id: id).delete.positive?
      rescue StandardError => e
        @logger&.warn { "content policy misfires: could not delete #{id}: #{e.message}" }
        false
      end

      def prune(window_days: DEFAULT_WINDOW_DAYS)
        cutoff = @clock.call - (self.class.window_days(window_days) * 86_400)
        @models.content_policy_misfire.where { created_at < cutoff }.delete
      rescue StandardError => e
        @logger&.warn { "content policy misfires: could not prune: #{e.message}" }
        0
      end

      # A window an operator asked for, held to the ceiling. Read here rather
      # than trusted from config, so a value stored before the ceiling existed
      # is pulled down instead of honoured.
      def self.window_days(value)
        days = value.to_i
        return DEFAULT_WINDOW_DAYS unless days.positive?

        [days, MAX_WINDOW_DAYS].min
      end

      private

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
