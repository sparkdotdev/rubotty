# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::MentionSpam do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  # One recording adapter and a two-endpoint room, so a removal and its propagation
  # are both observable on the same fake.
  def guard(ephemeral: nil, cleanup: nil, warnings: nil, audit: nil)
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: adapters,
      storage: storage,
      logger: Rubotty::Log.null,
      ephemeral: ephemeral,
      cleanup: cleanup,
      warnings: warnings,
      audit: audit
    )
  end

  def context(message, config: {}, operators: nil)
    Rubotty::Features::Context.new(message: message, config: config, operators: operators)
  end

  # A message carrying +count+ distinct user-mention spans, one per "@uN" token. +same+
  # points every span at one target, to exercise uniqueness.
  def mentions(count, origin: tg, native_id: "1", kind: :chat, same: false, **rest)
    tokens = (0...count).map { |i| "@u#{i}" }
    text = tokens.join(" ")
    cursor = 0
    spans = tokens.each_with_index.map do |token, index|
      from = cursor
      cursor += token.length + 1
      span(:mention, from, from + token.length, discord_id: same ? "shared" : "id#{index}", mention_type: :user)
    end
    message(origin, text: rich(text, *spans), native_id: native_id, kind: kind, **rest)
  end

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat and edit" do
      expect(described_class.feature_name).to eq("mention_spam")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat edit])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "leaves a message at or below the threshold alone" do
      outcome = guard.call(context(mentions(5), config: { threshold: 5 }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "does not run when the threshold is non-positive, so an unset threshold is inert" do
      outcome = guard.call(context(mentions(20), config: { threshold: 0 }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "counting distinct mentions" do
    it "trips when the number of distinct mentions exceeds the threshold" do
      outcome = guard.call(context(mentions(6, native_id: "9"), config: { threshold: 5 }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end

    it "counts the same target once however many times it is mentioned" do
      # Twelve spans, all the same person: one distinct target, well under five.
      outcome = guard.call(context(mentions(12, same: true), config: { threshold: 5 }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "counts a Telegram @handle span and a Discord role span alike (cross-platform)" do
      body = rich(
        "@ada and the @mods and <@1> and <@2>",
        span(:mention, 0, 4, username: "ada"),
        span(:mention, 13, 18, discord_id: "77", mention_type: :role),
        span(:mention, 23, 24, discord_id: "1", mention_type: :user),
        span(:mention, 33, 34, discord_id: "2", mention_type: :user)
      )
      outcome = guard.call(context(message(tg, text: body, native_id: "3"), config: { threshold: 3 }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 3]])
    end

    it "counts a Discord @everyone / @here as a target when count_mass is on (the default)" do
      # Four named targets plus @everyone and @here is six distinct targets.
      body = rich(
        "@everyone @here @u0 @u1 @u2 @u3",
        span(:mention, 16, 19, discord_id: "0", mention_type: :user),
        span(:mention, 20, 23, discord_id: "1", mention_type: :user),
        span(:mention, 24, 27, discord_id: "2", mention_type: :user),
        span(:mention, 28, 31, discord_id: "3", mention_type: :user)
      )
      outcome = guard.call(context(message(tg, text: body, native_id: "3"), config: { threshold: 5 }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 3]])
    end

    it "does not count @everyone / @here when count_mass is off" do
      body = rich(
        "@everyone @here @u0 @u1 @u2 @u3",
        span(:mention, 16, 19, discord_id: "0", mention_type: :user),
        span(:mention, 20, 23, discord_id: "1", mention_type: :user),
        span(:mention, 24, 27, discord_id: "2", mention_type: :user),
        span(:mention, 28, 31, discord_id: "3", mention_type: :user)
      )
      outcome = guard.call(context(message(tg, text: body), config: { threshold: 5, count_mass: false }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "the delete action" do
    it "removes the offending message on its own endpoint and halts the pipeline" do
      outcome = guard.call(context(mentions(6, native_id: "5"), config: { threshold: 5 }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "removes the relayed cross-platform copies too, using the message map" do
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      edit = mentions(6, native_id: "5", kind: :edit)

      outcome = guard.call(context(edit, config: { threshold: 5 }))

      expect(outcome).to be_halt
      expect(adapter.deleted).to contain_exactly(%w[tg 5], %w[dc d1])
      expect(storage.counterparts(ref("tg", "5"))).to be_empty
    end

    it "does not relay a tripped message: the bridge downstream never sees it", :control_plane do
      bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: adapters, storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null
      )
      channels = [tg, dc].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", tg, dc)]), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "mention_spam", enabled: true, config: { threshold: 3 }
          )
        ]
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
      pipeline = Rubotty::Features::Pipeline.new(features: [guard, bridge], registry: registry)

      pipeline.handle(mentions(6, native_id: "5"))

      expect(adapter.deleted).to eq([%w[tg 5]])
      expect(adapter.delivered).to be_empty
    end

    it "posts the standard self-deleting @mention removal notice through the shared flow" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = guard(ephemeral: ephemeral, cleanup: cleanup)

      subject.call(
        context(mentions(6, native_id: "5", author: author(native_id: "u9", first_name: "Ada")),
                config: { threshold: 5, removal_notice_ttl_seconds: 30 })
      )

      notice = adapter.delivered_to("tg").last
      expect(notice.body.text).to eq("Ada Your last message was automatically removed: Message mentioned too many people at once.")
      mention = notice.body.spans.find { |s| s.kind == :mention }
      expect(mention.attributes).to eq(fake_id_for_target: "u9")
      expect(cleanup).to have_received(:after).with(30)
    end

    it "honours a per-scope removal_reason override in the notice" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = guard(ephemeral: ephemeral, cleanup: cleanup)

      subject.call(
        context(mentions(6, native_id: "5"), config: { threshold: 5, removal_reason: "No ping raids here" })
      )

      expect(adapter.delivered_to("tg").last.body.text)
        .to eq("Ada Your last message was automatically removed: No ping raids here.")
    end
  end

  describe "the flag action" do
    it "leaves the message in place and continues, so the bridge still relays it" do
      outcome = guard.call(context(mentions(6), config: { threshold: 5, action: "flag" }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "the warn and mute stubs, pending a wired warnings ladder (#46)" do
    it "does not crash on a warn action and degrades to the stub action (delete by default)" do
      outcome = guard.call(context(mentions(6, native_id: "5"), config: { threshold: 5, action: "warn" }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "does not crash on a mute action and honours a flag stub_action" do
      outcome = guard.call(
        context(mentions(6, native_id: "5"), config: { threshold: 5, action: "mute", stub_action: "flag" })
      )
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "warn and mute routing to the warnings service (#46)" do
    let(:warnings) { instance_spy(Rubotty::Core::Warnings::Service) }
    let(:offender) { author(native_id: "u9", username: "troll") }

    it "issues a warning for the author on a warn action, still containing the message" do
      subject = guard(warnings: warnings)
      outcome = subject.call(
        context(mentions(6, native_id: "5", author: offender), config: { threshold: 5, action: "warn" })
      )
      expect(warnings).to have_received(:warn).with(hash_including(subject: offender, issued_by: "mention filter"))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]])
    end

    it "applies a mute for the author on a mute action, for the configured duration" do
      subject = guard(warnings: warnings)
      subject.call(
        context(mentions(6, author: offender),
                config: { threshold: 5, action: "mute", mute_duration: "2h", stub_action: "flag" })
      )
      expect(warnings).to have_received(:sanction)
        .with(hash_including(subject: offender, action: :mute, duration: 7200, issued_by: "mention filter"))
    end

    it "does not escalate a delete or flag trip" do
      subject = guard(warnings: warnings)
      subject.call(context(mentions(6, author: offender), config: { threshold: 5, action: "delete" }))
      expect(warnings).not_to have_received(:warn)
      expect(warnings).not_to have_received(:sanction)
    end

    it "passes the community's configured max and decay alongside a warn" do
      subject = guard(warnings: warnings)
      community = instance_double(Rubotty::ControlPlane::Snapshot::Community,
                                  feature_config: { max: 3, expires_after: "30d" }, operators: nil, slug: "sample")
      ctx = Rubotty::Features::Context.new(
        message: mentions(6, author: offender), community: community, config: { threshold: 5, action: "warn" }
      )
      subject.call(ctx)
      expect(warnings).to have_received(:warn).with(hash_including(max: 3, expire_after: 2_592_000))
    end
  end

  describe "operator exemption" do
    let(:operator) do
      Rubotty::Core::Moderation::Operator.new(name: "op", identities: { fake: ["u1"] })
    end
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
    let(:op_author) { author(native_id: "u1") }
    let(:member_author) { author(native_id: "u2") }

    it "exempts operators by default" do
      outcome = guard.call(context(mentions(6, author: op_author), config: { threshold: 5 }, operators: directory))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "still guards a non-operator" do
      outcome = guard.call(
        context(mentions(6, native_id: "9", author: member_author), config: { threshold: 5 }, operators: directory)
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end

    it "subjects operators to the guard when exempt_operators is false" do
      outcome = guard.call(
        context(mentions(6, native_id: "9", author: op_author),
                config: { threshold: 5, exempt_operators: false }, operators: directory)
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end

    # No community resolved means no directory, so the same operator is guarded
    # rather than exempted out of the merged deployment-wide view.
    it "guards an operator whose community did not resolve" do
      outcome = guard.call(context(mentions(6, native_id: "9", author: op_author), config: { threshold: 5 }))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 9]])
    end
  end

  describe "per-community and per-room config and enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_far) { Rubotty::Core::Endpoint.new(id: "ch-far", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "mention_spam", enabled: enabled, config: config
      )
    end

    def registry_for(feature_settings)
      channels = [ep_a, ep_b, ep_far].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("a", ep_a, ep_far), room("b", ep_b, ep_far)]),
        channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: feature_settings
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    end

    def pipeline_for(feature_settings)
      Rubotty::Features::Pipeline.new(features: [guard], registry: registry_for(feature_settings))
    end

    it "runs where a community-default row enables it, reading that row's threshold" do
      pipeline = pipeline_for([setting(enabled: true, config: { threshold: 3 })])
      pipeline.handle(mentions(6, origin: ep_a, native_id: "5"))
      expect(adapter.deleted).to eq([%w[ch-a 5]])
    end

    it "does not run where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { threshold: 3 }),
          setting(enabled: false, room_key: "b")
        ]
      )
      pipeline.handle(mentions(6, origin: ep_b, native_id: "5"))
      expect(adapter.deleted).to be_empty
    end

    it "resolves the threshold per room: a room row's threshold applies to its channel" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { threshold: 10 }),
          setting(enabled: true, room_key: "a", config: { threshold: 3 }) # room "a" is ch-a
        ]
      )
      pipeline.handle(mentions(6, origin: ep_a, native_id: "7"))
      expect(adapter.deleted).to eq([%w[ch-a 7]])
    end
  end
end
