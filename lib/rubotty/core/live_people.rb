# frozen_string_literal: true

module Rubotty
  module Core
    # A Directory-shaped (mentionable people) view that always reads the Registry's
    # CURRENT Snapshot, delegating every read to +registry.current.people+, so a person
    # linked or renamed on the dashboard changes mention resolution without a restart.
    class LivePeople
      # @param registry [ControlPlane::Registry]
      def initialize(registry)
        @registry = registry
      end

      # The live Directory behind this view.
      def current = @registry.current.people

      def people = current.people

      def empty? = current.empty?

      def size = current.size

      # The directory one community may resolve against, read off the live
      # Snapshot the same way as everything else here.
      def for_community(community) = current.for_community(community)

      def by_identity(adapter_name, native_id) = current.by_identity(adapter_name, native_id)

      def by_handle(adapter_name, handle) = current.by_handle(adapter_name, handle)

      def resolve_mention(attributes) = current.resolve_mention(attributes)

      def to_s = "live #{current}"

      def inspect = "#<LivePeople #{people.size} person/people>"
    end
  end
end
