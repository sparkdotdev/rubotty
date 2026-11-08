# frozen_string_literal: true

require "spec_helper"

# A Telegram file URL embeds the bot token, so Util::SafeUrl blocks it and
# Outbound#attachment_links falls back to a marker. Nothing told the sender
# that happened: the receipt carried no notes, so Features::Bridge#report_notes
# had nothing to relay back, unlike Discord's note_failed_upload.
RSpec.describe Rubotty::Adapters::Matrix::Adapter do
  let(:telegram_file_url) { "https://api.telegram.org/file/bot123456789:AAHqwertyuiop-asdfghjkl/photos/f_1.jpg" }

  let(:client) { MatrixFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:place) { endpoint("mx-general", adapter: :matrix, settings: { room_id: "!room:example.org" }) }

  subject(:adapter) do
    described_class.new(
      account: "mx", settings: { token: "t", token_env: "MATRIX_ACCESS_TOKEN", homeserver: "https://example.org" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [place]
    ).replace_client(client)
  end

  def telegram_attachment
    Rubotty::Core::Attachment.new(kind: :photo, url: telegram_file_url, filename: "f_1.jpg")
  end

  it "posts no part of the token" do
    adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    expect(client.sent_events.first[:content]["body"]).not_to include("AAHqwertyuiop")
  end

  it "still names the file in the room, as the could-not-relay marker" do
    adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    expect(client.sent_events.first[:content]["body"]).to include("f_1.jpg, could not be relayed")
  end

  it "tells the sender the file did not cross" do
    receipt = adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    note = receipt.extra[:notes].first
    expect(note).to include("f_1.jpg")
    expect(note).to include("Matrix")
  end

  it "carries a public url through with no note" do
    cdn = Rubotty::Core::Attachment.new(
      kind: :photo, url: "https://cdn.discordapp.com/attachments/1/2/pic.png", filename: "pic.png"
    )
    receipt = adapter.deliver(message(place, text: "look", attachments: [cdn]), place)
    expect(client.sent_events.first[:content]["body"]).to include("https://cdn.discordapp.com/attachments/1/2/pic.png")
    expect(receipt.extra).to eq({})
  end
end
