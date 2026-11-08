# frozen_string_literal: true

require "spec_helper"

# The Discord half of a live bug report: a poll bridging Telegram and Discord
# posted its card with none of the option keycaps Board is supposed to seed,
# and tapping one never moved the tally. Every other poll spec drives a
# generic fake instead of the real Discord adapter, the boundary the bug lived on.
RSpec.describe "a poll bridged onto Discord", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:dc_endpoint) { registry.current.channel_by_endpoint_key("dc-gaming").endpoint }
  let(:tg_endpoint) { registry.current.channel_by_endpoint_key("tg-gaming").endpoint }

  let(:dc_client) { DiscordFakes::Client.new }
  let(:dc_adapter) do
    Rubotty::Adapters::Discord::Adapter.new(
      account: "discord", settings: { token: "t", token_env: "DISCORD_BOT_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: [dc_endpoint]
    ).replace_client(dc_client)
  end
  let(:dc_channel) { dc_client.channel(dc_endpoint.settings[:channel_id]) }

  let(:tg_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }

  let(:adapters) do
    {
      [:discord, "discord"] => dc_adapter,
      [:telegram, "telegram"] => tg_adapter
    }
  end

  let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null) }
  let(:ballot) { Rubotty::Polls::Ballot.new(models: models, logger: Rubotty::Log.null) }
  let(:activity) { Rubotty::Polls::RoomActivity.new }
  let(:board) do
    Rubotty::Polls::Board.new(
      registry: registry, models: models, adapters: adapters, polls: writer,
      ballot: ballot, activity: activity, logger: Rubotty::Log.null
    )
  end
  let(:timekeeper) do
    Class.new do
      def arm(_poll) = 2

      def cancel_for(_poll) = 0
    end.new
  end
  let(:lifecycle) do
    Rubotty::Polls::Lifecycle.new(polls: writer, board: board, timekeeper: timekeeper, logger: Rubotty::Log.null)
  end

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  subject(:feature) do
    Rubotty::Features::PollCommand.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      polls: writer, board: board, ballot: ballot, lifecycle: lifecycle,
      activity: activity, ephemeral: ephemeral
    )
  end

  def ada = Rubotty::Core::Author.new(native_id: "77", username: "ada", first_name: "Ada")

  def turn_on!
    controls.enable(community: registry.current.community("sample"), selector: "gaming", feature: "poll")
  end

  def open_poll
    turn_on!
    feature.call(
      Rubotty::Features::Context.new(
        message: message(tg_endpoint, text: "/poll Which map? | Dust II | Inferno", native_id: "cmd-1", author: ada),
        community: registry.current.community("sample"), channel: registry.current.channel_by_endpoint_key("tg-gaming")
      )
    )
    writer.open_polls.last
  end

  def card_native_id(poll)
    models.poll_card.where(poll_id: poll.id, endpoint_id: dc_endpoint.id).first&.native_id
  end

  before { dc_adapter.start }

  it "seeds a keycap reaction per option onto the Discord copy of the card" do
    poll = open_poll

    target = dc_channel.load_message(card_native_id(poll))
    expect(target.reactions).to eq(%w[1️⃣ 2️⃣])
  end

  # discordrb resolves a reacting member with a live REST call every time
  # (Server#member), and #reaction_author now falls back to the id already
  # off the gateway payload when that lookup comes back nil, so this reaction
  # still lands a vote instead of the silent no-op it used to be.
  it "records a vote tapped on Discord even when discordrb could not resolve the reacting member" do
    poll = open_poll
    native_id = card_native_id(poll)
    inbound = dc_adapter.instance_variable_get(:@inbound)
    event = DiscordFakes::ReactionEvent.new(
      message_id: native_id, channel: dc_channel, user: nil, user_id: "909",
      emoji: DiscordFakes::Emoji.new(id: nil, name: "2️⃣")
    )
    reaction_message = inbound.reaction(event, :reaction_add)

    outcome = feature.call(
      Rubotty::Features::Context.new(
        message: reaction_message, community: registry.current.community("sample"),
        channel: registry.current.channel_by_endpoint_key("dc-gaming")
      )
    )

    expect(outcome).to be_halt
    voters = ballot.by_option(writer.by_id(poll.id))[writer.option_at(poll, 2).id]
    expect(voters.map(&:identity)).to eq(["909"])
  end

  it "re-renders the Discord card in place once a vote lands" do
    poll = open_poll
    native_id = card_native_id(poll)
    inbound = dc_adapter.instance_variable_get(:@inbound)
    event = DiscordFakes::ReactionEvent.new(
      message_id: native_id, channel: dc_channel, user: DiscordFakes.user(id: "77", username: "ada"),
      emoji: DiscordFakes::Emoji.new(id: nil, name: "1️⃣")
    )
    reaction_message = inbound.reaction(event, :reaction_add)

    feature.call(
      Rubotty::Features::Context.new(
        message: reaction_message, community: registry.current.community("sample"),
        channel: registry.current.channel_by_endpoint_key("dc-gaming")
      )
    )

    expect(dc_channel.load_message(native_id).content).to include("Dust II @ada")
  end
end
