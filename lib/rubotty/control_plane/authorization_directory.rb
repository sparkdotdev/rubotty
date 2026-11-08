# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # A private bot: it participates only in spaces an operator has authorized,
    # meaning a +platform_connections+ row maps the space's (adapter, account,
    # external_id) to a community, or its title matches the deployment-configured
    # {ProtectedCommunities} whitelist (which can never be removed by the CLI or
    # dashboard). Reads these rows directly rather than the Snapshot's route
    # index, since a stopped community is still authorized but drops out of
    # that index.
    class AuthorizationDirectory
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param protected_communities [ProtectedCommunities] the deployment-configured
      #   optional title whitelist. A fresh deployment grants nothing by title.
      def initialize(models:, protected_communities: ProtectedCommunities.default)
        @models = models
        @protected_communities = protected_communities
      end

      # Is this space authorized? True when its title is on the deployment-configured whitelist
      # OR the control plane maps it to a community.
      #
      # @param title [String, nil] the space title; one on the
      #   {ProtectedCommunities} whitelist authorizes the space regardless of any row
      # @return [Boolean]
      def authorized?(adapter:, account:, external_id:, title: nil)
        return true if protected_title?(title)

        mapped?(adapter: adapter, account: account, external_id: external_id)
      end

      # The row-only half of {#authorized?}: whether a +platform_connections+ row
      # maps this space to a community, ignoring the title whitelist. Use this
      # over {#authorized?} when a whitelisted-but-unmapped space still needs to
      # reach an operator, since it has no community to reach one through.
      #
      # @return [Boolean]
      def mapped?(adapter:, account:, external_id:)
        !connection(adapter, account, external_id).nil?
      end

      # The whitelist-only half of {#authorized?}: whether the deployment-configured
      # {ProtectedCommunities} list protects a space carrying this title.
      #
      # @return [Boolean]
      def protected_title?(title) = @protected_communities.protected?(title)

      # The community owning a space, or nil when the space is unauthorized.
      def community_for(adapter:, account:, external_id:)
        row = connection(adapter, account, external_id)
        row && @models.community[row.community_id]
      end

      private

      def connection(adapter, account, external_id)
        @models.platform_connection.where(
          adapter: adapter.to_s, account: account.to_s, external_id: external_id.to_s
        ).first
      end
    end
  end
end
