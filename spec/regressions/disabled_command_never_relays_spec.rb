# frozen_string_literal: true

require "spec_helper"

# A `/delete@rubotty_telegram_bot` typed where moderation was switched off
# arrived on Discord as chat: the pipeline skips a disabled feature, and the
# notice held moderation's verbs back for an anti-enumeration reason a client
# command menu makes pointless. Every recognised command is answered here.
RSpec.describe "a command word whose feature is switched off", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }
  let(:topology) { registry.current.topology }

  let(:cleanup) { Rubotty::Core::Scheduler.new(logger: Rubotty::Log.null) }

  let(:notice) do
    Rubotty::Features::DisabledCommandNotice.new(
      topology: topology, adapters: adapters, logger: Rubotty::Log.null, cleanup: cleanup
    )
  end

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology, adapters: adapters, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
    )
  end

  # The seeded bootstrap operator, so operator standing is never what stops a
  # command reaching the point this is about.
  let(:owner) { Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner") }

  after { cleanup.stop }

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint
  def far_platform_delivered = adapter.delivered_to("dc-gaming")
  def origin_delivered = adapter.delivered_to("tg-gaming")

  def switch!(feature_name, on)
    community = registry.current.community("sample")
    controls.public_send(on ? :enable : :disable, community: community, selector: "gaming",
                         feature: feature_name)
  end

  def send!(feature, text, author: owner, **rest)
    pipeline = Rubotty::Features::Pipeline.new(features: [feature, notice, bridge].compact,
                                               logger: Rubotty::Log.null, registry: registry)
    pipeline.handle(message(origin, text: text, native_id: "m#{rand(100_000)}", author: author, **rest))
  end

  shared_examples "answered here, never relayed" do |command_text:, names:|
    it "sends nothing to the far platform" do
      send!(feature, command_text)
      expect(far_platform_delivered).to be_empty
    end

    it "answers in the room the command was typed in, naming what stopped it" do
      send!(feature, command_text)
      reply = origin_delivered.last
      expect(reply).not_to be_nil
      expect(reply.body.text).to include(command_text.split.first.split("@").first)
      expect(reply.body.text).to include(names)
    end
  end

  describe Rubotty::Features::Moderation do
    before { switch!("moderation", false) }

    let(:feature) do
      described_class.new(
        topology: topology, adapters: adapters, storage: storage, logger: Rubotty::Log.null,
        commands: Rubotty::Core::Commands.new(actions: Rubotty::Core::Moderation::ACTIONS,
                                              logger: Rubotty::Log.null)
      )
    end

    # The message that was actually reported, verbatim, replying to another.
    it "answers the reported /delete rather than relaying it" do
      send!(feature, "/delete@rubotty_telegram_bot", reply_to: ref("tg-gaming", "68"))

      expect(far_platform_delivered).to be_empty
      expect(origin_delivered.last.body.text).to include("/delete")
      expect(origin_delivered.last.body.text).to include(described_class.description)
    end

    include_examples "answered here, never relayed", command_text: "/ban",
                                                     names: Rubotty::Features::Moderation.description
    include_examples "answered here, never relayed", command_text: "/lock",
                                                     names: Rubotty::Features::Moderation.description
    include_examples "answered here, never relayed", command_text: "/mute 30",
                                                     names: Rubotty::Features::Moderation.description

    # The refusal is a command acknowledgement like any other, so a room that
    # left moderation off does not fill up with permanent error messages. The
    # TTL is moderation's own, not a second timer belonging to the notice.
    def set_ack_ttl!(seconds)
      controls.set(community: registry.current.community("sample"), selector: "gaming",
                   feature: "moderation", key: Rubotty::Core::CommandAck::TTL_FIELD, value: seconds)
    end

    it "schedules the answer's own removal on moderation's configured TTL" do
      set_ack_ttl!(15)
      send!(feature, "/ban")

      expect(cleanup.pending).to eq(1)
    end

    it "leaves the answer standing where that same setting says not to remove it" do
      set_ack_ttl!(0)
      send!(feature, "/ban")

      expect(cleanup.pending).to eq(0)
      expect(origin_delivered.last.body.text).to include("/ban")
    end

    # Moderation answers its own refusals, including the operator one, so the
    # two paths must not both speak.
    it "leaves the verb to moderation once it is switched back on" do
      switch!("moderation", true)
      send!(feature, "/ban", author: Rubotty::Core::Author.new(native_id: "999", username: "passer_by"))

      expect(far_platform_delivered).to be_empty
      expect(origin_delivered.length).to eq(1)
      expect(origin_delivered.last.body.text).not_to include(described_class.description)
    end
  end

  describe Rubotty::Features::ModeratedRoom do
    before { switch!("moderated_room", false) }

    let(:feature) do
      described_class.new(topology: topology, adapters: adapters, storage: storage,
                          logger: Rubotty::Log.null)
    end

    include_examples "answered here, never relayed", command_text: "/whitelist @someone",
                                                     names: Rubotty::Features::ModeratedRoom.description
    include_examples "answered here, never relayed", command_text: "/unwhitelist @someone",
                                                     names: Rubotty::Features::ModeratedRoom.description
  end

  describe Rubotty::Features::Scripts do
    before { switch!("scripts", false) }

    let(:feature) { described_class.new(logger: Rubotty::Log.null) }

    include_examples "answered here, never relayed", command_text: "/debug-lua on",
                                                     names: Rubotty::Features::Scripts.description
  end

  describe Rubotty::Features::Redirection do
    before { switch!("redirection", false) }

    let(:feature) do
      described_class.new(topology: topology, adapters: adapters, storage: storage,
                          logger: Rubotty::Log.null, registry: registry)
    end

    include_examples "answered here, never relayed", command_text: "/end",
                                                     names: Rubotty::Features::Redirection.description

    it "leaves /end to redirection while redirection is still on" do
      switch!("redirection", true)
      send!(feature, "/end")

      expect(far_platform_delivered).to be_empty
      expect(origin_delivered.last.body.text).not_to include(described_class.description)
    end
  end

  # A feature can be switched on and still have nothing behind it, which is what
  # a deployment that never wired the service up looks like from a room.
  describe "a command whose feature is on but whose service is missing" do
    let(:feature) { nil }

    it "answers without blaming a setting nobody can change" do
      switch!("keyword_watch", true)
      send!(nil, "/watch aoe3")

      expect(far_platform_delivered).to be_empty
      expect(origin_delivered.last.body.text).to include("/watch")
      expect(origin_delivered.last.body.text).not_to include("isn't turned on")
    end
  end

  describe "everything that is not a command" do
    let(:feature) { nil }

    it "still relays ordinary chat" do
      switch!("moderation", false)
      send!(nil, "please delete that")

      expect(far_platform_delivered.map { |sent| sent.body.text }.join).to include("please delete")
    end

    it "still relays a word that only looks like a command" do
      switch!("moderation", false)
      send!(nil, "/deleteish and unrelated")

      expect(far_platform_delivered.map { |sent| sent.body.text }.join).to include("deleteish")
    end
  end
end
