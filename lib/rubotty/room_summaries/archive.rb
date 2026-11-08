# frozen_string_literal: true

module Rubotty
  module RoomSummaries
    # The pending input for a room summary. Rows are removed immediately after
    # their summary is posted, leaving the watermark as the durable boundary.
    class Archive
      Entry = Struct.new(:id, :endpoint_id, :native_id, :author_label, :body, :created_at,
                         keyword_init: true)

      # A hard backstop, independent of whether a summary ever succeeds. Without
      # this, a room stuck failing its summary run (a downed model server, a bad
      # config) retains raw message bodies indefinitely: {#complete} is the only
      # other deletion path, and it only runs after a success.
      RETENTION = 30 * 24 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      def record(community_id:, room_key:, message:)
        return nil if community_id.nil? || blank?(room_key) || message.synthetic? || message.empty?
        return nil if message.author&.bot?

        @models.room_summary_message.create(
          community_id: community_id,
          room_key: room_key.to_s[0, 128],
          endpoint_id: message.origin.id.to_s[0, 255],
          native_id: message.ref.native_id.to_s[0, 255],
          author_label: message.author&.any_name.to_s[0, 200],
          body: message.body.text.to_s,
          created_at: @clock.call
        )
      rescue StandardError => e
        @logger&.warn { "room summaries: could not retain #{message.ref}: #{e.class}: #{e.message}" }
        nil
      end

      def pending?(community_id:, room_key:, since: nil)
        messages(community_id: community_id, room_key: room_key, since: since, limit: 1).any?
      end

      # A plain count, for the count-mode trigger: cheaper than loading every
      # pending row just to measure how many there are.
      def pending_count(community_id:, room_key:)
        last_message_id = watermark_id(community_id, room_key)
        scoped_messages(community_id, room_key).where { id > last_message_id }.count
      end

      # +from_watermark+ false reads the window whole, ignoring the boundary a
      # posted summary left. That is what an on-demand DM wants: it consumes
      # nothing, so it must not be cut off at where the room's last posted
      # summary happened to stop, nor move that boundary for everybody else.
      def messages(community_id:, room_key:, since: nil, limit: nil, from_watermark: true)
        scope = scoped_messages(community_id, room_key)
        if from_watermark
          last_message_id = watermark_id(community_id, room_key)
          scope = scope.where { id > last_message_id }
        end
        scope = scope.where { created_at >= since } if since
        scope = scope.order(:id)
        scope = scope.limit(limit) if limit
        scope.all.map { |row| entry_for(row) }
      end

      # Move a room's watermark only after the caller has successfully posted
      # the result. Removing consumed source rows keeps the retained text bounded.
      def complete(community_id:, room_key:, last_message_id:)
        @models.db.transaction do
          row = watermark_scope(community_id, room_key).for_update.first
          last = last_message_id.to_i
          if row.nil?
            @models.room_summary_watermark.create(
              community_id: community_id, room_key: room_key.to_s[0, 128], last_message_id: last,
              completed_at: @clock.call
            )
          elsif row.last_message_id.to_i < last
            row.update(last_message_id: last, completed_at: @clock.call)
          end
          scoped_messages(community_id, room_key).where { id <= last }.delete
        end
      end

      # Whether delivery through last_message_id was already claimed by
      # #mark_posted. A retry of the same job checks this before asking
      # OpenArc or posting again, so only the interrupted step after a
      # successful post (advancing the watermark) is retried, never the post.
      def posted?(community_id:, room_key:, last_message_id:)
        watermark_scope(community_id, room_key).get(:posted_message_id).to_i >= last_message_id.to_i
      end

      # The claim itself: one row write recording that delivery through
      # last_message_id happened, kept separate from #complete's larger
      # transaction so the window a retry could still double-post through is
      # a single UPDATE rather than everything #complete does.
      def mark_posted(community_id:, room_key:, last_message_id:)
        @models.db.transaction do
          row = watermark_scope(community_id, room_key).for_update.first
          last = last_message_id.to_i
          if row.nil?
            @models.room_summary_watermark.create(
              community_id: community_id, room_key: room_key.to_s[0, 128], last_message_id: 0,
              posted_message_id: last, completed_at: @clock.call
            )
          elsif row.posted_message_id.to_i < last
            row.update(posted_message_id: last)
          end
        end
      end

      # The native id of the summary rubotty last pinned for this room on this
      # endpoint, or nil if it has never pinned one there. Never a read of what
      # is CURRENTLY pinned: no adapter exposes that, so this is the only
      # record of rubotty's own last pin.
      def pinned_native_id(community_id:, room_key:, endpoint_id:)
        pin_scope(community_id, room_key, endpoint_id).get(:native_id)
      end

      # Remember the summary just pinned, replacing whatever this room/endpoint
      # had tracked before.
      def track_pin(community_id:, room_key:, endpoint_id:, native_id:)
        scope = pin_scope(community_id, room_key, endpoint_id)
        row = scope.first
        if row.nil?
          @models.room_summary_pin.create(
            community_id: community_id, room_key: room_key.to_s[0, 128], endpoint_id: endpoint_id.to_s[0, 255],
            native_id: native_id.to_s[0, 255], updated_at: @clock.call
          )
        else
          row.update(native_id: native_id.to_s[0, 255], updated_at: @clock.call)
        end
      end

      # Drop pending rows past {RETENTION} regardless of summary success, so a
      # persistently failing room does not keep plaintext message bodies forever.
      #
      # @return [Integer] rows removed
      def prune(now: @clock.call)
        cutoff = now - RETENTION
        @models.room_summary_message.where { created_at <= cutoff }.delete.to_i
      end

      private

      def pin_scope(community_id, room_key, endpoint_id)
        @models.room_summary_pin.where(
          community_id: community_id, room_key: room_key.to_s, endpoint_id: endpoint_id.to_s
        )
      end

      def scoped_messages(community_id, room_key)
        @models.room_summary_message.where(community_id: community_id, room_key: room_key.to_s)
      end

      def watermark_scope(community_id, room_key)
        @models.room_summary_watermark.where(community_id: community_id, room_key: room_key.to_s)
      end

      def watermark_id(community_id, room_key)
        watermark_scope(community_id, room_key).get(:last_message_id).to_i
      end

      def entry_for(row)
        Entry.new(
          id: row.id, endpoint_id: row.endpoint_id, native_id: row.native_id,
          author_label: row.author_label.to_s, body: row.body.to_s, created_at: row.created_at
        )
      end

      def blank?(value) = value.to_s.strip.empty?
    end
  end
end
