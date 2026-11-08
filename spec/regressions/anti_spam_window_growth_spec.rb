# frozen_string_literal: true

require "spec_helper"

# Both anti-spam windows live in memory for the life of the process. Pruning
# what is inside a bucket is not enough: the bucket itself has to go, or a busy
# bridge keeps one per person per channel forever.
RSpec.describe Rubotty::Features::AntiSpam do
  include Builders

  let(:tg) { endpoint("tg") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapters) { Hash.new(Fakes::RecordingAdapter.new(own_id: "bot-1")) }

  let(:time_box) { [Time.now.to_f] }
  let(:clock) { -> { Time.at(time_box[0]) } }
  def advance(seconds) = (time_box[0] += seconds)

  subject(:feature) do
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, clock: clock
    )
  end

  # Flood on, duplicates off, so only the flood window is exercised.
  let(:config) { { "flood_threshold" => 5, "flood_window" => 5, "duplicate_threshold" => 0 } }

  def post(author_id:, text: "hello there")
    message = message(tg, text: text, native_id: "#{author_id}-#{time_box[0]}",
                          author: author(native_id: author_id, username: "user_#{author_id}"))
    feature.call(Rubotty::Features::Context.new(message: message, config: config))
  end

  def flood_buckets = feature.instance_variable_get(:@flood)

  describe "the flood window" do
    it "forgets an author whose messages have all aged out" do
      50.times { |i| post(author_id: "u#{i}") }
      expect(flood_buckets.size).to eq(50)

      advance(60)
      post(author_id: "current")

      expect(flood_buckets.keys.size).to eq(1)
    end

    it "keeps an author still inside the window" do
      post(author_id: "u1")
      advance(1)
      post(author_id: "u2")

      expect(flood_buckets.size).to eq(2)
    end

    # The cap is the backstop for the case ageing out never reaches: a room
    # where enough distinct people are talking inside one window.
    it "never grows past the cap" do
      stub_const("#{described_class}::MAX_TRACKED_FLOOD_KEYS", 10)

      25.times { |i| post(author_id: "u#{i}") }

      expect(flood_buckets.size).to be <= 10
    end

    it "still counts a flood from one author while others are pruned around them" do
      100.times { |i| post(author_id: "other#{i}") }
      advance(60)

      outcome = nil
      5.times { outcome = post(author_id: "flooder") }

      expect(outcome.value).not_to be_empty
    end
  end
end
