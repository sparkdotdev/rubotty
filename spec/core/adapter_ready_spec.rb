# frozen_string_literal: true

require "spec_helper"

# An adapter whose #start returns before its transport reports ready must not let
# the startup banner race ahead of it.
RSpec.describe Rubotty::Core::Runtime, "#await_adapters_ready" do
  let(:runtime) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@logger, Rubotty::Log.null)
    end
  end

  # #running? flips true only once a caller calls #settle, standing in for a
  # gateway connect that finishes after #start returned.
  class SlowAdapter
    def initialize
      @running = false
    end

    def running? = @running
    def settle = @running = true
    def adapter_name = "discord"
  end

  # Nothing is pending, so the poll must never run at all. A poll interval no join
  # would wait out means a single sleep leaves the call parked instead of returning.
  it "returns immediately when every adapter is already running" do
    stub_const("Rubotty::Core::Runtime::ADAPTER_READY_POLL_INTERVAL", 60)
    adapter = SlowAdapter.new
    adapter.settle

    waiter = Thread.new { runtime.send(:await_adapters_ready, [adapter]) }

    expect(waiter.join(5)).to be(waiter)
  end

  it "waits for an adapter that becomes ready shortly after start" do
    adapter = SlowAdapter.new
    Thread.new do
      sleep 0.1
      adapter.settle
    end

    runtime.send(:await_adapters_ready, [adapter])

    expect(adapter.running?).to be(true)
  end

  it "gives up after the bounded timeout rather than blocking boot forever" do
    stub_const("Rubotty::Core::Runtime::ADAPTER_READY_TIMEOUT", 0.1)
    stub_const("Rubotty::Core::Runtime::ADAPTER_READY_POLL_INTERVAL", 0.02)
    adapter = SlowAdapter.new # never settles

    expect { runtime.send(:await_adapters_ready, [adapter]) }.not_to raise_error
    expect(adapter.running?).to be(false)
  end

  it "is a no-op for an empty list" do
    expect { runtime.send(:await_adapters_ready, []) }.not_to raise_error
  end
end
