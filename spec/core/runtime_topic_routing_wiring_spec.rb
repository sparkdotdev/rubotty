# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Runtime, "topic routing wiring", :control_plane do
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

  it "wires the routing service, its durable handler and the rows a move needs" do
    runtime = build_runtime
    integrations = Rubotty::ControlPlane::Integrations.new(models: runtime.send(:control_plane_models))
    integrations.save(name: "openarc", url: "http://openarc.example")

    expect(runtime.topic_router).to be_a(Rubotty::SemanticAnalysis::TopicRouter)
    expect(runtime.topic_router.instance_variable_get(:@settings).url).to eq("http://openarc.example")
    expect(runtime.topic_router.instance_variable_get(:@redirections)).not_to be_nil
    expect(runtime.durable_scheduler.handler?(Rubotty::SemanticAnalysis::TopicRouter::KIND)).to be(true)
  end

  # Without these two a room set to announce its findings announces nothing,
  # which is the silence the setting exists to end.
  it "wires the DM audience and the cleanup an announced finding needs" do
    runtime = build_runtime

    expect(runtime.topic_router.instance_variable_get(:@admin_notifier)).not_to be_nil
    expect(runtime.topic_router.instance_variable_get(:@cleanup)).not_to be_nil
  end

  it "leaves the paced worker that carries out a move registered as well" do
    runtime = build_runtime

    expect(runtime.durable_scheduler.handler?(Rubotty::Features::Redirection::KIND)).to be(true)
  end

  it "creates no routing service without the control plane" do
    runtime = build_runtime(store: Rubotty::Storage::Memory.new)

    expect(runtime.topic_router).to be_nil
  end

  # Both toggles are off in the catalog, so a deployment that upgrades into this
  # feature does nothing differently until somebody ticks the first of them.
  it "ships both switches off" do
    expect(Rubotty::Features::TopicRouting.default_enabled?).to be(false)
    expect(Rubotty::Features::TopicRoutingMoves.default_enabled?).to be(false)
  end
end
