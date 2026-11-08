# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::VoteRoster do
  def voter(handle, platform: "discord", identity: "id-#{handle}", name: nil)
    described_class::Voter.new(identity: identity, platform: platform, handle: handle, name: name)
  end

  describe ".inline" do
    it "says nothing at all for nobody" do
      expect(described_class.inline([])).to be_nil
    end

    it "names everybody while there are no more than three" do
      list = [voter("ada"), voter("bruno", platform: "telegram"), voter("cleo", platform: "telegram")]

      expect(described_class.inline(list, on_platform: "discord"))
        .to eq("@ada, @bruno@telegram, @cleo@telegram")
    end

    it "collapses to a bare count once a fourth arrives" do
      list = Array.new(4) { |i| voter("voter#{i}") }

      expect(described_class.inline(list, on_platform: "discord")).to eq("4")
    end
  end

  describe ".long" do
    it "names everybody however many there are" do
      list = Array.new(5) { |i| voter("voter#{i}", platform: "telegram") }

      expect(described_class.long(list, on_platform: "discord"))
        .to eq((0..4).map { |i| "@voter#{i}@telegram" }.join(", "))
    end
  end

  describe ".handle_for" do
    it "drops the platform half for somebody the reader is standing beside" do
      expect(described_class.handle_for(voter("ada"), on_platform: "discord")).to eq("@ada")
      expect(described_class.handle_for(voter("ada"), on_platform: :discord)).to eq("@ada")
    end

    it "keeps the platform half for everybody else" do
      expect(described_class.handle_for(voter("ada"), on_platform: "telegram")).to eq("@ada@discord")
      expect(described_class.handle_for(voter("ada"))).to eq("@ada@discord")
    end

    it "writes the name, unprefixed, for somebody who never set a handle" do
      known = described_class::Voter.new(identity: "44120", platform: "telegram",
                                         handle: nil, name: "Pinniped Pete")

      expect(described_class.handle_for(known, on_platform: "telegram")).to eq("Pinniped Pete")
    end

    it "parenthesises the platform on a name, rather than dressing it as a handle" do
      known = described_class::Voter.new(identity: "44120", platform: "telegram",
                                         handle: nil, name: "Pinniped Pete")

      expect(described_class.handle_for(known, on_platform: "discord")).to eq("Pinniped Pete (telegram)")
    end

    it "prefers a real handle over the name beside it" do
      both = voter("pete", platform: "telegram", name: "Pinniped Pete")

      expect(described_class.handle_for(both, on_platform: "telegram")).to eq("@pete")
    end

    it "never writes a platform id, which means nothing to anybody reading the room" do
      nameless = described_class::Voter.new(identity: "5502187744", platform: "telegram", handle: nil)

      expect(described_class.handle_for(nameless, on_platform: "telegram")).to eq("someone")
    end

    it "still writes an identity that is a nick, which is all IRC and XMPP have" do
      nick = described_class::Voter.new(identity: "pete", platform: "irc", handle: nil)

      expect(described_class.handle_for(nick, on_platform: "irc")).to eq("@pete")
    end

    it "prefers the name over an identity of any shape" do
      both = described_class::Voter.new(identity: "pete", platform: "irc", handle: nil, name: "Pinniped Pete")

      expect(described_class.handle_for(both, on_platform: "irc")).to eq("Pinniped Pete")
    end
  end

  describe ".inline with a mixed roster" do
    it "reads as a list of people rather than a list of numbers" do
      list = [voter("ada", platform: "telegram"),
              described_class::Voter.new(identity: "5502187744", platform: "telegram",
                                         handle: nil, name: "Pinniped Pete"),
              described_class::Voter.new(identity: "9987", platform: "telegram", handle: nil)]

      expect(described_class.inline(list, on_platform: "telegram")).to eq("@ada, Pinniped Pete, someone")
    end
  end
end
