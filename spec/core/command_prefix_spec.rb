# frozen_string_literal: true

require "spec_helper"

# Discord reserves a leading "/" for its native slash-command UI, so accepting
# "!" alongside "/" unblocks the command surface there.
RSpec.describe Rubotty::Core::CommandPrefix do
  describe "the default set" do
    subject(:prefixes) { described_class.new }

    it "accepts both / and !, so / stays natural on Telegram and ! unblocks Discord" do
      expect(described_class::DEFAULT).to eq(["/", "!"])
      expect(prefixes.strip("/delete")).to eq("delete")
      expect(prefixes.strip("!delete")).to eq("delete")
    end

    it "returns nil for text that begins with no marker, so an ordinary message is left alone" do
      expect(prefixes.strip("just chatting")).to be_nil
      expect(prefixes.match?("just chatting")).to be(false)
    end

    it "reports the first marker as the representative one for help text" do
      expect(prefixes.primary).to eq("/")
    end

    it "leaves the body untokenised, so arguments survive for the caller to split" do
      expect(prefixes.strip("!mute 30 spamming")).to eq("mute 30 spamming")
    end
  end

  describe "normalisation" do
    it "drops blanks and duplicates" do
      expect(described_class.new(["/", "", "/", "!"]).to_a).to eq(["/", "!"])
    end

    it "falls back to the default when nothing usable is configured" do
      expect(described_class.new([]).to_a).to eq(["/", "!"])
      expect(described_class.new(["", nil]).to_a).to eq(["/", "!"])
    end

    it "matches the longest marker first, so a longer marker is not left dangling" do
      prefixes = described_class.new(["!", "!!"])
      expect(prefixes.strip("!!ban")).to eq("ban")
    end
  end

  # Fluxer's "/" menu is a fixed list compiled into its client, and three of its
  # entries are command names of ours, so help text read there has to print "!".
  describe "#preferred" do
    subject(:prefixes) { described_class.new }

    def caps(*reserved)
      Rubotty::Adapters::Capabilities.new(reserved_command_prefixes: reserved)
    end

    it "is the primary marker when the platform claims none of them" do
      expect(prefixes.preferred).to eq("/")
      expect(prefixes.preferred(capabilities: nil)).to eq("/")
      expect(prefixes.preferred(capabilities: caps)).to eq("/")
    end

    it "skips a marker the platform's own client swallows" do
      expect(prefixes.preferred(capabilities: caps("/"))).to eq("!")
    end

    it "falls back to the primary when every marker is claimed, since printing none helps nobody" do
      expect(prefixes.preferred(capabilities: caps("/", "!"))).to eq("/")
    end

    it "honours a community's own order rather than the default one" do
      expect(described_class.new(["#", "/"]).preferred(capabilities: caps("#"))).to eq("/")
    end

    it "asks the capabilities object's own predicate per marker, not a raw array it re-derives from" do
      asked = []
      capabilities = Object.new
      capabilities.define_singleton_method(:reserves_prefix?) { |token| asked << token; token == "/" }

      expect(prefixes.preferred(capabilities: capabilities)).to eq("!")
      expect(asked).to eq(["/", "!"])
    end
  end

  describe ".from" do
    it "coerces a single string" do
      expect(described_class.from("#").to_a).to eq(["#"])
    end

    it "coerces an array" do
      expect(described_class.from(["/", "."]).to_a).to eq(["/", "."])
    end

    it "passes an existing instance through untouched" do
      instance = described_class.new(["/"])
      expect(described_class.from(instance)).to be(instance)
    end
  end

  describe ".from_config" do
    it "defaults to / and ! when the config carries neither key" do
      expect(described_class.from_config({}).to_a).to eq(["/", "!"])
    end

    it "reads the prefixes list" do
      expect(described_class.from_config({ prefixes: ["/", "#"] }).to_a).to eq(["/", "#"])
    end

    it "folds the legacy singular prefix into the set, so an old config keeps working" do
      expect(described_class.from_config({ prefix: "/" }).to_a).to eq(["/"])
      expect(described_class.from_config({ prefixes: ["/"], prefix: "!" }).to_a).to eq(["/", "!"])
    end

    it "tolerates string keys, as a control-plane snapshot symbolises but a spec hash may not" do
      expect(described_class.from_config({ "prefixes" => ["#"] }).to_a).to eq(["#"])
    end
  end
end
