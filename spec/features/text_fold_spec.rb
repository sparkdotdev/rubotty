# frozen_string_literal: true

require "spec_helper"

# One definition of "the same word": the Lua sandbox has no utf8 library and every string
# function counts bytes, so a rule comparing Portuguese did it wrong and could not have done
# it right. What matters most here is not that folding works but that there is only one of
# it, so a script asking rubotty.fold and the word filter both reach the same answer.
RSpec.describe Rubotty::Features::TextFold do
  describe "folding" do
    it "strips the accents downcasing leaves in place" do
      expect("AÇÃO".downcase).to eq("ação")
      expect(described_class.fold("AÇÃO")).to eq("acao")
    end

    it "folds a word spelled with and without its accents onto the same text" do
      expect(described_class.fold("coração")).to eq(described_class.fold("CORACAO"))
    end

    it "case folds rather than merely downcasing, so a ligature is still the word" do
      expect(described_class.fold("Straße")).to eq("strasse")
      expect(described_class.fold("ﬁne")).to eq("fine")
    end

    it "leaves a script whose marks carry meaning rather than decoration alone" do
      # A Devanagari spacing combining mark carries a vowel, so stripping it
      # would produce a different word rather than the same one folded.
      expect(described_class.fold("का")).to eq("का")
    end

    it "survives text that is not valid UTF-8 rather than raising mid invocation" do
      expect(described_class.fold("caf\xC3(")).to be_a(String)
    end
  end

  describe "splitting into characters" do
    it "counts characters where string.len would count bytes" do
      expect("coração".bytesize).to eq(9)
      expect(described_class.chars("coração").length).to eq(7)
    end

    it "hands back whole characters, which string.sub(-1) cannot" do
      expect(described_class.chars("coração").last).to eq("o")
      expect(described_class.chars("olá").last).to eq("á")
    end

    it "is bounded, so one call cannot build a frame the child could not write" do
      expect(described_class.chars("a" * (described_class.max_chars + 500)).length)
        .to eq(described_class.max_chars)
    end
  end

  # The offsets are what offending_spans hands a script, so an error here is a
  # rule cutting a codepoint in half in a live room.
  describe "the map back to the original bytes" do
    it "folds to exactly what the cheap whole string fold produces" do
      text = "olá cariño, AÇÃO e Straße"

      expect(described_class.fold_with_offsets(text).first).to eq(described_class.fold(text))
    end

    it "points every folded byte at the character it came from" do
      folded, starts = described_class.fold_with_offsets("olá acao")
      at = folded.index("acao")

      expect("olá acao".byteslice(starts[at], starts[at + 4] - starts[at])).to eq("acao")
    end

    it "keeps a combining mark inside the span of the letter it sits on" do
      # e + combining acute, which folds away to a bare "e".
      folded, starts = described_class.fold_with_offsets("café here")
      at = folded.index("cafe")

      expect("café here".byteslice(starts[at], starts[at + 4] - starts[at])).to eq("café")
    end
  end
end

# The parity that stops a script and the filter disagreeing. Both go through
# Features::TextFold, so this is checking the wiring rather than the algorithm:
# nothing here would pass if either side grew a fold of its own.
RSpec.describe "folding, as the word filter and a script each see it" do
  let(:classifier) do
    Rubotty::Scripting::Classifier.new(config: { "custom" => %w[acao naive] },
                                       logger: Rubotty::Log.null)
  end

  # What rubotty.fold really serves, taken from the catalog's own handler rather
  # than from the module, so a handler wired to something else would fail here.
  let(:fold) { Rubotty::Scripting::HostFunctions.fold_handler }

  it "matches an accented spelling of an unaccented filter word" do
    expect(classifier.classify("olha a AÇÃO aqui")).to eq("community")
    expect(classifier.classify("that was naïve")).to eq("community")
  end

  it "agrees with the filter on every spelling the filter treats as one word" do
    same = ["acao", "AÇÃO", "Ação", "acão"]

    expect(same.map { |word| fold.call(word) }.uniq).to eq(["acao"])
    expect(same.map { |word| classifier.classify("about #{word} then") }.uniq).to eq(["community"])
  end

  it "agrees on a word the filter does NOT treat as the same one" do
    expect(fold.call("acaos")).not_to eq(fold.call("acao"))
    expect(classifier.classify("about acaos then")).to eq("clean")
  end

  # Byte offsets into the text the SCRIPT holds, not into the folded form, so a
  # rule replacing what it found cuts in the right place.
  it "reports spans against the original bytes, accents and all" do
    text = "olá cariño, AÇÃO e mais"
    span = classifier.spans(text).first

    expect(text.byteslice(span["from"], span["to"] - span["from"])).to eq("AÇÃO")
  end
end
