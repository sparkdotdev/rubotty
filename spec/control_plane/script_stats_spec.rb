# frozen_string_literal: true

require "spec_helper"
require "rubotty"

# A row name is free text a script fills in, so without a cap and an expiry, counting
# by author grows a per person table forever and counting by message text parks member
# content on a dashboard.
RSpec.describe Rubotty::ControlPlane::ScriptStats, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.now }

  subject(:stats) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }

  describe "counting" do
    it "starts a row at the step and adds to it after that" do
      stats.increment(community: community, stat: "commands", row: "roll")
      stats.increment(community: community, stat: "commands", row: "roll", step: 4)

      expect(stats.report(community)["commands"].first).to include(row: "roll", value: 5)
    end

    it "sets a row outright when asked to" do
      stats.increment(community: community, stat: "gauge", row: "online", step: 9)
      stats.record(community: community, stat: "gauge", row: "online", value: 2)

      expect(stats.report(community)["gauge"].first[:value]).to eq(2)
    end

    it "keeps the same row in two rooms apart" do
      stats.increment(community: community, stat: "commands", row: "roll", room_key: "kitchen")
      stats.increment(community: community, stat: "commands", row: "roll", room_key: "garden")

      expect(stats.report(community)["commands"].length).to eq(2)
    end

    it "orders the highest first, which is what a chart wants" do
      stats.increment(community: community, stat: "commands", row: "rare", step: 1)
      stats.increment(community: community, stat: "commands", row: "common", step: 50)

      expect(stats.report(community)["commands"].first[:row]).to eq("common")
    end

    # Counts sit in memory briefly, so another process sees one only after a flush.
    it "is shared, so any script in the community reads the same total" do
      stats.increment(community: community, stat: "commands", row: "roll")
      stats.flush
      other = described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now })

      expect(other.report(community)["commands"].first[:value]).to eq(1)
    end

    it "writes one row for a burst of counting rather than one per call" do
      30.times { stats.increment(community: community, stat: "commands", row: "roll") }
      stats.flush

      expect(models.script_stat.where(stat: "commands").count).to eq(1)
      expect(stats.report(community)["commands"].first[:value]).to eq(30)
    end
  end

  describe "the bounds" do
    it "refuses a row name longer than the cap" do
      ok, why = stats.increment(community: community, stat: "s", row: "x" * 500)

      expect(ok).to be(false)
      expect(why).to match(/under 120/)
    end

    it "refuses a stat name that is not a name" do
      expect(stats.increment(community: community, stat: "not a name!", row: "r").first).to be(false)
    end

    it "refuses a row past the per stat cap, rather than evicting an older one" do
      stub_const("#{described_class}::MAX_ROWS", 2)
      2.times { |i| stats.increment(community: community, stat: "s", row: "row#{i}") }
      stats.flush

      # Refused at the write, since that is where the row count is known.
      stats.increment(community: community, stat: "s", row: "one-too-many")
      stats.flush

      expect(stats.report(community)["s"].length).to eq(2)
    end

    it "still counts an existing row at the cap" do
      stub_const("#{described_class}::MAX_ROWS", 1)
      stats.increment(community: community, stat: "s", row: "kept")
      stats.flush
      stats.increment(community: community, stat: "s", row: "kept")

      expect(stats.report(community)["s"].first[:value]).to eq(2)
    end

    it "refuses a step that is absurd" do
      expect(stats.increment(community: community, stat: "s", row: "r", step: 10**9).first).to be(false)
    end

    it "refuses a step that does not parse as a whole number, instead of defaulting to 1" do
      ok, why = stats.increment(community: community, stat: "s", row: "r", step: "1o")
      expect(ok).to be(false)
      expect(why).to eq("a step has to be a whole number")
      expect(stats.report(community)).to eq({})
    end
  end

  # The retention is what makes counting by author safe to offer at all.
  describe "the 90 day retention" do
    it "leaves an expired row out of the report even before the prune runs" do
      stats.increment(community: community, stat: "s", row: "old")
      later = described_class.new(models: models, logger: Rubotty::Log.null,
                                 clock: -> { now + described_class::RETENTION + 60 })

      expect(later.report(community)).to be_empty
    end

    it "deletes what has expired when it runs" do
      stats.increment(community: community, stat: "s", row: "old")
      stats.flush
      later = described_class.new(models: models, logger: Rubotty::Log.null,
                                 clock: -> { now + described_class::RETENTION + 60 })

      expect(later.prune).to eq(1)
      expect(models.script_stat.count).to eq(0)
    end

    it "leaves a row that is still inside the window" do
      stats.increment(community: community, stat: "s", row: "fresh")

      expect(stats.prune).to eq(0)
    end
  end
