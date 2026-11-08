# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Watchdog::Runner do
  let(:tg) { endpoint("tg") }
  let(:context) { Rubotty::Features::Context.new(message: message(tg)) }
  let(:removal) { instance_spy(Rubotty::Watchdog::Removal) }

  # A watchdog stub that returns a fixed verdict (or raises, when handed a Proc)
  # and remembers whether it was consulted, so a spec can prove the runner stops
  # at the first removal and never reaches the ones behind it.
  let(:watchdog_class) do
    Class.new do
      attr_reader :calls

      def initialize(behaviour)
        @behaviour = behaviour
        @calls = 0
      end

      def name = "stub"

      def evaluate(context)
        @calls += 1
        @behaviour.is_a?(Proc) ? @behaviour.call(context) : @behaviour
      end
    end
  end

  def passing = watchdog_class.new(Rubotty::Watchdog::Verdict.pass)
  def removing(reason = "gone", metadata = {}) = watchdog_class.new(Rubotty::Watchdog::Verdict.remove(reason, metadata: metadata))
  def raising = watchdog_class.new(->(_context) { raise "boom" })

  def runner(*watchdogs) = described_class.new(watchdogs: watchdogs, removal: removal, logger: Rubotty::Log.null)

  before { allow(removal).to receive(:apply).and_return([ref("tg", "1")]) }

  it "continues when no watchdog votes to remove, leaving the removal untouched" do
    outcome = runner(passing, passing).run(context)
    expect(outcome).to be_continue
    expect(removal).not_to have_received(:apply)
  end

  it "applies the removal flow and halts on the first removal verdict" do
    outcome = runner(passing, removing("no cross-posting")).run(context)
    expect(outcome).to be_halt
    expect(outcome.value).to eq([ref("tg", "1")])
    expect(removal).to have_received(:apply).with(hash_including(context: context, reason: "no cross-posting"))
  end

  it "forwards the verdict's metadata into the audit trail" do
    runner(removing("gone", { channels: 4, threshold: 2 })).run(context)
    expect(removal).to have_received(:apply).with(hash_including(metadata: { channels: 4, threshold: 2 }))
  end

  it "stops at the first removal, never consulting the watchdogs behind it" do
    first = removing
    second = passing
    runner(first, second).run(context)
    expect(first.calls).to eq(1)
    expect(second.calls).to eq(0)
  end

  it "removes exactly once even when several watchdogs would remove" do
    runner(removing("first"), removing("second")).run(context)
    expect(removal).to have_received(:apply).once
    expect(removal).to have_received(:apply).with(hash_including(reason: "first"))
  end

  it "fails open: a watchdog that raises is treated as a pass, so the next still runs" do
    outcome = runner(raising, removing("still caught")).run(context)
    expect(outcome).to be_halt
    expect(removal).to have_received(:apply).with(hash_including(reason: "still caught"))
  end

  it "continues when the only watchdog raises, so one bad watchdog cannot halt the chain" do
    outcome = runner(raising).run(context)
    expect(outcome).to be_continue
    expect(removal).not_to have_received(:apply)
  end
end
