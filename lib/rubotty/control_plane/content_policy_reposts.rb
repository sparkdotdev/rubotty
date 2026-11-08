# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Who may take down a message rubotty put back. A restored message is the
    # bot's own post carrying somebody else's words, so the ordinary /delete
    # ownership test (does the replied-to message belong to you) can never say
    # yes to the person it actually speaks for. This is the allowlist that
    # answers instead: one row per posted copy, naming exactly one member.
    #
    # Nothing here widens anything. A row grants one member the right to delete
    # one message on one endpoint, and only through /delete.
    class ContentPolicyReposts
      # Kept as long as the action record it came from, so the right to remove a
      # restored message lasts as long as anything else about that reversal.
      MAX_WINDOW_DAYS = ContentPolicyActions::MAX_WINDOW_DAYS
      DEFAULT_WINDOW_DAYS = ContentPolicyActions::DEFAULT_WINDOW_DAYS

      PRUNE_KIND = "content_policy_reposts_prune"
      PRUNE_INTERVAL = 6 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Remember that +native_id+ on +endpoint_id+ speaks for +author_native_id+.
      def record(community_id:, adapter:, endpoint_id:, native_id:, author_native_id:, identity_verified: false)
        return nil if [community_id, endpoint_id, native_id, author_native_id].any? { |v| v.to_s.empty? }

        @models.content_policy_repost.create(
          community_id: community_id, adapter: adapter.to_s, endpoint_id: endpoint_id.to_s,
          native_id: native_id.to_s, author_native_id: author_native_id.to_s, created_at: @clock.call,
          identity_verified: identity_verified == true
        )
      rescue StandardError => e
        @logger&.warn { "content policy reposts: could not record: #{e.class}: #{e.message}" }
        nil
      end

      # The whole authorisation question, asked and answered in one place: is
      # this exact message on this exact endpoint a restoration that speaks for
      # this exact member? Anything less than all three matching is false, and
      # an error is false, so a store that cannot answer grants nothing.
      #
      # @return [Boolean]
      def deletable_by?(endpoint_id:, native_id:, author_native_id:)
        return false if [endpoint_id, native_id, author_native_id].any? { |value| value.to_s.empty? }

        row = @models.content_policy_repost.where(
          endpoint_id: endpoint_id.to_s, native_id: native_id.to_s,
          author_native_id: author_native_id.to_s, identity_verified: true
        ).first
        return false if row.nil?
        return true unless %w[irc xmpp].include?(row.adapter)

        !Security::GrantIdentity.native_id(adapter: row.adapter, native_id: row.author_native_id).nil?
      rescue StandardError => e
        @logger&.warn { "content policy reposts: could not check #{native_id}: #{e.message}" }
        false
      end

      # Forget a copy once it is gone, so the allowlist holds only live messages.
      def forget(endpoint_id:, native_id:)
        @models.content_policy_repost
               .where(endpoint_id: endpoint_id.to_s, native_id: native_id.to_s).delete
      rescue StandardError => e
        @logger&.warn { "content policy reposts: could not forget #{native_id}: #{e.message}" }
        0
      end

      def prune(window_days: DEFAULT_WINDOW_DAYS)
        cutoff = @clock.call - (ContentPolicyActions.window_days(window_days) * 86_400)
        @models.content_policy_repost.where { created_at < cutoff }.delete
      rescue StandardError => e
        @logger&.warn { "content policy reposts: could not prune: #{e.message}" }
        0
      end
    end
  end
end