end

RSpec.describe "the analytics windows" do
  it "offers 90d as well" do
    expect(Rubotty::ControlPlane::Analytics::WINDOWS.keys).to eq(%w[24h 7d 30d 90d])
  end

  it "matches the retention script stats actually keep" do
    expect(Rubotty::ControlPlane::Analytics::WINDOWS["90d"])
      .to eq(Rubotty::ControlPlane::ScriptStats::RETENTION)
  end
end

RSpec.describe Rubotty::ControlPlane::ScriptStats, "what it promises about writing", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 7, 29, 12, 0, 0) }
  let(:clock) { -> { @now ||= now } }
  let(:stats) { described_class.new(models: models, clock: clock) }

  def rows = models.script_stat.where(community_id: community.id).count

  # The threshold counts increments, so a room hammering one row still reaches it.
  it "writes a burst of one row out once it hits the threshold" do
    described_class::FLUSH_AFTER.times do
      stats.increment(community: community, stat: "commands", row: "roll")
    end

    expect(rows).to eq(1)
    expect(models.script_stat.first.value).to eq(described_class::FLUSH_AFTER)
  end

  # The time ceiling has to fire on silence, which is the case it exists for.
  it "writes out after the time ceiling, with nothing else arriving" do
    stats.increment(community: community, stat: "commands", row: "roll")
    expect(rows).to be_zero

    stats.flush_if_due(now: now + described_class::FLUSH_AFTER_SECONDS + 1)

    expect(rows).to eq(1)
  end

  it "leaves them held before the ceiling" do
    stats.increment(community: community, stat: "commands", row: "roll")
    stats.flush_if_due(now: now + 1)

    expect(rows).to be_zero
  end

  # Both halves of the class have to answer the same way about a full stat.
  it "refuses an increment that would be a row over the cap, rather than saying yes" do
    stub_const("#{described_class}::MAX_ROWS", 2)
    2.times { |n| stats.increment(community: community, stat: "s", row: "row#{n}") }
    stats.flush

    answer = stats.increment(community: community, stat: "s", row: "one too many")

    expect(answer).to eq([false, "s already has 2 rows, which is the limit"])
  end

  it "still counts a row that already exists once the stat is full" do
    stub_const("#{described_class}::MAX_ROWS", 2)
    2.times { |n| stats.increment(community: community, stat: "s", row: "row#{n}") }
    stats.flush

    expect(stats.increment(community: community, stat: "s", row: "row0")).to be(true)
  end

  it "counts what it really wrote, not what it tried to write" do
    stats.increment(community: community, stat: "commands", row: "roll")
    allow(models.script_stat).to receive(:where).and_raise(Sequel::DatabaseError, "boom")

    expect(stats.flush).to be_zero
  end
end

# One instance is shared by every room's thread, so two can be inside flush at once.
RSpec.describe Rubotty::ControlPlane::ScriptStats, "under concurrent counting", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:stats) { described_class.new(models: models) }

  it "loses no count when several threads count the same row" do
    threads = 8.times.map do
      Thread.new do
        60.times { stats.increment(community: community, stat: "commands", row: "roll") }
      end
    end
    threads.each(&:join)
    stats.flush

    expect(models.script_stat.where(stat: "commands", row_name: "roll").first.value).to eq(480)
  end

  # The add happens in the database, so a total is never read into Ruby and written back.
  it "adds to the stored value rather than to one it read earlier" do
    stats.increment(community: community, stat: "commands", row: "roll", step: 5)
    stats.flush
    models.script_stat.where(stat: "commands").update(value: 100)

    stats.increment(community: community, stat: "commands", row: "roll", step: 3)
    stats.flush

    expect(models.script_stat.where(stat: "commands").first.value).to eq(103)
  end
end
