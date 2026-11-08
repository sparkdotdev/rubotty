# frozen_string_literal: true

module Rubotty
  module Scripting
    # Which room a script invocation belongs to. Its own module because three
    # things depend on getting the same answer: what a script reads as
    # rubotty.room_key(), the memo store's per-room scope, and the keys
    # tracing and the rule cache are held under; two copies of this logic
    # drifting apart would scope a memo to one room and read it back under
    # another. A Snapshot::Channel's own route_key is the platform-side
    # identifier (a Telegram chat_id) and differs per channel inside one
    # room, so it is the wrong answer; the community holds the real mapping.
    module RoomKey
      module_function

      # @param channel [#room_key, #endpoint_key, String, Symbol, nil]
      # @param community [#room_key_of, nil]
      # @return [String] the room key, or "" when there is honestly no answer
      def for(channel:, community: nil)
        return "" if channel.nil?

        # A room handed straight in, which is what the pipeline does where it
        # already knows one.
        return channel.room_key.to_s if channel.respond_to?(:room_key)

        if community.respond_to?(:room_key_of)
          resolved = community.room_key_of(channel)
          return resolved.to_s if resolved
        end

        # No control plane (the memory path), or a channel in no room at all:
        # a plain string or symbol is its own key. Anything else has no
        # honest answer: the object address that to_s would give looks the
        # same as "" to a script and changes on restart.
        channel.is_a?(String) || channel.is_a?(Symbol) ? channel.to_s : ""
      end
    end
  end
end
