# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::CommandWord do
  # No community, so #command_prefixes falls back to Core::CommandPrefix::DEFAULT
  # ("/" and "!"), which is all this parsing needs to be exercised.
  def context_for(text)
    Rubotty::Features::Context.new(message: message(endpoint("a"), text: text))
  end

  describe ".parse" do
    it "reads the lowercased word and the words after it" do
      expect(described_class.parse(context_for("/Poll Which map? | A | B"))).to eq(["poll", %w[Which map? | A | B]])
    end

    it "chops a Telegram @botname suffix off the word" do
      expect(described_class.parse(context_for("/poll@somebot a")).first).to eq("poll")
    end

    it "honours whichever configured prefix is present" do
      expect(described_class.parse(context_for("!find ada")).first).to eq("find")
    end

    it "answers [nil, nil] for a message with no configured prefix at all" do
      expect(described_class.parse(context_for("just chatting"))).to eq([nil, nil])
    end

    it "answers [nil, nil] for a bare prefix with nothing after it" do
      expect(described_class.parse(context_for("/"))).to eq([nil, nil])
    end
  end
end
