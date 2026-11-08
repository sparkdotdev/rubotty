# frozen_string_literal: true

require "spec_helper"

# The catalog's declared order, checked against the pipeline the router really builds. A Lua
# processor runs after the word filter, so text it rewrites is never screened again.
RSpec.describe "the feature pipeline's run order" do
  let(:storage) { Rubotty::Storage::Memory.new }

  let(:endpoint) do
    Rubotty::Core::Endpoint.new(id: "tg-general", adapter_name: :telegram, account: "bot",
                                settings: { chat_id: "1" })
  end

  let(:adapter) do
    Class.new do
      def deliver(*) = []
      def capabilities = {}
      def name = :telegram
    end.new
  end

  # Scripts is only built when the runtime made the scripting services, so they are passed
  # here or the pipeline has no Lua processor to place.
  def built_features
    router = Rubotty::Core::Router.new(
      topology: topology(room("r", endpoint)),
      adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      scripts: Object.new, script_pool: Object.new, warnings: Object.new,
      member_reports: Object.new, identity_directory: Object.new, keyword_watches: Object.new
    )
    router.instance_variable_get(:@pipeline).features
  end

  # Every built feature's name, unfiltered. Filtering to names already in the constant was
  # what let six features run without being declared: a missing one simply vanished from
  # the comparison.
  def ordered_names
    built_features.map do |feature|
      feature.class.respond_to?(:feature_name) ? feature.class.feature_name : feature.class.name
    end
  end

  it "declares every feature that really runs" do
    expect(ordered_names.uniq - Rubotty::Features::Catalog::PIPELINE_ORDER).to be_empty
  end

  it "runs them in the order the catalog declares" do
    seen = ordered_names.uniq

    expect(seen).to eq(Rubotty::Features::Catalog::PIPELINE_ORDER & seen)
  end

  # uniq above hides a name that runs twice, which "events" legitimately does,
  # so the raw sequence is checked for monotonicity separately: each feature's
  # position in the declared order may repeat but must never go backwards.
  it "never runs a feature earlier than the one before it" do
    positions = ordered_names.map { |name| Rubotty::Features::Catalog::PIPELINE_ORDER.index(name) }

    expect(positions).to eq(positions.sort)
  end

  it "screens with the word filter before a script can rewrite anything" do
    seen = ordered_names

    expect(seen.index("word_filter")).to be < seen.index("scripts")
  end

  it "runs scripts last before the bridge, so a rewrite still reaches every platform" do
    seen = ordered_names

    expect(seen.index("scripts")).to be < seen.index("bridge")
    expect(seen.last).to eq("bridge")
  end

  # Every Features::Base subclass that declares a feature_name: a wider set than
  # PIPELINE_ORDER, since a deployment without a feature's services (Scripts,
  # say) never builds it.
  def every_feature_name
    Rubotty::Features.constants.filter_map do |const|
      value = Rubotty::Features.const_get(const)
      next unless value.is_a?(Class) && value < Rubotty::Features::Base
      next unless value.respond_to?(:feature_name)

      value.feature_name
    end.uniq
  end

  # A deployment without a feature's services does not build it, so the declared order is
  # a superset of what runs.
  it "names only real features" do
    expect(Rubotty::Features::Catalog::PIPELINE_ORDER - every_feature_name).to be_empty
  end
end
