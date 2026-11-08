# frozen_string_literal: true

require "spec_helper"

# The LibreTranslate connection the dashboard's Integrations page writes
# reaches the running translation relay through
# Runtime#translation_settings, with no restart needed: the same live reread
# every other control-plane-backed setting gets.
RSpec.describe Rubotty::Core::Runtime, "translation settings wiring", :control_plane do
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

  it "reads a stored connection over the control plane once one is saved" do
    runtime = build_runtime
    integrations = Rubotty::ControlPlane::Integrations.new(models: runtime.send(:control_plane_models))
    integrations.save(name: "libretranslate", url: "https://lt.example", api_key: "shh")

    settings = runtime.send(:translation_settings)

    expect(settings.url).to eq("https://lt.example")
    expect(settings.api_key).to eq("shh")
  end

  it "falls back to the environment once the control plane is active but nothing has been saved" do
    runtime = build_runtime(env: ControlPlaneHelpers::CONFIG_ENV.merge(
      "RUBOTTY_LIBRETRANSLATE_URL" => "http://env.example"
    ))

    expect(runtime.send(:translation_settings).url).to eq("http://env.example")
  end

  it "falls back to a bare, env-only Settings with no control plane at all" do
    runtime = build_runtime(store: Rubotty::Storage::Memory.new)
    expect(runtime.control_plane?).to be(false)

    expect(runtime.send(:translation_settings)).to be_a(Rubotty::Translation::Settings)
  end

  it "wires the live settings into the built translation relay" do
    runtime = build_runtime
    integrations = Rubotty::ControlPlane::Integrations.new(models: runtime.send(:control_plane_models))
    integrations.save(name: "libretranslate", url: "https://lt.example")

    expect(runtime.translation_relay.instance_variable_get(:@settings).url).to eq("https://lt.example")
  end

  it "hands the built translation relay the same live people the router reads nicknames from" do
    runtime = build_runtime

    expect(runtime.translation_relay.instance_variable_get(:@people)).to be(runtime.send(:routing_people))
  end
end
