# frozen_string_literal: true

require "spec_helper"

# The shared /end sentinel: the closing word belongs to no one feature, so these
# exercise it with two made-up kinds.
RSpec.describe Rubotty::Core::PendingOperations do
  subject(:pending) { described_class.new }

  it "closes an operation by running the handler its own kind registered" do
    seen = []
    pending.register("alpha") { |operation, context| seen << [operation.kind, context] }
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1", payload: { a: 1 })

    pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1", context: :ctx)

    expect(seen).to eq([["alpha", :ctx]])
  end

  it "sends the same word to a second kind's handler without either knowing about the other" do
    closed = []
    pending.register("alpha") { |_operation, _context| closed << "alpha" }
    pending.register("beta") { |_operation, _context| closed << "beta" }

    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1")
    pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1")
    pending.open(kind: "beta", community_id: 1, endpoint_id: "e1", actor_id: "u1")
    pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1")

    expect(closed).to eq(%w[alpha beta])
  end

  it "reports nothing open rather than raising" do
    expect(pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1")).to eq(:none)
  end

  it "reports an operation whose kind has no handler left, instead of losing it silently" do
    pending.open(kind: "gone", community_id: 1, endpoint_id: "e1", actor_id: "u1")

    expect(pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1")).to eq(:unhandled)
  end

  # One person can be an operator in two communities on the same deployment.
  it "never closes an operation opened in another community" do
    pending.register("alpha") { |_operation, _context| :ran }
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1")

    expect(pending.close(community_id: 2, endpoint_id: "e1", actor_id: "u1")).to eq(:none)
    expect(pending.peek(community_id: 1, endpoint_id: "e1", actor_id: "u1")).not_to be_nil
  end

  it "never closes another person's operation in the same room" do
    pending.register("alpha") { |_operation, _context| :ran }
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1")

    expect(pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u2")).to eq(:none)
  end

  it "takes the operation out before the handler runs, so a raise cannot leave it open" do
    pending.register("alpha") { |_operation, _context| raise "boom" }
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1")

    expect { pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1") }.to raise_error("boom")
    expect(pending.size).to eq(0)
  end

  it "forgets an operation once its window has passed" do
    now = Time.now
    clock = -> { now }
    pending = described_class.new(ttl: 60, clock: clock)
    pending.register("alpha") { |_operation, _context| :ran }
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1")

    now += 61
    expect(pending.close(community_id: 1, endpoint_id: "e1", actor_id: "u1")).to eq(:none)
  end

  it "lets a second start in the same room replace the first" do
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1", payload: { n: 1 })
    pending.open(kind: "alpha", community_id: 1, endpoint_id: "e1", actor_id: "u1", payload: { n: 2 })

    expect(pending.size).to eq(1)
    expect(pending.peek(community_id: 1, endpoint_id: "e1", actor_id: "u1").payload).to eq({ n: 2 })
  end

  describe "the MAX_OPEN eviction ceiling" do
    it "evicts the actual oldest operation, not a reopened one whose hash position never moved" do
      now = Time.now
      clock = -> { now }
      capped = described_class.new(clock: clock)
      capped.register("alpha") { |_operation, _context| :ran }

      described_class::MAX_OPEN.times do |i|
        capped.open(kind: "alpha", community_id: 1, endpoint_id: "e#{i}", actor_id: "u1")
      end

      # Reopen the very first one much later: opened_at refreshes, but a plain
      # hash reassignment leaves its iteration position wherever it started.
      now += 60
      capped.open(kind: "alpha", community_id: 1, endpoint_id: "e0", actor_id: "u1")

      # One more brand new operation pushes the total past MAX_OPEN.
      capped.open(
        kind: "alpha", community_id: 1, endpoint_id: "e#{described_class::MAX_OPEN}", actor_id: "u1"
      )

      expect(capped.peek(community_id: 1, endpoint_id: "e0", actor_id: "u1")).not_to be_nil
      expect(capped.peek(community_id: 1, endpoint_id: "e1", actor_id: "u1")).to be_nil
      expect(capped.size).to eq(described_class::MAX_OPEN)
    end
  end
end
