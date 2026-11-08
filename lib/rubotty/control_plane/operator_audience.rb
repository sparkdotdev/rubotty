# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # Who an operator alert for one community is addressed to, as directory
    # rows. Two audiences, and the second is the one that used to go missing:
    # the granted +operators+ rows, and the deployment-configured floor
    # {Security::ProtectedOperators} declares, which holds no row of its own
    # and joins to nothing, so its accounts are found by handle instead.
    # {AdminNotifier} turns these into DM targets and {OperatorReachability}
    # reports the ones a DM was refused at, through this one resolver so the
    # two can never answer for different people.
    class OperatorAudience
      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param protected_operators [Security::ProtectedOperators] the deployment-configured
      #   owner floor, whose handles count as operators of every community
      def initialize(models:, protected_operators: Security::ProtectedOperators.default)
        @models = models
        @protected_operators = protected_operators
      end

      # The verified +person_identities+ rows behind this community's
      # operators, granted rows first. Only a row here can carry a DM refusal,
      # which is why the dashboard's unreachable list reads this and not the
      # sightings below.
      def identity_rows(community_id)
        return [] if community_id.nil?

        rows = granted_rows(community_id) + floor_rows(@models.person_identity, community_id)
        seen = {}
        rows.each { |row| seen[row.id] ||= row }
        seen.values
      end

      # This community's sightings of a floor operator: the passively-observed
      # table {AdminNotifier#candidates} already resolves the deployment
      # administrator from, and for an owner never linked to a person the only
      # place their account is known at all.
      def sighting_rows(community_id)
        return [] if community_id.nil?

        floor_rows(@models.observed_identity, community_id)
      end

      private

      # The identities of the community's granted operator rows, read from the
      # verified directory rather than the passively-observed one, since an
      # alert names one.
      def granted_rows(community_id)
        person_ids = @models.operator.where(community_id: community_id).select_map(:person_id).uniq
        return [] if person_ids.empty?

        @models.person_identity.where(person_id: person_ids).order(:id).all
      end

      # Every row of one directory the floor protects. The SQL narrowing is a
      # coarse pre-filter, so an alert does not read a whole community's
      # sightings to find a handful of owners; it decides nothing, since
      # {Security::ProtectedOperators#owner?} still says which handle counts on
      # which adapter, which is what keeps this clear of the "never for
      # matching" rule that method's own documentation carries.
      def floor_rows(model, community_id)
        return [] if @protected_operators.nil? || @protected_operators.empty?

        handles = floor_handles
        return [] if handles.empty?

        model.where(community_id: community_id)
             .where(Sequel.|({ username: handles }, { native_id: handles }))
             .order(:id).all
             .select { |row| owner?(row) }
      end

      def owner?(row)
        @protected_operators.owner?(adapter: row.adapter, username: row.username, native_id: row.native_id)
      end

      def floor_handles
        @floor_handles ||= @protected_operators.entries.map { |entry| entry[:handle] }.compact.uniq
      end
    end
  end
end
