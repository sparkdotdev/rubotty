# frozen_string_literal: true

require "spec_helper"

# Ten command features bailed out of #call on a missing operations service
# BEFORE checking whether the message was even their command word, so a
# community that turned one on ahead of the deployment wiring it relayed the
# typed command into every room on every platform.
RSpec.describe "an unconfigured command feature at the bridge boundary", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: registry.current.topology, adapters: adapters, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
    )
  end

  # The seeded bootstrap operator, so a command that needs operator standing
  # is not itself the thing refusing.
  let(:owner) { Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner") }

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint
  def far_platform_delivered = adapter.delivered_to("dc-gaming")
  def origin_delivered = adapter.delivered_to("tg-gaming")

  def turn_on!(feature_name)
    community = registry.current.community("sample")
    controls.enable(community: community, selector: "gaming", feature: feature_name)
  end

  def send!(feature, text, author: owner)
    pipeline = Rubotty::Features::Pipeline.new(features: [feature, bridge], logger: Rubotty::Log.null,
                                               registry: registry)
    pipeline.handle(message(origin, text: text, native_id: "m#{rand(100_000)}", author: author))
  end

  shared_examples "swallows and answers, never relays" do |command_text:|
    it "sends nothing to the far platform" do
      send!(feature, command_text)
      expect(far_platform_delivered).to be_empty
    end

    it "answers in the room the command was typed in" do
      send!(feature, command_text)
      expect(origin_delivered.last.body.text).to include(command_text.split.first)
    end
  end

  describe Rubotty::Features::EventCommand do
    before { turn_on!("events") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          event_scheduling: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/event title=\"x\" start=\"now\" kind=gaming"
  end

  describe Rubotty::Features::EventsCommand do
    before { turn_on!("events") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          event_scheduling: nil, announcer: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/events"
  end

  describe Rubotty::Features::EventRemindCommand do
    before { turn_on!("events") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          event_scheduling: nil, announcer: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/remind 1"
  end

  describe Rubotty::Features::EventRsvp do
    before { turn_on!("events") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          event_scheduling: nil, announcer: nil, ledger: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/rsvp 1 yes"
  end

  describe Rubotty::Features::GuestCommand do
    before { turn_on!("guest_portal") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          guest_invites: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/guest Sam"
  end

  describe Rubotty::Features::UploadCommand do
    before { turn_on!("file_rehosting") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          tickets: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/upload"
  end

  describe Rubotty::Features::OperatorRequests do
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          operator_flow: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/operator request"
  end

  describe Rubotty::Features::PollCommand do
    before { turn_on!("poll") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          polls: nil, board: nil, ballot: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/poll Pizza? | Yes | No"
  end

  describe Rubotty::Features::Nickname do
    before { turn_on!("nickname") }
    let(:feature) do
      described_class.new(topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
                          nicknames: nil)
    end

    include_examples "swallows and answers, never relays", command_text: "/nickname"
  end

  describe Rubotty::Features::Moderation do
    # On by code default, so no dashboard toggle is needed to reach it.
    let(:feature) do
      described_class.new(
        topology: registry.current.topology, adapters: adapters, storage: storage, logger: Rubotty::Log.null,
        commands: nil
      )
    end

    include_examples "swallows and answers, never relays", command_text: "/ban"
  end
end
