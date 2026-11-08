# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Runtime, "script endpoint shutdown" do
  it "closes endpoint workers before adapters and storage are stopped" do
    stopped = []
    runtime = described_class.allocate
    runtime.instance_variable_set(:@logger, Rubotty::Log.null)
    endpoints = double("endpoints")
    adapter = double("adapter")
    storage = double("storage")
    allow(endpoints).to receive(:close) { stopped << :endpoints }
    allow(adapter).to receive(:stop) { stopped << :adapter }
    allow(storage).to receive(:close) { stopped << :storage }
    runtime.instance_variable_set(:@script_endpoints, endpoints)
    runtime.instance_variable_set(:@adapters, { [:fake, "default"] => adapter })
    runtime.instance_variable_set(:@storage, storage)

    expect(runtime.stop).to eq(runtime)
    expect(stopped).to eq(%i[endpoints adapter storage])
    runtime.stop
    expect(stopped).to eq(%i[endpoints adapter storage])
  end
end
