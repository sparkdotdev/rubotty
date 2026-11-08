# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::Reaction do
  def emoji(grapheme) = described_class.new(emoji: grapheme)

  # A skin tone is part of the emoji's identity: normalise it away and a toned
  # reaction keys the same as its base, so it is dropped or mismatched crossing
  # the bridge.
  describe "skin-tone graphemes as identity" do
    let(:base)  { emoji("👍") }
    let(:tone1) { emoji("👍🏻") }
    let(:tone5) { emoji("👍🏿") }

    it "keeps the full grapheme in the key" do
      expect(tone1.key).to eq("emoji:👍🏻")
    end

    it "keys a toned emoji differently from its base" do
      expect(tone1.key).not_to eq(base.key)
    end

    it "treats two different skin tones as two different reactions" do
      expect(tone1).not_to eq(tone5)
      expect(tone1.hash).not_to eq(tone5.hash)
    end

    it "treats the same tone as equal, so set arithmetic dedupes it" do
      expect(tone1).to eq(emoji("👍🏻"))
      expect([tone1, tone5, tone1].uniq.size).to eq(2)
    end
  end

  describe "#without_skin_tone" do
    it "removes the Fitzpatrick modifier to reach the base emoji" do
      expect(emoji("👌🏽").without_skin_tone.emoji).to eq("👌")
    end

    it "leaves an untoned emoji untouched, returning the same object" do
      base = emoji("👌")
      expect(base.without_skin_tone).to be(base)
    end

    it "keeps a toned emoji that also carries a ZWJ sequence readable" do
      expect(emoji("🤷🏽‍♀️").without_skin_tone.emoji).to eq("🤷‍♀️")
    end

    it "does not disturb the variation selector, a different modifier entirely" do
      expect(emoji("❤️").without_skin_tone.emoji).to eq("❤️")
    end

    it "is inert for a custom emoji" do
      custom = described_class.new(custom_id: "1", custom_name: "parrot")
      expect(custom.without_skin_tone).to be(custom)
    end
  end

  # "Alex R [sample_owner@telegram] reacted :5373015670822804395:" reached a
  # room. Telegram names a custom emoji by id alone, so the id was all the label had.
  describe "#label" do
    it "reads a plain emoji as itself" do
      expect(emoji("👍").label).to eq("👍")
    end

    it "prefers the shortcode where the platform names one" do
      named = described_class.new(custom_id: "999", custom_name: "parrot", emoji: "🦜")
      expect(named.label).to eq(":parrot:")
    end

    it "reads a nameless custom emoji as the emoji it is drawn from" do
      drawn = described_class.new(custom_id: "5373015670822804395", emoji: "😄")
      expect(drawn.label).to eq("😄")
    end

    it "says what it is in words rather than handing a reader an id" do
      expect(described_class.new(custom_id: "5373015670822804395").label).to eq("a custom emoji")
    end

    it "keys on the id, so two custom emoji drawn from one smile stay distinct" do
      first = described_class.new(custom_id: "1", emoji: "😄")
      second = described_class.new(custom_id: "2", emoji: "😄")
      expect(first).not_to eq(second)
      expect(first.base_emoji).to eq("😄")
    end

    it "has no base emoji when it is not custom at all" do
      expect(emoji("👍").base_emoji).to be_nil
    end
  end
end
