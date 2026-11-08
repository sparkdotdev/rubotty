# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Which operator accounts a DM actually reaches, remembered between runs.
    # A bot cannot open a private chat with somebody who has never opened one
    # with it, so an operator can hold a perfectly good grant and hear nothing;
    # the refusal is recorded against the platform identity it was aimed at and
    # cleared the moment a DM there lands, so the dashboard can say the
    # audience is smaller than the operator list makes it look. Nothing here
    # raises: every caller is mid-way through something that has already
    # happened, and a bookkeeping write must never undo it.
    class OperatorReachability
      # Longest refusal text kept, so a platform answering with an essay
      # cannot overflow the column.
      REASON_LIMIT = 200

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared
      #   adapter map, only needed by {#probe}
      # @param protected_operators [Security::ProtectedOperators] the deployment-configured
      #   owner floor, so this reports on the audience an alert really has
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, adapters: {}, protected_operators: Security::ProtectedOperators.default,
                     logger: nil, clock: -> { Time.now })
        @models = models
        @adapters = adapters
        @logger = logger
        @clock = clock
        @audience = OperatorAudience.new(models: models, protected_operators: protected_operators)
      end

      # Remember that this platform account would not take a DM.
      def refused(identity_id, reason)
        return if identity_id.nil?

        @models.person_identity.where(id: identity_id)
               .update(dm_refused_at: @clock.call, dm_refused_reason: trim(reason))
      rescue StandardError => e
        @logger&.warn { "operator reachability: could not record a refused DM: #{e.message}" }
      end

      # Remember that this platform account took one, clearing an older
      # refusal. Skips the write when there is nothing to clear, so an alert
      # that reaches everybody costs no writes at all.
      def delivered(identity_id)
        return if identity_id.nil?

        @models.person_identity.where(id: identity_id).exclude(dm_refused_at: nil)
               .update(dm_refused_at: nil, dm_refused_reason: nil)
      rescue StandardError => e
        @logger&.warn { "operator reachability: could not clear a refused DM: #{e.message}" }
      end

      # Try +text+ at one platform account and remember how it went, for a
      # caller that wants to know NOW rather than at the next alert.
      #
      # @return [Symbol] :delivered, :refused, or :unknown when this
      #   deployment cannot DM on that platform at all and the answer would
      #   say nothing about the account
      def probe(community_id:, adapter:, native_id:, text:)
        instance = adapter_for(community_id: community_id, adapter: adapter)
        return :unknown if instance.nil? || !instance.supports_admin_dm?

        identity_id = identity_id_for(community_id: community_id, adapter: adapter, native_id: native_id)
        if instance.send_admin_dm(native_id.to_s, text)
          delivered(identity_id)
          return :delivered
        end
        refused(identity_id, "the platform would not open a private chat")
        :refused
      rescue StandardError => e
        @logger&.warn { "operator reachability: #{adapter}:#{native_id} refused a DM: #{e.class}: #{e.message}" }
        refused(identity_id_for(community_id: community_id, adapter: adapter, native_id: native_id),
                "#{e.class}: #{e.message}")
        :refused
      end

      # Every operator account of this community a DM was last refused at,
      # oldest refusal first, named well enough for somebody reading the
      # dashboard to know who to go and ask.
      #
      # @return [Array<Hash>]
      def unreachable(community_id:)
        return [] if community_id.nil?

        rows_for(community_id).filter_map do |row|
          next if row.dm_refused_at.nil?

          { person_id: row.person_id, person: @models.person[row.person_id]&.name,
            adapter: row.adapter, native_id: row.native_id, username: row.username,
            refused_at: row.dm_refused_at, reason: row.dm_refused_reason }
        end.sort_by { |entry| entry[:refused_at].to_s }
      rescue StandardError => e
        @logger&.warn { "operator reachability: could not read the unreachable operators: #{e.message}" }
        []
      end

      private

      # The identity rows of this community's operators, granted and deployment-configured
      # alike, through the resolver {AdminNotifier#operator_candidates} reads
      # too, so the screen and the audience can never disagree. A floor
      # operator known only as a sighting is absent here on purpose: that row
      # carries no columns a refusal could be written to.
      def rows_for(community_id)
        @audience.identity_rows(community_id)
      end

      def identity_id_for(community_id:, adapter:, native_id:)
        platform = adapter.to_s
        id = native_id.to_s
        rows_for(community_id).find { |row| row.adapter.to_s == platform && row.native_id.to_s == id }&.id
      end

      # Which loaded connection serves this community on this platform.
      def adapter_for(community_id:, adapter:)
        account = @models.platform_connection
                         .where(community_id: community_id, adapter: adapter.to_s).first&.account
        return nil if account.nil?

        @adapters[[adapter.to_sym, account]]
      end

      def trim(reason)
        text = reason.to_s.strip
        return nil if text.empty?

        text.length > REASON_LIMIT ? text[0, REASON_LIMIT] : text
      end
    end
  end
end
