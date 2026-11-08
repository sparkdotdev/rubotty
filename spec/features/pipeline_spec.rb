# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::Pipeline do
  # A fake feature that appends its name to a shared log when it runs, and either
  # continues or halts.
  def fake_feature(name, seen:, observes: %i[chat], default_enabled: true, always_enabled: false,
                   halt: false, value: [])
    Class.new(Rubotty::Features::Base) do
      define_singleton_method(:feature_name) { name }
      define_singleton_method(:observes) { observes }
      define_singleton_method(:default_enabled?) { default_enabled }
      define_singleton_method(:always_enabled?) { always_enabled }
      define_method(:call) do |_context|
        seen << name
        halt ? Rubotty::Features::Outcome.halt(value) : Rubotty::Features::Outcome.continue(value)
      end
    end.new
  end

  let(:tg) { endpoint("tg") }
  let(:seen) { [] }

  describe "feature failure policy" do
    [[:halt, false], [:continue, true]].each do |policy, relays|
      it "#{policy == :halt ? 'stops' : 'continues'} after a feature with #{policy} failure policy raises" do
        failing = fake_feature("broken", seen: seen)
        failing.class.define_singleton_method(:failure_policy) { policy }
        failing.define_singleton_method(:call) { |_| raise "unavailable" }
        terminal = fake_feature("bridge", seen: seen)
        pipeline = described_class.new(features: [failing, terminal], logger: Rubotty::Log.null)
        expect { pipeline.handle(message(tg)) }.not_to raise_error
        expect(seen.include?("bridge")).to eq(relays)
      end
    end
  end

  describe "ordering" do
    it "runs the features in the order they were given" do
      pipeline = described_class.new(
        features: [fake_feature("a", seen: seen), fake_feature("b", seen: seen), fake_feature("c", seen: seen)]
      )
      pipeline.handle(message(tg))
      expect(seen).to eq(%w[a b c])
    end
  end

  describe "consume halts the chain" do
    it "stops at the first feature that halts" do
      pipeline = described_class.new(
        features: [
          fake_feature("first", seen: seen),
          fake_feature("halter", seen: seen, halt: true),
          fake_feature("never", seen: seen)
        ]
      )
      pipeline.handle(message(tg))
      expect(seen).to eq(%w[first halter])
    end

    it "returns the value of the feature that handled the message" do
      pipeline = described_class.new(
        features: [
          fake_feature("skip", seen: seen),
          fake_feature("act", seen: seen, halt: true, value: %i[receipt])
        ]
      )
      expect(pipeline.handle(message(tg))).to eq(%i[receipt])
    end

    it "returns the last feature's value when none halts" do
      pipeline = described_class.new(
        features: [
          fake_feature("a", seen: seen, value: [1]),
          fake_feature("b", seen: seen, value: [2])
        ]
      )
      expect(pipeline.handle(message(tg))).to eq([2])
    end
  end

  describe "kind filtering" do
    it "skips a feature for a kind it does not observe" do
      pipeline = described_class.new(
        features: [
          fake_feature("chat_only", seen: seen, observes: %i[chat]),
          fake_feature("edit_only", seen: seen, observes: %i[edit])
        ]
      )
      pipeline.handle(message(tg, kind: :chat))
      expect(seen).to eq(%w[chat_only])
    end
  end

  describe "the echo guard runs once, ahead of every feature" do
    let(:loop_guard) { instance_double(Rubotty::Core::LoopGuard) }

    it "drops an echo before any feature sees it" do
      allow(loop_guard).to receive(:echo?).and_return(:self_authored)
      pipeline = described_class.new(features: [fake_feature("a", seen: seen)], loop_guard: loop_guard)
      expect(pipeline.handle(message(tg))).to eq([])
      expect(seen).to be_empty
    end

    it "proceeds to the features when it is not an echo" do
      allow(loop_guard).to receive(:echo?).and_return(nil)
      pipeline = described_class.new(features: [fake_feature("a", seen: seen)], loop_guard: loop_guard)
      pipeline.handle(message(tg))
      expect(seen).to eq(%w[a])
    end
  end

  describe "enablement without a control plane" do
    it "runs a feature that is on by default and skips one that is off" do
      pipeline = described_class.new(
        features: [
          fake_feature("on", seen: seen, default_enabled: true),
          fake_feature("off", seen: seen, default_enabled: false)
        ]
      )
      pipeline.handle(message(tg))
      expect(seen).to eq(%w[on])
    end
  end

  # Enablement resolves per community and per room from feature_settings, read through the
  # live Snapshot. ch-a and ch-b sit in their own rooms so a room override is visibly scoped.
  describe "enablement resolved per community and per room from feature_settings", :control_plane do
    # Two channels, each the sole endpoint of its own room, so a community default plus one
    # per-room override exercises the whole rule: room over community over code default.
    def build_registry(feature_settings)
      ep_a = Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :telegram, account: "t", settings: {})
      ep_b = Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :telegram, account: "t", settings: {})
      channels = [ep_a, ep_b].map do |ep|
        Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 1, route_key: ep.id)
      end
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 1, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("a", ep_a), room("b", ep_b)]),
        channels: channels,
        operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: feature_settings
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    end

    def setting(feature:, enabled:, room_key: nil)
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: feature, enabled: enabled
      )
    end

    it "runs a feature enabled by a community-default row" do
      registry = build_registry([setting(feature: "widget", enabled: true)])
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: false)], registry: registry
      )
      pipeline.handle(message(endpoint("ch-a")))
      expect(seen).to eq(%w[widget])
    end

    it "skips a feature the community default leaves off" do
      registry = build_registry([setting(feature: "widget", enabled: false)])
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: true)], registry: registry
      )
      pipeline.handle(message(endpoint("ch-a")))
      expect(seen).to be_empty
    end

    # always_enabled? skips feature_settings entirely, because the command it is built for
    # has to work in a room that has never had a row written for it.
    it "runs an always_enabled? feature even when a row EXPLICITLY turns it off" do
      registry = build_registry([setting(feature: "widget", enabled: false)])
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: false, always_enabled: true)],
        registry: registry
      )
      pipeline.handle(message(endpoint("ch-a")))
      expect(seen).to eq(%w[widget])
    end

    it "runs an always_enabled? feature for an origin the snapshot does not know at all" do
      registry = build_registry([])
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: false, always_enabled: true)],
        registry: registry
      )
      pipeline.handle(message(endpoint("stranger")))
      expect(seen).to eq(%w[widget])
    end

    it "lets a per-room row override the community default, on that room only" do
      registry = build_registry([
                                  setting(feature: "widget", enabled: true),                  # community default: on
                                  setting(feature: "widget", enabled: false, room_key: "a")   # room "a" (ch-a): off
                                ])
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: false)], registry: registry
      )
      pipeline.handle(message(endpoint("ch-a")))
      expect(seen).to be_empty
      # ch-b's room still inherits the community default.
      pipeline.handle(message(endpoint("ch-b")))
      expect(seen).to eq(%w[widget])
    end

    it "falls back to the code default (bridge on, others off) when no row matches" do
      registry = build_registry([])
      pipeline = described_class.new(
        features: [
          fake_feature("bridge", seen: seen, default_enabled: false),
          fake_feature("word_filter", seen: seen, default_enabled: false)
        ],
        registry: registry
      )
      pipeline.handle(message(endpoint("ch-a")))
      # bridge is on by the Community code default, an unconfigured feature is off.
      expect(seen).to eq(%w[bridge])
    end

    it "runs all features by static default for an origin the snapshot does not know" do
      registry = build_registry([])
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: true)], registry: registry
      )
      pipeline.handle(message(endpoint("stranger")))
      expect(seen).to eq(%w[widget])
    end
  end

  # The passive identity recorder runs on the pipeline spine, once per message, ahead of the
  # feature chain, so the directory reflects the whole room and not just the enabled channels.
  describe "the identity recorder runs on the spine, regardless of features", :control_plane do
    # A stand-in for ControlPlane::IdentityRecorder, capturing the (message, community) pair
    # it is handed.
    let(:recorder) do
      Class.new do
        def calls = @calls ||= []

        def record(message, community) = calls << [message, community]
      end.new
    end

    def build_registry
      ep = Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :telegram, account: "t", settings: {})
      channel = Rubotty::ControlPlane::Snapshot::Channel.new(endpoint: ep, community_id: 7, route_key: ep.id)
      community = Rubotty::ControlPlane::Snapshot::Community.new(
        id: 7, slug: "c", name: "c", status: "active", settings: {},
        topology: Rubotty::Core::Topology.new([room("r", ep)]),
        channels: [channel], operators: Rubotty::Core::Moderation::Directory.new,
        people: Rubotty::Core::Directory.new,
        feature_settings: [Rubotty::ControlPlane::Snapshot::FeatureSetting.new(feature: "widget", enabled: false)]
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    end

    it "records the message with its resolved community even when every feature is gated off" do
      pipeline = described_class.new(
        features: [fake_feature("widget", seen: seen, default_enabled: false)],
        registry: build_registry, identity_recorder: recorder
      )
      pipeline.handle(message(endpoint("ch-a")))
      expect(seen).to be_empty                              # the feature was off
      expect(recorder.calls.size).to eq(1)                  # but the recorder still ran
      _message, community = recorder.calls.first
      expect(community.id).to eq(7)                          # with the resolved community
    end

    it "does not record an echo (the recorder is behind the echo guard)" do
      guard = instance_double(Rubotty::Core::LoopGuard)
      allow(guard).to receive(:echo?).and_return(:self_authored)
      pipeline = described_class.new(
        features: [], registry: build_registry, identity_recorder: recorder, loop_guard: guard
      )
      pipeline.handle(message(endpoint("ch-a")))
      expect(recorder.calls).to be_empty
    end
  end

  # A photo's QR decode and OCR pass (issues #857, #858) must run at most
  # once per message, however many enabled filters ask for the result, so
  # every feature in one #handle call has to see the SAME AttachmentText
  # instance rather than each building its own.
  describe "the attachment text extractor is shared across one message's features" do
    # Records the object_id of context.attachment_text into +seen+, rather
    # than the feature name fake_feature already does.
    def recording_feature(seen:)
      Class.new(Rubotty::Features::Base) do
        define_singleton_method(:feature_name) { "recorder" }
        define_singleton_method(:default_enabled?) { true }
        define_method(:call) do |context|
          seen << context.attachment_text.object_id
          Rubotty::Features::Outcome.continue([])
        end
      end.new
    end

    it "hands every feature the same extractor for one message" do
      ids = []
      pipeline = described_class.new(features: [recording_feature(seen: ids), recording_feature(seen: ids)])

      pipeline.handle(message(tg))

      expect(ids.uniq.size).to eq(1)
    end

    it "builds a fresh extractor for the next message" do
      ids = []
      pipeline = described_class.new(features: [recording_feature(seen: ids)])

      pipeline.handle(message(tg, native_id: "1"))
      pipeline.handle(message(tg, native_id: "2"))

      expect(ids.uniq.size).to eq(2)
    end
  end
end
