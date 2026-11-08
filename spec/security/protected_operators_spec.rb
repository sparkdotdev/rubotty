# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# Deployment-managed recovery identities provide the owner-level safety floor.
# Configured native IDs are authoritative; explicitly configured compatibility
# handles are exercised separately from spoofable display names.
RSpec.describe Rubotty::Security::ProtectedOperators do
  subject(:protected_operators) { described_class.default }

  describe "matching a bare username on a platform that issues the handle" do
    it "recognises `maintainer` as an owner, in any case and with stray whitespace" do
      %w[telegram discord].each do |adapter|
        expect(protected_operators.owner?(adapter: adapter, username: "maintainer")).to be(true)
        expect(protected_operators.owner?(adapter: adapter, username: "MAINTAINER")).to be(true)
        expect(protected_operators.owner?(adapter: adapter, username: "  Main Tainer  ")).to be(true)
      end
    end

    it "recognises the second deployment-configured handle `owner_handle`" do
      expect(protected_operators.owner?(adapter: :discord, username: "owner_handle")).to be(true)
      expect(protected_operators.owner?(adapter: :telegram, username: "Owner_Handle")).to be(true)
    end

    it "recognises the third deployment-configured handle `sample_owner`" do
      expect(protected_operators.owner?(adapter: :telegram, username: "sample_owner")).to be(true)
      expect(protected_operators.owner?(adapter: :discord, username: "Sample_Owner")).to be(true)
    end

    it "does not recognise an unrelated username" do
      expect(protected_operators.owner?(adapter: :telegram, username: "ada")).to be(false)
      expect(protected_operators.owner?(adapter: :telegram, username: nil)).to be(false)
    end
  end

  describe "the USERNAME-only rule" do
    # owner? has no display-name parameter at all: the class is structurally
    # incapable of reading one. This asserts the value that WOULD be a display
    # name, offered as a username, is the only thing that can match, and the
    # matching handle offered in any other position does not leak through.
    it "matches only the username, so a display name never grants access" do
      # A person whose display name is "maintainer" but whose username is not is not
      # an owner: only the username is ever consulted.
      expect(protected_operators.owner?(adapter: :telegram, username: "impostor")).to be(false)
      # The native id is not the username on a non-federated platform, so a
      # numeric id that happens to read like the handle is not matched either.
      expect(protected_operators.owner?(adapter: :telegram, native_id: "maintainer")).to be(false)
    end
  end

  describe "Matrix, the federated exception" do
    let(:mxid) { "@owner:matrix.example.org" }

    it "matches the full MXID (arriving as the native id on Matrix)" do
      expect(protected_operators.owner?(adapter: :matrix, native_id: mxid, username: "owner")).to be(true)
    end

    it "does not normalise a different Matrix account or an invalid padded MXID into an owner" do
      expect(protected_operators.owner?(adapter: :matrix, native_id: "@Owner:matrix.example.org")).to be(false)
      expect(protected_operators.owner?(adapter: :matrix, native_id: "@owner:MATRIX.EXAMPLE.ORG")).to be(false)
      expect(protected_operators.owner?(adapter: :matrix, native_id: "@Owner : Matrix.Example.Org")).to be(false)
    end

    it "does NOT match a bare localpart on Matrix (a localpart is not owned there)" do
      expect(protected_operators.owner?(adapter: :matrix, username: "owner")).to be(false)
    end

    it "does not treat a bare non-federated username as an owner on Matrix" do
      expect(protected_operators.owner?(adapter: :matrix, username: "maintainer")).to be(false)
    end

    it "does not grant a Matrix MXID on a non-federated platform" do
      expect(protected_operators.owner?(adapter: :telegram, username: mxid)).to be(false)
      expect(protected_operators.owner?(adapter: :telegram, native_id: mxid)).to be(false)
    end
  end

  describe "matching a native id, which a rename cannot recycle (issue #639)" do
    let(:floor) { described_class.new(usernames: [], matrix_ids: [], ids: { "telegram" => ["555000111"] }) }

    it "recognises the configured native id regardless of the username presented" do
      expect(floor.owner?(adapter: :telegram, native_id: "555000111", username: "anybody")).to be(true)
      expect(floor.owner?(adapter: :telegram, native_id: "555000111")).to be(true)
    end

    it "refuses whoever now holds the username, when the id does not match" do
      expect(floor.owner?(adapter: :telegram, native_id: "999999999", username: "anybody")).to be(false)
    end

    it "scopes an id to its own adapter" do
      expect(floor.owner?(adapter: :discord, native_id: "555000111")).to be(false)
    end

    it "labels the operator by the id when the id is what matched" do
      operator = floor.operator_for(adapter: :telegram, native_id: "555000111", username: "anybody")
      expect(operator.name).to eq("protected-operator:555000111")
    end

    it "is read from the ids: section of the YAML" do
      with_yaml("usernames: []\nids:\n  telegram:\n    - \"42\"\n") do |path|
        loaded = described_class.load(path)
        expect(loaded.owner?(adapter: :telegram, native_id: "42")).to be(true)
      end
    end

    it "grants no id-based access when the file is missing, since ids have no deployment-configured fallback" do
      loaded = described_class.load("/no/such/protected_operators.yml")
      expect(loaded.owner?(adapter: :telegram, native_id: "555000111")).to be(false)
    end
  end

  describe "the gap a bare username entry leaves open to a rename, and how an id closes it" do
    it "a bare username entry cannot tell the original owner from whoever holds the handle after a rename" do
      floor = described_class.new(usernames: ["maintainer"], matrix_ids: [])
      expect(floor.owner?(adapter: :telegram, username: "maintainer")).to be(true)
    end

    it "an id-pinned entry is unmoved: the id settles it, not whoever now holds the old username" do
      floor = described_class.new(usernames: [], matrix_ids: [], ids: { "telegram" => ["555000111"] })
      expect(floor.owner?(adapter: :telegram, native_id: "555000111", username: "maintainer")).to be(true)
      expect(floor.owner?(adapter: :telegram, native_id: "999999999", username: "maintainer")).to be(false)
    end
  end

  describe "#operator_for" do
    it "returns an owner-level operator authorised for every action in every room" do
      operator = protected_operators.operator_for(adapter: :telegram, username: "maintainer")
      expect(operator).to be_a(Rubotty::Core::Moderation::Operator)
      expect(operator.actions).to eq(:all)
      expect(operator.rooms).to eq(:all)
      expect(operator.may?(:ban, "any-room", community_id: 1)).to be(true)
      expect(operator.may?(:delete, "another-room", community_id: 1)).to be(true)
    end

    it "returns nil for a handle that is not on the whitelist" do
      expect(protected_operators.operator_for(adapter: :telegram, username: "ada")).to be_nil
    end

    it "labels the owner by the matched handle, for the audit trail" do
      expect(protected_operators.operator_for(adapter: :telegram, username: "maintainer").name)
        .to eq("protected-operator:maintainer")
    end
  end

  describe "unconfigured deployment", :release_defaults do
    it "grants nothing if the configuration is missing" do
      expect(described_class.load("/no/such/operators.yml")).to be_empty
    end

    it "grants nothing if the configuration is malformed" do
      with_yaml("usernames: [broken") { |path| expect(described_class.load(path)).to be_empty }
    end

    it "ships no privileged identities" do
      expect(described_class.load(described_class::DEFAULT_PATH)).to be_empty
    end

    it "loads an explicitly configured identity" do
      with_yaml("ids:\n  telegram: [\"42\"]\n") do |path|
        expect(described_class.load(path).owner?(adapter: :telegram, native_id: "42")).to be(true)
      end
    end
  end

  describe "#entries" do
    it "lists every deployment-configured handle, tagged by kind, for display (issue #153)" do
      expect(protected_operators.entries).to contain_exactly(
        { handle: "maintainer", kind: "username" },
        { handle: "owner_handle", kind: "username" },
        { handle: "sample_owner", kind: "username" },
        { handle: "@owner:matrix.example.org", kind: "matrix" }
      )
    end

    it "lists a configured id, tagged by adapter (issue #639)" do
      floor = described_class.new(usernames: [], matrix_ids: [], ids: { "telegram" => ["555000111"], "discord" => ["222"] })
      expect(floor.entries).to contain_exactly(
        { handle: "555000111", kind: "telegram_id" },
        { handle: "222", kind: "discord_id" }
      )
    end
  end

  describe "#protects_any?" do
    it "is true when one of several identities matches a deployment-configured username" do
      identities = [
        { adapter: "telegram", username: "someone_else", native_id: "1" },
        { adapter: "discord", username: "maintainer", native_id: "2" }
      ]
      expect(protected_operators.protects_any?(identities)).to be(true)
    end

    it "is true for the Matrix MXID, arriving as native_id" do
      identities = [{ adapter: "matrix", username: "owner", native_id: "@owner:matrix.example.org" }]
      expect(protected_operators.protects_any?(identities)).to be(true)
    end

    it "is false when no identity matches" do
      identities = [{ adapter: "telegram", username: "ada", native_id: "1" }]
      expect(protected_operators.protects_any?(identities)).to be(false)
    end

    it "is false for an empty list" do
      expect(protected_operators.protects_any?([])).to be(false)
    end
  end

  describe "the shipped default" do
    it "loads the committed config/protected_operators.yml and is never empty" do
      expect(described_class.default).not_to be_empty
      expect(described_class.default.owner?(adapter: :telegram, username: "maintainer")).to be(true)
    end
  end

  def with_yaml(contents)
    Tempfile.create(["protected_operators", ".yml"]) do |file|
      file.write(contents)
      file.flush
      yield file.path
    end
  end
