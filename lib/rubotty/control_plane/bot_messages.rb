# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The record of what rubotty has posted in a room and left standing, so
    # /clean has something to delete. Only the permanent posts: a self-deleting
    # one already carries a pending-deletion row and reaps itself.
    #
    # This is the ONLY way back to those messages on Telegram, whose Bot API
    # lets a bot read no history at all, so a failed write here is a message
    # nothing can remove afterwards. It is still never raised: losing the row
    # must not cost the post it was about.
    class BotMessages
      # How long a row is kept. Long, because the whole point is reaching a
      # message somebody only notices months later; the table takes a handful
      # of rows per room per week, so age is what bounds it rather than size.
      RETENTION = 365 * 24 * 60 * 60

      PRUNE_KIND = "bot_messages_prune"
      PRUNE_INTERVAL = 24 * 60 * 60

      Entry = Struct.new(:id, :room_key, :endpoint_id, :native_id, :kind, keyword_init: true)

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Write down one posted copy. Idempotent on (endpoint, native id), so a
      # resend that lands on an id already recorded updates rather than
      # duplicating.
      def record(community_id:, room_key:, endpoint_id:, native_id:, kind: nil)
        return nil if community_id.nil? || native_id.to_s.empty? || room_key.to_s.empty?

        row = scope_for(endpoint_id, native_id).first
        return row.update(posted_at: @clock.call) if row

        @models.bot_message.create(
          community_id: community_id, room_key: room_key.to_s[0, 128],
          endpoint_id: endpoint_id.to_s[0, 255], native_id: native_id.to_s[0, 255],
          kind: kind.to_s[0, 64], posted_at: @clock.call
        )
      rescue StandardError => e
        @logger&.warn { "bot messages: could not record #{endpoint_id}/#{native_id}: #{e.class}: #{e.message}" }
        nil
      end

      # What is still standing in one room, oldest first.
      def for_room(community_id:, room_key:)
        return [] if community_id.nil?

        rows = @models.bot_message.where(community_id: community_id, room_key: room_key.to_s).order(:id)
        rows.all.map { |row| entry_for(row) }
      rescue StandardError => e
        @logger&.warn { "bot messages: could not read #{room_key}: #{e.class}: #{e.message}" }
        []
      end

      # Drop one row, once its message has been deleted or found already gone.
      def forget(endpoint_id:, native_id:)
        scope_for(endpoint_id, native_id).delete.to_i
      rescue StandardError => e
        @logger&.warn { "bot messages: could not forget #{endpoint_id}/#{native_id}: #{e.message}" }
        0
      end

      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - RETENTION
        @models.bot_message.where { posted_at <= cutoff }.delete.to_i
      rescue StandardError => e
        @logger&.warn { "bot messages: could not prune: #{e.message}" }
        0
      end

      private

      def scope_for(endpoint_id, native_id)
        @models.bot_message.where(endpoint_id: endpoint_id.to_s, native_id: native_id.to_s)
      end

      def entry_for(row)
        Entry.new(id: row.id, room_key: row.room_key, endpoint_id: row.endpoint_id,
                  native_id: row.native_id, kind: row.kind)
      end
    end
  end
end
