# frozen_string_literal: true

require "spec_helper"

# Two jobs, both about the gap between handing a message to the
# inbound path and it actually arriving somewhere: what became of each copy, and
# what rate each destination will accept while a sweep is still feeding it.
RSpec.describe Rubotty::Core::RelayOutcomes do
  let(:elapsed) { [0.0] }
  let(:monotonic) { -> { elapsed.first } }
  let(:logged) { { error: [], warn: [] } }
  let(:logger) do
    instance_double(Logger).tap do |double|
      allow(double).to receive(:error) { |&block| logged[:error] << block.call }
      allow(double).to receive(:warn) { |&block| logged[:warn] << block.call }
      allow(double).to receive(:info)
      allow(double).to receive(:debug)
    end
  end

  subject(:outcomes) { Rubotty::Core::RelayOutcomes.new(logger: logger, monotonic: monotonic) }

  def ref(native) = Rubotty::Core::MessageRef.new("dc-general", native)

  describe "following one message's fan-out" do
    it "records nothing for a message nobody asked it to follow" do
      outcomes.delivered(ref("1"), "tg-general")
      outcomes.abandoned(ref("1"), "tg-general", "boom")

      expect(outcomes.reconcile([ref("1")]).lost).to eq(0)
      expect(logged[:error]).to be_empty
    end

    it "counts a message as lost when ANY of its copies was given up on" do
      outcomes.watch(ref("1"))
      outcomes.delivered(ref("1"), "st-general")
      outcomes.abandoned(ref("1"), "tg-general", "Too Many Requests")

      result = outcomes.reconcile([ref("1")])
      expect(result.lost).to eq(1)
      expect(result.losses).to eq(["dc-general:1 to tg-general (Too Many Requests)"])
    end

    it "counts a message whose every copy landed as nothing at all" do
      outcomes.watch(ref("1"))
      outcomes.delivered(ref("1"), "tg-general")
      outcomes.delivered(ref("1"), "st-general")

      expect(outcomes.reconcile([ref("1")]).lost).to eq(0)
    end

    # A message that never arrived is the one thing this whole feature exists to
    # stop, so it is said at error level and in words somebody will read.
    it "says a lost copy out loud, naming the message and where it never got to" do
      outcomes.watch(ref("1"))
      outcomes.abandoned(ref("1"), "tg-general", "Too Many Requests")

      expect(logged[:error].first)
        .to include("RELAY LOST", "dc-general:1", "tg-general", "Too Many Requests", "nothing will resend it")
    end

    it "forgets what it read back, so a long-lived process does not accumulate them" do
      outcomes.watch(ref("1"))
      outcomes.abandoned(ref("1"), "tg-general", "Too Many Requests")

      expect(outcomes.reconcile([ref("1")]).lost).to eq(1)
      expect(outcomes.reconcile([ref("1")]).lost).to eq(0)
    end

    it "forgets a batch on request, for a relay that ended without reading them" do
      outcomes.watch(ref("1"))
      outcomes.abandoned(ref("1"), "tg-general", "Too Many Requests")
      outcomes.forget([ref("1")])

      expect(outcomes.reconcile([ref("1")]).lost).to eq(0)
    end
  end

  describe "what rate a destination will accept" do
    it "remembers the wait a destination asked for" do
      outcomes.rate_limited("tg-general", 27)
      expect(outcomes.rate_limit_for("tg-general", since: 0.0)).to eq(27.0)
    end

    it "answers for that destination only" do
      outcomes.rate_limited("tg-general", 27)
      expect(outcomes.rate_limit_for("st-general", since: 0.0)).to be_nil
    end

    # Otherwise a sweep an hour later would start at yesterday's punishment rate.
    it "ignores news older than the relay asking about it" do
      outcomes.rate_limited("tg-general", 27)
      elapsed[0] = 600.0

      expect(outcomes.rate_limit_for("tg-general", since: 500.0)).to be_nil
    end

    it "ignores a wait of zero or less, which names no rate at all" do
      outcomes.rate_limited("tg-general", 0)
      expect(outcomes.rate_limit_for("tg-general", since: 0.0)).to be_nil
    end
  end

  describe Rubotty::Core::RelayOutcomes::Pacer do
    let(:sleeps) { [] }
    let(:sleeper) do
      lambda do |seconds|
        sleeps << seconds
        elapsed[0] += seconds
      end
    end

    def pacer(interval_ms: 1_000, max_interval_ms: nil)
      outcomes.pacer(interval_ms: interval_ms, max_interval_ms: max_interval_ms, sleeper: sleeper)
    end

    it "waits the configured interval after a send, however many destinations shared it" do
      budget = pacer
      3.times { budget.pace(%w[tg-general st-general dc-general]) }

      expect(sleeps).to eq([1.0, 1.0, 1.0])
    end

    it "waits for the slowest destination, so none of them is sent to faster than it allows" do
      budget = pacer
      budget.pace(%w[tg-general st-general])
      outcomes.rate_limited("tg-general", 27)
      budget.pace(%w[tg-general st-general])

      expect(sleeps).to eq([1.0, 27.0])
      expect(budget.intervals).to eq("tg-general" => 27.0, "st-general" => 1.0)
    end

    it "keeps the rate a platform named for the rest of the relay" do
      budget = pacer
      outcomes.rate_limited("tg-general", 27)
      3.times { budget.pace(%w[tg-general]) }

      expect(sleeps).to eq([27.0, 27.0, 27.0])
    end

    # Being told to wait twice must never read as being told to speed up.
    it "never lowers a destination's interval on a shorter later answer" do
      budget = pacer
      outcomes.rate_limited("tg-general", 27)
      budget.pace(%w[tg-general])
      outcomes.rate_limited("tg-general", 2)
      budget.pace(%w[tg-general])

      expect(sleeps).to eq([27.0, 27.0])
    end

    it "holds the slowdown at max_interval_ms, so an absurd answer cannot pin a sweep all day" do
      budget = pacer(max_interval_ms: 5_000)
      outcomes.rate_limited("tg-general", 3_600)
      budget.pace(%w[tg-general])

      expect(sleeps).to eq([5.0])
    end

    it "still costs the configured interval for a channel whose room membership cannot be read" do
      pacer.pace([])
      expect(sleeps).to eq([1.0])
    end
  end
end
