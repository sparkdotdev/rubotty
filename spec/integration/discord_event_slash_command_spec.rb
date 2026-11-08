# frozen_string_literal: true

require "spec_helper"

# The bug this guards: a native Discord slash /event offered one free text
# box for hand-typed "key=value" pairs instead of a labelled option per
# field, because body_text space-joined a bare value with no key name, and
# splitting into typed options would silently make parse_fields find none.
RSpec.describe "a Discord slash /event invocation, options round trip", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:scheduling) { Rubotty::ControlPlane::EventScheduling.new(models: models, logger: Rubotty::Log.null) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }
  let(:resolver) { Rubotty::ControlPlane::ChannelResolver.new(registry) }

  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  let(:feature) do
    Rubotty::Features::EventCommand.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      event_scheduling: scheduling, ephemeral: ephemeral
    )
  end

  # The gaming room's real seeded Discord endpoint (bridge.config.yaml).
  let(:discord_channel_id) { "8000000000000000003" }
  let(:discord_operator_id) { "80000000000000013" }

  let(:emitted) { [] }
  let(:client) { DiscordFakes::Client.new }
  let(:endpoint_for) { ->(channel_id) { resolver.endpoint_for(:discord, "discord", channel_id) } }
  let(:interactions) do
    Rubotty::Adapters::Discord::Interactions.new(
      client: client, endpoint_for: endpoint_for, emit: ->(message) { emitted << message },
      logger: Rubotty::Log.null
    )
  end

  def discord_interaction(options:)
    Rubotty::Adapters::Discord::Interactions::Interaction.new(
      name: "event", channel_id: discord_channel_id, guild_id: "guild-sample",
      user: Rubotty::Adapters::Discord::Interactions::User.new(
        id: discord_operator_id, username: "sample_owner", display_name: "Alex"
      ),
      options: options, responder: ->(_text) {}
    )
  end

  def turn_on!(who: "everyone")
    controls.enable(community: registry.current.community("sample"), selector: "gaming", feature: "events")
    controls.set(community: registry.current.community("sample"), selector: "gaming", feature: "events",
                 key: "who_can_create", value: who)
  end

  # Drive a slash /event with SEPARATE Discord options (never a single
  # hand-typed "fields" blob) through Interactions#handle, then feed the
  # resulting message into EventCommand#call exactly as Pipeline would.
  def invoke_event(options)
    interactions.handle(discord_interaction(options: options))
    message = emitted.last
    community = registry.current.community("sample")
    channel = registry.current.channel_by_endpoint_key("dc-gaming")
    feature.call(Rubotty::Features::Context.new(message: message, community: community, channel: channel))
  end

  def ack_on(endpoint_id) = adapter.delivered_to(endpoint_id).last&.body&.text

  before { turn_on! }

  it "reconstructs separate Discord options into the same key=value text a person typing it would produce" do
    interactions.handle(discord_interaction(options: {
                                               "title" => "Friday Raid Night",
                                               "start" => "2026-07-25 20:00",
                                               "kind" => "gaming"
                                             }))
    expect(emitted.last.body.text).to eq('/event title="Friday Raid Night" start="2026-07-25 20:00" kind=gaming')
  end

  it "creates an event from only the required options, every optional one left blank" do
    outcome = invoke_event(
      "title" => "Standup", "start" => "2026-07-25 09:00", "kind" => "general"
    )

    expect(outcome).to be_halt
    expect(models.event.count).to eq(1)
    event = models.event.first
    expect(event.title).to eq("Standup")
    expect(event.kind).to eq("general")
    expect(event.game_title).to be_nil
    expect(event.server_address).to be_nil
    expect(event.url).to be_nil
    expect(event.rsvp_mode).to eq("none")
  end

  it "creates an event with every option filled in" do
    outcome = invoke_event(
      "title" => "Friday Raid Night", "start" => "2026-07-25 20:00", "kind" => "gaming",
      "tz" => "Europe/Lisbon", "game" => "Counter-Strike 2", "server" => "1.2.3.4:7777",
      "rsvp" => "affirm"
    )

    expect(outcome).to be_halt
    event = models.event.first
    expect(event.title).to eq("Friday Raid Night")
    expect(event.kind).to eq("gaming")
    expect(event.timezone).to eq("Europe/Lisbon")
    expect(event.game_title).to eq("Counter-Strike 2")
    expect(event.server_address).to eq("1.2.3.4:7777")
    expect(event.rsvp_mode).to eq("affirm")
  end

  it "handles a spaced title/start value correctly through the keyed-argument round trip" do
    invoke_event(
      "title" => "Multi Word Title", "start" => "2026-07-25 09:00", "kind" => "general",
      "url" => "https://x"
    )

    expect(models.event.first.title).to eq("Multi Word Title")
  end

  it "declines with the same 'Missing ...' reply as a hand-typed command when a required option is left blank" do
    outcome = invoke_event("title" => "Standup", "kind" => "general")

    expect(outcome).to be_halt
    expect(models.event.count).to eq(0)
    expect(ack_on("dc-gaming")).to match(/Missing/)
    expect(ack_on("dc-gaming")).to match(/start/)
  end
end
