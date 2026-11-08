# frozen_string_literal: true

require "spec_helper"

# A term that starts or ends with punctuation has to match. whole_word wraps every literal
# in \b, and \b asserts a transition between a word character and a non-word one, so it can
# never match beside punctuation. whole_word defaults to true with no way to opt out from the
# dashboard, so a term like "@everyone" would compile cleanly and silently never fire.
RSpec.describe Rubotty::Features::Matcher, "terms that do not begin or end on a word character" do
  def matches?(pattern, text, mode: "literal")
    described_class.build(pattern: pattern, mode: mode, logger: Rubotty::Log.null).match?(text)
  end

  # Every one of these was reported as silently ignored.
  {
    "@everyone" => "hey @everyone now",
    "#airdrop" => "check the #airdrop channel",
    "$$$" => "make $$$ fast",
    "buy now!" => "buy now! limited offer"
  }.each do |pattern, text|
    it "matches #{pattern.inspect}" do
      expect(matches?(pattern, text)).to be(true)
    end
  end

  it "matches an emoji term" do
    expect(matches?("\u{1F4B0}", "free \u{1F4B0} here")).to be(true)
  end

  # Ruby's \w is ASCII, so CJK never had a boundary to sit beside either.
  it "matches a CJK term inside a run of CJK" do
    expect(matches?("你好", "我说你好了")).to be(true)
  end

  # The half of the term that DOES begin on a word character keeps its anchor,
  # so this is not a blanket downgrade to substring matching.
  it "still anchors the end of a term that ends on a word character" do
    expect(matches?("@everyone", "hey @everyonely now")).to be(false)
  end

  it "still anchors the start of a term that starts on a word character" do
    expect(matches?("buy now!", "standby now! please")).to be(false)
  end

  # The Scunthorpe guard, which is what the boundaries were for. Unchanged.
  it "keeps refusing a term embedded in a longer word" do
    expect(matches?("spam", "spammer")).to be(false)
    expect(matches?("spam", "this is spam")).to be(true)
  end

  it "keeps matching a masked term that is all word characters and asterisks" do
    expect(matches?("c**t", "you c**t")).to be(true)
  end

  describe "wildcards" do
    it "anchors only the end when the glob opens with a star" do
      expect(matches?("*drop", "an airdrop", mode: "wildcard")).to be(true)
    end

    it "matches a glob that ends in punctuation" do
      expect(matches?("buy*!", "buy this now! ok", mode: "wildcard")).to be(true)
    end

    it "still anchors a glob that begins and ends on a word character" do
      expect(matches?("sp*m", "unsp4mmed", mode: "wildcard")).to be(false)
    end
  end
end
