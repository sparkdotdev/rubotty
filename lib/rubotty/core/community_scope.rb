# frozen_string_literal: true

module Rubotty
  module Core
    # The tenancy guard for anything that resolves or delivers to an endpoint.
    # Room keys are unique only within a community, and the boot
    # {ControlPlane::Snapshot} merges every community's rooms into one flat
    # {Core::Topology}, so a lookup keyed on a name alone can land in another
    # tenant. This is the check that stands between that and a delivery, in one
    # place. {.assert!} and {.permit_or_log} guard a delivery the caller was
    # handed; {.within} picks among candidates, keeping only endpoints that
    # provably belong, so an unknown one is never guessed at.
    module CommunityScope
      # Raised when work belonging to one community was about to touch another
      # community's endpoint. Never rescued into a retry: a scoping mistake
      # does not become correct on a second attempt.
      class Violation < Rubotty::Error
        attr_reader :endpoint_id, :expected_community_id, :actual_community_id

        def initialize(endpoint_id:, expected_community_id:, actual_community_id:, doing: nil)
          @endpoint_id = endpoint_id
          @expected_community_id = expected_community_id
          @actual_community_id = actual_community_id
          super(build_message(doing))
        end

        private

        def build_message(doing)
          action = doing ? "#{doing}: " : ""
          "#{action}endpoint #{@endpoint_id} belongs to community #{@actual_community_id.inspect}, " \
            "not #{@expected_community_id.inspect}"
        end
      end

      module_function

      # Whether +endpoint+ may be acted on for +community_id+. An endpoint with
      # no community of its own is the single-community config-file path, which
      # has no other tenant to reach, so it passes.
      #
      # @param endpoint [Core::Endpoint, nil]
      # @param community_id [Integer, nil]
      # @return [Boolean]
      def permits?(endpoint, community_id)
        return false if endpoint.nil?

        actual = endpoint.respond_to?(:community_id) ? endpoint.community_id : nil
        return true if actual.nil? || community_id.nil?

        actual == community_id
      end

      # Guard a delivery point. Raises {Violation} rather than posting when the
      # endpoint belongs to another tenant.
      #
      # @param doing [String, nil] what was about to happen, for the message
      # @raise [Violation]
      # @return [Core::Endpoint] +endpoint+, so this can wrap an argument
      def assert!(endpoint, community_id, doing: nil)
        return endpoint if permits?(endpoint, community_id)

        raise Violation.new(
          endpoint_id: endpoint.respond_to?(:id) ? endpoint.id : endpoint.inspect,
          expected_community_id: community_id,
          actual_community_id: endpoint.respond_to?(:community_id) ? endpoint.community_id : nil,
          doing: doing
        )
      end

      # The endpoints of +community_id+, for a caller CHOOSING among candidates
      # rather than checking one it was handed. Exact match, nil included: on
      # the config-file path every endpoint is nil and they all match, while
      # under the control plane a nil-community endpoint matches only another
      # one, so a guess across tenants cannot come back from here.
      #
      # @return [Array<Core::Endpoint>]
      def within(endpoints, community_id)
        Array(endpoints).select do |endpoint|
          endpoint.respond_to?(:community_id) && endpoint.community_id == community_id
        end
      end

      # Log and skip instead of raising, for a broadcast loop where one bad
      # endpoint must not lose the rest of the fan-out. Returns whether the
      # endpoint may be used.
      #
      # @return [Boolean]
      def permit_or_log(endpoint, community_id, logger: nil, doing: nil)
        return true if permits?(endpoint, community_id)

        actual = endpoint.respond_to?(:community_id) ? endpoint.community_id : nil
        id = endpoint.respond_to?(:id) ? endpoint.id : endpoint.inspect
        logger&.error do
          "#{doing || "delivery"} REFUSED: endpoint #{id} belongs to community #{actual.inspect}, " \
            "not #{community_id.inspect}"
        end
        false
      end
    end
  end
end
