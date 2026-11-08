# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::Greetings do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  # One recording adapter, a two-endpoint room and a real ephemeral primitive, so a posted
  # greeting is observable on the fake.
  def greetings(ephemeral: default_ephemeral, cleanup: nil)
    described_class.new(
      topology: topology(room("r", tg, dc)),
      adapters: adapters,
      logger: Rubotty::Log.null,
      ephemeral: ephemeral,
      cleanup: cleanup
    )
  end

  def default_ephemeral
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: topology(room("r", tg, dc)), logger: Rubotty::Log.null
    )
  end

  def context(message, config: {})
    Rubotty::Features::Context.new(message: message, config: config)
  end

  # A membership event carrying +member+ as its author on the origin endpoint.
  def membership(kind, origin: tg, member: author(native_id: "u9", first_name: "Ada", username: "ada"), native_id: "1")
    message(origin, text: "", native_id: native_id, kind: kind, author: member)
  end

  # The last greeting delivered to +endpoint_id+.
  def greeting_on(endpoint_id) = adapter.delivered_to(endpoint_id).last

  describe "the feature contract" do
    it "names itself, is off by default, and observes only membership events" do
      expect(described_class.feature_name).to eq("greetings")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[join leave])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "is a no-op when nothing is configured, so it is safe to keep in the chain" do
      outcome = greetings.call(context(membership(:join)))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "welcome on join" do
    it "posts the welcome text to the joined channel and continues" do
      outcome = greetings.call(context(membership(:join), config: { welcome: "Welcome!" }))
      expect(outcome).to be_continue
      expect(greeting_on("tg").body.text).to eq("Welcome!")
    end

    it "does not post the welcome on a leave" do
      greetings.call(context(membership(:leave), config: { welcome: "Welcome!" }))
      expect(adapter.delivered).to be_empty
    end

    it "substitutes {name} with the member's display name" do
      greetings.call(context(membership(:join), config: { welcome: "Hi {name}, welcome!" }))
      expect(greeting_on("tg").body.text).to eq("Hi Ada, welcome!")
    end

    it "substitutes {username} with the member's handle" do
      greetings.call(context(membership(:join), config: { welcome: "hello @{username}" }))
      expect(greeting_on("tg").body.text).to eq("hello @ada")
    end
  end

  describe "goodbye on leave" do
    it "posts the goodbye text to the channel the member left and continues" do
      outcome = greetings.call(context(membership(:leave), config: { goodbye: "Bye {name}." }))
      expect(outcome).to be_continue
      expect(greeting_on("tg").body.text).to eq("Bye Ada.")
    end

    it "does not post the goodbye on a join" do
      greetings.call(context(membership(:join), config: { goodbye: "Bye." }))
      expect(adapter.delivered).to be_empty
    end
  end

  describe "the {mention} placeholder" do
    it "renders the member's name and carries the origin-platform id so it pings" do
      greetings.call(context(membership(:join, member: author(native_id: "u9", first_name: "Ada")),
                             config: { welcome: "welcome {mention}!" }))
      body = greeting_on("tg").body
      expect(body.text).to eq("welcome Ada!")
      mention = body.spans.find { |s| s.kind == :mention }
      # tg is a :fake-adapter endpoint, so the id-for-target key is namespaced to that platform.
      expect(mention.attributes).to eq(fake_id_for_target: "u9")
      expect(body.text[mention.begin_index...mention.end_index]).to eq("Ada")
    end

    it "degrades to the plain name when the member has no known native id" do
      greetings.call(context(membership(:join, member: author(native_id: nil, first_name: "Ghost")),
                             config: { welcome: "welcome {mention}!" }))
      body = greeting_on("tg").body
      expect(body.text).to eq("welcome Ghost!")
      expect(body.spans).to be_empty
    end
  end

  describe "persistence" do
    it "persists by default (no self-delete scheduled)" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      greetings(cleanup: cleanup).call(context(membership(:join), config: { welcome: "Welcome!" }))
      expect(cleanup).not_to have_received(:after)
    end

    it "self-deletes after delete_after seconds when configured" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      greetings(cleanup: cleanup).call(
        context(membership(:join), config: { welcome: "Welcome!", delete_after: "30s" })
      )
      expect(cleanup).to have_received(:after).with(30)
    end
  end

  describe "leaving the membership event for the bridge", :control_plane do
    it "posts a greeting to the origin AND lets the bridge relay the join across the room" do
      bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: adapters, storage: Rubotty::Storage::Memory.new,
        loop_guard: Rubotty::Core::LoopGuard.new(storage: Rubotty::Storage::Memory.new), logger: Rubotty::Log.null
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
            feature: "greetings", enabled: true, config: { welcome: "Welcome {name}!" }
          ),
          Rubotty::ControlPlane::Snapshot::FeatureSetting.new(feature: "bridge", enabled: true, config: {})
        ]
      )
      snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
      registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
      pipeline = Rubotty::Features::Pipeline.new(features: [greetings, bridge], registry: registry)

      pipeline.handle(membership(:join))

      expect(greeting_on("tg").body.text).to eq("Welcome Ada!") # greeting to origin
      expect(adapter.delivered_to("dc")).not_to be_empty         # join relayed to the far side
    end
  end

  describe "per-community and per-room config and enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "greetings", enabled: enabled, config: config
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
      Rubotty::Features::Pipeline.new(features: [greetings], registry: registry)
    end

    it "greets where a community-default row enables it, reading that row's text" do
      pipeline = pipeline_for([setting(enabled: true, config: { welcome: "hey {name}" })])
      pipeline.handle(membership(:join, origin: ep_a))
      expect(greeting_on("ch-a").body.text).to eq("hey Ada")
    end

    it "does not greet where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { welcome: "hey {name}" }),
          setting(enabled: false, room_key: "b")
        ]
      )
      pipeline.handle(membership(:join, origin: ep_b))
      expect(adapter.delivered).to be_empty
    end

    it "resolves the text per room: a room row's text applies to its channel" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: { welcome: "community hello" }),
          setting(enabled: true, room_key: "a", config: { welcome: "channel hello {name}" })
        ]
      )
      pipeline.handle(membership(:join, origin: ep_a))
      expect(greeting_on("ch-a").body.text).to eq("channel hello Ada")
    end
  end
end
