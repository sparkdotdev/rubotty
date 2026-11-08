# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::ModeratedRoom do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc", adapter: :discord) }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  def feature(ephemeral: nil, cleanup: nil, audit: nil, feature_controls: nil)
    described_class.new(
      topology: topology(room("r", tg, dc)), adapters: adapters, storage: storage,
      logger: Rubotty::Log.null, ephemeral: ephemeral, cleanup: cleanup, audit: audit,
      feature_controls: feature_controls
    )
  end

  def context(msg, config: {}, operators: nil)
    Rubotty::Features::Context.new(message: msg, config: config, operators: operators)
  end

  def post(origin: tg, native_id: "1", author_id: "member", kind: :chat, reply_to: nil,
           reply_author: nil, thread: nil)
    preview = reply_author && Rubotty::Core::ReplyPreview.new(author: reply_author)
    message(
      origin, text: "hello", native_id: native_id, kind: kind,
      author: author(native_id: author_id, username: "#{author_id}_handle"),
      reply_to: reply_to, reply_preview: preview, thread: thread
    )
  end

  let(:approved_config) { { approved_users: ["fake:approved"] } }

  describe "the feature contract" do
    it "is off by default, covers posts and edits, and publishes its room config" do
      expect(described_class.feature_name).to eq("moderated_room")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat edit])

      config = described_class.config_schema.call({})
      expect(config).to be_valid
      expect(config.value).to include(
        approved_users: [], pending_handles: [], allow_replies_to_approved_users: false,
        locked: false, removal_notice_ttl_seconds: 60
      )
    end
  end

  describe "the approved-user whitelist" do
    it "allows an approved identity to post" do
      outcome = feature.call(context(post(author_id: "approved"), config: approved_config))

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "keys an approval to the source platform as well as the native id" do
      outcome = feature.call(
        context(post(origin: dc, author_id: "approved"), config: approved_config)
      )

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["dc", "1"]])
    end

    it "fails closed when a moderated room has no approved users" do
      outcome = feature.call(context(post, config: {}))

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "removes an unapproved post before a downstream bridge can relay it", :control_plane do
      bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: adapters, storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null
      )
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: 1, route_key: tg.id)
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg, dc)]), channels: [channel],
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "moderated_room", enabled: true, config: approved_config
          )
        ]
      )
      registry = instance_double(
        Rubotty::ControlPlane::Registry,
        current: Rubotty::ControlPlane::Snapshot.new(communities: [community])
      )
      pipeline = Rubotty::Features::Pipeline.new(features: [feature, bridge], registry: registry)

      pipeline.handle(post)

      expect(adapter.deleted).to eq([["tg", "1"]])
      expect(adapter.delivered).to be_empty
    end

    it "removes an edited unapproved post and every copy already in the message map" do
      storage.record(source: ref("tg", "1"), destination: ref("dc", "copied"), room_id: "r")

      outcome = feature.call(context(post(kind: :edit), config: approved_config))

      expect(outcome).to be_halt
      expect(adapter.deleted).to contain_exactly(["tg", "1"], ["dc", "copied"])
    end
  end

  # Every example above calls #call directly, so it keeps passing whatever the
  # observes list says. These drive one real message per observed kind through a
  # real Pipeline, which is the only place the list is ever read.
  describe "every kind it observes, driven through the real pipeline", :control_plane do
    # The gate is off by code default, so a row has to switch it on before the
    # pipeline will run it at all.
    let(:pipeline) do
      channels = [tg, dc].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg, dc)]), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "moderated_room", enabled: true, config: approved_config
          )
        ]
      )
      Rubotty::Features::Pipeline.new(
        features: [feature],
        registry: instance_double(
          Rubotty::ControlPlane::Registry,
          current: Rubotty::ControlPlane::Snapshot.new(communities: [community])
        )
      )
    end

    observes_kind :chat, "a post from somebody off the list is removed before anyone reads it" do
      pipeline.handle(post)
      adapter.deleted
    end

    observes_kind :edit, "an old message edited into a new post is removed the same way" do
      pipeline.handle(post(kind: :edit))
      adapter.deleted
    end

    covers_every_observed_kind
  end

  describe "room-scoped configuration", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community_row) { models.community.where(slug: "sample").first }
    let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

    it "stores an approved list on one room through the ordinary feature controls" do
      controls.enable(community: community_row, selector: "general", feature: "moderated_room")
      controls.set(
        community: community_row, selector: "general", feature: "moderated_room",
        key: "approved_users", value: ["telegram:111", "discord:222"]
      )
      controls.set(
        community: community_row, selector: "general", feature: "moderated_room",
        key: "allow_replies_to_approved_users", value: true
      )

      registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts)
      community = registry.current.community("sample")
      channel = registry.current.channel_by_endpoint_key("tg-general")

      expect(community.feature_enabled?(channel, "moderated_room")).to be(true)
      expect(community.feature_config(channel, "moderated_room")).to include(
        approved_users: ["telegram:111", "discord:222"], allow_replies_to_approved_users: true
      )
    end
  end

  describe "the optional reply exemption" do
    let(:approved_author) { author(native_id: "approved", username: "approved_handle") }
    let(:unapproved_author) { author(native_id: "unapproved", username: "unapproved_handle") }
    let(:reply_config) { approved_config.merge(allow_replies_to_approved_users: true) }

    it "is off by default, so a reply cannot bypass the whitelist" do
      outcome = feature.call(
        context(post(reply_to: ref("tg", "parent"), reply_author: approved_author), config: approved_config)
      )

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "allows an unapproved person to reply to an approved poster when enabled" do
      outcome = feature.call(
        context(post(reply_to: ref("tg", "parent"), reply_author: approved_author), config: reply_config)
      )

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "allows a reply to a relayed copy of an approved post when the source is still known" do
      subject = feature
      source = post(native_id: "source", author_id: "approved")
      subject.call(context(source, config: approved_config))
      storage.record(source: source.ref, destination: ref("dc", "copy"), room_id: "r")

      outcome = subject.call(
        context(post(origin: dc, reply_to: ref("dc", "copy")), config: reply_config)
      )

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "keeps a reply to an unapproved poster blocked" do
      outcome = feature.call(
        context(post(reply_to: ref("tg", "parent"), reply_author: unapproved_author), config: reply_config)
      )

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "fails closed when a reply carries no parent author" do
      outcome = feature.call(context(post(reply_to: ref("tg", "parent")), config: reply_config))

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "allows a native thread rooted by an approved poster when enabled" do
      thread = Rubotty::Core::ThreadRef.new(native_id: "thread", creator_native_id: "approved")
      outcome = feature.call(context(post(thread: thread), config: reply_config))

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "keeps a thread rooted by an unapproved poster blocked" do
      thread = Rubotty::Core::ThreadRef.new(native_id: "thread", creator_native_id: "unapproved")
      outcome = feature.call(context(post(thread: thread), config: reply_config))

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end
  end

  describe "a locked room (#1723)" do
    let(:operator_person) do
      Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["op-1"] })
    end
    let(:operators) { Rubotty::Core::Moderation::Directory.new([operator_person]) }
    let(:locked_config) { { locked: true } }

    it "removes a non-operator's post through the same removal flow an unapproved poster gets" do
      outcome = feature.call(context(post(author_id: "member"), config: locked_config, operators: operators))

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "still lets an operator post" do
      outcome = feature.call(context(post(author_id: "op-1"), config: locked_config, operators: operators))

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "ignores approved_users entirely, blocking even a whitelisted non-operator" do
      config = locked_config.merge(approved_users: ["fake:approved"])
      outcome = feature.call(context(post(author_id: "approved"), config: config, operators: operators))

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "does not honour the reply-to-an-approved-poster exemption even when it is configured on" do
      approved_author = author(native_id: "approved", username: "approved_handle")
      config = locked_config.merge(approved_users: ["fake:approved"], allow_replies_to_approved_users: true)

      outcome = feature.call(
        context(post(reply_to: ref("tg", "parent"), reply_author: approved_author), config: config, operators: operators)
      )

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([["tg", "1"]])
    end

    it "gives the plain removal reason rather than the reply-exemption wording, even with replies configured on" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      config = locked_config.merge(allow_replies_to_approved_users: true)

      feature(ephemeral: ephemeral, cleanup: cleanup).call(
        context(post(author_id: "member"), config: config, operators: operators)
      )

      text = adapter.delivered_to("tg").last.body.text
      expect(text).to include("This room is moderated and only approved members may post.")
      expect(text).not_to include("you may reply")
    end
  end

  describe "the acknowledgement" do
    it "posts a self-deleting source-side acknowledgement that names the restriction" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )

      feature(ephemeral: ephemeral, cleanup: cleanup).call(
        context(post(author_id: "member"), config: approved_config.merge(removal_notice_ttl_seconds: 30))
      )

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq(
        "Ada Your last message was automatically removed: " \
        "This room is moderated and only approved members may post."
      )
      expect(notice.body.spans.find { |span| span.kind == :mention }.attributes).to eq(fake_id_for_target: "member")
      expect(cleanup).to have_received(:after).with(30)
      expect(adapter.delivered_to("dc")).to be_empty
    end

    it "explains the reply exception when that mode is enabled" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )

      feature(ephemeral: ephemeral, cleanup: cleanup).call(
        context(post, config: approved_config.merge(allow_replies_to_approved_users: true))
      )

      expect(adapter.delivered_to("tg").last.body.text).to include("you may reply to an approved poster")
    end
  end

  describe "the moderation audit" do
    let(:audit) do
      Class.new do
        attr_reader :events

        def initialize = @events = []

        def record(**event) = @events << event
      end.new
    end

    it "records the removal under the moderated-room source" do
      feature(audit: audit).call(context(post, config: approved_config))

      expect(audit.events.last).to include(
        source: "moderated_room", action: "delete", subject_native_id: "member",
        reason: "This room is moderated and only approved members may post."
      )
    end
  end

  describe "the /whitelist and /unwhitelist commands", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community_row) { models.community.where(slug: "sample").first }
    let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

    let(:operator_person) do
      Rubotty::Core::Moderation::Operator.new(name: "Op", identities: { fake: ["op-1"] })
    end
    let(:target_person) do
      Rubotty::Core::Person.new(name: "Bob", identities: { fake: ["bob-1"] }, handles: { fake: ["bob"] })
    end
    let(:operators) { Rubotty::Core::Moderation::Directory.new([operator_person]) }
    let(:people) { Rubotty::Core::Directory.new([target_person]) }
    let(:identity_directory) { Rubotty::ControlPlane::IdentityDirectory.new(models: models) }

    let(:channel) do
      Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: tg, community_id: community_row.id, route_key: tg.id)
    end

    # Its id matches the real seeded community, and its room id is the real
    # seeded room_key ("general"), so a write here lands on the same row the
    # gate itself would read; everything else (operators, people) is hand
    # built so each example controls exactly who can act and who can be found.
    let(:snapshot_community) do
      Rubotty::ControlPlane::Snapshot::Community.new(
        id: community_row.id, slug: "sample", name: "sample", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("general", tg, dc)]), channels: [channel],
        operators: operators, people: people, feature_settings: []
      )
    end

    def whitelist_feature(ephemeral: nil, cleanup: nil, identity_directory: self.identity_directory)
      described_class.new(
        topology: topology(room("general", tg, dc)), adapters: adapters, storage: storage,
        logger: Rubotty::Log.null, ephemeral: ephemeral, cleanup: cleanup, feature_controls: controls,
        identity_directory: identity_directory
      )
    end

    def command(text, author_id:, reply_author: nil)
      preview = reply_author && Rubotty::Core::ReplyPreview.new(author: reply_author)
      message(
        tg, text: text, native_id: "cmd-1", kind: :chat,
        author: author(native_id: author_id, username: "#{author_id}_handle"),
        reply_to: reply_author && ref("tg", "parent"), reply_preview: preview
      )
    end

    def command_context(msg, config: {})
      Rubotty::Features::Context.new(message: msg, community: snapshot_community, channel: channel, config: config)
    end

    # Reads the room's config back the same way the live gate would: through a
    # freshly built Registry and Snapshot, not the row this spec wrote.
    def live_room_config
      registry = Rubotty::ControlPlane::Registry.build(models: models, accounts: sample_model.accounts)
      general = registry.current.channel_by_endpoint_key("tg-general")
      registry.current.community("sample").feature_config(general, "moderated_room")
    end

    def live_approved_users = live_room_config[:approved_users]

    def live_pending_handles = live_room_config[:pending_handles]

    it "adds the mentioned person's identity to this room's whitelist" do
      whitelist_feature.call(command_context(command("/whitelist @bob", author_id: "op-1")))

      expect(live_approved_users).to eq(["fake:bob-1"])
    end

    it "accepts a bare username with no leading @" do
      whitelist_feature.call(command_context(command("/whitelist bob", author_id: "op-1")))

      expect(live_approved_users).to eq(["fake:bob-1"])
    end

    it "targets the replied-to message's author when no argument is given" do
      whitelist_feature.call(
        command_context(command("/whitelist", author_id: "op-1", reply_author: author(native_id: "carol-1")))
      )

      expect(live_approved_users).to eq(["fake:carol-1"])
    end

    it "removes an already-approved identity with /unwhitelist" do
      controls.set(
        community: community_row, selector: "general", feature: "moderated_room",
        key: "approved_users", value: ["fake:bob-1", "fake:carol-1"]
      )

      whitelist_feature.call(command_context(command("/unwhitelist @bob", author_id: "op-1")))

      expect(live_approved_users).to eq(["fake:carol-1"])
    end

    it "does not add the same identity twice" do
      whitelist_feature.call(command_context(command("/whitelist @bob", author_id: "op-1")))
      whitelist_feature.call(command_context(command("/whitelist @bob", author_id: "op-1")))

      expect(live_approved_users).to eq(["fake:bob-1"])
    end

    it "refuses a non-operator, leaving the whitelist untouched" do
      whitelist_feature.call(command_context(command("/whitelist @bob", author_id: "someone-else")))

      expect(live_approved_users).to be_nil
    end

    it "files a name nobody has seen post yet instead of refusing, since that is who an invite names" do
      outcome = whitelist_feature.call(command_context(command("/whitelist @nobody", author_id: "op-1")))

      expect(outcome).to be_halt
      expect(live_pending_handles).to eq(["fake:nobody"])
      expect(live_approved_users).to be_nil
    end

    it "folds a filed name to lower case, since no platform here treats a username as case sensitive" do
      whitelist_feature.call(command_context(command("/whitelist @NoBody", author_id: "op-1")))

      expect(live_pending_handles).to eq(["fake:nobody"])
    end

    it "does not file the same name twice" do
      2.times { whitelist_feature.call(command_context(command("/whitelist @nobody", author_id: "op-1"))) }

      expect(live_pending_handles).to eq(["fake:nobody"])
    end

    it "says plainly that a filed approval is not live yet" do
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("general", tg, dc)), logger: Rubotty::Log.null
      )

      whitelist_feature(ephemeral: ephemeral).call(command_context(command("/whitelist @nobody", author_id: "op-1")))

      expect(adapter.delivered_to("tg").last.body.text).to eq(
        "Nobody here goes by @nobody yet. They will be added to this room's whitelist the first time they post."
      )
    end

    it "clears a filed name with /unwhitelist before its owner ever posts" do
      controls.set(
        community: community_row, selector: "general", feature: "moderated_room",
        key: "pending_handles", value: ["fake:nobody"]
      )

      whitelist_feature.call(command_context(command("/unwhitelist @nobody", author_id: "op-1")))

      expect(live_pending_handles).to eq([])
    end

    it "drops a stale filed name once the same handle resolves to somebody" do
      controls.set(
        community: community_row, selector: "general", feature: "moderated_room",
        key: "pending_handles", value: ["fake:bob"]
      )

      whitelist_feature.call(command_context(command("/whitelist @bob", author_id: "op-1")))

      expect(live_approved_users).to eq(["fake:bob-1"])
      expect(live_pending_handles).to eq([])
    end

    it "binds a filed name to a stable identity the first time its owner posts" do
      outcome = whitelist_feature.call(
        command_context(command("hello", author_id: "kev"), config: { pending_handles: ["fake:kev_handle"] })
      )

      expect(outcome).to be_continue
      expect(live_approved_users).to eq(["fake:kev"])
      expect(live_pending_handles).to eq([])
    end

    it "keeps a locked room shut to a filed name, the same as it ignores approved_users" do
      outcome = whitelist_feature.call(
        command_context(
          command("hello", author_id: "kev"), config: { pending_handles: ["fake:kev_handle"], locked: true }
        )
      )

      expect(outcome).to be_halt
      expect(live_approved_users).to be_nil
    end

    it "leaves a filed name alone when somebody else posts" do
      outcome = whitelist_feature.call(
        command_context(command("hello", author_id: "mallory"), config: { pending_handles: ["fake:kev_handle"] })
      )

      expect(outcome).to be_halt
      expect(live_approved_users).to be_nil
    end

    it "resolves a handle from the observed directory when nobody has merged that person into a person row" do
      identity_directory.record(community_id: community_row.id, adapter: :fake, native_id: "dave-1", username: "dave")

      whitelist_feature.call(command_context(command("/whitelist dave", author_id: "op-1")))

      expect(live_approved_users).to eq(["fake:dave-1"])
    end

    it "refuses a handle two different accounts have both worn, rather than guessing" do
      identity_directory.record(community_id: community_row.id, adapter: :fake, native_id: "dave-1", username: "dave")
      identity_directory.record(community_id: community_row.id, adapter: :fake, native_id: "dave-2", username: "dave")

      whitelist_feature.call(command_context(command("/whitelist dave", author_id: "op-1")))

      expect(live_approved_users).to be_nil
    end

    it "does not resolve a display name, only a username" do
      identity_directory.record(community_id: community_row.id, adapter: :fake, native_id: "cody-1", display: "Cody")

      whitelist_feature.call(command_context(command("/whitelist Cody", author_id: "op-1")))

      expect(live_approved_users).to be_nil
    end

    it "falls back to nothing when no identity directory is wired, same as before this existed" do
      identity_directory.record(community_id: community_row.id, adapter: :fake, native_id: "dave-1", username: "dave")

      whitelist_feature(identity_directory: nil).call(command_context(command("/whitelist dave", author_id: "op-1")))

      expect(live_approved_users).to be_nil
    end

    it "points a failed name lookup at the reply route instead" do
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("general", tg, dc)), logger: Rubotty::Log.null
      )

      whitelist_feature(ephemeral: ephemeral).call(command_context(command("/unwhitelist @nobody", author_id: "op-1")))

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq(
        "Could not find that person to /unwhitelist. Reply to one of their messages with /unwhitelist instead."
      )
    end

    it "does not suggest replying when a bare /whitelist with no reply target already tried that" do
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("general", tg, dc)), logger: Rubotty::Log.null
      )

      whitelist_feature(ephemeral: ephemeral).call(command_context(command("/whitelist", author_id: "op-1")))

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Could not find that person to /whitelist.")
    end

    it "posts a self-deleting acknowledgement" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("general", tg, dc)), logger: Rubotty::Log.null
      )

      whitelist_feature(ephemeral: ephemeral, cleanup: cleanup).call(
        command_context(command("/whitelist @bob", author_id: "op-1"), config: { removal_notice_ttl_seconds: 20 })
      )

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Added fake:bob-1 to this room's whitelist.")
      expect(cleanup).to have_received(:after).with(20)
    end

    it "tells a non-operator they need to be one" do
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("general", tg, dc)), logger: Rubotty::Log.null
      )

      whitelist_feature(ephemeral: ephemeral).call(command_context(command("/whitelist @bob", author_id: "someone-else")))

      expect(adapter.delivered_to("tg").last.body.text).to eq("You need to be an operator to use this command.")
    end
  end
end
