# frozen_string_literal: true

module Rubotty
  module Polls
    # How far a posted card has scrolled, per room rather than per endpoint,
    # since the bridge relays every message to all of them. Not durable.
    class RoomActivity
      VISIBLE_WINDOW = 10

      # room_key is unique only within a community.
      def self.key(community_id, room_key) = "#{community_id}:#{room_key}"

      def initialize(window: VISIBLE_WINDOW)
        @window = window
        @by_room = Hash.new { |hash, key| hash[key] = [] }
        @last_ref = {}
        @mutex = Mutex.new
      end

      attr_reader :window

      # @param ref [#==, nil] the message's own identity, so the same message
      #   handed to #record twice in a row (PollCommand and ScheduleCommand
      #   both see every chat message, and share one RoomActivity) counts
      #   once, not once per feature watching this room.
      def record(key, at: Time.now, ref: nil)
        return if key.nil?

        @mutex.synchronize do
          room_key = key.to_s
          next if !ref.nil? && @last_ref[room_key] == ref

          @last_ref[room_key] = ref
          list = @by_room[room_key]
          list << at.to_f
          list.shift(list.size - @window) if list.size > @window
        end
      end

      # Whether a card posted at +moment+ has fallen out of the room's last
      # {#window} messages. A nil moment is never buried.
      def buried?(key, moment)
        return false if key.nil? || moment.nil?

        since = moment.to_f
        @mutex.synchronize { @by_room[key.to_s].count { |seen| seen >= since } >= @window }
      end
    end
  end
end
