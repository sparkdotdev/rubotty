# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# Who holds the dashboard's viewer dimension. Two guarantees matter: an
# empty or broken shipped list reads as nobody, never everybody, and the
# match is on the username, the handle a person owns, never the spoofable
# display name (the same rule Security::ProtectedOperators uses).
RSpec.describe Rubotty::Security::DashboardViewers do
  def with_yaml(text)
    file = Tempfile.new(["viewers", ".yml"])
    file.write(text)
    file.flush
    yield described_class.load(file.path)
  ensure
    file&.close
    file&.unlink
  end

  describe "the shipped default" do
    it "names nobody, so viewer status has to be asked for in the deployment's YAML" do
      expect(described_class.default).to be_empty
    end

    it "answers no for any handle at all" do
      expect(described_class.default.viewer?(adapter: :telegram, username: "maintainer")).to be(false)
      expect(described_class.default.viewer?(adapter: :discord, username: "anybody")).to be(false)
    end
  end

  describe "matching a bare username on a platform that issues the handle" do
    it "recognises a named handle, in any case and with stray whitespace" do
      with_yaml("usernames:\n  - ada\n") do |viewers|
        %w[telegram discord].each do |adapter|
          expect(viewers.viewer?(adapter: adapter, username: "ada")).to be(true)
          expect(viewers.viewer?(adapter: adapter, username: "ADA")).to be(true)
          expect(viewers.viewer?(adapter: adapter, username: "  A da  ")).to be(true)
        end
      end
    end

    it "does not recognise a handle nobody named" do
      with_yaml("usernames:\n  - ada\n") do |viewers|
        expect(viewers.viewer?(adapter: :telegram, username: "grace")).to be(false)
      end
    end

    # The rule that matters: a display name is spoofable and a username is not,
    # so only the username field is ever read.
    it "never matches on a platform id when the handle is what was named" do
      with_yaml("usernames:\n  - ada\n") do |viewers|
        expect(viewers.viewer?(adapter: :telegram, native_id: "ada")).to be(false)
      end
    end
  end

  describe "matching a native id, which a rename cannot recycle (issue #639)" do
    it "recognises the configured native id regardless of the username presented" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |viewers|
        expect(viewers.viewer?(adapter: :telegram, native_id: "555000111", username: "anybody")).to be(true)
        expect(viewers.viewer?(adapter: :telegram, native_id: "555000111")).to be(true)
      end
    end

    it "refuses whoever now holds the username, when the id does not match" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |viewers|
        expect(viewers.viewer?(adapter: :telegram, native_id: "999999999", username: "anybody")).to be(false)
      end
    end

    it "scopes an id to its own adapter" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |viewers|
        expect(viewers.viewer?(adapter: :discord, native_id: "555000111")).to be(false)
      end
    end

    it "a bare username entry cannot tell the original owner from whoever holds the handle after a rename" do
      with_yaml("usernames:\n  - ada\n") do |viewers|
        expect(viewers.viewer?(adapter: :telegram, username: "ada")).to be(true)
      end
    end

    it "an id-pinned entry is unmoved: the id settles it, not whoever now holds the old username" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |viewers|
        expect(viewers.viewer?(adapter: :telegram, native_id: "555000111", username: "ada")).to be(true)
        expect(viewers.viewer?(adapter: :telegram, native_id: "999999999", username: "ada")).to be(false)
      end
    end
  end

  describe "matching Matrix on the full MXID" do
    it "recognises a named MXID from either field" do
      with_yaml(%(matrix:\n  - "@ada:matrix.example.org"\n)) do |viewers|
        expect(viewers.viewer?(adapter: :matrix, native_id: "@ada:matrix.example.org")).to be(true)
        expect(viewers.viewer?(adapter: :matrix, username: "@ada:matrix.example.org")).to be(true)
      end
    end

    # A bare localpart is not globally owned on a federated network: anybody can
    # register it on a homeserver of their own.
    it "refuses a bare localpart, which anyone can register elsewhere" do
      with_yaml(%(matrix:\n  - "@ada:matrix.example.org"\n)) do |viewers|
        expect(viewers.viewer?(adapter: :matrix, username: "ada")).to be(false)
        expect(viewers.viewer?(adapter: :matrix, native_id: "@ada:evil.example")).to be(false)
      end
    end

    it "does not let a matrix entry grant anything on another platform" do
      with_yaml(%(matrix:\n  - "@ada:matrix.example.org"\n)) do |viewers|
        expect(viewers.viewer?(adapter: :telegram, username: "@ada:matrix.example.org")).to be(false)
      end
    end
  end

  describe "a file that cannot be read as a list of handles" do
    it "reads a missing file as nobody" do
      expect(described_class.load("/nonexistent/dashboard_viewers.yml")).to be_empty
    end

    it "reads an empty document as nobody" do
      with_yaml("") { |viewers| expect(viewers).to be_empty }
    end

    it "reads a document that is not a mapping as nobody" do
      with_yaml("- ada\n- grace\n") { |viewers| expect(viewers).to be_empty }
    end

    it "reads a malformed document as nobody" do
      with_yaml("usernames: [unclosed\n") { |viewers| expect(viewers).to be_empty }
    end

    it "ignores a blank entry rather than matching every blank handle" do
      with_yaml("usernames:\n  - \"\"\n  - \"   \"\n") do |viewers|
        expect(viewers).to be_empty
        expect(viewers.viewer?(adapter: :telegram, username: "")).to be(false)
        expect(viewers.viewer?(adapter: :telegram, username: nil)).to be(false)
      end
    end
  end

  describe "#entries" do
    it "lists what was named, normalised, for display" do
      with_yaml(%(usernames:\n  - Ada\nmatrix:\n  - "@Grace:matrix.example.org"\n)) do |viewers|
        expect(viewers.entries).to eq(
          [{ handle: "@Grace:matrix.example.org", kind: "matrix" }, { handle: "ada", kind: "username" }]
        )
      end
    end

    it "lists a configured id, tagged by adapter (issue #639)" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |viewers|
        expect(viewers.entries).to eq([{ handle: "555000111", kind: "telegram_id" }])
      end
    end
  end
end
