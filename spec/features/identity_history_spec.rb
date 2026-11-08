# frozen_string_literal: true

require "spec_helper"

# The operator-gated /identity command: prints a person's name history (#1477),
# resolved by reply or by a typed handle, sourced from the real
# IdentityDirectory/BridgedNicknames a control-plane deployment already keeps.
RSpec.describe Rubotty::Features::IdentityHistory, :control_plane do
  let(:tg) { endpoint("tg", adapter: :telegram) }
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot") }
  let(:adapters) { Hash.new(adapter) }

  let(:db) { migrated_db }
  let(:models) { build_models(db) }
  let(:now) { Time.now }

  def community(slug)
    stamp = Time.now
    id = db[:communities].insert(slug: slug, name: slug.upcase, status: "active",
                                 settings: "{}", created_at: stamp, updated_at: stamp)
    id
  end

  let(:community_id) { community("sample") }

  let(:identity_directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }
  let(:bridged_nicknames) { Rubotty::ControlPlane::BridgedNicknames.new(models: models, logger: Rubotty::Log.null) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg)), logger: Rubotty::Log.null
    )
  end

  let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { telegram: ["op1"] }) }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
  let(:issuer) { author(native_id: "op1", username: "op") }
  let(:subject_author) { author(native_id: "u9", username: "ada") }

  def feature
    described_class.new(
      topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
      identity_directory: identity_directory, bridged_nicknames: bridged_nicknames,
      ephemeral: ephemeral
    )
  end

  def enable_identity_history
    models.feature_setting.create(
      community_id: community_id, room_id: nil, feature: "identity_history", enabled: true,
      config: "{}", created_at: now, updated_at: now
    )
  end

  def snapshot_community
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: community_id, slug: "sample", name: "sample", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: directory, people: Rubotty::Core::Directory.new,
      feature_settings: []
    )
  end

  def command(text, from: issuer, target: nil, native_id: "100")
    reply = target && Rubotty::Core::ReplyPreview.new(author: target, ref: ref("tg", "parent"))
    message(
      tg, text: text, native_id: native_id, author: from,
      reply_to: target && ref("tg", "parent"), reply_preview: reply
    )
  end

  def context(message, community: snapshot_community, config: {})
    Rubotty::Features::Context.new(message: message, config: config, community: community, operators: directory)
  end

  def last_ack = adapter.delivered_to("tg").last&.body&.text

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("identity_history")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "publishes a config schema for the dashboard and loader" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "carries a retention notice naming what it keeps" do
      expect(described_class.retention_notice).to include("USERNAME")
      expect(described_class.retention_notice).to include("BRIDGED NICKNAME")
    end
  end

  describe "#call" do
    it "is not recognised text: continues, leaving the chain to relay it" do
      outcome = feature.call(context(command("just chatting")))
      expect(outcome).to be_continue
    end

    it "refuses a non operator" do
      stranger = author(native_id: "s1", username: "stranger")
      outcome = feature.call(context(command("/identity", from: stranger, target: subject_author)))
      expect(outcome).to be_halt
      expect(last_ack).to include("operator standing")
    end

    it "asks for a reply or a handle when neither is given" do
      outcome = feature.call(context(command("/identity")))
      expect(outcome).to be_halt
      expect(last_ack).to include("needs either a reply")
    end

    it "reports no history kept when identity_history has never been on" do
      identity_directory.record(community_id: community_id, adapter: :telegram, native_id: "u9", username: "ada")

      feature.call(context(command("/identity", target: subject_author)))

      expect(last_ack).to include("No history kept")
    end

    it "prints the username/display-name history, resolved by reply, once the feature is on" do
      enable_identity_history
      identity_directory.record(community_id: community_id, adapter: :telegram, native_id: "u9",
                                username: "ada", display: "Ada")
      identity_directory.record(community_id: community_id, adapter: :telegram, native_id: "u9", username: "grace")

      feature.call(context(command("/identity", target: subject_author)))

      expect(last_ack).to include("username ada")
      expect(last_ack).to include("username grace")
    end

    it "resolves the subject by a typed handle when there is no reply" do
      enable_identity_history
      identity_directory.record(community_id: community_id, adapter: :telegram, native_id: "u9", username: "ada")

      feature.call(context(command("/identity ada")))

      expect(last_ack).to include("Name history for ada")
      expect(last_ack).to include("username ada")
    end

    it "asks for a reply or a handle when the typed handle resolves to nobody" do
      outcome = feature.call(context(command("/identity nobody-by-this-name")))
      expect(outcome).to be_halt
      expect(last_ack).to include("needs either a reply")
    end

    it "includes bridged nickname history alongside the username/display history" do
      enable_identity_history
      identity_directory.record(community_id: community_id, adapter: :telegram, native_id: "u9", username: "ada")
      person = bridged_nicknames.person_for(
        community_id: community_id, adapter: "telegram", native_id: "u9", username: "ada"
      )
      bridged_nicknames.set(community_id: community_id, person_id: person.id, adapter: "telegram", nickname: "River")

      feature.call(context(command("/identity", target: subject_author)))

      expect(last_ack).to include("Bridged nicknames:")
      expect(last_ack).to include("River")
    end
  end

  # /identity answered and left the typed command in the channel, which for a
  # command that names a person by handle is the half worth removing.
  describe "clearing up after itself" do
    let(:base) { Time.now }
    let(:clock) { -> { @now ||= base } }
    let(:scheduler) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null, clock: clock) }

    def advance(seconds) = (@now = (@now || base) + seconds)

    def feature
      described_class.new(
        topology: topology(room("r", tg)), adapters: adapters, logger: Rubotty::Log.null,
        identity_directory: identity_directory, bridged_nicknames: bridged_nicknames,
        ephemeral: ephemeral, cleanup: scheduler
      )
    end

    after { scheduler.stop }

    it "removes the invocation together with the reply it produced" do
      feature.call(context(command("/identity", target: subject_author, native_id: "typed-1"),
                           config: { ack_ttl_seconds: 5 }))

      advance(5)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg typed-1])
    end

    it "leaves the invocation where the scope asked to keep it" do
      feature.call(context(command("/identity", target: subject_author, native_id: "typed-2"),
                           config: { ack_ttl_seconds: 5, delete_command_message: false }))

      advance(5)
      scheduler.run_due

      expect(adapter.deleted).not_to include(%w[tg typed-2])
    end

    # A refusal is still an answer, so it is cleared up like an accepted command.
    it "clears up after the operator refusal too" do
      feature.call(context(command("/identity", from: author(native_id: "nobody"), native_id: "typed-3"),
                           config: { ack_ttl_seconds: 5 }))

      advance(5)
      scheduler.run_due

      expect(adapter.deleted).to include(%w[tg typed-3])
    end

    it "reads its window from the same key every other command feature uses" do
      feature.call(context(command("/identity", target: subject_author, native_id: "typed-4"),
                           config: { ack_ttl_seconds: 0 }))

      expect(scheduler.pending).to eq(0)
      expect(last_ack).to include("Name history")
    end
  end
end
