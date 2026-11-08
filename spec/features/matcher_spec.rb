# frozen_string_literal: true

require "spec_helper"
require "timeout"

# The bounded matching core shared by the word filter and the FAQ engine, exercised directly
# so the shared contract is pinned in one place.
RSpec.describe Rubotty::Features::Matcher do
  def matches?(pattern, text, **options)
    matcher = described_class.build(pattern: pattern, **options)
    matcher.match?(text)
  end

  describe "literal mode" do
    it "is case-insensitive by default" do
      expect(matches?("badword", "stop saying BADWORD now")).to be(true)
      expect(matches?("badword", "stop saying BadWord now")).to be(true)
    end

    it "honours case_sensitive: true" do
      expect(matches?("badword", "BADWORD", case_sensitive: true)).to be(false)
      expect(matches?("badword", "badword", case_sensitive: true)).to be(true)
    end

    it "matches on a word boundary by default, dodging the Scunthorpe problem" do
      expect(matches?("cunt", "I moved to Scunthorpe")).to be(false)
      expect(matches?("cunt", "what a cunt")).to be(true)
    end

    it "matches a substring when whole_word is turned off" do
      expect(matches?("cunt", "I moved to Scunthorpe", whole_word: false)).to be(true)
    end
  end

  describe "wildcard mode" do
    it "expands * to any run and matches on a word boundary" do
      expect(matches?("bad*", "such badness today", mode: "wildcard")).to be(true)
      expect(matches?("bad*", "nothing wrong here", mode: "wildcard")).to be(false)
    end

    it "expands ? to a single character" do
      expect(matches?("f?ck", "that is fsck", mode: "wildcard")).to be(true)
      expect(matches?("f?ck", "that is frick", mode: "wildcard")).to be(false)
    end
  end

  describe "regex mode" do
    it "matches a user-supplied regex, case-insensitively by default" do
      expect(matches?("h[e3]llo", "h3llo world", mode: "regex")).to be(true)
      expect(matches?("h[e3]llo", "H3LLO world", mode: "regex")).to be(true)
      expect(matches?("h[e3]llo", "goodbye world", mode: "regex")).to be(false)
    end
  end

  describe "unsafe or malformed patterns yield nil" do
    it "rejects an empty pattern" do
      expect(described_class.build(pattern: "")).to be_nil
    end

    it "rejects an unknown mode" do
      expect(described_class.build(pattern: "x", mode: "semantic")).to be_nil
    end

    it "rejects a nested-unbounded-quantifier pattern before it can run" do
      %w[(a+)+$ (a*)* ([a-z]+)* (.*)+].each do |pattern|
        expect(described_class.build(pattern: pattern, mode: "regex")).to be_nil,
                                                                          "expected #{pattern.inspect} to be rejected"
      end
    end

    it "rejects a pattern longer than the bound" do
      expect(described_class.build(pattern: "a" * 1000, mode: "regex")).to be_nil
    end

    it "rejects an invalid regex without crashing" do
      expect(described_class.build(pattern: "(", mode: "regex")).to be_nil
    end
  end

  describe "the per-pattern timeout backstop" do
    it "time-boxes every compiled regex" do
      matcher = described_class.build(pattern: "h[e3]llo", mode: "regex")
      expect(matcher.regex.timeout).to eq(described_class::REGEX_TIMEOUT_SECONDS)
    end

    it "treats a pattern that blows its budget as no match rather than hanging" do
      regex = Regexp.new("(?:a|a)*b", 0, timeout: 0.05)
      matcher = described_class.new(pattern: "rigged", mode: "regex", regex: regex, logger: Rubotty::Log.null)
      allow(regex).to receive(:match?).and_raise(Regexp::TimeoutError)
      result = Timeout.timeout(5) { matcher.match?("a" * 100) }
      expect(result).to be(false)
    end
  end

  describe ".bound_input" do
    it "truncates input to the bound so a huge message is never a vector" do
      long = "a" * (described_class::MAX_INPUT_CHARS + 500)
      expect(described_class.bound_input(long).length).to eq(described_class::MAX_INPUT_CHARS)
    end

    it "leaves ordinary input untouched" do
      expect(described_class.bound_input("hello")).to eq("hello")
    end
  end
end
