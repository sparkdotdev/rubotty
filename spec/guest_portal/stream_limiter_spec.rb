# frozen_string_literal: true

require "spec_helper"
require "rubotty/guest_portal"

# An SSE stream holds a thread and two queries a second against a Sequel pool of
# four, shared with the dashboard and the API, so one invite cannot have as many
# as it likes.
RSpec.describe Rubotty::GuestPortal::StreamLimiter do
  subject(:limiter) { described_class.new(max: 2) }

  it "runs the block and returns its value while there is room" do
    expect(limiter.hold("invite-1") { :ran }).to eq(:ran)
  end

  it "returns nil without running the block once the invite is at its limit" do
    held = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new { limiter.hold("invite-1") { held << :in and release.pop } }
    end
    2.times { held.pop }

    ran = false
    expect(limiter.hold("invite-1") { ran = true }).to be_nil
    expect(ran).to be(false)

    2.times { release << :go }
    threads.each(&:join)
  end

  it "frees the slot when the block finishes" do
    limiter.hold("invite-1") { :first }
    limiter.hold("invite-1") { :second }

    expect(limiter.hold("invite-1") { :third }).to eq(:third)
    expect(limiter.open_for("invite-1")).to eq(0)
  end

  it "frees the slot when the block raises, so a dropped connection is not a leak" do
    expect { limiter.hold("invite-1") { raise "boom" } }.to raise_error("boom")

    expect(limiter.open_for("invite-1")).to eq(0)
    expect(limiter.hold("invite-1") { :ok }).to eq(:ok)
  end

  it "counts each invite separately, so one guest cannot starve another" do
    held = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new { limiter.hold("invite-1") { held << :in and release.pop } }
    end
    2.times { held.pop }

    expect(limiter.hold("invite-2") { :ok }).to eq(:ok)

    2.times { release << :go }
    threads.each(&:join)
  end
end
