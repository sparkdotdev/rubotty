# frozen_string_literal: true

require "spec_helper"
require "sequel"
require "json"

# The reminder engine: one durable job per rung of an event's reminder ladder, on
# the same durable scheduler the warnings ladder and scheduled announcements use.
# Driven throughout against a deterministic injected clock.
RSpec.describe Rubotty::Events::Reminders, :control_plane do
  let(:db) { Sequel.sqlite }
  let(:store) { Rubotty::Core::DurableSchedulerStore::Sequel.new(db: db) }

  let(:base) { Time.utc(2026, 8, 1, 0, 0, 0) }
  let(:clock_time) { [base] }
  let(:clock) { -> { clock_time.first } }
  def advance(seconds) = clock_time[0] = clock_time.first + seconds

  let(:scheduler) do
    Rubotty::Core::DurableScheduler.new(store: store, session_id: "s", clock: clock, logger: Rubotty::Log.null)
  end

  subject(:reminders) do
    described_class.new(scheduler: scheduler, logger: Rubotty::Log.null, clock: clock)
  end

  before { Rubotty::ControlPlane::Migrator.run(db) }

  def event(overrides = {})
    row = {
      id: 1, community_id: 10, room_id: 20, title: "Raid night",
      description: nil, timezone: "Europe/Lisbon", kind: "gaming",
      game_title: "Baldur's Gate 3", server_address: nil, url: nil,
      rsvp_mode: "full", status: "scheduled",
      reminder_intervals: nil, native_refs: "{}", created_by: "sample_owner",
      starts_at: base + 86_400, ends_at: nil
    }.merge(overrides)
    Rubotty::Events::Event.new(row)
  end

  def jobs = db[:scheduled_jobs].where(kind: "event_reminder").all

  def payload_of(row) = JSON.parse(row[:payload])

  # SQLite round trips the wall clock digits through Sequel with no timezone tag,
  # so compare these rather than Time#to_i.
  def wall_clock(time) = time.strftime("%Y-%m-%d %H:%M:%S")

  it "registers its job kind on the durable scheduler when constructed" do
    reminders
    expect(scheduler.handler?(described_class::KIND)).to be(true)
  end

  describe "#schedule_for" do
    it "schedules one durable job per rung of the default ladder for a comfortably future event" do
      ev = event(starts_at: base + (10 * 86_400)) # ten days out, every default rung is future
      count = reminders.schedule_for(ev)

      expect(count).to eq(Rubotty::Features::Events::DEFAULT_REMINDER_INTERVALS.size)
      expect(scheduler.pending).to eq(count)
      jobs.each do |row|
        payload = payload_of(row)
        expect(wall_clock(row[:run_at])).to eq(wall_clock(ev.starts_at - payload["interval"]))
        expect(payload["event_id"]).to eq(ev.id)
      end
    end

    it "uses the event's own reminder_intervals override instead of the default" do
      ev = event(starts_at: base + 7200, reminder_intervals: [3600, 1800].to_json)
      count = reminders.schedule_for(ev)

      expect(count).to eq(2)
      expect(jobs.map { |r| payload_of(r)["interval"] }.sort).to eq([1800, 3600])
    end

    it "skips any rung whose fire time has already passed" do
      ev = event(starts_at: base + 3600) # starts in exactly one hour
      count = reminders.schedule_for(ev)

      # Every default rung of 1h or longer fires at or before "now" and is
      # skipped; only the 30m and 15m rungs still have useful lead time.
      expect(count).to eq(2)
      expect(jobs.map { |r| payload_of(r)["interval"] }.sort).to eq([900, 1800])
    end

    it "schedules nothing for an event with no future rungs at all" do
      ev = event(starts_at: base + 60, reminder_intervals: [900].to_json)
      expect(reminders.schedule_for(ev)).to eq(0)
      expect(scheduler.pending).to eq(0)
    end

    it "schedules nothing when the event's own override is an explicit empty ladder" do
      ev = event(starts_at: base + 7200, reminder_intervals: [].to_json)
      expect(reminders.schedule_for(ev)).to eq(0)
      expect(scheduler.pending).to eq(0)
    end

    it "resolves a callable default_intervals per event rather than a fixed array" do
      resolver = ->(ev) { ev.community_id == 10 ? [3600] : [1800] }
      engine = described_class.new(scheduler: scheduler, default_intervals: resolver, logger: Rubotty::Log.null, clock: clock)
      ev = event(community_id: 10, starts_at: base + 7200)

      engine.schedule_for(ev)
      expect(jobs.map { |r| payload_of(r)["interval"] }).to eq([3600])
    end
  end

  describe "reschedule on a time change" do
    it "cancels the stale jobs and schedules fresh ones at the new starts_at, never doubling up" do
      original = event(starts_at: base + 3600, reminder_intervals: [1800, 900].to_json)
      reminders.schedule_for(original)
      expect(scheduler.pending).to eq(2)

      moved = event(starts_at: base + 7200, reminder_intervals: [1800, 900].to_json)
      reminders.schedule_for(moved)

      expect(scheduler.pending).to eq(2)
      run_ats = jobs.map { |r| wall_clock(r[:run_at]) }.sort
      expect(run_ats).to eq([wall_clock(moved.starts_at - 1800), wall_clock(moved.starts_at - 900)].sort)
    end

    it "never touches another event's pending reminders" do
      one = event(id: 1, starts_at: base + 3600, reminder_intervals: [900].to_json)
      two = event(id: 2, starts_at: base + 3600, reminder_intervals: [900].to_json)
      reminders.schedule_for(one)
      reminders.schedule_for(two)
      expect(scheduler.pending).to eq(2)

      reminders.schedule_for(event(id: 1, starts_at: base + 7200, reminder_intervals: [900].to_json))

      expect(scheduler.pending).to eq(2)
      expect(jobs.map { |r| payload_of(r)["event_id"] }.sort).to eq([1, 2])
    end
  end

  describe "#cancel_for" do
    it "removes every pending reminder job for the event, and only that event's" do
      one = event(id: 1, starts_at: base + 3600, reminder_intervals: [1800, 900].to_json)
      two = event(id: 2, starts_at: base + 3600, reminder_intervals: [900].to_json)
      reminders.schedule_for(one)
      reminders.schedule_for(two)

      cancelled = reminders.cancel_for(one)

      expect(cancelled).to eq(2)
      expect(scheduler.pending).to eq(1)
      expect(payload_of(jobs.first)["event_id"]).to eq(2)
    end

    it "is a harmless no-op for an event with nothing pending" do
      expect(reminders.cancel_for(event(id: 404))).to eq(0)
    end
  end

  describe "firing" do
    it "invokes the injected on_fire seam with the rebuilt event and the interval that fired" do
      on_fire = double("on_fire")
      allow(on_fire).to receive(:call)
      engine = described_class.new(scheduler: scheduler, on_fire: on_fire, logger: Rubotty::Log.null, clock: clock)
      ev = event(id: 5, title: "Raid night", kind: "gaming", starts_at: base + 3600, reminder_intervals: [1800].to_json)
      engine.schedule_for(ev)
      due_at = jobs.first[:run_at]

      scheduler.run_due(now: due_at)

      expect(on_fire).to have_received(:call).with(
        having_attributes(id: 5, title: "Raid night", kind: "gaming"), 1800
      )
    end

    it "rebuilds an event whose starts_at round trips through the durable payload" do
      fired = []
      engine = described_class.new(
        scheduler: scheduler, on_fire: ->(ev, interval) { fired << [ev, interval] },
        logger: Rubotty::Log.null, clock: clock
      )
      ev = event(starts_at: base + 3600, reminder_intervals: [1800].to_json)
      engine.schedule_for(ev)

      scheduler.run_due(now: jobs.first[:run_at])

      expect(fired.size).to eq(1)
      fired_event, interval = fired.first
      expect(interval).to eq(1800)
      expect(fired_event.starts_at.to_i).to eq(ev.starts_at.to_i)
    end

    it "defaults to a silent no-op when no on_fire seam is injected" do
      silent = described_class.new(scheduler: scheduler, logger: Rubotty::Log.null, clock: clock)
      ev = event(starts_at: base + 3600, reminder_intervals: [1800].to_json)
      silent.schedule_for(ev)

      expect { scheduler.run_due(now: jobs.first[:run_at]) }.not_to raise_error
    end
  end

  describe "boot recovery" do
    it "recovers a due reminder across a restart, mirroring the warnings ladder's expiry recovery" do
      ev = event(id: 9, starts_at: base + 1800, reminder_intervals: [900].to_json)

      first_session = Rubotty::Core::DurableScheduler.new(
        store: store, session_id: "session-1", clock: clock, logger: Rubotty::Log.null
      )
      described_class.new(scheduler: first_session, logger: Rubotty::Log.null, clock: clock).schedule_for(ev)
      # The process dies here: first_session is never told to run_due or stop, so the
      # row is left pending in the shared store.

      advance(2000) # now past starts_at - 900

      recovered = []
      second_session = Rubotty::Core::DurableScheduler.new(
        store: store, session_id: "session-2", clock: clock, logger: Rubotty::Log.null
      )
      described_class.new(
        scheduler: second_session, on_fire: ->(event, interval) { recovered << [event, interval] },
        logger: Rubotty::Log.null, clock: clock
      )

      second_session.recover(alive_session_ids: ["session-2"])

      expect(recovered.size).to eq(1)
      fired_event, interval = recovered.first
      expect(fired_event.id).to eq(9)
      expect(interval).to eq(900)
    end
  end
end
