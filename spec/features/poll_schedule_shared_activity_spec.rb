# frozen_string_literal: true

require "spec_helper"

# router.rb wires PollCommand and ScheduleCommand to the exact same
# Polls::RoomActivity instance (and the same Board), because a card either
# kind posts should bury at the same room-wide message throughput. Both
# mix in PollSurface, so an ordinary chat message reaches both instances.
RSpec.describe "poll and schedule sharing one RoomActivity", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models, registry: registry) }

  let(:writer) { Rubotty::ControlPlane::Polls.new(models: models, logger: Rubotty::Log.null) }
  let(:ballot) { Rubotty::Polls::Ballot.new(models: models, logger: Rubotty::Log.null) }
  let(:activity) { Rubotty::Polls::RoomActivity.new }
  let(:board) do
    Rubotty::Polls::Board.new(
      registry: registry, models: models, adapters: adapters, polls: writer,
      ballot: ballot, activity: activity, logger: Rubotty::Log.null
    )
  end

  let(:adapter) { Fakes::ReactingAdapter.new(own_id: "bot-1") }
  let(:adapters) { Hash.new(adapter) }

  let(:ephemeral) do
    Rubotty::Core::EphemeralMessage.new(
      adapters: adapters, session_id: "s", topology: registry.current.topology, logger: Rubotty::Log.null
    )
  end

  let(:poll_command) do
    Rubotty::Features::PollCommand.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      polls: writer, board: board, ballot: ballot, activity: activity, ephemeral: ephemeral
    )
  end

  let(:schedule_command) do
    Rubotty::Features::ScheduleCommand.new(
      topology: registry.current.topology, adapters: adapters, logger: Rubotty::Log.null,
      polls: writer, board: board, ballot: ballot, activity: activity, ephemeral: ephemeral
    )
  end

  def origin = registry.current.channel_by_endpoint_key("tg-gaming").endpoint

  def ada = Rubotty::Core::Author.new(native_id: "999888", username: "ada", first_name: "Ada")

  def turn_on!
    community = registry.current.community("sample")
    controls.enable(community: community, selector: "gaming", feature: "poll")
    controls.enable(community: community, selector: "gaming", feature: "events")
    controls.set(community: community, selector: "gaming", feature: "events",
                 key: "allow_schedule_polling", value: true)
  end

  def context(message)
    Rubotty::Features::Context.new(
      message: message, community: registry.current.community("sample"),
      channel: registry.current.channel_by_endpoint_key("tg-gaming"), config: { allow_schedule_polling: true }
    )
  end

  def chat(text, native_id:)
    message(origin, text: text, native_id: native_id, author: ada)
  end

  it "records one ordinary chat message once, not once per feature watching the room" do
    turn_on!
    key = Rubotty::Polls::RoomActivity.key(registry.current.community("sample").id, "gaming")
    before = Time.now - 1
    half_window = Rubotty::Polls::RoomActivity::VISIBLE_WINDOW / 2

    half_window.times do |i|
      msg = chat("message #{i}", native_id: "m#{i}")
      poll_command.call(context(msg))
      schedule_command.call(context(msg))
    end

    # Double-recorded, half the room's real messages would already fill the
    # window and trip buried? at roughly twice the intended rate.
    expect(activity.buried?(key, before)).to be(false)
  end

  it "still buries after enough distinct real messages" do
    turn_on!
    key = Rubotty::Polls::RoomActivity.key(registry.current.community("sample").id, "gaming")
    before = Time.now - 1

    Rubotty::Polls::RoomActivity::VISIBLE_WINDOW.times do |i|
      msg = chat("message #{i}", native_id: "m#{i}")
      poll_command.call(context(msg))
      schedule_command.call(context(msg))
    end

    expect(activity.buried?(key, before)).to be(true)
  end
end
