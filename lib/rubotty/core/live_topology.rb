# frozen_string_literal: true

module Rubotty
  module Core
    # A Topology-shaped view that always reads the Registry's CURRENT Snapshot, so a
    # reload reaches the relay path without a restart. New endpoints and rooms
    # apply live; {Dispatcher#queue_for} starts a room worker on first use.
    class LiveTopology
      # @param registry [ControlPlane::Registry]
      def initialize(registry)
        @registry = registry
      end

      # The live Topology behind this view; everything below reads through here.
      def current = @registry.current.topology

      def rooms = current.rooms

      def rooms_for(endpoint_id) = current.rooms_for(endpoint_id)

      def endpoints = current.endpoints

      def endpoint(endpoint_id) = current.endpoint(endpoint_id)

      def accounts_by_adapter = current.accounts_by_adapter

      def empty? = current.empty?

      def to_s = "live #{current}"

      def inspect = "#<LiveTopology #{rooms.size} room(s), #{endpoints.size} endpoint(s)>"
    end
  end
end
