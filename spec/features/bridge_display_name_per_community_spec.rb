# frozen_string_literal: true

require "spec_helper"

# config.display_name is the last resort DisplayName.resolve falls back to
# once a room or endpoint names no template. A community's own display_name
# block (seeded verbatim into communities.settings) wins that fallback, field by field.
RSpec.describe Rubotty::Features::Bridge do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:deployment_default) { Rubotty::Core::DisplayName.new(template: "{first_name}", fallback: "{username}") }

  subject(:bridge) do
    described_class.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, default_display_name: deployment_default
    )
  end

  def community(settings)
    instance_double(Rubotty::ControlPlane::Snapshot::Community, settings: settings)
  end

  it "uses the community's own format and fallback_format, not the deployment default" do
    scope = community({ "display_name" => { "format" => "{username}@{platform}", "fallback_format" => "{platform}" } })

    naming = bridge.send(:display_name_default, scope)

    expect(naming.template).to eq("{username}@{platform}")
    expect(naming.fallback).to eq("{platform}")
  end

  it "overrides only the field it names, leaving the other on the deployment default" do
    scope = community({ "display_name" => { "format" => "{username}" } })

    naming = bridge.send(:display_name_default, scope)

    expect(naming.template).to eq("{username}")
    expect(naming.fallback).to eq(deployment_default.fallback)
  end

  it "falls through to the deployment-wide default when the community names neither field" do
    naming = bridge.send(:display_name_default, community({}))

    expect(naming.template).to eq(deployment_default.template)
    expect(naming.fallback).to eq(deployment_default.fallback)
  end

  it "always uses the deployment-wide default on the config-only path" do
    naming = bridge.send(:display_name_default, nil)

    expect(naming.template).to eq(deployment_default.template)
    expect(naming.fallback).to eq(deployment_default.fallback)
  end
end
