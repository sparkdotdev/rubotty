# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Pairs the in-room notice a warning posted with the message that warning
    # was about, so removing the message through the bot takes the notice with
    # it rather than leaving it standing over a blank space.
    #
    # Only bot-mediated removals reach this. A platform that never tells a bot
    # about a deletion made in its own client cannot, which is why the pairing
    # lives here rather than being inferred later from the room.
    class WarningAnnouncements
      # Nothing is kept beyond this whatever a warning's own decay says, so a
      # forgotten row cannot outlive the retention the community was promised.
      MAX_RETENTION_DAYS = 90

      PRUNE_KIND = "warning_announcements_prune"
      PRUNE_INTERVAL = 6 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Pair one notice with the message it is about. Answers nil rather than
      # raising: the notice is already posted by the time this runs, and losing
      # the pairing costs a retraction, never the warning itself.
      def record(community_id:, adapter:, endpoint_id:, native_id:, notice_endpoint_id:,
                 notice_native_id:, expires_at: nil)
        return nil if community_id.nil? || native_id.to_s.empty? || notice_native_id.to_s.empty?

        @models.warning_announcement.create(
          community_id: community_id, adapter: adapter.to_s, endpoint_id: endpoint_id.to_s,
          native_id: native_id.to_s, notice_endpoint_id: notice_endpoint_id.to_s,
          notice_native_id: notice_native_id.to_s,
          expires_at: capped(expires_at), created_at: @clock.call
        )
      rescue StandardError => e
        @logger&.warn { "warning announcements: could not pair the notice for #{native_id}: #{e.message}" }
        nil
      end

      # The notices paired with one message. Plural because a room can carry
      # more than one warning about the same message over its life.
      def for_message(endpoint_id:, native_id:)
        return [] if native_id.to_s.empty?

        @models.warning_announcement
               .where(endpoint_id: endpoint_id.to_s, native_id: native_id.to_s)
               .order(:id).all
      rescue StandardError => e
        @logger&.warn { "warning announcements: could not read the pairing for #{native_id}: #{e.message}" }
        []
      end

      # Drop one pairing, once its notice has been retracted or found gone.
      def forget(row)
        return false if row.nil?

        row.delete
        true
      rescue StandardError => e
        @logger&.warn { "warning announcements: could not forget #{row.id}: #{e.message}" }
        false
      end

      def prune
        now = @clock.call
        @models.warning_announcement.where { expires_at < now }.delete
      rescue StandardError => e
        @logger&.warn { "warning announcements: could not prune: #{e.message}" }
        0
      end

      private

      def capped(expires_at)
        ceiling = @clock.call + (MAX_RETENTION_DAYS * 86_400)
        given = expires_at.is_a?(Time) ? expires_at : ceiling
        given > ceiling ? ceiling : given
      end
    end
  end
end
