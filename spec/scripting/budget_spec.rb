# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# What one invocation may spend. Held apart from the pipe on purpose, so the arithmetic
# that decides whether a script is cut off can be read without a Lua interpreter anywhere
# near it. The old version was a single counter in the middle of the frame loop, compared
# against a round-trip cost that measurement later put at 0.003 ms.
RSpec.describe Rubotty::Scripting::Budget do
  subject(:budget) { described_class.new(max_calls: 5, max_broadcasts: 2) }

  it "charges nothing for a call that only touches a string" do
    20.times { expect(budget.charge(:free)).to eq(described_class::ALLOWED) }

    expect(budget.calls).to be_zero
  end

  it "charges an ordinary call against the total" do
    5.times { expect(budget.charge(:read)).to eq(described_class::ALLOWED) }

    expect(budget.charge(:read)).to eq(described_class::SPENT)
  end

  # The whole point of the split: a script may notify twice and go on working.
  it "stops a broadcast well before the total runs out" do
    expect(budget.charge(:broadcast)).to eq(described_class::ALLOWED)
    expect(budget.charge(:broadcast)).to eq(described_class::ALLOWED)

    expect(budget.charge(:broadcast)).to eq(described_class::BROADCAST_SPENT)
    expect(budget.calls).to eq(3)
  end

  # A refused broadcast still cost the round trip, and a script that ignores the
  # refusal and loops should still meet the runaway guard rather than spinning
  # for free until the deadline.
  it "counts a refused broadcast against the total anyway" do
    5.times { budget.charge(:broadcast) }

    expect(budget.charge(:broadcast)).to eq(described_class::SPENT)
  end

  it "leaves an ordinary call alone once the broadcasts are gone" do
    3.times { budget.charge(:broadcast) }

    expect(budget.charge(:read)).to eq(described_class::ALLOWED)
  end

  # The old message named no function at all, so an operator got a dead script
  # and a hundred lines of Lua to guess from.
  it "names the function in both answers" do
    expect(budget.broadcast_refusal("notify")).to include("notify")
    expect(budget.exhausted_reason("recall")).to include("recall").and include("5")
  end

  it "takes its ceilings from the registry that will serve the calls" do
    registry = Rubotty::Scripting::Registry.new(max_calls: 9, max_broadcasts: 1)

    expect(described_class.for(registry).max_calls).to eq(9)
    expect(described_class.for(registry).max_broadcasts).to eq(1)
  end

  it "falls back to the defaults for an invocation with no host functions" do
    expect(described_class.for(nil).max_calls).to eq(Rubotty::Scripting::Registry::DEFAULT_MAX_CALLS)
  end
end
