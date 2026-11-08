# frozen_string_literal: true

require "spec_helper"

# The unsend gesture: edit a message to a single full stop and it goes away
# everywhere. Telegram never tells a bot that a message was deleted, so an
# edit to "." (which arrives as an edited_message) is the only signal there
# is, and /delete needs operators a fresh install has none of.
RSpec.describe "unsend by editing to a full stop" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" }) }

  def adapter(enabled: true)
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg",
      settings: { token: "t", token_env: "TG", cross_delete_on_discord: enabled },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [place]
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "t", http: http))
  end

  def edit_to(text, entities: nil, enabled: true)
    adapter(enabled: enabled).handle_update(
      "update_id" => 1,
      "edited_message" => {
        "message_id" => 700, "date" => 1_700_000_000,
        "chat" => { "id" => -100_111 },
        "from" => { "id" => 55, "first_name" => "Alex", "username" => "alex" },
        "text" => text, "entities" => entities
      }.compact
    )
  end

  it "turns the edit into a delete so the copies go too" do
    edit_to(".")
    expect(dispatcher.last.kind).to eq(:delete)
    expect(dispatcher.last.ref.native_id).to eq("700")
  end

  # Only this adapter can remove the Telegram original: there is no delete event
  # for the router to act on.
  it "removes the Telegram original as well" do
    edit_to(".")
    expect(http.last("deleteMessage").params["message_id"]).to eq(700)
  end

  it "ignores surrounding whitespace" do
    edit_to("  .  ")
    expect(dispatcher.last.kind).to eq(:delete)
  end

  # An ordinary edit that happens to end in a full stop must be untouched.
  it "does not fire for a message merely ending in a full stop" do
    edit_to("that is all.")
    expect(dispatcher.last.kind).to eq(:edit)
    expect(http.called?("deleteMessage")).to be(false)
  end

  it "does not fire for a longer message" do
    edit_to("...")
    expect(dispatcher.last.kind).to eq(:edit)
  end

  # A formatted full stop counts as a deliberate edit rather than the gesture.
  it "does not fire when the full stop carries formatting" do
    edit_to(".", entities: [{ "type" => "bold", "offset" => 0, "length" => 1 }])
    expect(dispatcher.last.kind).to eq(:edit)
  end

  it "can be turned off" do
    edit_to(".", enabled: false)
    expect(dispatcher.last.kind).to eq(:edit)
    expect(http.called?("deleteMessage")).to be(false)
  end

  describe "end to end" do
    let(:storage) { Rubotty::Storage::Memory.new }
    let(:dc) { endpoint("dc") }
    let(:recorder) { Fakes::ReactingAdapter.new }

    it "removes the relayed copy through the message map" do
      router = Rubotty::Core::Router.new(
        topology: topology(room("r", place, dc)), adapters: Hash.new(recorder),
        storage: storage, loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
        logger: Rubotty::Log.null
      )
      storage.record(source: ref("tg", "700"), destination: ref("dc", "d1"), room_id: "r")

      edit_to(".")
      router.handle(dispatcher.last)

      expect(recorder.deleted).to eq([%w[dc d1]])
    end
  end
end
