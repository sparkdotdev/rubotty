# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::AdapterHealth do
  before { @now = Time.utc(2026, 8, 21, 9, 0) }

  def now = @now

  def travel(seconds) = @now += seconds

  let(:window) { 300 }
  let(:tracker) { described_class.new(window: window, clock: -> { now }) }
  let(:key) { %i[discord dc] }

  it "reads healthy for an adapter that has never errored" do
    expect(tracker.healthy?(key)).to be(true)
  end

  it "reads unhealthy right after an error, and lists it as a recent failure" do
    tracker.record_error(key, RuntimeError.new("401 Unauthorized"))

    expect(tracker.healthy?(key)).to be(false)
    expect(tracker.recent_failures).to contain_exactly(
      { adapter_key: key, at: now, message: "401 Unauthorized", seconds_ago: 0 }
    )
  end

  it "ages the error out of the window rather than remembering it forever" do
    tracker.record_error(key, RuntimeError.new("boom"))
    travel(window - 1)
    expect(tracker.healthy?(key)).to be(false)

    travel(1)
    expect(tracker.healthy?(key)).to be(true)
    expect(tracker.recent_failures).to be_empty
  end

  it "clears an error immediately on a fresh success, without waiting out the window" do
    tracker.record_error(key, RuntimeError.new("boom"))
    tracker.clear(key)

    expect(tracker.healthy?(key)).to be(true)
    expect(tracker.recent_failures).to be_empty
  end

  it "tracks every adapter independently" do
    other = %i[telegram tg]
    tracker.record_error(key, RuntimeError.new("discord down"))

    expect(tracker.healthy?(key)).to be(false)
    expect(tracker.healthy?(other)).to be(true)
  end

  it "keeps failing on repeated errors rather than reading healthy between them" do
    tracker.record_error(key, RuntimeError.new("first"))
    travel(window - 1)
    tracker.record_error(key, RuntimeError.new("second"))
    travel(window - 1)

    expect(tracker.healthy?(key)).to be(false)
    expect(tracker.recent_failures.first[:message]).to eq("second")
  end
end
