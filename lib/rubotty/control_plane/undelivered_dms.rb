# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # DMs the bot meant to send a member and could not, kept until it can.
    # Telegram refuses to let a bot open a conversation, so a warning issued to
    # somebody who has never written in reaches nobody, and the text was lost
    # with only an audit line to say it existed. Handed over the moment they
    # first write to the bot. Every row carries its own expiry, taken from the
    # thing it is about, so a notice about a warning that has since decayed is
    # dropped rather than delivered late.
    class UndeliveredDms
      # How many a single first contact will send, newest last. A member coming
      # back to a long history gets the recent ones rather than a wall.
      FLUSH_LIMIT = 5

      # Nothing is kept longer than this however long its subject lives, so a
      # forgotten row cannot outlive the retention the community was promised.
      MAX_RETENTION_DAYS = 90

      PRUNE_KIND = "undelivered_dms_prune"
      PRUNE_INTERVAL = 6 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Keep one undelivered DM. Answers the row, or nil when it could not be
      # kept: the send has already failed by the time this runs, and a
      # bookkeeping failure must not raise into the caller on top of that.
      #
      # @param expires_at [Time] when the thing this is about lapses
      def retain(community_id:, adapter:, account:, native_id:, body:, event:, expires_at:, display: nil)
        return nil if community_id.nil? || native_id.to_s.empty? || body.to_s.empty?

        @models.undelivered_dm.create(
          community_id: community_id, adapter: adapter.to_s, account: account.to_s,
          native_id: native_id.to_s, display: display&.to_s, event: event.to_s, body: body.to_s,
          expires_at: capped(expires_at), created_at: @clock.call
        )
      rescue StandardError => e
        @logger&.warn { "undelivered dms: could not keep the #{event} DM for #{native_id}: #{e.message}" }
        nil
      end

      # What is still owed to one person on one connection, oldest first and
      # bounded. An expired row is left for the prune rather than delivered.
      def pending_for(adapter:, account:, native_id:, limit: FLUSH_LIMIT)
        return [] if native_id.to_s.empty?

        now = @clock.call
        @models.undelivered_dm
               .where(adapter: adapter.to_s, account: account.to_s,
                      native_id: native_id.to_s, delivered_at: nil)
               .where { expires_at > now }
               .order(:created_at, :id).limit(limit.to_i.clamp(1, 25)).all
      rescue StandardError => e
        @logger&.warn { "undelivered dms: could not read what is owed to #{native_id}: #{e.message}" }
        []
      end

      # Stamp one row delivered. Only ever called once a send has actually
      # landed, so a refusal leaves the row for the next time they write in.
      def delivered!(row)
        return false if row.nil?

        row.update(delivered_at: @clock.call)
        true
      rescue StandardError => e
        @logger&.warn { "undelivered dms: could not stamp #{row.id} delivered: #{e.message}" }
        false
      end

      # Drop what has been delivered or has expired undelivered. The second
      # half is the point: an undelivered notice about a lapsed warning is not
      # kept waiting for somebody who may never write in.
      def prune
        now = @clock.call
        @models.undelivered_dm.where { expires_at < now }.delete +
          @models.undelivered_dm.exclude(delivered_at: nil).delete
      rescue StandardError => e
        @logger&.warn { "undelivered dms: could not prune: #{e.message}" }
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
