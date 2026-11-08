# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::Multipost do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  before { @now = Time.now }

  # One recording adapter and a two-endpoint room, so a removal and its propagation are both
  # observable on the fake. The clock is mutable, so a spec can drive the window.
  def guard(ephemeral: nil, cleanup: nil, audit: nil)
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: adapters,
      storage: storage,
      logger: Rubotty::Log.null,
      ephemeral: ephemeral,
      cleanup: cleanup,
      audit: audit,
      clock: -> { @now }
    )
  end

  def context(message, config: { channel_threshold: 2 }, operators: nil)
    Rubotty::Features::Context.new(message: message, config: config, operators: operators)
  end

  def spam = "join my brand new channel right now"

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("multipost")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end
  end

  describe "removing a cross-post" do
    it "leaves the first post and removes the same content in a second channel" do
      subject = guard
      first = subject.call(context(message(tg, text: spam, native_id: "1")))
      expect(first).to be_continue
      expect(adapter.deleted).to be_empty

      second = subject.call(context(message(dc, text: spam, native_id: "2")))
      expect(second).to be_halt
      expect(adapter.deleted).to eq([%w[dc 2]])
    end

    it "runs with the code defaults when the config is blank" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1"), config: {}))
      outcome = subject.call(context(message(dc, text: spam, native_id: "2"), config: {}))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[dc 2]])
    end

    it "removes the relayed cross-platform copies too, using the message map" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1")))
      # The second-channel post was already relayed to tg before it tripped.
      storage.record(source: ref("dc", "2"), destination: ref("tg", "d1"), room_id: "r")

      outcome = subject.call(context(message(dc, text: spam, native_id: "2")))

      expect(outcome).to be_halt
      expect(adapter.deleted).to contain_exactly(%w[dc 2], %w[tg d1])
    end

    it "does not trip on a repeat in the same channel" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1")))
      outcome = subject.call(context(message(tg, text: spam, native_id: "2")))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "does not trip once the first post has aged out of the window" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1"), config: { channel_threshold: 2, window_seconds: 300 }))
      @now += 400
      outcome = subject.call(context(message(dc, text: spam, native_id: "2"), config: { channel_threshold: 2, window_seconds: 300 }))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "ignores trivially short messages" do
      subject = guard
      subject.call(context(message(tg, text: "ok", native_id: "1")))
      outcome = subject.call(context(message(dc, text: "ok", native_id: "2")))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "the standard removal notice" do
    it "posts the self-deleting @mention notice through the shared flow" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      subject = guard(ephemeral: ephemeral, cleanup: cleanup)

      subject.call(context(message(tg, text: spam, native_id: "1",
                                   author: author(native_id: "u9", first_name: "Ada"))))
      subject.call(
        context(message(dc, text: spam, native_id: "2",
                        author: author(native_id: "u9", first_name: "Ada")),
                config: { channel_threshold: 2, removal_notice_ttl_seconds: 30 })
      )

      notice = adapter.delivered_to("dc").last
      expect(notice.body.text)
        .to eq("Ada Your last message was automatically removed: " \
               "Posting the same message across multiple channels is not allowed.")
      mention = notice.body.spans.find { |s| s.kind == :mention }
      expect(mention.attributes).to eq(fake_id_for_target: "u9")
      expect(cleanup).to have_received(:after).with(30)
    end

    it "records the removal in the moderation audit log under the multipost source" do
      audit = instance_spy(Rubotty::Core::AuditLog::Null)
      subject = guard(audit: audit)
      subject.call(context(message(tg, text: spam, native_id: "1")))
      subject.call(context(message(dc, text: spam, native_id: "2")))
      expect(audit).to have_received(:record).with(hash_including(source: "multipost", action: "delete"))
    end
  end

  describe "operator exemption" do
    let(:operator) do
      Rubotty::Core::Moderation::Operator.new(name: "op", identities: { fake: ["u1"] })
    end
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }
    let(:op_author) { author(native_id: "u1") }
    let(:member_author) { author(native_id: "u2") }

    it "exempts operators by default, and does not even record their posts" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1", author: op_author), operators: directory))
      outcome = subject.call(context(message(dc, text: spam, native_id: "2", author: op_author),
                                     operators: directory))
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "still guards a non-operator posting the same content across channels" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1", author: member_author), operators: directory))
      outcome = subject.call(context(message(dc, text: spam, native_id: "2", author: member_author),
                                     operators: directory))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[dc 2]])
    end

    it "subjects operators to the guard when exempt_operators is false" do
      subject = guard
      subject.call(
        context(message(tg, text: spam, native_id: "1", author: op_author),
                config: { channel_threshold: 2, exempt_operators: false }, operators: directory)
      )
      outcome = subject.call(
        context(message(dc, text: spam, native_id: "2", author: op_author),
                config: { channel_threshold: 2, exempt_operators: false }, operators: directory)
      )
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[dc 2]])
    end

    # No community resolved means no directory, so the same operator is guarded
    # rather than exempted out of the merged deployment-wide view.
    it "guards an operator whose community did not resolve" do
      subject = guard
      subject.call(context(message(tg, text: spam, native_id: "1", author: op_author)))
      outcome = subject.call(context(message(dc, text: spam, native_id: "2", author: op_author)))
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[dc 2]])
    end
  end

  # #1426: an operator forwarding by hand got their own messages deleted.
  # The username-threading bug that could cause that is already fixed
  # (#1160), so this covers what that fix left open: no operator row, or
  # exempt_operators off, should still not catch the deployment's deployment-configured owner.
  describe "the deployment-configured deployment owner" do
    let(:chan_a) { endpoint("cha", adapter: :discord) }
    let(:chan_b) { endpoint("chb", adapter: :discord) }
    let(:owner_author) { author(native_id: "999", username: "sample_owner") }
    let(:member_author) { author(native_id: "111", username: "someone") }

    def bare_guard
      described_class.new(
        topology: topology(room("rp", chan_a, chan_b)), adapters: adapters, storage: storage,
        logger: Rubotty::Log.null, clock: -> { @now }
      )
    end

    it "exempts the deployment owner even when this community lists nobody as an operator" do
      subject = bare_guard
      subject.call(context(message(chan_a, text: spam, native_id: "1", author: owner_author)))
      outcome = subject.call(context(message(chan_b, text: spam, native_id: "2", author: owner_author)))

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "exempts the deployment owner even when this community turns exempt_operators off" do
      subject = bare_guard
      subject.call(
        context(message(chan_a, text: spam, native_id: "1", author: owner_author),
                config: { channel_threshold: 2, exempt_operators: false })
      )
      outcome = subject.call(
        context(message(chan_b, text: spam, native_id: "2", author: owner_author),
                config: { channel_threshold: 2, exempt_operators: false })
      )

      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "still guards somebody who is not the deployment owner" do
      subject = bare_guard
      subject.call(context(message(chan_a, text: spam, native_id: "1", author: member_author)))
      outcome = subject.call(context(message(chan_b, text: spam, native_id: "2", author: member_author)))

      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[chb 2]])
    end
  end

  # The end-to-end path through the Snapshot, with the guard enabled community-wide.
  describe "per-community enablement and no relay", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }

    def pipeline_with_bridge
      bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("a", ep_a), room("b", ep_b)), adapters: adapters, storage: storage,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: storage), logger: Rubotty::Log.null
      )
      channels = [ep_a, ep_b].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("a", ep_a), room("b", ep_b)]), channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
        feature_settings: [
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
            feature: "multipost", enabled: true, config: { channel_threshold: 2 }
          )
        ]
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
      Rubotty::Features::Pipeline.new(features: [guard, bridge], registry: registry)
    end

    it "removes the cross-post and never relays it once enabled" do
      pipeline = pipeline_with_bridge
      pipeline.handle(message(ep_a, text: spam, native_id: "1"))
      pipeline.handle(message(ep_b, text: spam, native_id: "2"))

      expect(adapter.deleted).to eq([%w[ch-b 2]]) # only the cross-post removed
    end
  end
end
