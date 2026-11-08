# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Telegram::Reactions do
  subject(:reactions) { described_class }

  def reaction(emoji) = Rubotty::Core::Reaction.new(emoji: emoji)

  describe "the whitelist" do
    it "accepts an emoji Telegram permits" do
      expect(reactions.allowed?("👍")).to be(true)
    end

    it "rejects an emoji Telegram does not permit" do
      expect(reactions.allowed?("🥑")).to be(false)
    end

    it "matches the documented size" do
      expect(described_class::ALLOWED.size).to eq(73)
      expect(described_class::ALLOWED.uniq.size).to eq(described_class::ALLOWED.size)
    end
  end

  # Telegram's whitelist spells several emoji without U+FE0F while Discord sends
  # them with it, so a naive comparison fails and the API rejects the reaction.
  describe "variation selector normalisation" do
    it "accepts a heart sent with the variation selector" do
      expect(reactions.normalise(reaction("❤️"))).to eq("❤")
    end

    it "accepts a heart sent without it" do
      expect(reactions.normalise(reaction("❤"))).to eq("❤")
    end

    it "handles the other whitelist entries that omit the selector" do
      { "⚡️" => "⚡", "✍️" => "✍", "🕊️" => "🕊", "☃️" => "☃" }.each do |sent, expected|
        expect(reactions.normalise(reaction(sent))).to eq(expected)
      end
    end

    it "leaves an emoji that legitimately carries the selector alone" do
      expect(reactions.normalise(reaction("👍"))).to eq("👍")
    end

    it "returns nil for something outside the list entirely" do
      expect(reactions.normalise(reaction("🥑"))).to be_nil
    end
  end

  describe ".map" do
    it "passes an allowed emoji through unchanged" do
      expect(reactions.map(reaction("🎉"))).to eq(["🎉", :direct])
    end

    it "substitutes a near equivalent under the nearest policy" do
      expect(reactions.map(reaction("😂"), policy: :nearest)).to eq(["🤣", :substituted])
    end

    it "strips a skin tone modifier to reach the base emoji" do
      expect(reactions.map(reaction("👍🏽"), policy: :nearest).first).to eq("👍")
    end

    # Telegram has no toned reactions at all, so every whitelisted base absorbs a tone.
    it "strips a skin tone from any whitelisted emoji, not only the listed ones" do
      { "👌🏻" => "👌", "🖕🏾" => "🖕", "✍🏻" => "✍", "🙏🏿" => "🙏", "🎅🏽" => "🎅" }.each do |toned, base|
        expect(reactions.map(reaction(toned), policy: :nearest)).to eq([base, :substituted])
      end
    end

    it "strips a skin tone from a toned emoji that also carries a ZWJ sequence" do
      expect(reactions.map(reaction("🤷🏽‍♀️"), policy: :nearest).first).to eq("🤷‍♀")
    end

    it "still cannot represent a toned emoji whose base Telegram does not allow" do
      # point_up_2 is not in Telegram's set with or without a tone.
      expect(reactions.map(reaction("👆🏻"), policy: :nearest)).to eq([nil, :unmappable])
    end

    it "drops rather than substituting under the drop policy" do
      expect(reactions.map(reaction("😂"), policy: :drop)).to eq([nil, :unmappable])
    end

    it "drops a toned emoji under the drop policy, since a tone is not native" do
      expect(reactions.map(reaction("👌🏽"), policy: :drop)).to eq([nil, :unmappable])
    end

    it "always drops a Discord custom emoji, which Telegram cannot show at all" do
      custom = Rubotty::Core::Reaction.new(custom_id: "123", custom_name: "parrot")
      expect(reactions.map(custom, policy: :nearest)).to eq([nil, :custom_dropped])
    end

    it "reports an emoji with no equivalent as unmappable" do
      expect(reactions.map(reaction("🥑"), policy: :nearest)).to eq([nil, :unmappable])
    end

    # A caution mark is not in the whitelist and, until now, had no NEAREST
    # substitute either, so content_policy's warning reaction silently
    # dropped rather than showing anything or raising.
    it "substitutes eyes for the caution mark content_policy's warning reaction uses" do
      expect(reactions.map(reaction("⚠️"), policy: :nearest)).to eq(["👀", :substituted])
      expect(reactions.map(reaction("⚠"), policy: :nearest)).to eq(["👀", :substituted])
    end
  end

  # A bot may hold exactly one reaction per message on Telegram, the default
  # budget here; the adapter passes capabilities.max_reactions as +max+.
  describe ".choose" do
    it "picks the oldest reaction when several are present" do
      emoji, dropped = reactions.choose([reaction("🎉"), reaction("👍")])
      expect(emoji).to eq(["🎉"])
      expect(dropped.map(&:emoji)).to eq(["👍"])
    end

    it "skips a reaction it cannot represent and takes the next" do
      emoji, dropped = reactions.choose([reaction("🥑"), reaction("👍")])
      expect(emoji).to eq(["👍"])
      expect(dropped.map(&:emoji)).to eq(["🥑"])
    end

    it "returns nothing when no reaction can be represented" do
      emoji, dropped = reactions.choose([reaction("🥑")], policy: :drop)
      expect(emoji).to eq([])
      expect(dropped.size).to eq(1)
    end

    it "returns nothing for an empty set, which is how a removal is expressed" do
      expect(reactions.choose([])).to eq([[], []])
    end

    it "is stable, so the mirror does not flicker as people react" do
      set = [reaction("🎉"), reaction("👍"), reaction("🔥")]
      expect(reactions.choose(set).first).to eq(reactions.choose(set).first)
    end

    it "holds up to the given budget rather than always exactly one" do
      emoji, dropped = reactions.choose([reaction("🎉"), reaction("👍"), reaction("🔥")], max: 2)
      expect(emoji).to eq(["🎉", "👍"])
      expect(dropped.map(&:emoji)).to eq(["🔥"])
    end
  end
end
