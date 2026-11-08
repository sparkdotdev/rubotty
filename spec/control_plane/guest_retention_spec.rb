# frozen_string_literal: true

require "spec_helper"
require "stringio"

# A guest_messages row of direction "in" is a member's message captured
# verbatim, so it must not outlive the guest session that justified capturing
# it. Every path that ends a session is covered here.
RSpec.describe Rubotty::ControlPlane::GuestRetention, :control_plane do
  around do |example|
    with_object_store_root do |root|
      @root = root
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }
  let(:other_room) { models.room.where(community_id: community.id, room_key: "gaming").first }

  # A fixed local time with no fractional seconds. SQLite stores a naive
  # timestamp in this zone, so it round-trips to the same instant.
  let(:start) { Time.at(Time.new(2026, 7, 24, 12, 0, 0).to_i) }
  let(:clock) { -> { @now } }

  # Never #start-ed: the specs drive #run_due by hand with the fake clock.
  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(
      store: Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db),
      session_id: "spec", clock: clock
    )
  end

  subject(:retention) do
    described_class.new(models: models, scheduler: scheduler, clock: clock, uploads: uploads)
  end

  let(:feed) { Rubotty::ControlPlane::GuestFeed.new(models: models, clock: clock) }
  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:uploads) do
    Rubotty::ControlPlane::GuestUploads.new(models: models, store: store, clock: clock)
  end
  let(:invites) do
    Rubotty::ControlPlane::GuestInvites.new(models: models, clock: clock, retention: retention)
  end

  before do
    @now = start
    controls = Rubotty::ControlPlane::FeatureControls.new(models: models)
    %w[general gaming].each do |selector|
      controls.enable(community: community, selector: selector, feature: "guest_portal")
    end
    # Built lazily, so force it to get KIND registered before any recovery.
    retention
  end

  def issue!(nickname: "Sam", ttl: 3600, target: room)
    invites.issue(community: community, room: target, nickname: nickname, ttl_seconds: ttl).invite
  end

  def capture_member_message!(target: room, body: "a member said this")
    feed.record_in(community_id: community.id, room_id: target.id,
                   author_label: "Ada@discord", body: body)
  end

  def guest_sends!(invite, body: "hello from the guest")
    feed.record_out(invite: invite, body: body)
  end

  def message_count(target: room) = models.guest_message.where(room_id: target.id).count

  def upload_count(target: room) = models.guest_upload.where(room_id: target.id).count

  def upload!(invite, bytes: "PNGDATA", filename: "photo.png", content_type: "image/png")
    uploads.store_file(invite: invite, source: StringIO.new(bytes), filename: filename,
                       content_type: content_type)
  end

  # Every sealed object on disk, so a spec can tell files from rows.
  def stored_object_count = stored_objects(@root, "guest-upload").size

  def advance_to(time)
    @now = time
  end

  describe "the scheduled job at expiry" do
    it "deletes both directions of the feed and the uploads when the invite expires" do
      invite = issue!(ttl: 3600)
      capture_member_message!
      guest_sends!(invite)
      upload!(invite)
      expect(message_count).to eq(2)
      expect(upload_count).to eq(1)

      advance_to(start + 3601)
      expect(scheduler.run_due).to eq(1)

      expect(message_count).to eq(0)
      expect(upload_count).to eq(0)
    end

    it "schedules exactly one job, at the invite's expiry, when the invite is issued" do
      issue!(ttl: 3600)
      pending_jobs = db[:scheduled_jobs].where(kind: described_class::KIND, status: "pending").all
      expect(pending_jobs.length).to eq(1)
      expect(pending_jobs.first[:run_at].to_time).to eq(start + 3600)
    end

    it "does not fire before the invite expires" do
      issue!(ttl: 3600)
      capture_member_message!

      advance_to(start + 3599)
      expect(scheduler.run_due).to eq(0)
      expect(message_count).to eq(1)
    end

    it "leaves the feed alone when the invite row itself is already gone" do
      invite = issue!(ttl: 3600)
      capture_member_message!
      # A missing invite means done, not a failure to retry.
      models.guest_invite.where(id: invite.id).delete

      advance_to(start + 3601)
      expect { scheduler.run_due }.not_to raise_error
      expect(db[:scheduled_jobs].where(kind: described_class::KIND, status: "failed").count).to eq(0)
    end
  end

  describe "revocation" do
    it "deletes immediately rather than waiting for the original expiry" do
      invite = issue!(ttl: 86_400)
      capture_member_message!
      upload!(invite, bytes: "a", filename: "a.txt", content_type: "text/plain")

      invites.revoke(invite: invite)

      expect(message_count).to eq(0)
      expect(upload_count).to eq(0)
    end

    it "cancels the pending expiry job, which no longer means anything" do
      invite = issue!(ttl: 86_400)
      invites.revoke(invite: invite)

      expect(db[:scheduled_jobs].where(kind: described_class::KIND, status: "pending").count).to eq(0)
    end

    it "reclaims immediately even when a retention grace is configured" do
      graced = described_class.new(models: models, scheduler: scheduler, grace: 604_800, clock: clock)
      graced_invites = Rubotty::ControlPlane::GuestInvites.new(
        models: models, clock: clock, retention: graced
      )
      invite = graced_invites.issue(community: community, room: room, nickname: "Sam",
                                    ttl_seconds: 3600).invite
      capture_member_message!

      graced_invites.revoke(invite: invite)

      expect(message_count).to eq(0)
    end
  end

  # The notice fires from #reclaim_for, where revoke and expiry converge.
  describe "the departure announcement" do
    let(:announcer) { instance_double(Rubotty::ControlPlane::GuestAnnouncer) }
    let(:announced_retention) do
      Rubotty::ControlPlane::GuestRetention.new(
        models: models, scheduler: scheduler, clock: clock, announcer: announcer
      )
    end
    let(:announced_invites) do
      Rubotty::ControlPlane::GuestInvites.new(models: models, clock: clock, retention: announced_retention)
    end

    it "announces once when an invite is revoked" do
      invite = announced_invites.issue(community: community, room: room, nickname: "Sam",
                                       ttl_seconds: 3600).invite

      expect(announcer).to receive(:announce_departure).with(invite, reason: "invite revoked").once
      announced_invites.revoke(invite: invite)
      announced_invites.revoke(invite: invite.refresh) # idempotent: no second announcement
    end

    it "announces once when the scheduled expiry job fires" do
      invite = announced_invites.issue(community: community, room: room, nickname: "Sam",
                                       ttl_seconds: 3600).invite

      expect(announcer).to receive(:announce_departure).with(invite, reason: "access expired").once
      advance_to(start + 3601)
      scheduler.run_due
    end

    it "still announces a guest's own departure even while a second guest keeps the room's feed" do
      sam = announced_invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600).invite
      announced_invites.issue(community: community, room: room, nickname: "Kim", ttl_seconds: 86_400)

      expect(announcer).to receive(:announce_departure).with(sam, reason: "access expired").once
      advance_to(start + 3601)
      scheduler.run_due
    end

    # An operator revokes right as the durable scheduler has already claimed
    # (but not finished) that invite's own expiry job. cancel_for cannot touch
    # a claimed job, and the job's revoked_at check runs too late, so it falls
    # through into a second #reclaim_for. Only the first is allowed to announce.
    it "announces only once when a revoke races an already-claimed expiry job" do
      invite = announced_invites.issue(community: community, room: room, nickname: "Sam",
                                       ttl_seconds: 3600).invite

      expect(announcer).to receive(:announce_departure).with(invite, reason: "invite revoked").once

      announced_retention.reclaim_for(invite, reason: "invite revoked")
      announced_retention.reclaim_for(invite.refresh, reason: "access expired")
    end
  end

  describe "a live session" do
    it "keeps the feed and the uploads of an invite that has not ended" do
      invite = issue!(ttl: 3600)
      capture_member_message!
      upload!(invite, bytes: "a", filename: "a.txt", content_type: "text/plain")

      advance_to(start + 60)
      retention.sweep
      retention.reconcile

      expect(message_count).to eq(1)
      expect(upload_count).to eq(1)
    end

    it "keeps a room's feed while a SECOND guest is still live there" do
      first = issue!(nickname: "Sam", ttl: 3600)
      issue!(nickname: "Kim", ttl: 86_400)
      capture_member_message!

      advance_to(start + 3601)
      scheduler.run_due

      # Still serving Kim, so it stays until the last session out reclaims it.
      expect(message_count).to eq(1)
      expect(first.reload.expires_at.to_time).to eq(start + 3600)
    end

    it "reclaims the room once the LAST live invite has also ended" do
      issue!(nickname: "Sam", ttl: 3600)
      issue!(nickname: "Kim", ttl: 7200)
      capture_member_message!

      advance_to(start + 7201)
      scheduler.run_due

      expect(message_count).to eq(0)
    end

    it "never touches another room's feed" do
      issue!(ttl: 3600, target: room)
      issue!(ttl: 86_400, target: other_room)
      capture_member_message!(target: room)
      capture_member_message!(target: other_room)

      advance_to(start + 3601)
      scheduler.run_due

      expect(message_count(target: room)).to eq(0)
      expect(message_count(target: other_room)).to eq(1)
    end
  end

  describe "extending a lifetime" do
    it "reschedules rather than reclaiming at the original expiry" do
      invite = issue!(ttl: 3600)
      capture_member_message!

      advance_to(start + 3000)
      invites.extend_lifetime(invite: invite, ttl_seconds: 7200)

      advance_to(start + 3601)
      expect(scheduler.run_due).to eq(0)
      expect(message_count).to eq(1)

      advance_to(start + 10_201)
      expect(scheduler.run_due).to eq(1)
      expect(message_count).to eq(0)
    end

    it "leaves exactly one pending job behind, at the new expiry" do
      invite = issue!(ttl: 3600)
      advance_to(start + 60)
      invites.extend_lifetime(invite: invite, ttl_seconds: 7200)

      pending_jobs = db[:scheduled_jobs].where(kind: described_class::KIND, status: "pending").all
      expect(pending_jobs.length).to eq(1)
      expect(pending_jobs.first[:run_at].to_time).to eq(start + 60 + 7200)
    end

    it "does not delete a live session even if a stale job somehow fires" do
      invite = issue!(ttl: 3600)
      capture_member_message!
      # Move the expiry without rescheduling, the shape of a lost reschedule.
      invite.update(expires_at: start + 86_400)

      advance_to(start + 3601)
      scheduler.run_due

      expect(message_count).to eq(1)
      # It re-armed itself at the new expiry rather than leaving nothing.
      expect(db[:scheduled_jobs].where(kind: described_class::KIND, status: "pending").count).to eq(1)
    end
  end

  describe "the boot reconcile" do
    it "clears a session that ended while the process was down" do
      invite = issue!(ttl: 3600)
      capture_member_message!
      upload!(invite, bytes: "a", filename: "a.txt", content_type: "text/plain")
      # The process dies, taking its pending job with it.
      db[:scheduled_jobs].delete

      advance_to(start + 7200)
      reclaimed = retention.reconcile

      expect(message_count).to eq(0)
      expect(upload_count).to eq(0)
      expect(reclaimed.messages).to eq(1)
      expect(reclaimed.uploads).to eq(1)
    end

    it "clears rows predating this change, which have no invite and no job at all" do
      # What an upgraded database looks like: content, a long-expired invite
      # that was never deleted, nothing scheduled.
      models.guest_invite.create(
        community_id: community.id, room_id: room.id, nickname: "Old",
        token_hash: "a" * 64, expires_at: start - 86_400,
        created_at: start - 172_800, updated_at: start - 172_800
      )
      capture_member_message!
      capture_member_message!(body: "and another")
      db[:scheduled_jobs].delete

      retention.reconcile

      expect(message_count).to eq(0)
    end

    it "clears orphaned rows whose room_id was never resolved" do
      # Migration 016 left room_id nil where it could not resolve a channel's
      # room. A bare NOT IN would spare such a row, since NOT IN evaluates to
      # UNKNOWN rather than true for a NULL.
      issue!(ttl: 3600)
      models.guest_message.create(
        community_id: community.id, room_id: nil, direction: "in",
        author_label: "Ada@discord", body: "orphaned member message",
        attachments: "[]", kind: "chat", created_at: start
      )

      retention.reconcile

      expect(models.guest_message.where(room_id: nil).count).to eq(0)
      expect(models.guest_invite.count).to eq(1)
    end

    it "re-arms exactly one job per live invite and none for the ended ones" do
      issue!(nickname: "Sam", ttl: 3600)
      issue!(nickname: "Kim", ttl: 7200, target: other_room)
      ended = issue!(nickname: "Gone", ttl: 60, target: other_room)
      advance_to(start + 61)
      db[:scheduled_jobs].delete

      retention.reconcile

      pending_jobs = db[:scheduled_jobs].where(kind: described_class::KIND, status: "pending").all
      expect(pending_jobs.length).to eq(2)
      expect(ended.reload).not_to be_nil
    end

    it "is idempotent: a second reconcile finds nothing and re-arms the same jobs" do
      issue!(ttl: 3600)
      capture_member_message!

      retention.reconcile
      second = retention.reconcile

      expect(second.total).to eq(0)
      expect(db[:scheduled_jobs].where(kind: described_class::KIND, status: "pending").count).to eq(1)
    end
  end

  describe "the hard-bound sweep" do
    it "reclaims a session whose job never fired" do
      invite = issue!(ttl: 3600)
      capture_member_message!
      upload!(invite, bytes: "a", filename: "a.txt", content_type: "text/plain")
      # The job is lost, out of retries or never written at all.
      db[:scheduled_jobs].delete

      advance_to(start + 3601)
      reclaimed = retention.sweep

      expect(message_count).to eq(0)
      expect(upload_count).to eq(0)
      expect(reclaimed.messages).to eq(1)
      expect(reclaimed.uploads).to eq(1)
    end

    it "reclaims content left by an invite that was revoked without the service wired in" do
      invite = issue!(ttl: 86_400)
      capture_member_message!
      # A revocation written straight to the row, the way older surfaces did it.
      invite.update(revoked_at: start + 10)
      db[:scheduled_jobs].delete

      advance_to(start + 20)
      retention.sweep

      expect(message_count).to eq(0)
    end

    it "honours a configured retention grace on both the job and the sweep" do
      # The sweep's cutoff is content age (now minus grace), not expires_at
      # plus grace, so ttl stays small enough to sit inside the window.
      ttl = 60
      grace = 1800
      graced = described_class.new(models: models, scheduler: scheduler, grace: grace, clock: clock)
      graced_invites = Rubotty::ControlPlane::GuestInvites.new(
        models: models, clock: clock, retention: graced
      )
      graced_invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: ttl)
      capture_member_message!

      # Past expiry but inside the grace, so both mechanisms keep it.
      advance_to(start + ttl + 1)
      expect(scheduler.run_due).to eq(0)
      graced.sweep
      expect(message_count).to eq(1)

      advance_to(start + ttl + grace + 1)
      expect(scheduler.run_due).to eq(1)
      expect(message_count).to eq(0)
    end

    # Content never outlives a session by more than MAX_GRACE.
    it "clamps a configured grace above MAX_GRACE, rather than honouring it" do
      over_cap = described_class::MAX_GRACE + 604_800
      capped = described_class.new(models: models, scheduler: scheduler, grace: over_cap, clock: clock)

      expect(capped.grace).to eq(described_class::MAX_GRACE)
    end
  end

  describe "issuing a fresh invite" do
    it "does not let a new session inherit the previous session's captured content" do
      issue!(nickname: "Sam", ttl: 60)
      capture_member_message!
      advance_to(start + 61)
      db[:scheduled_jobs].delete

      # Sam's session ended without its job running. Kim's arrival must not
      # extend the life of what Sam's session captured.
      issue!(nickname: "Kim", ttl: 3600)

      expect(message_count).to eq(0)
    end

    it "leaves a live guest's feed alone when a second guest joins the same room" do
      first = issue!(nickname: "Sam", ttl: 3600)
      capture_member_message!
      guest_sends!(first)

      issue!(nickname: "Kim", ttl: 3600)

      expect(message_count).to eq(2)
    end
  end

  # An upload's bytes live on the object store, so deleting rows is not enough.
  describe "uploads on disk" do
    it "retains a failed deletion row and retries after the filesystem recovers" do
      invite = issue!(ttl: 3600)
      stored = upload!(invite, bytes: "first")
      upload!(invite, bytes: "second")
      first = models.guest_upload.order(:id).first
      failing_path = File.join(@root, first.object_key)
      allow(File).to receive(:delete).and_call_original
      allow(File).to receive(:delete).with(failing_path).and_raise(Errno::EACCES)
      invite.update(expires_at: start - 60)

      expect(retention.sweep.uploads).to eq(1)
      expect(models.guest_upload.select_map(:id)).to eq([first.id])
      expect(stored_object_count).to eq(1)
      expect(uploads.fetch(secret: stored.secret)).to be_nil
      allow(File).to receive(:delete).with(failing_path).and_call_original
      expect(retention.sweep.uploads).to eq(1)
      expect(models.guest_upload.count).to eq(0)
      expect(stored_object_count).to eq(0)
    end

    it "reclaims metadata for an object whose bytes are already absent" do
      invite = issue!(ttl: 3600)
      upload!(invite)
      row = models.guest_upload.first
      uploads.forget_bytes(row)
      invite.update(expires_at: start - 60)
      expect(retention.sweep.uploads).to eq(1)
      expect(models.guest_upload.count).to eq(0)
    end

    it "deletes the file, not only the row, when a session is revoked" do
      invite = issue!(ttl: 3600)
      stored = upload!(invite, filename: "secret.png")
      expect(stored_object_count).to eq(1)

      invites.revoke(invite: invite)

      expect(models.guest_upload.count).to eq(0)
      expect(uploads.fetch(secret: stored.secret)).to be_nil
      expect(stored_object_count).to eq(0)
    end

    it "deletes the file when the scheduled expiry job runs" do
      invite = issue!(ttl: 3600)
      upload!(invite, filename: "secret.png")

      advance_to(start + 3601)
      expect(scheduler.run_due).to eq(1)

      expect(stored_object_count).to eq(0)
    end

    it "deletes the file on the periodic sweep, whatever became of the job" do
      invite = issue!(ttl: 3600)
      upload!(invite, filename: "secret.png")
      invite.update(expires_at: start - 60)

      retention.sweep

      expect(upload_count).to eq(0)
      expect(stored_object_count).to eq(0)
    end

    it "leaves a live session's file where it is" do
      invite = issue!(ttl: 3600)
      upload!(invite, filename: "secret.png")

      retention.sweep

      expect(stored_object_count).to eq(1)
    end

    it "keeps the retry metadata while no upload service can confirm deletion" do
      invite = issue!(ttl: 3600)
      upload!(invite, filename: "secret.png")
      invite.update(expires_at: start - 60)

      described_class.new(models: models, clock: clock).reclaim_for(invite)

      expect(upload_count).to eq(1)
      expect(stored_object_count).to eq(1)
      expect(retention.sweep.uploads).to eq(1)
      expect(stored_object_count).to eq(0)
    end
  end

  describe "logging" do
    it "reports counts and never any captured content" do
      lines = []
      logger = Class.new do
        def initialize(sink) = @sink = sink

        def info(&block) = @sink << block.call

        def warn(&block) = @sink << block.call

        def debug(&block) = @sink << block.call
      end.new(lines)
      logged = described_class.new(models: models, scheduler: scheduler, logger: logger, clock: clock,
                                   uploads: uploads)
      logged_invites = Rubotty::ControlPlane::GuestInvites.new(
        models: models, clock: clock, retention: logged
      )
      invite = logged_invites.issue(community: community, room: room, nickname: "Sam",
                                    ttl_seconds: 3600).invite
      capture_member_message!(body: "a very private member message")
      upload!(invite, filename: "private-photo.png")

      logged_invites.revoke(invite: invite)

      expect(lines.join("\n")).to include("reclaimed 1 feed row(s) and 1 upload(s)")
      expect(lines.join("\n")).not_to include("a very private member message")
      expect(lines.join("\n")).not_to include("private-photo.png")
      expect(lines.join("\n")).not_to include("Ada@discord")
    end
  end

  describe "without a durable scheduler" do
    subject(:retention) { described_class.new(models: models, clock: clock) }

    it "still reclaims on revocation and on the sweep" do
      invite = invites.issue(community: community, room: room, nickname: "Sam",
                             ttl_seconds: 3600).invite
      capture_member_message!

      expect(retention.schedule_for(invite)).to be_nil
      invites.revoke(invite: invite)
      expect(message_count).to eq(0)
    end
  end
end
