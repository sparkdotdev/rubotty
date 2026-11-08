# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Watchdog::Verdict do
  it "passes by default, carrying no reason" do
    verdict = described_class.pass
    expect(verdict).to be_pass
    expect(verdict).not_to be_remove
    expect(verdict.reason).to be_nil
  end

  it "removes, carrying the reason and any metadata" do
    verdict = described_class.remove("no cross-posting", metadata: { channels: 3 })
    expect(verdict).to be_remove
    expect(verdict).not_to be_pass
    expect(verdict.reason).to eq("no cross-posting")
    expect(verdict.metadata).to eq(channels: 3)
  end

  it "defaults metadata to an empty hash" do
    expect(described_class.remove("gone").metadata).to eq({})
  end

  it "is frozen: a verdict is a decision, not a mutable accumulator" do
    expect(described_class.pass).to be_frozen
  end
end
