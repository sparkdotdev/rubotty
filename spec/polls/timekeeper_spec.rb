# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "json"

# A poll's two durable clocks, against a deterministic injected clock.
RSpec.describe Rubotty::Polls::Timekeeper, :control_plane do
  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

  let(:base) { Time.utc(2026, 8, 12, 18, 0, 0) }
  let(:clock_time) { [base] }
  let(:clock) { -> { clock_time.first } }
  def advance(seconds) = clock_time[0] = clock_time.first + seconds

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", clock: clock, logger: Rubotty::Log.null)
  end

  let(:closed) { [] }
  let(:reposted) { [] }

  subject(:timekeeper) do
    described_class.new(
      scheduler: scheduler, clock: clock, logger: Rubotty::Log.null,
      on_close: ->(id) { closed << id }, on_repost: ->(id) { reposted << id }
    )
  end

  before { Rubotty::ControlPlane::Migrator.run(db) }

  def poll(id: 7, closes_at: base + 86_400, status: "open")
    Rubotty::Polls::Poll.new(
      id: id, community_id: 1, room_id: 2, kind: "poll", question: "Which map?",
      detail: nil, timezone: nil, multi_select: false, reply_votes: true, reply_options: false,
      closes_at: closes_at, status: status, created_by: nil, last_posted_at: nil
    )
  end

  def jobs(kind) = db[:scheduled_jobs].where(kind: kind).all

  it "registers both job kinds when constructed" do
    timekeeper
    expect(scheduler.handler?(described_class::CLOSE_KIND)).to be(true)
    expect(scheduler.handler?(described_class::REPOST_KIND)).to be(true)
  end

  describe "#arm" do
    it "schedules the close at the deadline and the first nudge one interval out" do
      timekeeper.arm(poll)

      expect(jobs(described_class::CLOSE_KIND).size).to eq(1)
      expect(jobs(described_class::REPOST_KIND).size).to eq(1)
      expect(JSON.parse(jobs(described_class::CLOSE_KIND).first[:payload])).to eq("poll_id" => 7)
    end

    it "makes the nudge recur every six hours" do
      timekeeper.arm(poll)

      expect(jobs(described_class::REPOST_KIND).first[:recurrence].to_i).to eq(described_class::REPOST_INTERVAL)
    end

    it "is safe to call twice, leaving one of each rather than two" do
      timekeeper.arm(poll)
      timekeeper.arm(poll)

      expect(jobs(described_class::CLOSE_KIND).size).to eq(1)
      expect(jobs(described_class::REPOST_KIND).size).to eq(1)
    end

    it "arms nothing at all for a poll that has already closed" do
      timekeeper.arm(poll(status: "closed"))

      expect(scheduler.pending).to eq(0)
    end

    # Polls::Lifecycle's sweep is what closes one already behind the clock.
    it "skips a deadline already in the past, and still arms the nudge" do
      timekeeper.arm(poll(closes_at: base - 60))

      expect(jobs(described_class::CLOSE_KIND)).to be_empty
      expect(jobs(described_class::REPOST_KIND).size).to eq(1)
    end
  end

  describe "when a job comes due" do
    it "calls the close seam with the poll's own id" do
      timekeeper.arm(poll)
      advance(86_401)
      scheduler.run_due

      expect(closed).to eq([7])
    end

    it "calls the repost seam every interval" do
      timekeeper.arm(poll)
      advance(described_class::REPOST_INTERVAL + 1)
      scheduler.run_due
      advance(described_class::REPOST_INTERVAL)
      scheduler.run_due

      expect(reposted).to eq([7, 7])
    end
  end

  describe "#cancel_for" do
    it "withdraws both clocks for one poll, and only that poll's" do
      timekeeper.arm(poll(id: 7))
      timekeeper.arm(poll(id: 8))

      expect(timekeeper.cancel_for(poll(id: 7))).to eq(2)
      expect(jobs(described_class::CLOSE_KIND).size).to eq(1)
      expect(JSON.parse(jobs(described_class::CLOSE_KIND).first[:payload])).to eq("poll_id" => 8)
    end
  end
end
