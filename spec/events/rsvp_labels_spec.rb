# frozen_string_literal: true

require "spec_helper"

# The one place the words around an event's RSVP tally live, so the card, the
# reminder and /events cannot end up naming the same number differently.
RSpec.describe Rubotty::Events::RsvpLabels do
  describe ".attending_line" do
    it "spells the label out, so the count is not read as a countdown" do
      expect(described_class.attending_line("5")).to eq("Attending: 5")
    end

    it "reads the same for one person as for many" do
      expect(described_class.attending_line("@u1")).to eq("Attending: @u1")
      expect(described_class.attending_line("@u1, @u2")).to eq("Attending: @u1, @u2")
    end

    it "says nobody yet rather than a zero when nobody has answered" do
      expect(described_class.attending_line(nil)).to eq("Attending: nobody yet")
      expect(described_class.attending_line("")).to eq("Attending: nobody yet")
    end
  end

  describe "FULL" do
    it "pairs each full-mode response with the word it is shown under, in display order" do
      expect(described_class::FULL).to eq([%w[yes Going], %w[maybe Maybe], %w[no No]])
    end

    it "covers exactly the responses a full-mode reaction can record" do
      recorded = [Rubotty::Events::RsvpReactions::GOING, Rubotty::Events::RsvpReactions::MAYBE,
                  Rubotty::Events::RsvpReactions::NO].map do |reaction|
        Rubotty::Events::RsvpReactions.response_for("full", reaction)
      end
      expect(described_class::FULL.map(&:first)).to eq(recorded)
    end
  end
end
