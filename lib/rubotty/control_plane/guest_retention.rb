# frozen_string_literal: true

require "securerandom"

module Rubotty
  module ControlPlane
    # Reclaims a guest session's captured content once its access ends: the
    # guest portal is the only place rubotty persists message CONTENT
    # verbatim, and an invite is never deleted, so this would otherwise
    # outlive it. Room-scoped, never per invite (an "in" row carries no
    # invite_id): the feed stays as long as the room has a live invite, and
    # the last session out reclaims it. An upload's bytes live in
    # {Storage::ObjectStore}, unlinked via {GuestUploads#forget_bytes}
    # BEFORE the row deletes. Reclaimed counts are logged, never content.
    class GuestRetention
      # The durable-scheduler job kind this service registers and enqueues.
      KIND = "guest_retention"

      # Seconds kept after access expires, zero by default; an operator may
      # raise it with behaviour.guest_retention. Revocation ignores it.
      DEFAULT_GRACE = 0

      # Hard ceiling on a configured grace, clamped in the constructor so no value
      # from any source can widen the retention window.
      MAX_GRACE = 3600

      # What one reclamation removed, in row counts. The only thing ever logged.
      Reclaimed = Struct.new(:messages, :uploads, keyword_init: true) do
        def any? = messages.positive? || uploads.positive?

        def total = messages + uploads

        def +(other) = Reclaimed.new(messages: messages + other.messages, uploads: uploads + other.uploads)
      end

      # The empty result, returned whenever there was nothing to do.
      def self.nothing = Reclaimed.new(messages: 0, uploads: 0)

      # @param scheduler [Core::DurableScheduler, nil] registers {KIND} at
      #   construction, before boot recovery runs. Nil makes scheduling a no-op;
      #   revocation, sweeping and reconcile still work.
      # @param uploads [GuestUploads, nil] unlinks an upload's bytes before its row
      #   goes. Nil keeps upload metadata so deletion can be retried later.
      def initialize(models:, scheduler: nil, grace: DEFAULT_GRACE, logger: nil, clock: -> { Time.now },
                     announcer: nil, uploads: nil)
        @models = models
        @scheduler = scheduler
        @grace = [[grace.to_i, 0].max, MAX_GRACE].min
        @logger = logger
        @clock = clock
        @announcer = announcer
        @uploads = uploads
        @scheduler&.register(KIND) { |job| run(job) }
      end

      # Seconds of retention kept after access expires.
      attr_reader :grace

      # Schedule, or reschedule, reclamation of +invite+'s session at its expiry.
      # Cancels this invite's own pending job first, so a lifetime change leaves no
      # stale job that would reclaim a live session early.
      def schedule_for(invite)
        return nil if @scheduler.nil? || invite.nil?

        cancel_for(invite)
        @scheduler.schedule(kind: KIND, run_at: reclaim_at(invite), payload: { "invite_id" => invite.id })
      end

      # Cancel +invite+'s pending reclamation job, and only that invite's. Returns
      # how many were cancelled.
      def cancel_for(invite)
        return 0 if @scheduler.nil? || invite.nil?

        @scheduler.cancel(kind: KIND, every_community: true) { |payload| payload["invite_id"] == invite.id }
      end

      # When +invite+'s content becomes reclaimable: hard expiry plus the grace.
      def reclaim_at(invite) = to_time(invite.expires_at) + @grace

      # Reclaim +invite+'s session content now: the revocation path, where the grace
      # does not apply, and the body of the scheduled job. An invite with no room
      # can only account for its own out rows, so the sweep takes the rest.
      #
      # @return [Reclaimed] row counts
      def reclaim_for(invite, now: @clock.call, reason: "session ended")
        return self.class.nothing if invite.nil?

        cancel_for(invite)
        # A revoke can race a job the scheduler already claimed before revoke landed:
        # cancel_for cannot touch a claimed job, and the job's own revoked_at check
        # runs too late to stop it. This is the actual guard against reclaiming (and
        # announcing) the same invite's departure twice.
        return self.class.nothing unless claim!(invite, now)

        reclaimed = if invite.room_id.nil?
                      Reclaimed.new(messages: guest_messages.where(invite_id: invite.id).delete.to_i, uploads: 0)
                    else
                      reclaim_room(invite.room_id, now: now)
                    end
        log(reclaimed, "invite=#{invite.id} reason=#{reason}")
        # Not gated on +reclaimed.any?+: a room with another live guest reclaims
        # nothing, but this invite's access still ended and members deserve to know.
        @announcer&.announce_departure(invite, reason: reason)
        reclaimed
      end

      # Reclaim a room's whole guest feed and uploads, unless the room still has a
      # live invite. Public because {GuestInvites#issue} calls it before minting a
      # fresh invite, so a new session starts on a clean feed.
      #
      # @return [Reclaimed] row counts
      def reclaim_room(room_id, now: @clock.call)
        return self.class.nothing if room_id.nil? || live_on_room?(room_id, now)

        Reclaimed.new(
          messages: guest_messages.where(room_id: room_id).delete.to_i,
          uploads: reclaim_uploads(guest_uploads.where(room_id: room_id))
        )
      end

      # The hard upper bound: reclaim every guest feed row and upload whose room has
      # no live invite and which is older than the grace, whatever invite wrote it
      # and whether or not its job ever fired.
      #
      # Not its own poll loop: it runs from Runtime#start_purge_thread's existing
      # tick and from {#reconcile} at boot.
      #
      # @return [Reclaimed] row counts
      def sweep(now: @clock.call)
        cutoff = now - @grace
        live = live_room_ids(now)
        reclaimed = Reclaimed.new(
          messages: stale(guest_messages.dataset, live, cutoff).delete.to_i,
          uploads: reclaim_uploads(stale(guest_uploads.dataset, live, cutoff))
        )
        @uploads&.sweep_orphans(now: now)
        log(reclaimed, "periodic sweep")
        reclaimed
      end

      # The boot pass: sweep everything already ended, including sessions that ended
      # while the process was down, then re-arm a job per live invite. The re-arm is
      # clear-and-recreate, so a boot leaves exactly one pending job per invite.
      #
      # @return [Reclaimed] what the sweep removed
      def reconcile(now: @clock.call)
        reclaimed = sweep(now: now)
        rearm(now: now)
        reclaimed
      end

      # Clear every pending reclamation job and schedule a fresh one per live
      # invite. Returns how many were scheduled.
      def rearm(now: @clock.call)
        return 0 if @scheduler.nil?

        @scheduler.forget(kind: KIND, every_community: true)
        live_invites(now).count do |invite|
          @scheduler.schedule(kind: KIND, run_at: reclaim_at(invite), payload: { "invite_id" => invite.id })
          true
        end
      end

      # Whether a room currently has a live invite: issued, unrevoked, unexpired.
      # Gated in SQL, so "now" is compared against the stored expiry in the
      # database's own zone on every backend.
      def live_on_room?(room_id, now = @clock.call)
        return false if room_id.nil?

        @models.guest_invite.where(room_id: room_id, revoked_at: nil)
               .where { expires_at > now }.count.positive?
      end

      private

      def guest_messages = @models.guest_message

      def guest_uploads = @models.guest_upload

      # Whether THIS call is the one that gets to reclaim +invite+: conditional
      # at the DB layer (WHERE reclaimed_at IS NULL), so two calls racing on the
      # same never-reclaimed invite cannot both win.
      def claim!(invite, now)
        @models.guest_invite.where(id: invite.id, reclaimed_at: nil).update(reclaimed_at: now).positive?
      end

      # Reclaim a set of upload rows and the object each one names. The rows are
      # read first because the object keys are the only way back to the bytes, and
      # the delete is by id list so only rows whose bytes went are the rows that go.
      #
      # @return [Integer] rows removed
      def reclaim_uploads(dataset)
        rows = dataset.all
        return 0 if rows.empty?

        removed = rows.filter_map do |row|
          if @uploads&.forget_bytes(row, missing_ok: true)
            row.id
          else
            # The public link expires even while its blob awaits another unlink.
            row.update(token_hash: SecureRandom.hex(32))
            nil
          end
        end
        removed.empty? ? 0 : guest_uploads.where(id: removed).delete.to_i
      end

      # Every live invite, for the boot re-arm.
      def live_invites(now)
        @models.guest_invite.where(revoked_at: nil).where { expires_at > now }.all
      end

      # The rooms with at least one live invite. Everything else is reclaimable.
      def live_room_ids(now)
        @models.guest_invite.where(revoked_at: nil).where { expires_at > now }
               .exclude(room_id: nil).select_map(:room_id).uniq
      end

      # Rows old enough to reclaim whose room has no live guest. Spelled "IS NULL OR
      # NOT IN (...)" because SQL's NOT IN is UNKNOWN for a NULL room_id, so a bare
      # exclude would spare exactly the orphaned rows that most need reclaiming.
      def stale(dataset, live_room_ids, cutoff)
        scope = dataset.where { created_at <= cutoff }
        return scope if live_room_ids.empty?

        scope.where(::Sequel.|({ room_id: nil }, ::Sequel.~(room_id: live_room_ids)))
      end

      # The durable-scheduler handler. Reloads the invite by id, because whether the
      # row still exists and whether its lifetime moved are what a payload snapshot
      # could not say.
      def run(job)
        invite_id = (job.payload || {})["invite_id"]
        invite = invite_id && @models.guest_invite[invite_id.to_i]
        # The invite row is gone, so its cascade already removed these rows.
        return if invite.nil?

        now = @clock.call
        # The lifetime was extended past this job's run_at without the reschedule
        # landing. Re-arm at the new expiry rather than reclaiming a live session.
        if to_time(invite.expires_at) + @grace > now && invite.revoked_at.nil?
          schedule_for(invite)
          return
        end

        reclaim_for(invite, now: now, reason: "access expired")
      end

      # Counts only. A body, author label or filename must never reach a log line.
      def log(reclaimed, context)
        return unless reclaimed.any?

        @logger&.info do
          "guest retention reclaimed #{reclaimed.messages} feed row(s) and " \
            "#{reclaimed.uploads} upload(s): #{context}"
        end
      end

      # Sequel returns DateTime or Time for a timestamp column depending on the
      # backend; normalise so the arithmetic is backend-independent.
      def to_time(value)
        return value if value.is_a?(Time)

        value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
      end
    end
  end
end
