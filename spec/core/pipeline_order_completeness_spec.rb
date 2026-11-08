# frozen_string_literal: true

require "spec_helper"

# Features::Catalog::PIPELINE_ORDER is what the dashboard shows as the run
# order, and nothing forces it to name everything the router really builds. A
# feature missing from it disappears from that page without a word, so the two
# lists are compared here rather than trusted.
RSpec.describe Rubotty::Features::Catalog do
  include Builders

  let(:storage) { Rubotty::Storage::Memory.new }

  let(:relay_endpoint) do
    endpoint("tg-general", adapter: :telegram, account: "bot", settings: { chat_id: "1" })
  end

  let(:adapter) do
    Class.new do
      def deliver(*) = []
      def capabilities = {}
      def name = :telegram
    end.new
  end

  # The scripting services are passed so Scripts is built too, since a
  # deployment without them simply does not add that step.
  def built_feature_names
    router = Rubotty::Core::Router.new(
      topology: topology(room("r", relay_endpoint)),
      adapters: Hash.new(adapter), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null,
      scripts: Object.new, script_pool: Object.new, warnings: Object.new,
      member_reports: Object.new, identity_directory: Object.new, keyword_watches: Object.new
    )
    router.instance_variable_get(:@pipeline).features.filter_map do |feature|
      feature.class.feature_name if feature.class.respond_to?(:feature_name)
    end.uniq
  end

  # Every Features::Base subclass that declares a feature_name: a wider set than
  # Catalog.names, since a deployment without a feature's services never builds
  # it into the pipeline at all.
  def every_feature_name
    Rubotty::Features.constants.filter_map do |const|
      value = Rubotty::Features.const_get(const)
      next unless value.is_a?(Class) && value < Rubotty::Features::Base
      next unless value.respond_to?(:feature_name)

      value.feature_name
    end.uniq
  end

  describe "PIPELINE_ORDER" do
    # Every step the router really builds, whether or not it is configurable.
    # Comparing against the catalog alone was what let identify_topic and
    # disabled_command_notice run undeclared.
    it "names every feature the router builds into the pipeline" do
      expect(built_feature_names - described_class::PIPELINE_ORDER).to be_empty
    end

    it "names only real features" do
      expect(described_class::PIPELINE_ORDER - every_feature_name).to be_empty
    end

    it "names each feature once" do
      expect(described_class::PIPELINE_ORDER.uniq).to eq(described_class::PIPELINE_ORDER)
    end

    it "puts the moderated-room gate before every ordinary content feature" do
      names = built_feature_names

      expect(names.index("moderated_room")).to be < names.index("word_filter")
      expect(names.index("moderated_room")).to be < names.index("bridge")
    end

    # Scheduled announcements are woken by the clock, so no pipeline step
    # carries that name and the order is right to leave it out.
    it "leaves out a feature nothing in the pipeline carries" do
      clock_driven = Rubotty::Core::AnnouncementScheduler::FEATURE

      expect(built_feature_names).not_to include(clock_driven)
      expect(described_class::PIPELINE_ORDER).not_to include(clock_driven)
    end
  end
end
