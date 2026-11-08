# frozen_string_literal: true

module Rubotty
  module Core
    # A Moderation::Directory-shaped view that always reads the Registry's CURRENT
    # Snapshot, by delegating to +registry.current.operators+ on every call, so a
    # reload reaches every holder of this object with no change to their code.
    #
    # NOT an authorisation surface: the Snapshot merges every community's
    # operators, and a room key is unique only within one, so a permission check
    # reads the message's own community's directory instead.
    class LiveOperators
      # @param registry [ControlPlane::Registry]
      def initialize(registry)
        @registry = registry
      end

      # The live Moderation::Directory behind this view.
      def current = @registry.current.operators

      def operators = current.operators

      def empty? = current.empty?

      def resolve(adapter_name, native_id, username: nil)
        current.resolve(adapter_name, native_id, username: username)
      end

      def to_s = "live #{current}"

      def inspect = "#<LiveOperators #{operators.size} operator(s)>"
    end
  end
end
