# frozen_string_literal: true

require "spec_helper"

# Paces sends BEFORE a platform refuses one. RetryPolicy already reads a 429 and
# waits the stated retry_after, but by then the request has been refused and the
# room's worker is blocked for as long as the platform says.
RSpec.describe Rubotty::Core::OutboundPacer do
  let(:now) { [0.0] }
  subject(:pacer) { described_class.new(clock: -> { now[0] }) }

  describe "#claim" do
    it "lets the first send through and spaces the ones behind it" do
      waits = Array.new(3) { pacer.claim("chat", rate: 1.0, burst: 1) }
      expect(waits).to eq([0.0, 1.0, 2.0])
    end

    it "keys each destination separately, so one busy room does not pace a quiet one" do
      pacer.claim("busy", rate: 1.0, burst: 1)
      pacer.claim("busy", rate: 1.0, burst: 1)

      expect(pacer.claim("quiet", rate: 1.0, burst: 1)).to eq(0.0)
    end

    it "opens up again once the wait has actually passed" do
      2.times { pacer.claim("chat", rate: 1.0, burst: 1) }
      now[0] = 10.0

      expect(pacer.claim("chat", rate: 1.0, burst: 1)).to eq(0.0)
    end

    # Every platform's own limiter allows a burst, so pacing one at a time
    # would be slower than the platform actually requires.
    it "lets a burst through together and paces only what is past it" do
      waits = Array.new(6) { pacer.claim("chat", rate: 1.0, burst: 5) }
      expect(waits.first(5)).to all(eq(0.0))
      expect(waits.last).to eq(1.0)
    end

    it "refills the burst after an idle stretch" do
      5.times { pacer.claim("chat", rate: 1.0, burst: 5) }
      now[0] = 20.0

      expect(Array.new(5) { pacer.claim("chat", rate: 1.0, burst: 5) }).to all(eq(0.0))
    end

    # A platform whose published limit nobody has read is not one to invent a
    # number for; the 429 handling still catches it.
    it "does not pace a key with no declared rate" do
      expect(pacer.claim("chat", rate: nil)).to eq(0.0)
      expect(pacer.claim("chat", rate: 0)).to eq(0.0)
    end

    it "reserves a slot per claim, so two callers at once take different ones" do
      first = pacer.claim("chat", rate: 2.0, burst: 1)
      second = pacer.claim("chat", rate: 2.0, burst: 1)

      expect([first, second]).to eq([0.0, 0.5])
    end
  end

  describe "#pace" do
    it "waits the claim out, then runs the block" do
      slept = []
      paced = described_class.new(clock: -> { now[0] }, sleeper: ->(seconds) { slept << seconds })
      ran = []

      2.times { paced.pace("chat", rate: 2.0) { ran << :sent } }

      expect(ran.length).to eq(2)
      expect(slept).to eq([0.5])
    end

    it "returns whatever the block returned" do
      expect(pacer.pace("chat", rate: 100.0) { :receipt }).to eq(:receipt)
    end
  end

  it "drops the coldest key rather than holding one for every room forever" do
    stub_const("#{described_class}::MAX_KEYS", 3)
    5.times { |i| pacer.claim("chat-#{i}", rate: 1.0) }

    expect(pacer.tracked).to eq(3)
  end
end
