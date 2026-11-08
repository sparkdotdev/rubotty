# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The seconds-long buffer behind the REST API's live stream. This must
    # never become a message archive: {#record} prunes anything past
    # {TTL_SECONDS}, and {#since} also refuses to return a row past
    # {TTL_SECONDS} regardless of whether a prune has run. A message written
    # while nobody is subscribed is gone once it ages out; that is intended,
    # not a bug to fix.
    class LiveRoomFeed
      # How long a buffered row is readable, and how far back {#prune} keeps. Long
      # enough that a subscriber polling on {Api::App::SSE_INTERVAL} never misses a
      # message, short enough that nothing can be found here later.
      TTL_SECONDS = 15

      # The shortest gap between two prunes on the write path. Without it a busy
      # room would run a delete for every relayed message.
      PRUNE_INTERVAL = 2

      # A buffered row projected for a reader, decoupled from the Sequel model so
      # the API never has to know the column layout.
      Entry = Struct.new(:id, :origin_key, :author_label, :body, :kind, :created_at,
                         keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, clock: -> { Time.now })
        @models = models
        @clock = clock
        @pruned_at = nil
        @prune_mutex = Mutex.new
      end

      # Buffer one message for a room, on the relay's hot path: one insert and (at
      # most every {PRUNE_INTERVAL}) one ranged delete. Never raises, so a failed
      # buffer write cannot cost the room its actual relay.
      #
      # @param room_key [String] the Core::Room id, which IS the room_key
      # @return [Models::LiveRoomMessage, nil] nil when the write failed
      def record(community_id:, room_key:, body:, origin_key: nil, author_label: nil, kind: "chat")
        now = @clock.call
        row = @models.live_room_message.create(
          community_id: community_id,
          room_key: room_key.to_s[0, 128],
          origin_key: origin_key&.to_s&.slice(0, 200),
          author_label: author_label&.to_s&.slice(0, 200),
          body: body.to_s,
          kind: kind.to_s[0, 16],
          created_at: now
        )
        prune_if_due(now)
        row
      rescue StandardError
        nil
      end

      # Everything buffered for one room with an id above +since+, oldest first.
      #
      # The community is part of the query, so a caller cannot read another
      # community's room by naming a room_key it happens to share: room_key is
      # unique only WITHIN a community.
      #
      # @return [Array<Entry>]
      def since(community_id:, room_key:, since: 0, limit: 200)
        floor = since.to_i
        cutoff = @clock.call - TTL_SECONDS
        rows = scope(community_id, room_key)
               .where { id > floor }
               .where { created_at > cutoff }
               .order(:id)
               .limit(limit)
               .all
        rows.map { |row| entry_for(row) }
      end

      # The highest buffered id for a room, or 0 when nothing is buffered. A stream
      # opens here rather than at 0 so a fresh subscriber starts with what happens
      # NEXT.
      def latest_id(community_id:, room_key:)
        scope(community_id, room_key).max(:id).to_i
      end

      # Drop everything past the TTL, everywhere. About the bytes on disk rather
      # than about access: {#since} already refuses these rows.
      #
      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - TTL_SECONDS
        @models.live_room_message.where { created_at <= cutoff }.delete.to_i
      end

      private

      def scope(community_id, room_key)
        @models.live_room_message.where(community_id: community_id, room_key: room_key.to_s)
      end

      # Prune at most once per {PRUNE_INTERVAL}, and never let a prune failure
      # reach the relay: the row is already written and the next pass tries again.
      def prune_if_due(now)
        due = @prune_mutex.synchronize do
          next false if @pruned_at && (now - @pruned_at) < PRUNE_INTERVAL

          @pruned_at = now
          true
        end
        prune(now: now) if due
      rescue StandardError
        nil
      end

      def entry_for(row)
        Entry.new(
          id: row.id, origin_key: row.origin_key, author_label: row.author_label,
          body: row.body.to_s, kind: row.kind, created_at: row.created_at
        )
      end
    end
  end
end
