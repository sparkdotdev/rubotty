# frozen_string_literal: true

require "spec_helper"

# @windows holds one sliding join-time array per channel scope. Rejecting stale
# entries out of an array is not enough on its own: the scope key itself has to
# go, or a long-running bridge across many channels, or one whose rooms get
# created and abandoned, accumulates one entry forever.
RSpec.describe Rubotty::Features::AntiRaid do
  include Builders

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:topo) { topology(*(0..199).map { |i| room("r#{i}", endpoint("ch#{i}")) }) }

  let(:time_box) { [Time.now.to_f] }
  let(:clock) { -> { Time.at(time_box[0]) } }
  def advance(seconds) = (time_box[0] += seconds)

  subject(:feature) do
    described_class.new(
      topology: topo, adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, clock: clock
    )
  end

  # A threshold above what any single test sends, so nobody trips a lockdown
  # and the sliding window is all that is exercised.
  let(:config) { { "join_threshold" => 1000, "window" => 5 } }

  def post(scope)
    origin = endpoint("ch#{scope}")
    joiner = message(origin, text: "", native_id: "#{scope}-#{time_box[0]}", kind: :join,
                              author: author(native_id: "u#{scope}"))
    feature.call(Rubotty::Features::Context.new(message: joiner, config: config))
  end

  def windows = feature.instance_variable_get(:@windows)

  describe "the join window" do
    it "forgets a channel whose joins have all aged out" do
      50.times { |i| post(i) }
      expect(windows.size).to eq(50)

      advance(60)
      post("current")

      expect(windows.keys.size).to eq(1)
    end

    it "keeps a channel still inside its window" do
      post(1)
      advance(1)
      post(2)

      expect(windows.size).to eq(2)
    end

    # The cap is the backstop for the case ageing out never reaches: many
    # distinct channels each seeing a join inside the same window.
    it "never grows past the cap" do
      stub_const("#{described_class}::MAX_TRACKED_WINDOWS", 10)

      25.times { |i| post(i) }

      expect(windows.size).to be <= 10
    end
  end
end
