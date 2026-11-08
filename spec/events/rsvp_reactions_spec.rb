# frozen_string_literal: true

require "spec_helper"

# The emoji vocabulary for RSVP-by-reaction: which reactions a card is seeded with
# per mode, and what an incoming reaction means under that mode.
RSpec.describe Rubotty::Events::RsvpReactions do
  def reaction(emoji) = Rubotty::Core::Reaction.new(emoji: emoji)

  describe ".for_mode" do
    it "is empty for a none-mode event" do
      expect(described_class.for_mode("none")).to eq([])
    end

    it "is a single GOING reaction for an affirm-mode event" do
      expect(described_class.for_mode("affirm")).to eq([described_class::GOING])
    end

    it "is GOING, MAYBE, NO, in that order, for a full-mode event" do
      expect(described_class.for_mode("full")).to eq(
        [described_class::GOING, described_class::MAYBE, described_class::NO]
      )
    end

    it "is empty for an unrecognised mode" do
      expect(described_class.for_mode("bogus")).to eq([])
    end

    it "returns every three reactions from Telegram's own whitelist, so a member can always tap them natively" do
      described_class.for_mode("full").each do |candidate|
        expect(Rubotty::Adapters::Telegram::Reactions.allowed?(candidate.emoji)).to be(true)
      end
    end
  end

  describe ".response_for" do
    it "maps GOING to 'in' under affirm mode" do
      expect(described_class.response_for("affirm", described_class::GOING)).to eq("in")
    end

    it "does not recognise MAYBE or NO under affirm mode" do
      expect(described_class.response_for("affirm", described_class::MAYBE)).to be_nil
      expect(described_class.response_for("affirm", described_class::NO)).to be_nil
    end

    it "maps GOING, MAYBE and NO under full mode" do
      expect(described_class.response_for("full", described_class::GOING)).to eq("yes")
      expect(described_class.response_for("full", described_class::MAYBE)).to eq("maybe")
      expect(described_class.response_for("full", described_class::NO)).to eq("no")
    end

    it "is nil for any reaction under none mode" do
      expect(described_class.response_for("none", described_class::GOING)).to be_nil
    end

    it "is nil for an unrelated emoji" do
      expect(described_class.response_for("full", reaction("🔥"))).to be_nil
    end

    it "is nil for a custom emoji" do
      custom = Rubotty::Core::Reaction.new(custom_id: "123", custom_name: "party")
      expect(described_class.response_for("full", custom)).to be_nil
    end

    it "is nil for a nil reaction" do
      expect(described_class.response_for("full", nil)).to be_nil
    end

    it "normalises the variation selector before comparing" do
      with_vs16 = described_class::GOING.with_variation_selector
      expect(with_vs16).not_to eq(described_class::GOING) # sanity: really a different form
      expect(described_class.response_for("full", with_vs16)).to eq("yes")
    end
  end
end
