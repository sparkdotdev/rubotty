# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The tenancy guard the REST API's two relay queues share. Both write a
    # community and a room into a pending row that {Adapters::Api::Adapter}
    # later drains and posts into, and the row is the last place the pair can
    # be compared: past it the relay routes on the room alone. Room keys are
    # unique only within a community, so a pair nothing checked is a post
    # landing in another tenant's room.
    module ApiRoomScope
      module_function

      # @param community [Models::Community]
      # @param room [Models::Room]
      # @raise [ArgumentError] when +room+ is not this community's
      def assert_pair!(community, room)
        return if !room.nil? && !community.nil? && room.community_id == community.id

        raise ArgumentError,
              "room #{room&.id.inspect} belongs to community #{room&.community_id.inspect}, " \
              "not #{community&.id.inspect}"
      end

      # A meta-level action names a message by the ref the room's own POST
      # minted, whose endpoint_id IS the room's synthetic API endpoint key.
      # Taking the ref rather than a bare id is what makes the pair checkable
      # at all: a bare id says nothing about which room it came from.
      #
      # @param room [Models::Room]
      # @param message [Core::MessageRef]
      # @raise [ArgumentError] when +message+ was not minted for +room+
      def assert_message!(room, message)
        expected = Adapters::Api.endpoint_key_for(room.id)
        actual = message.respond_to?(:endpoint_id) ? message.endpoint_id : nil
        return if actual == expected

        raise ArgumentError, "message ref #{actual.inspect} was not minted for room #{room.id} (#{expected})"
      end
    end
  end
end
