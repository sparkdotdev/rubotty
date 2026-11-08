# frozen_string_literal: true

require "spec_helper"

# Only the wiring: HistorySweep's own spec covers the matching and safety rules.
RSpec.describe Rubotty::Core::Runtime, "#sweep_stray_banners" do
  let(:runtime) do
    described_class.allocate.tap do |instance|
      instance.instance_variable_set(:@logger, Rubotty::Log.null)
      instance.instance_variable_set(:@adapters, {})
    end
  end

  it "never raises when the sweep itself blows up" do
    allow(Rubotty::Core::HistorySweep).to receive(:new).and_raise(RuntimeError.new("boom"))
    expect { runtime.send(:sweep_stray_banners) }.not_to raise_error
  end

  it "sweeps the live adapters and topology, and returns the removed count" do
    fake_sweep = instance_double(Rubotty::Core::HistorySweep, sweep: 2)
    allow(Rubotty::Core::HistorySweep).to receive(:new).and_return(fake_sweep)
    allow(runtime).to receive(:routing_topology).and_return(topology(room("general", endpoint("dc"))))

    expect { runtime.send(:sweep_stray_banners) }.not_to raise_error
    expect(Rubotty::Core::HistorySweep).to have_received(:new).with(
      adapters: {}, topology: kind_of(Rubotty::Core::Topology), logger: kind_of(Rubotty::TaggedLogger)
    )
  end
end
