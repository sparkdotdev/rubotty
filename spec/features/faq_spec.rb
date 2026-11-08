# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::Faq do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  # One recording adapter, a two-endpoint room and a real ephemeral primitive, so a posted
  # response is observable on the fake.
  def faq(ephemeral: default_ephemeral, cleanup: nil)
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

  def context(message, config: {}, community: nil)
    Rubotty::Features::Context.new(message: message, config: config, community: community)
  end

  # A Snapshot::Community carrying only the shared command marker, the scope
  # every command-bearing feature (including this one) now reads it through.
  def community_with(prefixes: nil, prefix: nil)
    marker_config = {}
    marker_config["prefixes"] = prefixes unless prefixes.nil?
    marker_config["prefix"] = prefix unless prefix.nil?
    Rubotty::ControlPlane::Snapshot::Community.new(
      id: "c1", slug: "c1", name: "c1", status: "active", settings: {},
      topology: Rubotty::Core::Topology.new([]), channels: [],
      operators: Rubotty::Core::Moderation::Directory.new, people: Rubotty::Core::Directory.new,
      feature_settings: [
        Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
          feature: Rubotty::Core::CommandPrefix::CONFIG_FEATURE, enabled: true, config: marker_config
        )
      ]
    )
  end

  # A config with a list of entries.
  def entries(*list, **overrides)
    { entries: list, **overrides }
  end

  # The last thing the fake was asked to deliver to tg: the FAQ's own response.
  def response_on(endpoint_id) = adapter.delivered_to(endpoint_id).last

  describe "the feature contract" do
    it "names itself, is off by default, and observes only chat" do
      expect(described_class.feature_name).to eq("faq")
      expect(described_class.default_enabled?).to be(false)
      expect(described_class.observes).to eq(%i[chat])
    end

    it "publishes a config schema for the dashboard and loader to validate against" do
      expect(described_class.config_schema).to be_a(Rubotty::Config::Schema)
    end

    it "is a no-op when no entries are configured, so it is safe to keep in the chain" do
      outcome = faq.call(context(message(tg, text: "anything at all")))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "command triggers" do
    let(:config) { entries({ command: "rules", response: "Be nice. No spam." }) }

    it "posts the configured response when the command is invoked" do
      faq.call(context(message(tg, text: "/rules"), config: config))
      expect(response_on("tg").body.text).to eq("Be nice. No spam.")
    end

    it "consumes the command: it halts, so the bare command is never relayed" do
      outcome = faq.call(context(message(tg, text: "/rules"), config: config))
      expect(outcome).to be_halt
    end

    it "matches the command case-insensitively" do
      faq.call(context(message(tg, text: "/RULES"), config: config))
      expect(response_on("tg").body.text).to eq("Be nice. No spam.")
    end

    it "fires when the command carries trailing arguments" do
      outcome = faq.call(context(message(tg, text: "/rules please"), config: config))
      expect(outcome).to be_halt
      expect(response_on("tg").body.text).to eq("Be nice. No spam.")
    end

    it "does not fire when the command only appears mid-sentence: it is anchored to the start" do
      outcome = faq.call(context(message(tg, text: "what are the /rules here"), config: config))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "honours the community's own configured legacy singular prefix" do
      outcome = faq.call(context(message(tg, text: "?rules"), config: config, community: community_with(prefix: "?")))
      expect(outcome).to be_halt
      expect(response_on("tg").body.text).to eq("Be nice. No spam.")
    end

    # Discord reserves a leading "/" for its native slash UI, so the default set carries "!" too.
    it "fires under the alternate ! prefix by default, not only under /" do
      outcome = faq.call(context(message(tg, text: "!rules"), config: config))
      expect(outcome).to be_halt
      expect(response_on("tg").body.text).to eq("Be nice. No spam.")
    end

    it "leaves an unknown prefixed token alone, so it relays normally" do
      outcome = faq.call(context(message(tg, text: "!notrules"), config: config))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "honours a community's restricted prefix set: with only /, ! is not a command trigger" do
      outcome = faq.call(
        context(message(tg, text: "!rules"), config: config, community: community_with(prefixes: ["/"]))
      )
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end

    it "does not relay the command downstream: the bridge never sees it", :control_plane do
      pipeline = pipeline_with_bridge_enabling(entries({ command: "rules", response: "Be nice." }))
      pipeline.handle(message(tg, text: "/rules", native_id: "5"))

      expect(response_on("tg").body.text).to eq("Be nice.")
      expect(adapter.delivered_to("dc")).to be_empty
    end
  end

  describe "auto-response triggers" do
    let(:config) { entries({ keyword: "how do i join", response: "See the pinned message.", mode: "literal" }) }

    it "posts the configured response when the keyword appears" do
      faq.call(context(message(tg, text: "hey, how do i join this place?"), config: config))
      expect(response_on("tg").body.text).to eq("See the pinned message.")
    end

    it "does NOT consume: it continues, so the user's own message still relays" do
      outcome = faq.call(context(message(tg, text: "how do i join?"), config: config))
      expect(outcome).to be_continue
    end

    it "posts the answer AND relays the original when driven through the real pipeline", :control_plane do
      pipeline = pipeline_with_bridge_enabling(config)
      pipeline.handle(message(tg, text: "how do i join?", native_id: "5"))

      expect(response_on("tg").body.text).to eq("See the pinned message.")
      relayed = adapter.delivered_to("dc").map { |m| m.body.text }
      expect(relayed).to include("how do i join?")
    end

    it "supports wildcard and regex keywords through the shared matcher" do
      wildcard = entries({ keyword: "join*", response: "wild", mode: "wildcard" })
      expect(faq.call(context(message(tg, text: "joining soon"), config: wildcard))).to be_continue
      expect(response_on("tg").body.text).to eq("wild")

      regex = entries({ keyword: "h[e3]llo", response: "hi there", mode: "regex" })
      faq.call(context(message(tg, text: "h3llo everyone"), config: regex))
      expect(response_on("tg").body.text).to eq("hi there")
    end

    it "fires only the FIRST matching auto-response, so one message is not a flood" do
      config = entries(
        { keyword: "join", response: "first" },
        { keyword: "join", response: "second" }
      )
      faq.call(context(message(tg, text: "how do i join"), config: config))
      expect(adapter.delivered_to("tg").map { |m| m.body.text }).to eq(["first"])
    end

    it "rejects a ReDoS-shaped keyword before it can run, so the entry is simply dropped" do
      config = entries({ keyword: "(a+)+$", response: "boom", mode: "regex" })
      outcome = faq.call(context(message(tg, text: "aaaaaaaaaaaaaaaaaaaa!"), config: config))
      expect(outcome).to be_continue
      expect(adapter.delivered).to be_empty
    end
  end

  describe "command precedence over auto-responses" do
    it "fires the command and swallows the message, never the keyword, when a message is a command" do
      config = entries(
        { command: "rules", response: "the rules" },
        { keyword: "rules", response: "auto rules" }
      )
      outcome = faq.call(context(message(tg, text: "/rules"), config: config))
      expect(outcome).to be_halt
      expect(adapter.delivered_to("tg").map { |m| m.body.text }).to eq(["the rules"])
    end
  end

  describe "response lifetime" do
    it "persists by default: no self-delete is scheduled" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      subject = faq(cleanup: cleanup)
      subject.call(context(message(tg, text: "/hours"), config: entries({ command: "hours", response: "10-6 UTC" })))
      expect(response_on("tg").body.text).to eq("10-6 UTC")
      expect(cleanup).not_to have_received(:after)
    end

    it "self-deletes after delete_after seconds when the entry sets one" do
      cleanup = instance_spy(Rubotty::Core::Scheduler)
      subject = faq(cleanup: cleanup)
      subject.call(
        context(message(tg, text: "/hours"), config: entries({ command: "hours", response: "10-6 UTC", delete_after: 30 }))
      )
      expect(response_on("tg").body.text).to eq("10-6 UTC")
      expect(cleanup).to have_received(:after).with(30)
    end
  end

  describe "mention safety" do
    it "posts the response as plain text with no resolved mention spans, so it cannot ping" do
      # With no mention spans the adapters pin allowed_mentions to nothing, so the text
      # reaches the channel inert whatever it says.
      config = entries({ command: "shout", response: "hey @everyone and <@111>, welcome" })
      faq.call(context(message(tg, text: "/shout"), config: config))

      body = response_on("tg").body
      expect(body.text).to eq("hey @everyone and <@111>, welcome")
      expect(body.spans.select { |span| span.kind == :mention }).to be_empty
    end
  end

  describe "per-community and per-room config and enablement", :control_plane do
    let(:ep_a) { Rubotty::Core::Endpoint.new(id: "ch-a", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_b) { Rubotty::Core::Endpoint.new(id: "ch-b", adapter_name: :fake, account: "default", settings: {}) }
    let(:ep_far) { Rubotty::Core::Endpoint.new(id: "ch-far", adapter_name: :fake, account: "default", settings: {}) }

    def setting(enabled:, room_key: nil, config: {})
      Rubotty::ControlPlane::Snapshot::FeatureSetting.new(
        room_key: room_key, feature: "faq", enabled: enabled, config: config
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
      Rubotty::Features::Pipeline.new(features: [faq], registry: registry_for(feature_settings))
    end

    it "answers where a community-default row enables it, reading that row's entries" do
      pipeline = pipeline_for([setting(enabled: true, config: entries({ command: "rules", response: "be nice" }))])
      pipeline.handle(message(ep_a, text: "/rules", native_id: "5"))
      expect(response_on("ch-a").body.text).to eq("be nice")
    end

    it "does not answer where a per-room row overrides the community default off" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: entries({ command: "rules", response: "be nice" })),
          setting(enabled: false, room_key: "b")
        ]
      )
      pipeline.handle(message(ep_b, text: "/rules", native_id: "5"))
      expect(adapter.delivered).to be_empty
    end

    it "resolves the entry list per room: a room row's entries apply to its channel" do
      pipeline = pipeline_for(
        [
          setting(enabled: true, config: entries({ command: "rules", response: "community rules" })),
          setting(enabled: true, room_key: "a", config: entries({ command: "rules", response: "channel rules" }))
        ]
      )
      pipeline.handle(message(ep_a, text: "/rules", native_id: "7"))
      expect(response_on("ch-a").body.text).to eq("channel rules")
    end

    it "does not answer for an origin the snapshot does not know" do
      pipeline = pipeline_for([setting(enabled: true, config: entries({ command: "rules", response: "be nice" }))])
      pipeline.handle(message(endpoint("stranger"), text: "/rules", native_id: "5"))
      expect(adapter.delivered).to be_empty
    end
  end

  # A real [faq, bridge] pipeline with the FAQ enabled on both endpoints of one room.
  def pipeline_with_bridge_enabling(config)
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
        Rubotty::ControlPlane::Snapshot::FeatureSetting.new(feature: "faq", enabled: true, config: config)
      ]
    )
    snapshot = Rubotty::ControlPlane::Snapshot.new(communities: [community])
    registry = instance_double(Rubotty::ControlPlane::Registry, current: snapshot)
    Rubotty::Features::Pipeline.new(features: [faq, bridge], registry: registry)
  end
end
