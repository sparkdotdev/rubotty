# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubotty::Features::AntiRaid do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  # A moderating adapter so the kick / ban containment is observable.
  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  # A mutable time box so the sliding window and the lockdown horizon are deterministic.
  let(:time_box) { [Time.now.to_f] }
  let(:clock) { -> { Time.at(time_box[0]) } }
  def advance(seconds) = (time_box[0] += seconds)

  def default_ephemeral
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
    )
  end

  def raid(cleanup: nil, ephemeral: default_ephemeral, clock: self.clock)
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: adapters,
      storage: storage,
      logger: Rubotty::Log.null,
      ephemeral: ephemeral,
      cleanup: cleanup,
      clock: clock
    )
  end

  def context(message, config: {}, operators: nil)
    Rubotty::Features::Context.new(message: message, config: config, operators: operators)
  end

  def join(member: author(native_id: "j1"), origin: tg, native_id: "1")
    message(origin, text: "", native_id: native_id, kind: :join, author: member)
  end

  # Feed +count+ distinct joins to +feature+ and return the last outcome.
  def flood(feature, count, config:, origin: tg, start: 0)
    outcome = nil
    count.times do |i|
      idx = start + i
      msg = join(member: author(native_id: "u#{idx}"), origin: origin, native_id: (idx + 1).to_s)
      outcome = feature.call(context(msg, config: config))
    end
    outcome
  end

  def kicks = adapter.moderations.select { |m| m[:action] == :kick }
  def bans = adapter.moderations.select { |m| m[:action] == :ban }
  def notice_on(endpoint_id) = adapter.delivered_to(endpoint_id).last

  describe "the feature contract" do
    it "names itself, is off by default, and observes only joins" do
      expect(described_class.feature_name).to eq("anti_raid")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[join])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end
  end

  describe "burst detection" do
    it "does not trip below the join threshold" do
      outcome = flood(raid, 4, config: { join_threshold: 5, window: 30 })
      expect(outcome).to be_continue
      expect(storage.get_state("anti_raid:lockdown:tg")).to be_nil
      expect(adapter.delivered).to be_empty
    end

    it "trips a lockdown when the join count reaches the threshold within the window" do
      feature = raid
      flood(feature, 5, config: { join_threshold: 5, window: 30, lockdown_duration: 300 })

      record = storage.get_state("anti_raid:lockdown:tg")
      expect(record).not_to be_nil
      expect(JSON.parse(record)["until"]).to be_within(1).of(time_box[0] + 300)
      expect(notice_on("tg").body.text).to include("Raid protection")
    end

    it "only counts joins inside the sliding window, so a slow trickle never trips" do
      feature = raid
      config = { join_threshold: 3, window: 30 }
      flood(feature, 2, config: config)          # two joins at t=0
      advance(40)                                # window elapses
      outcome = flood(feature, 2, config: config, start: 2) # two more, the old pair pruned

      expect(outcome).to be_continue
      expect(storage.get_state("anti_raid:lockdown:tg")).to be_nil
    end
  end

  describe "the announce action (default)" do
    it "posts the notice, enters lockdown, but takes no action against joiners and continues" do
      outcome = flood(raid, 5, config: { join_threshold: 5 })
      expect(outcome).to be_continue
      expect(adapter.moderations).to be_empty
      expect(notice_on("tg").body.text).to include("Raid protection")
    end

    it "uses a custom notice when one is configured" do
      flood(raid, 5, config: { join_threshold: 5, notice: "Under attack, locking down." })
      expect(notice_on("tg").body.text).to eq("Under attack, locking down.")
    end
  end

  describe "the kick action" do
    it "kicks the joiner that trips the lockdown and halts so the join is not relayed" do
      feature = raid
      outcome = flood(feature, 5, config: { join_threshold: 5, action: "kick" })
      expect(outcome).to be_halt
      expect(kicks.size).to eq(1)
      expect(kicks.last[:target_user_id]).to eq("u4") # the fifth joiner (0-indexed)
    end

    it "keeps kicking joiners that arrive during the lockdown" do
      feature = raid
      flood(feature, 5, config: { join_threshold: 5, action: "kick" })
      outcome = feature.call(context(join(member: author(native_id: "late"), native_id: "6"),
                                     config: { join_threshold: 5, action: "kick" }))
      expect(outcome).to be_halt
      expect(kicks.map { |m| m[:target_user_id] }).to include("late")
    end
  end

  describe "the ban action" do
    it "bans joiners during lockdown" do
      feature = raid
      flood(feature, 5, config: { join_threshold: 5, action: "ban" })
      expect(bans.size).to eq(1)
    end
  end

  describe "exemptions during a kick lockdown" do
    let(:operator) { Rubotty::Core::Moderation::Operator.new(name: "op", identities: { fake: ["op1"] }) }
    let(:directory) { Rubotty::Core::Moderation::Directory.new([operator]) }

    it "does not kick a known operator who joins during lockdown" do
      feature = raid
      flood(feature, 5, config: { join_threshold: 5, action: "kick" }) # trip
      before = kicks.size
      outcome = feature.call(context(join(member: author(native_id: "op1"), native_id: "9"),
                                     config: { join_threshold: 5, action: "kick" }, operators: directory))
      expect(outcome).to be_continue
      expect(kicks.size).to eq(before)
    end

    # No community resolved means no directory, so the same operator is kicked
    # rather than spared by the merged deployment-wide view.
    it "kicks an operator whose community did not resolve" do
      feature = raid
      flood(feature, 5, config: { join_threshold: 5, action: "kick" }) # trip
      before = kicks.size
      outcome = feature.call(context(join(member: author(native_id: "op1"), native_id: "9"),
                                     config: { join_threshold: 5, action: "kick" }))
      expect(outcome).to be_halt
      expect(kicks.size).to eq(before + 1)
    end

    it "never kicks a bot account that joins during lockdown" do
      feature = raid
      flood(feature, 5, config: { join_threshold: 5, action: "kick" }) # trip
      before = kicks.size
      outcome = feature.call(context(join(member: author(native_id: "b1", bot: true), native_id: "9"),
                                     config: { join_threshold: 5, action: "kick" }))
      expect(outcome).to be_continue
      expect(kicks.size).to eq(before)
    end
  end

  describe "reversibility" do
    it "lifts the lockdown once its duration has elapsed, so joiners are no longer acted on" do
      feature = raid
      config = { join_threshold: 5, window: 30, lockdown_duration: 300, action: "kick" }
      flood(feature, 5, config: config) # trip + kick the fifth joiner
      expect(kicks.size).to eq(1)

      advance(400) # past both the window and the lockdown horizon
      outcome = feature.call(context(join(member: author(native_id: "later"), native_id: "9"), config: config))

      expect(outcome).to be_continue
      expect(kicks.size).to eq(1)
    end

    it "schedules the optional lift notice on the cleanup scheduler when configured" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      flood(raid(cleanup: cleanup), 5,
            config: { join_threshold: 5, lockdown_duration: 300, lift_notice: "All clear." })
      expect(cleanup).to have_received(:after).with(300)
    end
  end

  describe "per-community and per-room enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "anti_raid", enabled: enabled, config: config
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
      Rubotty::Features::Pipeline.new(features: [raid], registry: registry)
    end

    it "trips where a community-default row enables it, reading that row's threshold" do
      pipeline = pipeline_for([setting(enabled: true, config: { join_threshold: 3 })])
      3.times { |i| pipeline.handle(join(member: author(native_id: "r#{i}"), origin: ep_a, native_id: (i + 1).to_s)) }
      expect(storage.get_state("anti_raid:lockdown:ch-a")).not_to be_nil
      expect(notice_on("ch-a").body.text).to include("Raid protection")
    end

    it "does not run where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { join_threshold: 3 }),
          setting(enabled: false, room_key: "b")
        ]
      )
      5.times { |i| pipeline.handle(join(member: author(native_id: "r#{i}"), origin: ep_b, native_id: (i + 1).to_s)) }
      expect(storage.get_state("anti_raid:lockdown:ch-b")).to be_nil
      expect(adapter.delivered).to be_empty
    end
  end
end
