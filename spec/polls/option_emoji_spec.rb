# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Polls::OptionEmoji do
  def reaction(emoji) = Rubotty::Core::Reaction.new(emoji: emoji)

  it "has exactly one keycap per option a poll can hold" do
    expect(described_class::KEYCAPS.size).to eq(Rubotty::Polls::Poll::MAX_OPTIONS)
  end

  describe ".for_position" do
    it "answers the keycap for a position inside the vocabulary" do
      expect(described_class.for_position(1)).to eq(reaction(described_class::KEYCAPS.first))
      expect(described_class.for_position(9)).to eq(reaction(described_class::KEYCAPS.last))
    end

    it "answers nothing outside it" do
      expect(described_class.for_position(0)).to be_nil
      expect(described_class.for_position(10)).to be_nil
      expect(described_class.for_position(nil)).to be_nil
    end
  end

  describe ".for_count" do
    it "seeds one keycap per option, leftmost first" do
      expect(described_class.for_count(3)).to eq((1..3).map { |i| described_class.for_position(i) })
    end

    it "never seeds more than the vocabulary holds" do
      expect(described_class.for_count(50).size).to eq(described_class::KEYCAPS.size)
      expect(described_class.for_count(0)).to be_empty
    end
  end

  describe ".position_for" do
    it "reads a keycap back to its position" do
      expect(described_class.position_for(reaction(described_class::KEYCAPS[2]))).to eq(3)
    end

    it "reads one that arrived without its variation selector" do
      stripped = reaction(described_class::KEYCAPS[4]).without_variation_selector

      expect(described_class.position_for(stripped)).to eq(5)
    end

    it "ignores anything outside the vocabulary" do
      expect(described_class.position_for(reaction("👍"))).to be_nil
      expect(described_class.position_for(nil)).to be_nil
      expect(described_class.position_for(Rubotty::Core::Reaction.new(custom_id: "42"))).to be_nil
    end
  end
end
