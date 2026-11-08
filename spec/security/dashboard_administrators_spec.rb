# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# Who administers the deployment, from the shipped YAML alone. This role is
# total control, so the same two guarantees the viewer floor makes matter
# more here: an empty or broken list reads as nobody, never everybody, and
# the match is on the username, the handle a person owns, never the spoofable display name.
RSpec.describe Rubotty::Security::DashboardAdministrators do
  def with_yaml(text)
    file = Tempfile.new(["administrators", ".yml"])
    file.write(text)
    file.flush
    yield described_class.load(file.path)
  ensure
    file&.close
    file&.unlink
  end

  describe "the shipped default" do
    it "names nobody, so a deployment starts with the root password and nothing else" do
      expect(described_class.default).to be_empty
    end

    it "answers no for any handle at all" do
      expect(described_class.default.administrator?(adapter: :telegram, username: "maintainer")).to be(false)
      expect(described_class.default.administrator?(adapter: :discord, username: "anybody")).to be(false)
    end
  end

  describe "matching a bare username on a platform that issues the handle" do
    it "recognises a named handle, in any case and with stray whitespace" do
      with_yaml("usernames:\n  - ada\n") do |floor|
        %w[telegram discord].each do |adapter|
          expect(floor.administrator?(adapter: adapter, username: "ada")).to be(true)
          expect(floor.administrator?(adapter: adapter, username: "  A DA ")).to be(true)
        end
      end
    end

    it "does not recognise a handle nobody named" do
      with_yaml("usernames:\n  - ada\n") do |floor|
        expect(floor.administrator?(adapter: :telegram, username: "grace")).to be(false)
      end
    end

    # The rule the whole file exists to keep. A display name is spoofable and a
    # username is not, so only the username field is ever read.
    it "never reads the id field when a bare handle is what was named" do
      with_yaml("usernames:\n  - ada\n") do |floor|
        expect(floor.administrator?(adapter: :telegram, native_id: "ada")).to be(false)
      end
    end

    # The handle on these platforms is a nick the client picks at connect, so a
    # match there would hand a stranger the deployment.
    %i[irc xmpp stoat fluxer].each do |adapter|
      it "never matches a bare handle on #{adapter}, where nobody vouches for it" do
        with_yaml("usernames:\n  - ada\n") do |floor|
          expect(floor.administrator?(adapter: adapter, username: "ada")).to be(false)
        end
      end
    end
  end

  describe "matching a native id, which a rename cannot recycle" do
    it "recognises the configured id regardless of the username presented" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |floor|
        expect(floor.administrator?(adapter: :telegram, native_id: "555000111", username: "anybody"))
          .to be(true)
      end
    end

    it "refuses whoever now holds the username, when the id does not match" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |floor|
        expect(floor.administrator?(adapter: :telegram, native_id: "999999999", username: "ada"))
          .to be(false)
      end
    end

    it "scopes an id to its own adapter" do
      with_yaml("ids:\n  telegram:\n    - \"555000111\"\n") do |floor|
        expect(floor.administrator?(adapter: :discord, native_id: "555000111")).to be(false)
      end
    end
  end

  describe "matching Matrix on the full MXID" do
    it "recognises a named MXID from either field" do
      with_yaml(%(matrix:\n  - "@ada:matrix.example.org"\n)) do |floor|
        expect(floor.administrator?(adapter: :matrix, native_id: "@ada:matrix.example.org")).to be(true)
        expect(floor.administrator?(adapter: :matrix, username: "@ada:matrix.example.org")).to be(true)
      end
    end

    it "refuses a bare localpart, which anyone can register on a homeserver of their own" do
      with_yaml(%(matrix:\n  - "@ada:matrix.example.org"\n)) do |floor|
        expect(floor.administrator?(adapter: :matrix, username: "ada")).to be(false)
        expect(floor.administrator?(adapter: :matrix, native_id: "@ada:evil.example")).to be(false)
      end
    end
  end

  describe "a file that cannot be read as a list of handles" do
    it "reads a missing file as nobody" do
      expect(described_class.load("/nonexistent/dashboard_administrators.yml")).to be_empty
    end

    it "reads an empty document as nobody" do
      with_yaml("") { |floor| expect(floor).to be_empty }
    end

    it "reads a document that is not a mapping as nobody" do
      with_yaml("- ada\n") { |floor| expect(floor).to be_empty }
    end

    it "reads a malformed document as nobody" do
      with_yaml("usernames: [unclosed\n") { |floor| expect(floor).to be_empty }
    end

    it "ignores a blank entry rather than handing every blank handle the deployment" do
      with_yaml("usernames:\n  - \"\"\n  - \"   \"\n") do |floor|
        expect(floor).to be_empty
        expect(floor.administrator?(adapter: :telegram, username: "")).to be(false)
        expect(floor.administrator?(adapter: :telegram, username: nil)).to be(false)
      end
    end
  end

  describe "#entries" do
    it "lists what was named, normalised, for display" do
      with_yaml(%(usernames:\n  - Ada\nmatrix:\n  - "@Grace:matrix.example.org"\n)) do |floor|
        expect(floor.entries).to eq(
          [{ handle: "@Grace:matrix.example.org", kind: "matrix" }, { handle: "ada", kind: "username" }]
        )
      end
    end
  end

  # The shipped file is loaded on every boot, so it has to parse and it has to
  # name nobody by default.
  describe "the file that ships with this repository" do
    it "parses to an empty floor" do
      expect(described_class.load(described_class::DEFAULT_PATH)).to be_empty
    end
  end
end