end

# The floor as it is actually consulted: through the operator directory the
# moderation pipeline authorises against, and end to end through the command
# parser. This is the "may perform operator actions in any room" guarantee.
RSpec.describe "Rubotty::Core::Moderation::Directory owner floor (issue #119)" do
  let(:directory) { Rubotty::Core::Moderation::Directory.new(explicit_operators) }
  let(:explicit_operators) { [] }

  it "resolves a deployment-configured USERNAME to an owner-level operator with no DB/config row" do
    operator = directory.resolve(:telegram, "no-such-native-id", username: "maintainer")
    expect(operator).not_to be_nil
    expect(operator.may?(:ban, "any-room", community_id: 1)).to be(true)
    expect(operator.may?(:delete, "some-other-room", community_id: 1)).to be(true)
  end

  it "matches the USERNAME, not the display name" do
    # The directory only ever receives the username. A person whose display name
    # is "maintainer" but whose username differs is passed their real (different)
    # username here, and does not resolve.
    expect(directory.resolve(:telegram, "42", username: "impostor")).to be_nil
    # The same person, now actually holding the username, does resolve.
    expect(directory.resolve(:telegram, "42", username: "maintainer")).not_to be_nil
  end

  it "does not grant anything when no username is supplied (native id alone)" do
    expect(directory.resolve(:telegram, "maintainer")).to be_nil
  end

  it "grants the Matrix owner by MXID but not a bare localpart" do
    expect(directory.resolve(:matrix, "@owner:matrix.example.org", username: "owner")).not_to be_nil
    expect(directory.resolve(:matrix, "some-id", username: "owner")).to be_nil
  end

  context "with a DB/config operator present (the OR path stays intact)" do
    let(:explicit_operators) do
      [Rubotty::Core::Moderation::Operator.new(name: "DB Op", identities: { telegram: ["55"] })]
    end

    it "still resolves the explicit operator by native id" do
      expect(directory.resolve(:telegram, "55").name).to eq("DB Op")
    end

    it "resolves the owner floor for the author's username, additively" do
      owner = directory.resolve(:telegram, "999", username: "maintainer")
      expect(owner).not_to be_nil
      expect(owner.name).to eq("protected-operator:maintainer")
    end

    it "reports empty? on the EXPLICIT operators only, so existing gating is unchanged" do
      expect(Rubotty::Core::Moderation::Directory.new([]).empty?).to be(true)
      expect(directory.empty?).to be(false)
    end
  end

  context "when the floor is explicitly disabled" do
    let(:directory) { Rubotty::Core::Moderation::Directory.new([], protected_operators: nil) }

    it "no longer grants the deployment-configured owner (the floor is the only thing granting)" do
      expect(directory.resolve(:telegram, "x", username: "maintainer")).to be_nil
    end
  end
