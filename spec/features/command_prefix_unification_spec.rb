# frozen_string_literal: true

require "spec_helper"
require "rubotty/scripting"

# A handful of features used to read Core::CommandPrefix without ever
# declaring their own copy of the setting, so their config was always empty
# and they silently fell back to the hardcoded "/" and "!" no matter what an
# operator configured elsewhere.
RSpec.describe "the shared command marker reaching every command-bearing feature", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  # registry: registry so a controls.set write reloads the snapshot #run reads
  # context.community from, the same way the dashboard does.
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  def gaming_origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def newcomer
    Rubotty::Core::Author.new(native_id: "999888", username: "newbie", first_name: "New", last_name: "Bie")
  end

  # The seeded bootstrap operator on Telegram (sample_owner), for the one
  # scenario below (Scripts' /debug-lua) that is operator gated.
  def boss
    Rubotty::Core::Author.new(native_id: "80000012", username: "sample_owner", first_name: "Alex")
  end

  # Moves the community's shared command marker off the hardcoded default,
  # the same write path the dashboard's Features page drives.
  def set_marker!(prefixes, selector: "all")
    controls.set(community: registry.current.community("sample"), selector: selector,
                 feature: "commands", key: "prefixes", value: prefixes)
  end

  # A fresh Context off the CURRENT snapshot, so a controls.set above is
  # picked up rather than a stale community captured before the reload.
  def run(feature, text, origin: gaming_origin, author: newcomer)
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key(origin.id)
    msg = message(origin, text: text, native_id: "m#{rand(1_000_000)}", author: author)
    feature.call(Rubotty::Features::Context.new(message: msg, community: community, channel: channel))
  end

  describe "/event (EventCommand)" do
    let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }
    let(:feature) do
      Rubotty::Features::EventCommand.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        event_scheduling: scheduling, ephemeral: ephemeral
      )
    end
    let(:fields) { "title=Standup start=now kind=general tz=UTC" }

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])

      expect(run(feature, "/event #{fields}")).to be_continue
      expect(run(feature, "#event #{fields}")).to be_halt
    end
  end

  describe "/rsvp (EventRsvp)" do
    let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }
    let(:announcer) do
      Rubotty::Events::Announcer.new(registry: registry, models: models, adapters: adapters, logger: Rubotty::Log.null)
    end
    let(:ledger) { Rubotty::Events::RsvpLedger.new(models: models, logger: Rubotty::Log.null) }
    let(:feature) do
      Rubotty::Features::EventRsvp.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        event_scheduling: scheduling, announcer: announcer, ledger: ledger, ephemeral: ephemeral
      )
    end

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])

      expect(run(feature, "/rsvp 1 yes")).to be_continue
      expect(run(feature, "#rsvp 1 yes")).to be_halt
    end
  end

  describe "/poll (PollCommand)" do
    let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null) }
    let(:ballot) { Rubotty::Polls::Ballot.new(models: models, logger: Rubotty::Log.null) }
    let(:activity) { Rubotty::Polls::RoomActivity.new }
    let(:board) do
      Rubotty::Polls::Board.new(
        registry: registry, models: models, adapters: adapters, polls: writer,
        ballot: ballot, activity: activity, logger: Rubotty::Log.null
      )
    end
    let(:feature) do
      Rubotty::Features::PollCommand.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        polls: writer, board: board, ballot: ballot, activity: activity, ephemeral: ephemeral
      )
    end
    let(:body) { "Which map? | Dust II | Inferno" }

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])

      expect(run(feature, "/poll #{body}")).to be_continue
      expect(run(feature, "#poll #{body}")).to be_halt
    end
  end

  describe "/upload (UploadCommand)" do
    let(:tickets) { Rubotty::ControlPlane::UploadTickets.new(models: models, logger: Rubotty::Log.null) }
    let(:feature) do
      Rubotty::Features::UploadCommand.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        tickets: tickets, ephemeral: ephemeral, env: { "GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat" }
      )
    end

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])

      expect(run(feature, "/upload", origin: registry.current.channel_by_endpoint_key("tg-general").endpoint))
        .to be_continue
      expect(run(feature, "#upload", origin: registry.current.channel_by_endpoint_key("tg-general").endpoint))
        .to be_halt
    end
  end

  describe "/guest (GuestCommand)" do
    let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models, logger: Rubotty::Log.null) }
    let(:feature) do
      Rubotty::Features::GuestCommand.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        guest_invites: invites, ephemeral: ephemeral,
        env: { "GUEST_PORTAL_URL" => "https://rubotty.example/guest-chat" }
      )
    end

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])
      general = registry.current.channel_by_endpoint_key("tg-general").endpoint

      expect(run(feature, "/guest Sam", origin: general, author: boss)).to be_continue
      expect(run(feature, "#guest Sam", origin: general, author: boss)).to be_halt
    end
  end

  describe "/identify-topic (IdentifyTopic)" do
    IdentifiedChannel = Struct.new(:label, :suggested, keyword_init: true)

    def fake_channel_discovery
      Class.new do
        def identify_known(**) = IdentifiedChannel.new(label: "Lisbon Meetup", suggested: false)
      end.new
    end

    let(:feature) do
      Rubotty::Features::IdentifyTopic.new(
        topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
        ephemeral: ephemeral, channel_discovery: fake_channel_discovery
      )
    end

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])

      expect(run(feature, "/identify-topic Lisbon Meetup", author: boss)).to be_continue
      expect(run(feature, "#identify-topic Lisbon Meetup", author: boss)).to be_halt
    end
  end

  describe "/debug-lua (Scripts)" do
    before(:all) do
      skip "no Lua interpreter on PATH" if Rubotty::Scripting::Child.find_binary.nil?
    end

    let(:pool) { Rubotty::Scripting::Pool.new(size: 1, logger: Rubotty::Log.null) }
    let(:smoke) { Rubotty::Scripting::SmokeTest.new(pool: pool, logger: Rubotty::Log.null, timeout: SMOKE_TEST_SPEC_TIMEOUT) }
    let(:scripts) { Rubotty::ControlPlane::Scripts.new(models: models, logger: Rubotty::Log.null, smoke_test: smoke) }
    let(:removal) do
      Class.new do
        def remove_everywhere(*) = []

        def notice(**) = nil
      end.new
    end
    # The answer is a command acknowledgement, so it goes through the shared
    # ephemeral primitive rather than out to the room.
    let(:answered) { [] }
    let(:ephemeral) do
      Class.new do
        def initialize(log) = @log = log

        def post(body:, **)
          @log << body.text
          Object.new.tap { |group| def group.any? = false }
        end
      end.new(answered)
    end
    let(:feature) do
      Rubotty::Features::Scripts.new(
        scripts: scripts, pool: pool, logger: Rubotty::Log.null,
        removal: removal, ephemeral: ephemeral
      )
    end

    after { pool.close }

    it "ignores the hardcoded default and answers the community's own marker instead" do
      set_marker!(["#"])

      expect(run(feature, "/debug-lua on", author: boss)).to be_continue
      expect(run(feature, "#debug-lua on", author: boss)).to be_halt
      expect(answered.last).to include("tracing on")
    end
  end

  # disabled_command_notice.rb is fixed the same way, and specifically covered
  # in spec/features/disabled_command_notice_spec.rb ("reading the same shared
  # marker as the feature it is describing"), since its own bug was different:
  # not silence, but a notice quoting the wrong marker.
end
