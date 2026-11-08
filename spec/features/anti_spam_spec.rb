# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::AntiSpam do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:time_box) { [Time.now.to_f] }
  let(:clock) { -> { Time.at(time_box[0]) } }
  def advance(seconds) = (time_box[0] += seconds)

  def engine(ephemeral: nil, cleanup: nil, warnings: nil, clock: self.clock)
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: adapters,
      storage: storage,
      logger: Rubotty::Log.null,
      ephemeral: ephemeral,
      cleanup: cleanup,
      warnings: warnings,
      clock: clock
    )
  end

  def context(message, config: {}, operators: nil)
    Rubotty::Features::Context.new(message: message, config: config, operators: operators)
  end

  def post(feature, config:, text: "hello there", author_id: "u1", native_id: "1")
    msg = message(tg, text: text, native_id: native_id,
                  author: author(native_id: author_id, username: "user_#{author_id}"))
    feature.call(context(msg, config: config))
  end

  # Post +count+ messages, returning the last outcome.
  def spam(feature, count, config:, text: "hello there", author_id: "u1")
    outcome = nil
    count.times { |i| outcome = post(feature, config: config, text: text, author_id: author_id, native_id: (i + 1).to_s) }
    outcome
  end

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("anti_spam")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end
  end

  describe "flood detection" do
    let(:config) { { flood_threshold: 5, flood_window: 5, duplicate_threshold: 0 } }

    it "does not trip below the threshold" do
      outcome = spam(engine, 4, config: config, text: "msg")
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "trips when a user posts more than the threshold within the window" do
      feature = engine
      outcome = nil
      5.times { |i| outcome = post(feature, config: config, text: "flood #{i}", native_id: (i + 1).to_s) }
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 5]]) # the message that crossed the threshold
    end

    it "counts per author, so two chatty users do not trip each other" do
      feature = engine
      3.times { |i| post(feature, config: config, text: "a#{i}", author_id: "alice", native_id: "a#{i}") }
      outcome = nil
      3.times { |i| outcome = post(feature, config: config, text: "b#{i}", author_id: "bob", native_id: "b#{i}") }
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "only counts messages inside the window, so a paced talker never trips" do
      feature = engine
      paced = { flood_threshold: 3, flood_window: 5, duplicate_threshold: 0 }
      post(feature, config: paced, text: "m1", native_id: "1")
      post(feature, config: paced, text: "m2", native_id: "2")
      advance(10)
      post(feature, config: paced, text: "m3", native_id: "3")
      outcome = post(feature, config: paced, text: "m4", native_id: "4")
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "duplicate detection" do
    # Flood off, so only repetition is under test.
    let(:config) { { flood_threshold: 0, duplicate_threshold: 3, duplicate_window: 60 } }

    it "trips when the same message is repeated past the threshold" do
      feature = engine
      outcome = nil
      3.times { |i| outcome = post(feature, config: config, text: "buy cheap followers now", native_id: (i + 1).to_s) }
      expect(outcome).to be_halt
      expect(adapter.deleted).to eq([%w[tg 3]])
    end

    it "catches a copy-paste drop coordinated across several accounts (keyed by text)" do
      feature = engine
      outcome = nil
      %w[acct1 acct2 acct3].each_with_index do |acct, i|
        outcome = post(feature, config: config, text: "join my server discord gg", author_id: acct, native_id: (i + 1).to_s)
      end
      expect(outcome).to be_halt
    end

    it "treats case and whitespace variants as the same message" do
      feature = engine
      post(feature, config: config, text: "Buy Cheap Now Please", native_id: "1")
      post(feature, config: config, text: "buy   cheap   now   please", native_id: "2")
      outcome = post(feature, config: config, text: "BUY CHEAP NOW PLEASE", native_id: "3")
      expect(outcome).to be_halt
    end

    it "does not trip on distinct messages" do
      feature = engine
      outcome = nil
      3.times { |i| outcome = post(feature, config: config, text: "a distinct message #{i}", native_id: (i + 1).to_s) }
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    it "ignores messages shorter than the minimum length" do
      feature = engine
      outcome = nil
      5.times { |i| outcome = post(feature, config: config.merge(duplicate_min_length: 8), text: "ok", native_id: (i + 1).to_s) }
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "disabling a mode with a zero threshold" do
    it "does nothing when both modes are off, however fast the identical messages arrive" do
      feature = engine
      outcome = nil
      10.times { |i| outcome = post(feature, config: { flood_threshold: 0, duplicate_threshold: 0 }, text: "same", native_id: (i + 1).to_s) }
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "the flag action" do
    it "leaves the message in place and continues" do
      feature = engine
      outcome = nil
      5.times { |i| outcome = post(feature, config: { flood_threshold: 5, flood_window: 5, action: "flag" }, text: "f#{i}", native_id: (i + 1).to_s) }
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end
  end

  describe "the delete action" do
    it "removes the relayed cross-platform copies too, using the message map" do
      feature = engine
      storage.record(source: ref("tg", "5"), destination: ref("dc", "d1"), room_id: "r")
      4.times { |i| post(feature, config: { flood_threshold: 5, flood_window: 5, duplicate_threshold: 0 }, text: "x#{i}", native_id: (i + 1).to_s) }
      outcome = post(feature, config: { flood_threshold: 5, flood_window: 5, duplicate_threshold: 0 }, text: "x5", native_id: "5")
      expect(outcome).to be_halt
      expect(adapter.deleted).to contain_exactly(%w[tg 5], %w[dc d1])
    end

    it "posts a self-deleting notice through the ephemeral primitive when configured" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      ephemeral = Rubotty::Core::EphemeralMessage.new(
        adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
      )
      feature = engine(ephemeral: ephemeral, cleanup: cleanup)
      cfg = { flood_threshold: 3, flood_window: 5, duplicate_threshold: 0, notice: "slow down", notice_delete_after: 15 }
      3.times { |i| post(feature, config: cfg, text: "z#{i}", native_id: (i + 1).to_s) }
      expect(adapter.delivered_to("tg").last.body.text).to eq("slow down")
      expect(cleanup).to have_received(:after).with(15)
    end
  end

  describe "warn and mute routing to the warnings service (#46)" do
    let(:warnings) { instance_spy(Rubotty::Core::Warnings::Service) }
    let(:offender) { author(native_id: "troll", username: "troll") }

    def flood_as_offender(feature, config)
      outcome = nil
      5.times do |i|
        msg = message(tg, text: "flood #{i}", native_id: (i + 1).to_s, author: offender)
        outcome = feature.call(context(msg, config: config))
      end
      outcome
    end

    it "warns the author on a warn action, still containing the message" do
      feature = engine(warnings: warnings)
      outcome = flood_as_offender(feature, { flood_threshold: 5, flood_window: 5, action: "warn" })
      expect(warnings).to have_received(:warn).with(hash_including(subject: offender, issued_by: "anti-spam"))
      expect(outcome).to be_halt
    end

    it "mutes the author on a mute action for the configured duration" do
      feature = engine(warnings: warnings)
      flood_as_offender(feature, { flood_threshold: 5, flood_window: 5, action: "mute", mute_duration: "2h", stub_action: "flag" })
      expect(warnings).to have_received(:sanction)
        .with(hash_including(subject: offender, action: :mute, duration: 7200, issued_by: "anti-spam"))
    end

    it "passes the community's configured max and decay alongside a warn" do
      feature = engine(warnings: warnings)
      community = instance_double(Rubotty::ControlPlane::Snapshot::Community,
                                  feature_config: { max: 3, expires_after: "30d" }, operators: nil, slug: "sample")
      outcome = nil
      5.times do |i|
        msg = message(tg, text: "flood #{i}", native_id: (i + 1).to_s, author: offender)
        ctx = Rubotty::Features::Context.new(
          message: msg, community: community, config: { flood_threshold: 5, flood_window: 5, action: "warn" }
        )
        outcome = feature.call(ctx)
      end
      expect(outcome).to be_halt
      expect(warnings).to have_received(:warn).with(hash_including(max: 3, expire_after: 2_592_000))
    end
  end

  describe "operator exemption" do
    let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "op", identities: { fake: ["op1"] }) }
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }

    it "does not count an operator's own messages toward a flood" do
      feature = engine
      outcome = nil
      8.times do |i|
        msg = message(tg, text: "burst #{i}", native_id: (i + 1).to_s, author: author(native_id: "op1"))
        outcome = feature.call(context(msg, config: { flood_threshold: 5, flood_window: 5 }, operators: directory))
      end
      expect(outcome).to be_continue
      expect(adapter.deleted).to be_empty
    end

    # No community resolved means no directory, so the same operator floods
    # like anyone else rather than reading the merged deployment-wide view.
    it "counts an operator's messages when their community did not resolve" do
      feature = engine
      outcome = nil
      8.times do |i|
        msg = message(tg, text: "burst #{i}", native_id: (i + 1).to_s, author: author(native_id: "op1"))
        outcome = feature.call(context(msg, config: { flood_threshold: 5, flood_window: 5 }))
      end
      expect(outcome).to be_halt
      expect(adapter.deleted).not_to be_empty
    end
  end

  describe "per-community and per-room enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "anti_spam", enabled: enabled, config: config
      )
    end

    def pipeline_for(feature_settings)
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
      registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
      Rubotty::Features::Pipeline.new(features: [engine], registry: registry)
    end

    it "runs where a community-default row enables it, reading that row's thresholds" do
      pipeline = pipeline_for([setting(enabled: true, config: { flood_threshold: 3, flood_window: 5 })])
      3.times { |i| pipeline.handle(message(ep_a, text: "flood #{i}", native_id: (i + 1).to_s)) }
      expect(adapter.deleted).to eq([%w[ch-a 3]])
    end

    it "does not run where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { flood_threshold: 3, flood_window: 5 }),
          setting(enabled: false, room_key: "b")
        ]
      )
      5.times { |i| pipeline.handle(message(ep_b, text: "flood #{i}", native_id: (i + 1).to_s)) }
      expect(adapter.deleted).to be_empty
    end
  end
end