end

RSpec.describe "Rubotty::Core::Commands owner floor end to end (issue #119)" do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  # A single unrelated DB operator, so the command surface is enabled. The owner
  # is deliberately NOT among these, modelling the real threat: the system has
  # operators, but the author's row was removed, and the floor must still stand.
  let(:directory) do
    Rubotty::Core::Moderation::Directory.new(
      [Rubotty::Core::Moderation::Operator.new(name: "Someone Else", identities: { telegram: ["55"] })]
    )
  end
  subject(:commands) { Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, logger: Rubotty::Log.null) }

  def issue(text, author:, reply_to: ref("tg", "900"))
    commands.parse(message(tg, text: text, author: author, reply_to: reply_to), directory: directory)
  end

  it "lets a deployment-configured USERNAME issue an operator action with no DB row of their own" do
    owner = author(native_id: "77777", username: "maintainer", display_name: "Some Display Name")
    command = issue("/ban", author: owner)
    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.action).to eq(:ban)
    expect(command.issuer).not_to be_nil
    expect(command.issuer.may?(:ban, "any-room", community_id: 1)).to be(true)
  end

  it "refuses a user whose DISPLAY name is the owner handle but whose username is not" do
    impostor = author(native_id: "88888", username: "not_the_owner", display_name: "maintainer")
    expect(issue("/ban", author: impostor)).to be_a(Rubotty::Core::Commands::Refusal)
  end
end
