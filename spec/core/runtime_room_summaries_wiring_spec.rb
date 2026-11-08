# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Runtime, "room summaries wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def build_runtime(store: sequel_store, env: ControlPlaneHelpers::CONFIG_ENV)
    described_class.new(config: config, logger: Rubotty::Log.null, storage: store, env: env).build
  end

  it "wires the configured integration and durable handlers on the control-plane path" do
    runtime = build_runtime
    integrations = Rubotty::ControlPlane::Integrations.new(models: runtime.send(:control_plane_models))
    integrations.save(name: "openarc", url: "http://openarc.example")

    expect(runtime.room_summaries).to be_a(Rubotty::RoomSummaries::Service)
    expect(runtime.room_summaries.instance_variable_get(:@settings).url).to eq("http://openarc.example")
    expect(runtime.durable_scheduler.handler?(Rubotty::RoomSummaries::Service::KIND)).to be(true)
    expect(runtime.semantic_analysis).to be_a(Rubotty::SemanticAnalysis::Service)
    expect(runtime.durable_scheduler.handler?(Rubotty::SemanticAnalysis::Service::KIND)).to be(true)
  end

  it "does not create a retained-text service without the control plane" do
    runtime = build_runtime(store: Rubotty::Storage::Memory.new)

    expect(runtime.room_summaries).to be_nil
  end
end
