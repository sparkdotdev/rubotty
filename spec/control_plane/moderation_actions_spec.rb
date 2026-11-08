# frozen_string_literal: true

require "spec_helper"
require "sequel"

# The operations core behind the dashboard's moderation page, driven with no Sinatra
# over the same stores the warnings ladder uses, so an operator's mute and an
# escalated one are the same kind of row.
RSpec.describe Rubotty::ControlPlane::ModerationActions, :control_plane do
  let(:seeded) { seeded_sample }
  let(:db) { seeded[0] }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:store) { Rubotty::Core::WarningsStore::Sequel.new(db: db) }
  let(:sched_store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

  let(:base) { Time.utc(2026, 7, 23, 12, 0, 0) }
  let(:clock_time) { [base] }
  let(:clock) { -> { clock_time.first } }
  def advance(seconds) = clock_time[0] = clock_time.first + seconds

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: sched_store, session_id: "dashboard", clock: clock,
                                        logger: Rubotty::Log.null)
  end
  let(:audit) { Rubotty::Core::AuditLog::Sequel.new(db: db) }

  subject(:actions) { described_class.new(store: store, scheduler: scheduler, audit: audit, clock: clock) }

  describe "#mute" do
    it "records an active sanction and returns it" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1",
                            username: "troll", reason: "spam")
      expect(record.action).to eq("mute")
      expect(record.community).to eq("sample")
      expect(record.adapter).to eq("telegram")
      expect(record.subject_native_id).to eq("u1")
      expect(record.active).to be(true)
    end

    it "raises Invalid without both a platform and a user id" do
      expect { actions.mute(community: community, adapter: "", native_id: "u1") }
        .to raise_error(described_class::Invalid, /platform/)
      expect { actions.mute(community: community, adapter: "telegram", native_id: "") }
        .to raise_error(described_class::Invalid, /platform/)
    end

    it "raises Invalid for a duration it cannot parse" do
      expect { actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "banana") }
        .to raise_error(described_class::Invalid, /duration/)
    end

    it "parses the same duration vocabulary the ladder's config uses, and schedules its reversal" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
      expect(record.until_at).to be_within(1).of(base + 3600)
      expect(scheduler.pending).to eq(1)

      job = sched_store.find(db[:scheduled_jobs].max(:id))
      expect(job.kind).to eq(Rubotty::Core::Warnings::EXPIRE_KIND)
      expect(job.payload["sanction_id"]).to eq(record.id)
      expect(job.payload["action"]).to eq("mute")
      expect(job.payload["native_id"]).to eq("u1")
      expect(job.payload["endpoints"]).to eq([])
      expect(store.find_sanction(community: "sample", id: record.id).job_id).to eq(job.id.to_s)
    end

    it "leaves an indefinite mute with a nil until_at and schedules no expiry" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1")
      expect(record.until_at).to be_nil
      expect(scheduler.pending).to eq(0)
    end

    it "records a durable audit event for the mute" do
      actions.mute(community: community, adapter: "telegram", native_id: "u1",
                   username: "troll", display: "Troll McTrollface", reason: "spam", issued_by: "dashboard:administrator")
      event = audit.query(community: "sample", action: "mute").first
      expect(event.source).to eq("dashboard")
      expect(event.subject_native_id).to eq("u1")
      expect(event.subject).to eq("Troll McTrollface")
      expect(event.reason).to eq("spam")
      expect(event.actor).to eq("dashboard:administrator")
    end
  end

  describe "#active_mutes" do
    it "lists only active mutes for the community, newest first" do
      first = actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
      second = actions.mute(community: community, adapter: "discord", native_id: "u2", duration: "1h")
      expect(actions.active_mutes(community: community).map(&:id)).to eq([second.id, first.id])
    end

    it "excludes a sanction the ladder recorded as a ban" do
      store.record_sanction(community: "sample", adapter: "telegram", subject_native_id: "u9",
                            action: :ban, until_at: base + 86_400)
      expect(actions.active_mutes(community: community)).to be_empty
    end

    it "excludes a mute already lifted" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
      actions.unmute(community: community, id: record.id)
      expect(actions.active_mutes(community: community)).to be_empty
    end

    it "never leaks another community's mute" do
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      settings: "{}", created_at: base, updated_at: base)
      store.record_sanction(community: "other", adapter: "telegram", subject_native_id: "u1",
                            action: :mute, until_at: base + 3600)
      expect(actions.active_mutes(community: community)).to be_empty
      expect(actions.active_mutes(community: other).length).to eq(1)
    end
  end

  describe "#unmute" do
    it "lifts an active mute and records an audit event" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
      lifted = actions.unmute(community: community, id: record.id)
      expect(lifted.id).to eq(record.id)
      expect(store.find_sanction(community: "sample", id: record.id).active).to be(false)
      event = audit.query(community: "sample", action: "unmute").first
      expect(event.subject_native_id).to eq("u1")
    end

    it "cancels the scheduled expiry job, so it cannot fire later and overwrite the manual lift" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")
      expect(scheduler.pending).to eq(1)

      actions.unmute(community: community, id: record.id)
      expect(scheduler.pending).to eq(0)
    end

    it "returns nil for an id that does not exist" do
      expect(actions.unmute(community: community, id: 999_999)).to be_nil
    end

    it "returns nil, and does not touch the row, for a sanction from another community" do
      other = models.community.create(slug: "other", name: "Other", status: "active",
                                      settings: "{}", created_at: base, updated_at: base)
      foreign = store.record_sanction(community: "other", adapter: "telegram", subject_native_id: "u1",
                                      action: :mute, until_at: base + 3600)
      expect(actions.unmute(community: community, id: foreign.id)).to be_nil
      expect(store.find_sanction(community: "other", id: foreign.id).active).to be(true)
    end
  end

  describe "a mute scheduled here reversed by an entirely different process" do
    it "lifts on schedule even though this session never applied it to a platform" do
      record = actions.mute(community: community, adapter: "telegram", native_id: "u1", duration: "1h")

      # A fresh session over the same database, standing in for the bot process that
      # runs while the dashboard is a separate one.
      bot_scheduler = Rubotty::Core::DurableScheduler.new(
        store: sched_store, session_id: "bot-session", clock: clock, logger: Rubotty::Log.null
      )
      bot_service = Rubotty::Core::Warnings::Service.new(
        store: store, scheduler: bot_scheduler, topology: topology, adapters: {}, clock: clock
      )
      bot_scheduler.register(Rubotty::Core::Warnings::EXPIRE_KIND) { |job| bot_service.expire(job) }

      advance(3601)
      ran = bot_scheduler.run_due
      expect(ran).to eq(1)
      expect(store.find_sanction(community: "sample", id: record.id).active).to be(false)
    end
  end
end
