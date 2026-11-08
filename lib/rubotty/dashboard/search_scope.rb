# frozen_string_literal: true

module Rubotty
  module Dashboard
    # Turns a {Role} into the {ControlPlane::Search::Scope} the search service
    # narrows its queries with. Every action the service asks about is answered
    # by the same {Role#can?} the route for that page consults, so a search can
    # never offer a page its reader would be refused, and a page whose gate
    # changes changes here with it.
    module SearchScope
      module_function

      # @param role [Role, nil] the role behind the session, nil when there is none
      # @param communities [Array] every community row, for the per-community case
      # @return [ControlPlane::Search::Scope]
      def for(role:, communities:)
        return ControlPlane::Search::Scope.none if role.nil?
        return everywhere(role) if role.administrator? || role.viewer?

        named(role, communities)
      end

      # A reader whose answer is the same in every community, so the question is
      # asked once with none named. Reached only for an administrator or a
      # deployment-wide viewer, since for anybody else a nil community means the
      # landing page shell rather than "anywhere".
      def everywhere(role)
        ControlPlane::Search::Scope.deployment_wide(
          actions: ControlPlane::Search::ACTIONS.select { |action| permits?(role, action, nil) }
        )
      end

      # An operator or a community-scoped viewer, asked community by community.
      # A community where nothing at all is permitted is left out entirely, so
      # its id never reaches a query.
      def named(role, communities)
        by_community = communities.each_with_object({}) do |community, out|
          allowed = ControlPlane::Search::ACTIONS.select { |action| permits?(role, action, community) }
          out[community.id] = allowed if allowed.any?
        end
        ControlPlane::Search::Scope.communities(actions_by_community_id: by_community)
      end

      # The Files page is the one search destination no Role action names: its
      # route is require_admin!, so it is answered here rather than by the
      # permission matrix.
      def permits?(role, action, community)
        return role.administrator? if action == ControlPlane::Search::FILES_ACTION

        role.can?(action, community: community)
      end
    end
  end
end
