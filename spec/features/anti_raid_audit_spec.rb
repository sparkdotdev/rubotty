# frozen_string_literal: true

require "spec_helper"

# Anti-raid writes a durable audit row. The router used to never pass it an audit sink at
# all, so a lockdown left nothing but a log line, and filtering the moderation log by
# source never returned anti_raid.
RSpec.describe Rubotty::Features::AntiRaid, "audit rows" do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

  let(:recorder) do
    Class.new do
      attr_reader :events

      def initialize = @events = []

      def record(**kwargs) = (@events << kwargs) && kwargs
    end.new
  end

  let(:feature) do
    described_class.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter),
      storage: Rubotty::Storage::Memory.new, logger: Rubotty::Log.null,
      ephemeral: Rubotty::Core::EphemeralMessage.new(
        adapters: Hash.new(adapter), session_id: "s",
        topology: topology(room("r", tg)), logger: Rubotty::Log.null
      ),
      audit: recorder
    )
  end

  def community = instance_double(Rubotty::ControlPlane::Snapshot::Community, slug: "acme", operators: nil)

  def flood(count, config)
    count.times do |i|
      msg = message(tg, text: "", native_id: (i + 1).to_s, kind: :join, author: author(native_id: "u#{i}"))
      feature.call(Rubotty::Features::Context.new(message: msg, community: community, config: config))
    end
  end

  it "records the lockdown as a durable row" do
    flood(5, { join_threshold: 5, window: 30 })

    tripped = recorder.events.find { |e| e[:action] == "tripped" }
    expect(tripped).to include(source: "anti_raid", community: "acme")
    expect(tripped[:reason]).to include("lockdown")
  end

  it "records the containment applied to each joiner during a lockdown" do
    flood(6, { join_threshold: 5, window: 30, action: "kick" })

    kicked = recorder.events.select { |e| e[:action] == "kick" }
    expect(kicked).not_to be_empty
    expect(kicked.last[:subject_native_id]).to eq("u5")
  end

  it "writes nothing at all below the threshold" do
    flood(3, { join_threshold: 5, window: 30 })

    expect(recorder.events).to be_empty
  end
end
