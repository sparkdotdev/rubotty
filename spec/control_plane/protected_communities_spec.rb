# frozen_string_literal: true
require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ProtectedCommunities, :release_defaults do
  around do |example|
    previous = ENV.to_h
    described_class.reset!
    example.run
  ensure
    ENV.replace(previous)
    described_class.reset!
  end

  it "loads the production file and re-reads it only after an explicit reset" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "private.yml")
      File.write(path, "patterns: [Private Title]\ncommunities:\n  - slug: stable\n")
      ENV["ENVIRONMENT"] = "PRODUCTION"
      ENV["RUBOTTY_PROTECTED_COMMUNITIES_FILE"] = path
      first = described_class.default
      expect(first.protected?("Private Title lobby")).to be(true)
      expect(first.community_slugs).to eq(["stable"])
      File.write(path, "patterns: []\ncommunities: []\n")
      expect(described_class.default).to equal(first)
      described_class.reset!
      expect(described_class.default.patterns).to be_empty
      expect(described_class.default.community_slugs).to be_empty
    end
  end

  it "ignores a configured private file outside production" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "private.yml")
      File.write(path, "patterns: [Private Title]\ncommunities:\n  - slug: stable\n")
      ENV["ENVIRONMENT"] = "DEVELOPMENT"
      ENV["RUBOTTY_PROTECTED_COMMUNITIES_FILE"] = path
      expect(described_class.default.patterns).to be_empty
      expect(described_class.default.community_slugs).to be_empty
    end
  end

  it "accepts legacy title lists while discarding non-string entries" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "legacy.yml")
      File.write(path, "- Legacy Title\n- 42\n- null\n")
      expect(described_class.read_patterns(path)).to eq(["Legacy Title"])
      policy = described_class.from_file(path)
      expect(policy.patterns).to eq(["legacytitle"])
      expect(policy.community_slugs).to be_empty
      expect(policy.protected?("legacy title lobby")).to be(true)
      expect(policy.protected?("42")).to be(false)
    end
  end

  it "filters malformed mapping entries without creating recovery grants" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mixed.yml")
      File.write(path, <<~YAML)
        patterns: [Valid Title, 42, null]
        communities:
          - invalid
          - slug: stable
          - slug: stable
          - slug: null
          - slug: ""
          - slug: 42
      YAML
      policy = described_class.from_file(path)
      expect(policy.patterns).to eq(["validtitle"])
      expect(policy.community_slugs).to eq(["stable"])
      expect(described_class.read_patterns(path)).to eq(["Valid Title"])
      expect(policy.protected?("42")).to be(false)
    end
  end

  it "returns no compatibility patterns without a usable file" do
    expect(described_class.read_patterns(nil)).to be_empty
    expect(described_class.read_patterns("/missing.yml")).to be_empty
    expect(described_class.from_file(nil).community_slugs).to be_empty
  end

  it "ships no trusted titles" do
    expect(described_class.from_file(described_class::DEFAULT_PATH).patterns).to be_empty
    expect(described_class.new.protected?("Example Community")).to be(false)
  end

  it "grants nothing for a missing or malformed configuration" do
    expect(described_class.from_file("/missing.yml").patterns).to be_empty
    Dir.mktmpdir do |dir|
      path = File.join(dir, "broken.yml")
      File.write(path, "patterns: [broken")
      expect(described_class.from_file(path).patterns).to be_empty
    end
  end

  it "uses only explicitly configured patterns" do
    policy = described_class.new(patterns: ["Example Community"])
    expect(policy.protected?("EXAMPLE community lobby")).to be(true)
    expect(policy.protected?("Somewhere Else")).to be(false)
  end
  it "preserves management guards by slug without authorizing copied titles" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "private.yml")
      File.write(path, "patterns: []\ncommunities:\n  - slug: stable-community\n")
      policy = described_class.from_file(path)
      community = Struct.new(:slug, :name).new("stable-community", "Renamed community")
      expect(policy.protects_community?(community)).to be(true)
      expect(policy.protects_community?(Struct.new(:slug, :name).new("other", community.name))).to be(false)
      expect(policy.protected?(community.name)).to be(false)
      expect(policy.protects_community?(nil)).to be(false)
    end
  end

  it "retains legacy explicitly configured title guards" do
    policy = described_class.new(patterns: ["Example Community"])
    community = Struct.new(:slug, :name).new("example", "Example Community")
    expect(policy.protects_community?(community)).to be(true)
  end

end
