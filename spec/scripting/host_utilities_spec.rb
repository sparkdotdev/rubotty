# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Randomness in bulk. One number per host call meant dealing a hand or shuffling a deck
# cost more calls than an invocation is allowed, so both were impossible rather than merely
# expensive. The shipped roll example worked around it by deriving the numbers from the
# message text, which made every result predictable from the message that asked for it.
RSpec.describe Rubotty::Scripting::HostFunctions, "randomness" do
  # Seeded, so an example asserting a shape is not also asserting luck.
  let(:random) { described_class.random_handler(generator: Random.new(4)) }
  let(:shuffle) { described_class.shuffle_handler(generator: Random.new(4)) }

  describe "one number, which is what it always did" do
    it "answers within the range, both ends included" do
      expect(Array.new(50) { random.call(1, 6) }.uniq.sort).to eq((1..6).to_a)
    end

    it "takes the range the wrong way round rather than answering nonsense" do
      expect(random.call(6, 1)).to be_between(1, 6)
    end
  end

  describe "a handful at once" do
    it "answers a list of the length asked for" do
      drawn = random.call({ "count" => 5, "min" => 1, "max" => 6 })

      expect(drawn.length).to eq(5)
      expect(drawn).to all(be_between(1, 6))
    end

    it "draws without replacement when asked" do
      drawn = random.call({ "count" => 10, "min" => 1, "max" => 10, "unique" => true })

      expect(drawn.sort).to eq((1..10).to_a)
    end

    # This answers a list, so it has no second return value to carry a reason.
    # Cutting to the range beats refusing silently or repeating a "unique" draw.
    it "cuts a unique draw to the range when the range is narrower" do
      expect(random.call({ "count" => 10, "min" => 1, "max" => 3, "unique" => true }).length).to eq(3)
    end

    it "holds one draw to the ceiling, so a frame stays writable" do
      drawn = random.call({ "count" => described_class::MAX_RANDOM_COUNT + 500, "min" => 1, "max" => 6 })

      expect(drawn.length).to eq(described_class::MAX_RANDOM_COUNT)
    end

    it "draws one when a count is missing rather than none" do
      expect(random.call({ "min" => 1, "max" => 6 }).length).to eq(1)
    end

    # A unique draw used to materialize the whole min..max range before sampling
    # from it, so a narrow count against a huge range allocated an array the size
    # of the range instead of the count. This pins that a wide range no longer
    # builds the range at all; a regression here shows up as a timeout, not a red assertion.
    it "draws unique numbers from a wide range without building the range" do
      drawn = random.call({ "count" => 5, "min" => 1, "max" => 999_999_999_999_999_999, "unique" => true })

      expect(drawn.length).to eq(5)
      expect(drawn.uniq.length).to eq(5)
      expect(drawn).to all(be_between(1, 999_999_999_999_999_999))
    end
  end

  describe "shuffling" do
    it "answers a new list holding exactly what it was given" do
      original = %w[ada grace alan edsger barbara]
      reordered = shuffle.call(original)

      expect(reordered).to match_array(original)
      expect(original).to eq(%w[ada grace alan edsger barbara])
    end

    # A Lua table with a gap arrives as a mapping rather than a list, and
    # "shuffle this" still has an obvious meaning.
    it "reads a table that arrived as a mapping in its own numeric key order" do
      expect(shuffle.call({ "2" => "b", "1" => "a", "3" => "c" })).to match_array(%w[a b c])
    end

    it "leaves a list past the ceiling alone rather than quietly truncating it" do
      long = Array.new(described_class::MAX_SHUFFLE_LENGTH + 1, "x")

      expect(shuffle.call(long).length).to eq(long.length)
    end
  end
end

# The gate has to see the same shapes production does, or it fails a script for
# a fault entirely of its own. A stubbed random answering one number would fail
# every rule that loops over the list.
RSpec.describe Rubotty::Scripting::SmokeTest, "what a probe is handed" do
  let(:registry) { described_class::CountingRegistry.new }

  it "runs the real randomness, so a script dealing a hand is checked on a hand" do
    expect(registry.call("random", [{ "count" => 3, "min" => 1, "max" => 6 }]).length).to eq(3)
  end

  it "runs the real folding, so a rule comparing words is checked on real text" do
    expect(registry.call("fold", ["AÇÃO"])).to eq("acao")
    expect(registry.call("chars", ["olá"]).length).to eq(3)
  end

  # Two runs of the gate over the same script have to agree, or a failure cannot
  # be looked at twice.
  it "starts every check from the same seed" do
    first = described_class::CountingRegistry.new.call("random", [{ "count" => 5, "min" => 1, "max" => 1000 }])
    second = described_class::CountingRegistry.new.call("random", [{ "count" => 5, "min" => 1, "max" => 1000 }])

    expect(first).to eq(second)
  end

  it "shows a script the careful branch of what a room can do" do
    answer = registry.call("room_capabilities", [])

    expect(answer["reactions"]).to be(false)
    expect(answer["longest_message"]).to be_a(Integer)
  end
end
