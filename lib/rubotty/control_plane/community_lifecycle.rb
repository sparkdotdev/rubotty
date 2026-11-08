# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Start or stop the bot in a community: the reusable core the operator DM
    # console and the dashboard both drive. A community's +status+ is the
    # whitelist state auto-leave hangs on: "active" resolves its channels so
    # events route; "suspended" drops its channels from {Snapshot}'s route
    # index without removing the community or leaving the space. Every write
    # flips the status, rebuilds and swaps the Snapshot, and bumps
    # +updated_at+ so another process's {ChangeDetector} picks it up. Because
    # a suspended community can't resolve an in-channel command, restart comes from a DM.
    class CommunityLifecycle
      # Raised for a request that cannot be carried out: no community with that
      # slug. Carries a human-readable message a caller prints as-is.
      class Invalid < Rubotty::Error; end

      ACTIVE = "active"
      SUSPENDED = "suspended"

      # The outcome of an operation, uniform so a caller branches on +status+
      # without catching exceptions for control flow.
      Result = Struct.new(:status, :community, keyword_init: true) do
        def started? = status == :started

        def stopped? = status == :stopped

        # The request was a no-op because the community was already in the target
        # state, which is not an error.
        def already_active? = status == :already_active

        def already_suspended? = status == :already_suspended

        # A change actually landed (as opposed to being a no-op).
        def changed? = %i[started stopped].include?(status)
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param registry [Registry, nil] reloaded after a write when present; nil
      #   in a pure-data test that asserts on rows without a running Snapshot
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, registry: nil, logger: nil, clock: -> { Time.now })
        @models = models
        @registry = registry
        @logger = logger
        @clock = clock
      end

      # The community row for a slug, or raise {Invalid} naming it. The slug is the
      # operator-assigned handle the console's "stop <slug>" form references.
      def community!(slug)
        row = @models.community.where(slug: slug.to_s).first
        return row if row

        raise Invalid, "no community with slug #{slug.to_s.inspect}."
      end

      # The community row a slug names, or nil (the non-raising variant).
      def find_by_slug(slug)
        @models.community.where(slug: slug.to_s).first
      end

      # The community owning a coarse platform space, or nil: the caller passes the
      # space id of the message origin (the Telegram supergroup chat_id, the
      # Discord guild id), which platform_connections keys a community by.
      def community_for_space(adapter:, account:, external_id:)
        connection = @models.platform_connection.where(
          adapter: adapter.to_s, account: account.to_s, external_id: external_id.to_s
        ).first
        connection && @models.community[connection.community_id]
      end

      # Whether a community row is currently started (active).
      def active?(community) = community.status.to_s == ACTIVE

      # Start the bot in a community: set its status active and reload the
      # Snapshot so its channels resolve again on the next event. Idempotent: an
      # already-active community is a no-op reported as :already_active.
      #
      # @param community [Models::Community]
      # @return [Result] :started or :already_active
      def start(community:)
        return Result.new(status: :already_active, community: community) if active?(community)

        community.update(status: ACTIVE, updated_at: @clock.call)
        reload
        log_change(community, "started")
        Result.new(status: :started, community: community)
      end

      # Stop the bot in a community: set its status suspended and reload the
      # Snapshot so its channels stop resolving. Idempotent: an already-suspended
      # community is a no-op reported as :already_suspended.
      #
      # @param community [Models::Community]
      # @return [Result] :stopped or :already_suspended
      def stop(community:)
        return Result.new(status: :already_suspended, community: community) unless active?(community)

        community.update(status: SUSPENDED, updated_at: @clock.call)
        reload
        log_change(community, "stopped")
        Result.new(status: :stopped, community: community)
      end

      private

      # Rebuild the Snapshot and swap it atomically, so a start or stop applies on
      # the very next event. A reload failure never loses the committed status
      # write: the row is already saved, only live recognition is delayed.
      def reload
        @registry&.reload
      rescue StandardError => e
        @logger&.warn { "community lifecycle: snapshot reload after a write failed: #{e.message}" }
      end

      def log_change(community, verb)
        @logger&.info { "community #{verb}: #{community.slug} (id=#{community.id})" }
      end
    end
  end
end
