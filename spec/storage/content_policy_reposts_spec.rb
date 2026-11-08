# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::ControlPlane::ContentPolicyReposts, :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.first }
  let(:now) { Time.utc(2026, 11, 5, 12) }
  let(:ledger) { described_class.new(models: models, logger: Rubotty::Log.null, clock: -> { now }) }
  let(:source) { endpoint("restored-source", adapter: :telegram, account: "primary") }
  let(:directory) { Rubotty::Core::Moderation::Directory.new([]) }

  def record(**changes)
    ledger.record(**{ community_id: community.id, adapter: :telegram, endpoint_id: source.id,
      native_id: "restored-1", author_native_id: "member-9", identity_verified: true }.merge(changes))
  end

  def allowed?(**changes)
    ledger.deletable_by?(**{ endpoint_id: source.id, native_id: "restored-1",
      author_native_id: "member-9" }.merge(changes))
  end

  def command_for(origin: source, member: "member-9", native_id: "restored-1", verb: "delete")
    commands = Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS,
      reposts: ledger, logger: Rubotty::Log.null)
    preview = Rubotty::Core::ReplyPreview.new(author: author(native_id: "the-bot"),
      body: Rubotty::Core::RichText.plain("Restored on behalf of a member"))
    message = message(origin, text: "/#{verb}", author: author(native_id: member),
      reply_to: Rubotty::Core::MessageRef.new(origin.id, native_id), reply_preview: preview)
    commands.parse(message, directory: directory)
  end

  it "grants only the restored author's delete command through the real database" do
    record

    command = command_for

    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.action).to eq(:delete)
    expect(command.issuer).to be_nil
    expect(command_for(member: "somebody-else")).to be_a(Rubotty::Core::Commands::Refusal)
    expect(command_for(native_id: "other-message")).to be_a(Rubotty::Core::Commands::Refusal)
    expect(command_for(origin: endpoint("other-endpoint", adapter: :telegram)))
      .to be_a(Rubotty::Core::Commands::Refusal)
    expect(command_for(verb: "pin")).to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "retains authority across service instances and revokes it when the copy is forgotten" do
    record
    reopened = described_class.new(models: models)
    expect(reopened.deletable_by?(endpoint_id: source.id, native_id: "restored-1", author_native_id: "member-9"))
      .to be(true)

    expect(reopened.forget(endpoint_id: source.id, native_id: "restored-1")).to eq(1)
    expect(reopened.forget(endpoint_id: source.id, native_id: "restored-1")).to eq(0)
    expect(command_for).to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "does not reassign a copy's owner when a duplicate or conflicting write is retried" do
    first = record
    record
    record(author_native_id: "attacker", adapter: :discord)

    expect(models.content_policy_repost.count).to eq(1)
    expect(models.content_policy_repost.first.id).to eq(first.id)
    expect(allowed?).to be(true)
    expect(allowed?(author_native_id: "attacker")).to be(false)
  end

  it "keeps an unproven direct write as tracking metadata without authorizing deletion" do
    record(identity_verified: false)

    expect(models.content_policy_repost.count).to eq(1)
    expect(allowed?).to be(false)
  end

  it "refuses unstable nick grants even if a stale caller marks them verified" do
    record(adapter: :irc, author_native_id: "Alice")
    record(adapter: :xmpp, native_id: "xmpp-copy", author_native_id: "occupant:Alice")

    expect(allowed?(author_native_id: "Alice")).to be(false)
    expect(allowed?(native_id: "xmpp-copy", author_native_id: "occupant:Alice")).to be(false)
  end

  it "preserves legacy rows and action evidence while invalidating unprovable old grants on upgrade" do
    db = Sequel.sqlite
    migrations = File.expand_path("../../db/migrations", __dir__)
    Sequel::Migrator.run(db, migrations, target: 104)
    old_models = Rubotty::ControlPlane.models(db)
    old_community = old_models.community.create(slug: "legacy", name: "Legacy", status: "active",
      settings: "{}", created_at: now, updated_at: now)
    old_action = Rubotty::ControlPlane::ContentPolicyActions.new(models: old_models).record(
      community_id: old_community.id, adapter: :telegram, endpoint_id: "old-source", native_id: "old-original",
      action: "delete", author_native_id: "777", body: "retained action evidence"
    )
    old_copy = { community_id: old_community.id, adapter: "discord", endpoint_id: "old-copy-endpoint",
      native_id: "old-copy", author_native_id: "777", created_at: now }
    copy_id = db[:content_policy_reposts].insert(old_copy)

    Sequel::Migrator.run(db, migrations)

    upgraded = described_class.new(models: Rubotty::ControlPlane.models(db))
    expect(upgraded.deletable_by?(endpoint_id: "old-copy-endpoint", native_id: "old-copy", author_native_id: "777"))
      .to be(false)
    expect(db[:content_policy_reposts].where(id: copy_id).first).to include(old_copy.merge(identity_verified: false))
    expect(db[:content_policy_actions].where(id: old_action.id).get(:body)).to eq("retained action evidence")
  ensure
    db&.disconnect
  end

  it "refuses rollback with tracked copies instead of reviving old deletion grants" do
    record(identity_verified: false)
    migrations = File.expand_path("../../db/migrations", __dir__)

    expect { Sequel::Migrator.run(models.db, migrations, target: 104) }
      .to raise_error(Sequel::Error, /restoration tracking/)
    expect(models.db.schema(:content_policy_reposts).map(&:first)).to include(:identity_verified)
    expect(models.content_policy_repost.count).to eq(1)
    expect(allowed?).to be(false)
  end

  it "allows an empty disposable schema to roll back and migrate forward again" do
    migrations = File.expand_path("../../db/migrations", __dir__)

    Sequel::Migrator.run(models.db, migrations, target: 104)
    expect(models.db.schema(:content_policy_reposts).map(&:first)).not_to include(:identity_verified)
    Sequel::Migrator.run(models.db, migrations)
    expect(models.db.schema(:content_policy_reposts).map(&:first)).to include(:identity_verified)
    expect(models.content_policy_repost.count).to eq(0)
  end

  it "isolates two endpoints that happen to reuse the same platform message number" do
    record
    record(endpoint_id: "restored-peer", native_id: "restored-1", author_native_id: "peer-author")

    expect(allowed?).to be(true)
    expect(allowed?(endpoint_id: "restored-peer")).to be(false)
    expect(allowed?(endpoint_id: "restored-peer", author_native_id: "peer-author")).to be(true)
    ledger.forget(endpoint_id: source.id, native_id: "restored-1")
    expect(allowed?(endpoint_id: "restored-peer", author_native_id: "peer-author")).to be(true)
  end

  it "treats numeric platform IDs consistently without granting blank identities" do
    record(native_id: 901, author_native_id: 77)

    expect(allowed?(native_id: "901", author_native_id: "77")).to be(true)
    expect(allowed?(native_id: "901", author_native_id: "")).to be(false)
    expect(allowed?(endpoint_id: "")).to be(false)
    expect(allowed?(native_id: nil)).to be(false)
  end

  it "creates no grants when required ownership fields are missing" do
    %i[community_id endpoint_id native_id author_native_id].each { |field| expect(record(field => nil)).to be_nil }

    expect(models.content_policy_repost.count).to eq(0)
    expect(command_for).to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "removes only expired grants and honors the bounded retention window" do
    record(native_id: "old")
    models.content_policy_repost.where(native_id: "old").update(created_at: now - (31 * 86_400))
    record(native_id: "current")

    expect(ledger.prune(window_days: 365)).to eq(1)
    expect(allowed?(native_id: "old")).to be(false)
    expect(allowed?(native_id: "current")).to be(true)
    expect(ledger.prune).to eq(0)
  end

  it "cascades grants away when their owning community is removed" do
    record
    models.community.where(id: community.id).delete

    expect(allowed?).to be(false)
    expect(models.content_policy_repost.count).to eq(0)
  end

  it "fails closed if the authorization table cannot be read" do
    record
    models.db.drop_table(:content_policy_reposts)

    expect(allowed?).to be(false)
    expect(command_for).to be_a(Rubotty::Core::Commands::Refusal)
    expect(record).to be_nil
    expect(ledger.forget(endpoint_id: source.id, native_id: "restored-1")).to eq(0)
    expect(ledger.prune).to eq(0)
  end

  def note_restoration(target, origin: source, author_native_id: "777")
    routing = Struct.new(:id, :rooms).new(community.id, [
      Rubotty::Core::Room.new(id: "restored-room", endpoints: [origin, target], community_id: community.id)
    ])
    actions = Rubotty::ControlPlane::ContentPolicyActions.new(models: models)
    action = actions.record(community_id: community.id, adapter: origin.adapter_name, endpoint_id: origin.id,
      native_id: "removed", action: "delete", author_native_id: author_native_id, body: "removed words")
    copy = Struct.new(:endpoint, :native_id).new(target, "copy-on-target")
    group = Struct.new(:copies).new([copy])
    vindication = Rubotty::ContentPolicy::Vindication.new(adapters: {}, ephemeral: nil,
      actions: actions, reposts: ledger, logger: Rubotty::Log.null)
    vindication.send(:note_reposts, routing, target, action, group)
  end

  it "does not grant a different platform's user merely because their numeric ID collides" do
    target = endpoint("restored-discord", adapter: :discord, account: "primary")

    note_restoration(target)

    expect(command_for(origin: target, member: "777", native_id: "copy-on-target"))
      .to be_a(Rubotty::Core::Commands::Refusal)
    expect(models.content_policy_repost.count).to eq(0)
  end

  it "does not reuse a native ID across separate accounts of the same adapter" do
    target = endpoint("restored-other-account", adapter: :telegram, account: "another")

    note_restoration(target)

    expect(command_for(origin: target, member: "777", native_id: "copy-on-target"))
      .to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "keeps a verified original native namespace usable on same-account copies" do
    target = endpoint("restored-same-account", adapter: :telegram, account: source.account)

    note_restoration(target)

    command = command_for(origin: target, member: "777", native_id: "copy-on-target")
    expect(command).to be_a(Rubotty::Core::Moderation::Command)
    expect(command.action).to eq(:delete)
    expect(command_for(origin: target, member: "other", native_id: "copy-on-target"))
      .to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "does not turn an XMPP room occupant nickname into a lasting deletion grant" do
    origin = endpoint("xmpp-original", adapter: :xmpp, account: "xmpp")
    target = endpoint("xmpp-copy", adapter: :xmpp, account: "xmpp")

    note_restoration(target, origin: origin, author_native_id: "occupant:Alice")

    expect(command_for(origin: target, member: "occupant:Alice", native_id: "copy-on-target"))
      .to be_a(Rubotty::Core::Commands::Refusal)
  end

  it "preserves the trusted scoped IRC account identity accepted by the canonical helper" do
    origin = endpoint("irc-account-original", adapter: :irc, account: "network")
    target = endpoint("irc-account-copy", adapter: :irc, account: "network")
    identity = "account:network:alice"
    expect(Rubotty::Security::GrantIdentity.native_id(adapter: :irc, native_id: identity)).to eq(identity)

    note_restoration(target, origin: origin, author_native_id: identity)

    expect(command_for(origin: target, member: identity, native_id: "copy-on-target"))
      .to be_a(Rubotty::Core::Moderation::Command)
  end

  it "restores an IRC message without letting a later holder of its ordinary nick delete it" do
    origin = endpoint("irc-restored", adapter: :irc, account: "irc", settings: { channel: "#fixture" })
    topology = topology(room("fixture", origin, community_id: community.id))
    routing = Struct.new(:id, :rooms).new(community.id, topology.rooms)
    client = IrcFakes::Client.new(
      negotiated_capabilities: %w[message-tags msgid draft/message-redaction], next_native_id: "restored-msgid"
    )
    adapter = Rubotty::Adapters::Irc::Adapter.new(account: "irc",
      settings: { server: "irc.invalid", nick: "rubotty" }, dispatcher: nil,
      logger: Rubotty::Log.null, endpoints: [origin]).replace_client(client)
    adapter.start
    inbound = Rubotty::Adapters::Irc::Inbound.new(endpoint_for: ->(_) { origin })
    original = inbound.message("channel" => "#fixture", "nick" => "Alice", "body" => "original", "msgid" => "original-id")
    actions = Rubotty::ControlPlane::ContentPolicyActions.new(models: models)
    action = actions.record(community_id: community.id, adapter: :irc, endpoint_id: origin.id,
      native_id: "original-id", action: "delete", author_native_id: original.author.native_id, body: "original")
    adapters = { [:irc, "irc"] => adapter }
    ephemeral = Rubotty::Core::EphemeralMessage.new(adapters: adapters,
      session_id: "finite-fixture", topology: topology, logger: Rubotty::Log.null)
    service = Rubotty::ContentPolicy::Vindication.new(adapters: adapters,
      ephemeral: ephemeral, actions: actions, reposts: ledger, logger: Rubotty::Log.null)

    expect(service.send(:repost, routing, origin, action, "corrected", mention: true)).to be(true)
    expect(adapter.capabilities_for(origin)).to be_deletes
    expect(client.messages.last[:text]).to include("original")
    later = inbound.message("channel" => "#fixture", "nick" => "Alice", "body" => "/delete",
      "msgid" => "later-command", "reply_to" => "restored-msgid")
    commands = Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS, reposts: ledger)

    expect(commands.parse(later, directory: directory)).to be_a(Rubotty::Core::Commands::Refusal)
    expect(models.content_policy_repost.count).to eq(0)
    expect(client.redactions).to be_empty
  ensure
    adapter&.stop
  end
end
