# frozen_string_literal: true

require "spec_helper"

# Telegram has no album update: several photos sent as one album arrive as
# separate messages sharing a media_group_id, with the caption on exactly one of
# them and not reliably the first. AlbumBuffer was written and unit tested but
# never called, so this covers the wiring rather than the buffer.
RSpec.describe "inbound Telegram albums" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" }) }

  subject(:adapter) do
    Rubotty::Adapters::Telegram::Adapter.new(
      account: "tg",
      # A short window keeps the test quick; the default is 1.5 seconds.
      settings: { token: "t", token_env: "TG", album_window: 0.05 },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [place]
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "t", http: http))
  end

  after { adapter.stop }

  def part(id, group: "G1", caption: nil, file: nil)
    adapter.handle_update(
      "update_id" => id,
      "message" => {
        "message_id" => id, "date" => 1_700_000_000,
        "chat" => { "id" => -100_111 },
        "media_group_id" => group,
        "caption" => caption,
        "photo" => [{ "file_id" => file || "f#{id}" }]
      }.compact
    )
  end

  def settle
    # Let the buffer's timer close the window.
    30.times { break if dispatcher.messages.any?; sleep 0.02 }
  end

  it "merges the parts of one album into a single message" do
    3.times { |i| part(i + 1) }
    settle
    expect(dispatcher.messages.size).to eq(1)
  end

  it "carries every attachment on that one message" do
    3.times { |i| part(i + 1, file: "file-#{i + 1}") }
    settle
    expect(dispatcher.last.attachments.map(&:native_ref)).to eq(%w[file-1 file-2 file-3])
  end

  # The caption can land on any part, which is what strands it under a random photo.
  it "finds the caption wherever Telegram put it" do
    part(1)
    part(2, caption: "the caption")
    part(3)
    settle
    expect(dispatcher.last.body.text).to eq("the caption")
  end

  it "identifies the album by its first part, so the message map stays stable" do
    part(7)
    part(5)
    settle
    expect(dispatcher.last.ref.native_id).to eq("5")
  end

  it "keeps two albums apart" do
    part(1, group: "G1")
    part(2, group: "G2")
    30.times { break if dispatcher.messages.size >= 2; sleep 0.02 }
    expect(dispatcher.messages.size).to eq(2)
  end

  it "does not hold back an ordinary message that is not part of an album" do
    adapter.handle_update(
      "update_id" => 99,
      "message" => {
        "message_id" => 99, "date" => 1_700_000_000,
        "chat" => { "id" => -100_111 }, "text" => "just a message"
      }
    )
    expect(dispatcher.messages.size).to eq(1)
    expect(dispatcher.last.body.text).to eq("just a message")
  end

  # A part assembled album must not vanish when the process goes down.
  it "flushes what it is holding on shutdown" do
    part(1)
    part(2)
    adapter.stop
    expect(dispatcher.messages.size).to eq(1)
    expect(dispatcher.last.attachments.size).to eq(2)
  end
end
