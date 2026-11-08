# frozen_string_literal: true

require "spec_helper"

# The shared key=value reader behind /schedule, /event and /reschedule
# (issue #1797): a value runs until the next key= word, quoted or not, so
# neither an unquoted multi-word value nor an apostrophe breaks the parse.
RSpec.describe Rubotty::Core::KeyedArguments do
  describe ".parse" do
    it "reads the exact input reported in issue #1797" do
      text = "name=When do you want to play AOE3 today? game=AOE3 times=2PM | 3PM | 4PM"
      expect(described_class.parse(text)).to eq(
        "name" => "When do you want to play AOE3 today?",
        "game" => "AOE3",
        "times" => "2PM | 3PM | 4PM"
      )
    end

    it "reads fields in any order" do
      expect(described_class.parse("game=AOE3 name=Raid night")).to eq("game" => "AOE3", "name" => "Raid night")
    end

    it "lowercases keys" do
      expect(described_class.parse("NAME=Foo")).to eq("name" => "Foo")
    end

    it "does not break on an apostrophe inside an unquoted value" do
      text = "name=Alex's game night game=Chess"
      expect(described_class.parse(text)).to eq("name" => "Alex's game night", "game" => "Chess")
    end

    it "does not break on an apostrophe inside a quoted value" do
      expect(described_class.parse('name="Alex\'s game night"')).to eq("name" => "Alex's game night")
    end

    it "reads an unquoted multi-word value up to the next key" do
      expect(described_class.parse("title=Movie Night start=tomorrow")).to eq(
        "title" => "Movie Night", "start" => "tomorrow"
      )
    end

    it "reads a quoted value verbatim, even one holding something that looks like a key" do
      text = 'name="today game=foo" game=Real'
      expect(described_class.parse(text)).to eq("name" => "today game=foo", "game" => "Real")
    end

    it "reads a curly-quoted value, the pair iOS and macOS substitute automatically while typing" do
      text = "title=“Game zone” start=“today 14:45”"
      expect(described_class.parse(text)).to eq("title" => "Game zone", "start" => "today 14:45")
    end

    it "does not break on a curly apostrophe, the same character a phone substitutes for one" do
      text = "name=Alex’s game night game=Chess"
      expect(described_class.parse(text)).to eq("name" => "Alex’s game night", "game" => "Chess")
    end

    it "returns nil for an unmatched curly quote" do
      expect(described_class.parse("name=“Unterminated")).to be_nil
    end

    it "still honours plain double-quoted values the old quoting style relied on" do
      text = 'name="Raid night" game="Deep Rock Galactic" times="tuesday 7pm | wednesday 7pm"'
      expect(described_class.parse(text)).to eq(
        "name" => "Raid night", "game" => "Deep Rock Galactic", "times" => "tuesday 7pm | wednesday 7pm"
      )
    end

    it "does not let a query-string equals sign inside a value start a new field" do
      expect(described_class.parse("url=https://example.test?x=1&y=2")).to eq(
        "url" => "https://example.test?x=1&y=2"
      )
    end

    it "trims incidental whitespace around an unquoted value" do
      expect(described_class.parse("name=  Raid night   game=Foo")).to eq("name" => "Raid night", "game" => "Foo")
    end

    it "returns an empty hash for blank text" do
      expect(described_class.parse("")).to eq({})
      expect(described_class.parse(nil)).to eq({})
      expect(described_class.parse("   ")).to eq({})
    end

    it "returns nil for text with no key at all" do
      expect(described_class.parse("just some words")).to be_nil
    end

    it "returns nil for text before the first key" do
      expect(described_class.parse("oops name=Foo")).to be_nil
    end

    it "returns nil for an unmatched quote" do
      expect(described_class.parse('name="Unterminated')).to be_nil
    end

    it "returns nil for text stuck onto the end of a quoted value" do
      expect(described_class.parse('name="Foo"bar game=Baz')).to be_nil
    end

    it "reads an empty value as an empty string, same as a bare key=" do
      expect(described_class.parse("name= game=Foo")).to eq("name" => "", "game" => "Foo")
    end
  end
end
