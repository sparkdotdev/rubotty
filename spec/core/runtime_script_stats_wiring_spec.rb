# frozen_string_literal: true

require "spec_helper"

# A function with no service behind it is dropped from the sandbox, so while the
# runtime built a ScriptStats and never passed it, every statistics call passed
# the save time check and then died on the first real message.
RSpec.describe Rubotty::Core::Runtime, "script statistics wiring", :control_plane do
  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def runtime
    described_class.new(config: config, logger: Rubotty::Log.null, storage: sequel_store,
                        env: ControlPlaneHelpers::CONFIG_ENV).build
  end

  # Taken from the feature the router built; a saved row goes in because the memo
  # functions bind to the script that owns the memory.
  def served_names(built)
    feature = built.router.instance_variable_get(:@pipeline).features
                   .find { |candidate| candidate.is_a?(Rubotty::Features::Scripts) }
    return nil if feature.nil?

    community = built.registry.current.communities.first
    context = Rubotty::Features::Context.new(message: nil, community: community)
    row = built.instance_variable_get(:@scripts)
               .save(community: community, name: "probe", kind: "processor",
                     source: "return nil", trigger_type: "always")
    feature.instance_variable_get(:@registry_for).call(context, row).names
  end

  it "builds a real statistics service" do
    expect(runtime.instance_variable_get(:@script_stats)).to be_a(Rubotty::ControlPlane::ScriptStats)
  end

  it "builds the analytics community_stats reads from" do
    expect(runtime.instance_variable_get(:@analytics)).to be_a(Rubotty::ControlPlane::Analytics)
  end

  it "serves the three statistics functions to a script, rather than dropping them" do
    names = served_names(runtime)
    skip "no Lua on this machine, so the scripts feature was not built" if names.nil?

    expect(names).to include("increment_stat", "record_stat", "community_stats")
  end

  # A day's runs is a row per script, and nothing else ever removes one, so a
  # sweep the runtime forgets to register is a table that only grows.
  it "registers the daily sweep that ages a script's run counts out" do
    built = runtime
    skip "no Lua on this machine, so the scripts service was not built" if built.instance_variable_get(:@scripts).nil?

    expect(built.durable_scheduler.handler?(Rubotty::ControlPlane::Scripts::RUN_PRUNE_KIND)).to be(true)
  end

  # The save time check stubs the whole catalog, so anything the runtime forgets
  # passes it and fails later.
  it "serves everything the save time check says a script may call" do
    names = served_names(runtime)
    skip "no Lua on this machine, so the scripts feature was not built" if names.nil?

    expect(Rubotty::Scripting::HostFunctions.callable_names - names).to be_empty
  end
end
