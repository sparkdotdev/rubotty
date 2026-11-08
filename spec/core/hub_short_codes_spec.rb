# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Core::HubShortCodes do
  describe ".assign" do
    it "derives a code from the first letter of each of a label's first two words" do
      codes = described_class.assign([%w[gaming Gaming\ &\ Scheduling]])
      expect(codes["gaming"]).to eq("gs")
    end

    it "derives a code from the first two letters of a single-word label" do
      codes = described_class.assign([%w[general General]])
      expect(codes["general"]).to eq("ge")
    end

    it "is stable: the same labels in the same order always produce the same codes" do
      entries = [%w[gaming Gaming], %w[travel Travel]]
      expect(described_class.assign(entries)).to eq(described_class.assign(entries))
    end

    it "resolves a collision deterministically: the first room in order keeps the natural code" do
      entries = [%w[a Gaming\ &\ Scheduling], %w[b General\ Support]]
      codes = described_class.assign(entries)
      expect(codes["a"]).to eq("gs")
      expect(codes["b"]).not_to eq("gs")
      # And it is reproducible: swapping the input order changes who wins.
      swapped = described_class.assign(entries.reverse)
      expect(swapped["b"]).to eq("gs")
      expect(swapped["a"]).not_to eq("gs")
    end

    it "never assigns two rooms the same code" do
      entries = [
        %w[a Gaming\ Group], %w[b General\ Gathering], %w[c Great\ Games], %w[d Good\ Group]
      ]
      codes = described_class.assign(entries)
      expect(codes.values.uniq.size).to eq(codes.size)
    end

    it "falls back to a numbered code when every derived candidate is taken" do
      entries = [%w[a Gaming], %w[b Gaming], %w[c Gaming], %w[d Gaming]]
      codes = described_class.assign(entries)
      expect(codes.values.uniq.size).to eq(4)
      expect(codes["a"]).to eq("ga")
    end

    it "takes an explicit per-room override as given, never recomputing it" do
      codes = described_class.assign([%w[gaming Gaming\ &\ Scheduling]], overrides: { "gaming" => "GX" })
      expect(codes["gaming"]).to eq("gx")
    end

    it "never assigns a reserved code" do
      codes = described_class.assign([%w[gaming Gs]], reserved: ["gs"])
      expect(codes["gaming"]).not_to eq("gs")
    end

    it "never assigns a code equal to an override already claimed by another room" do
      entries = [%w[a Gaming], %w[b General]]
      codes = described_class.assign(entries, overrides: { "b" => "ga" })
      expect(codes["a"]).not_to eq("ga")
    end

    it "produces a two-character code for a label with no letters at all" do
      codes = described_class.assign([%w[weird 42]])
      expect(codes["weird"].length).to eq(2)
    end

    # words() only scans [[:alnum:]]+, so an emoji or punctuation only label
    # produces no significant words at all. String#hash uses a seed MRI
    # randomizes per process, so proving stability across a restart needs two
    # REAL separate processes, not two calls in this one that would share a seed.
    it "produces the same code across two fresh process invocations for a symbols-only label" do
      lib_path = File.expand_path("../../../lib/rubotty/core/hub_short_codes.rb", __FILE__)
      script = 'print Rubotty::Core::HubShortCodes.assign([["hub", "\u{1F3AE}\u{1F3AE}"]])["hub"]'
      first = IO.popen([RbConfig.ruby, "-r", lib_path, "-e", script], &:read)
      second = IO.popen([RbConfig.ruby, "-r", lib_path, "-e", script], &:read)

      expect(first).not_to be_empty
      expect(first).to eq(second)
    end

    it "returns an empty hash for no entries" do
      expect(described_class.assign([])).to eq({})
    end
  end
end
