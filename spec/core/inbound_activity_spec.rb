# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::InboundActivity do
  it "has no last-seen moment for an endpoint it has never heard from" do
    activity = described_class.new

    expect(activity.last_seen("tg-a")).to be_nil
  end

  it "records the clock's time when an endpoint is touched" do
    now = Time.utc(2026, 8, 3, 12, 0)
    activity = described_class.new(clock: -> { now })

    activity.touch("tg-a")

    expect(activity.last_seen("tg-a")).to eq(now)
  end

  it "keeps each endpoint's moment independent of the others" do
    now = Time.utc(2026, 8, 3, 12, 0)
    activity = described_class.new(clock: -> { now })

    activity.touch("tg-a")

    expect(activity.last_seen("tg-b")).to be_nil
  end

  it "moves forward on a second touch rather than keeping the first" do
    times = [Time.utc(2026, 8, 3, 12, 0), Time.utc(2026, 8, 3, 12, 5)]
    activity = described_class.new(clock: -> { times.shift })

    activity.touch("tg-a")
    activity.touch("tg-a")

    expect(activity.last_seen("tg-a")).to eq(Time.utc(2026, 8, 3, 12, 5))
  end

  it "counts what each endpoint has delivered" do
    now = Time.utc(2026, 8, 3, 12, 0)
    activity = described_class.new(clock: -> { now })

    2.times { activity.touch("tg-a") }

    expect(activity.deliveries("tg-a")).to eq(2)
    expect(activity.deliveries("tg-b")).to eq(0)
  end

  # What Core::QuietGatewayWatchdog measures a silence against, so an endpoint
  # that has always trickled is judged on its own rhythm.
  describe "#typical_gap" do
    def activity_over(*minutes)
      base = Time.utc(2026, 8, 3, 12, 0)
      times = minutes.map { |offset| base + (offset * 60) }
      activity = described_class.new(clock: -> { times.shift })
      minutes.size.times { activity.touch("tg-a") }
      activity
    end

    it "is the average of the gaps between an endpoint's deliveries" do
      expect(activity_over(0, 10, 20).typical_gap("tg-a")).to eq(600)
    end

    it "averages uneven gaps rather than reporting only the last one" do
      expect(activity_over(0, 2, 30).typical_gap("tg-a")).to eq(900)
    end

    it "says nothing about an endpoint that has delivered too little to have a rhythm" do
      expect(activity_over(0, 10).typical_gap("tg-a")).to be_nil
      expect(activity_over(0).typical_gap("tg-a")).to be_nil
      expect(described_class.new.typical_gap("tg-a")).to be_nil
    end

    it "says nothing when every delivery landed on the same instant" do
      now = Time.utc(2026, 8, 3, 12, 0)
      activity = described_class.new(clock: -> { now })
      3.times { activity.touch("tg-a") }

      expect(activity.typical_gap("tg-a")).to be_nil
    end
  end
end
