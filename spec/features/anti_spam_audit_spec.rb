# frozen_string_literal: true

require "spec_helper"

# Anti-spam writes a durable audit row and explains itself. remove_everywhere does not
# audit; the row is written by Watchdog::Removal's notice seam, which anti-spam never
# called, so the audit sink injected at construction was dead. The notice field had no
# default either, so on a stock config a member's message vanished with nothing said.
RSpec.describe "anti-spam auditing and its default notice (#396)" do
  let(:tg) { endpoint("tg") }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }

  let(:recorder) do
    Class.new do
      attr_reader :events

      def initialize = @events = []

      def record(**kwargs) = (@events << kwargs) && kwargs
    end.new
  end

  let(:posted) { [] }

  # Records what the notice would have said rather than sending it.
  let(:ephemeral) do
    Class.new do
      def initialize(sink) = @sink = sink

      def post(endpoints:, body:, name:, delete_after:)
        @sink << { text: body.text, name: name, delete_after: delete_after }
        []
      end
    end.new(posted)
  end

  let(:feature) do
    Rubotty::Features::AntiSpam.new(
      topology: topology(room("r", tg)), adapters: Hash.new(adapter),
      storage: Rubotty::Storage::Memory.new, logger: Rubotty::Log.null,
      ephemeral: ephemeral, audit: recorder
    )
  end

  def community = instance_double(Rubotty::ControlPlane::Snapshot::Community, slug: "acme", operators: nil)

  # Four identical messages past the default duplicate threshold, long enough
  # to clear the minimum length.
  def flood(config = {})
    outcome = nil
    5.times do |i|
      msg = message(tg, text: "buy my coin now", native_id: "m#{i}", author: author(native_id: "55"))
      outcome = feature.call(
        Rubotty::Features::Context.new(message: msg, community: community, config: config)
      )
    end
    outcome
  end

  it "writes a durable audit row when it removes a message" do
    flood

    expect(recorder.events).not_to be_empty
    expect(recorder.events.last).to include(source: "anti_spam", community: "acme", action: "delete")
  end

  it "names the author it acted on in the row" do
    flood

    expect(recorder.events.last[:subject_native_id]).to eq("55")
  end

  it "records the reason, so the log says which mode tripped" do
    flood

    expect(recorder.events.last[:reason]).to include("anti-spam")
  end

  it "tells the author why the message went, without any config" do
    flood

    expect(posted.last[:text]).to eq(Rubotty::Features::AntiSpam::DEFAULT_NOTICE)
  end

  it "still lets an operator turn the notice off by blanking it" do
    flood({ "notice" => "" })

    expect(posted).to be_empty
  end

  it "still prefers an operator's own wording" do
    flood({ "notice" => "no spam here please" })

    expect(posted.last[:text]).to eq("no spam here please")
  end
end
