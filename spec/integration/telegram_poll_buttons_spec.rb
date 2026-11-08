# frozen_string_literal: true

require "spec_helper"

# Telegram's reaction whitelist has no keycap digits and a bot may hold only
# one reaction on a message, so the card's numbered affordances never
# existed there; a reply was the only way to answer. This drives the real
# Telegram adapter and board end to end rather than through a double.
RSpec.describe "a poll answered by button on Telegram", :control_plane do
  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:accounts) { sample_model.accounts }
  let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: accounts) }
  let(:controls) { Rubotty::ControlPlane::FeatureControls.new(models: models) }

  let(:tg_endpoint) { registry.current.channel_by_endpoint_key("tg-gaming").endpoint }
  let(:http) { Fakes::TelegramHttp.new }
  let(:tg_dispatcher) { Fakes::RecordingDispatcher.new }
  let(:tg_adapter) do
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "telegram", settings: { token: "123:abc", token_env: "TELEGRAM_BOT_TOKEN" },
      dispatcher: tg_dispatcher, logger: Rubotty::Log.null, endpoints: [tg_endpoint]
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
  end

  let(:dc_adapter) { Fakes::ReactingAdapter.new(own_id: "bot-2") }

  let(:adapters) do
    { [:telegram, "telegram"] => tg_adapter, [:discord, "discord"] => dc_adapter }
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

  def run(message)
    feature.call(
      Rubotty::Features::Context.new(
        message: message, community: registry.current.community("sample"),
        channel: registry.current.channel_by_endpoint_key("tg-gaming")
      )
    )
  end

  def open_poll(text = "/poll Which map? | Dust II | Inferno")
    controls.enable(community: registry.current.community("sample"), selector: "gaming", feature: "poll")
    run(message(tg_endpoint, text: text, native_id: "cmd-1", author: ada))
    writer.open_polls.last
  end

  def card_native_id(poll)
    models.poll_card.where(poll_id: poll.id, endpoint_id: tg_endpoint.id).first&.native_id
  end

  # What Telegram posts when somebody taps a button on the card.
  def press(poll, position, user: { "id" => 77, "username" => "ada", "is_bot" => false })
    tg_adapter.handle_update(
      "update_id" => 5,
      "callback_query" => {
        "id" => "cb-1", "from" => user,
        "data" => Rubotty::Polls::VoteButtons.token_for(position),
        "message" => {
          "message_id" => card_native_id(poll).to_i,
          "date" => 1_700_000_000,
          "message_thread_id" => 142_483,
          "chat" => { "id" => -1008000000001, "type" => "supergroup", "is_forum" => true }
        }
      }
    )
    run(tg_dispatcher.last)
  end

  def voters_on(poll, position)
    ballot.by_option(writer.by_id(poll.id))[writer.option_at(poll, position).id].map(&:handle)
  end

  # The card is the first thing sent; the acknowledgement follows it.
  def card_call = http.calls("sendMessage").first

  def keyboard_of(call) = call.params.dig("reply_markup", "inline_keyboard").flatten

  it "posts the card with one tappable button per option" do
    open_poll

    expect(keyboard_of(card_call).map { |button| button["callback_data"] })
      .to eq(%w[poll-option:1 poll-option:2])
    expect(keyboard_of(card_call).map { |button| button["text"] })
      .to eq(["1️⃣ Dust II", "2️⃣ Inferno"])
  end

  it "tells the room to tap rather than to react, which it cannot do here" do
    open_poll

    expect(card_call.params["text"]).to include("Tap an option below to vote")
    expect(card_call.params["text"]).not_to include("React with")
  end

  it "records the press as a vote and redraws the card in place" do
    poll = open_poll
    expect(press(poll, 2)).to be_halt

    expect(voters_on(poll, 2)).to eq(["ada"])
    expect(http.last("editMessageText").params["text"]).to include("Inferno @ada")
  end

  # The keyboard belongs to the message, and an edit naming none takes it off.
  it "keeps the buttons on the card the refreshed tally goes onto" do
    poll = open_poll
    press(poll, 1)

    expect(keyboard_of(http.last("editMessageText")).map { |button| button["callback_data"] })
      .to eq(%w[poll-option:1 poll-option:2])
  end

  it "answers the query, so the presser's client is not left spinning" do
    poll = open_poll
    press(poll, 1)

    expect(http.last("answerCallbackQuery").params["callback_query_id"]).to eq("cb-1")
  end

  it "leaves the copy on a platform where the keycaps work as it was" do
    open_poll

    expect(dc_adapter.syncs.first[:desired]).to eq(Rubotty::Polls::OptionEmoji.for_count(2))
    expect(dc_adapter.delivered.last.last.body.text).to include("React with a number to vote.")
  end
end
