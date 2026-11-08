# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# Answering what a script needs to know about text without handing over the word list:
# a script learns whether something matched and where, never what the list contains.
RSpec.describe Rubotty::Scripting::Classifier do
  subject(:classifier) { described_class.new(config: config, logger: Rubotty::Log.null) }

  let(:config) { { "custom" => %w[pineapple hawaiian] } }

  describe "#classify" do
    it "says clean for ordinary text" do
      expect(classifier.classify("good morning everyone")).to eq("clean")
    end

    it "recognises the community's own additions separately from the shipped list" do
      expect(classifier.classify("I hate pineapple on pizza")).to eq("community")
    end

    it "recognises profanity from the vendored list" do
      expect(classifier.classify("this is shit")).to eq("profanity")
    end

    it "treats an empty message as clean rather than raising" do
      expect(classifier.classify("")).to eq("clean")
      expect(classifier.classify(nil)).to eq("clean")
    end

    # A community chose its own words deliberately, so its rule firing is the more
    # useful answer when both would match.
    it "puts the community's own list above generic profanity" do
      both = described_class.new(config: { "custom" => ["shit"] }, logger: Rubotty::Log.null)

      expect(both.classify("this is shit")).to eq("community")
    end

    it "matches whole words rather than fragments" do
      expect(classifier.classify("pineapples are nice")).to eq("clean")
    end
  end

  describe "#spans" do
    # What replace mode needs, and it works without the script ever seeing what is
    # banned.
    it "gives offsets that slice the offending word out of the script's own text" do
      text = "I hate pineapple on pizza"
      span = classifier.spans(text).first

      expect(text[span["from"]...span["to"]]).to eq("pineapple")
      expect(span["category"]).to eq("community")
    end

    it "finds every occurrence, in order" do
      text = "pineapple then hawaiian then pineapple"

      expect(classifier.spans(text).map { |s| s["from"] }).to eq([0, 15, 29])
    end

    it "returns nothing for clean text" do
      expect(classifier.spans("a perfectly nice sentence")).to eq([])
    end

    # Overlapping spans would let a script replace the same stretch twice.
    it "never returns spans that overlap" do
      spans = classifier.spans("pineapple hawaiian pineapple")

      spans.each_cons(2) { |a, b| expect(b["from"]).to be >= a["to"] }
    end

    it "copes with an empty message" do
      expect(classifier.spans("")).to eq([])
    end
  end

  describe "with no community words configured" do
    let(:config) { {} }

    it "still classifies against the shipped list" do
      expect(classifier.classify("this is shit")).to eq("profanity")
      expect(classifier.classify("nothing wrong here")).to eq("clean")
    end
  end
end
