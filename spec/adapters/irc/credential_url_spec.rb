# frozen_string_literal: true

require "spec_helper"

# A Telegram file URL embeds the bot token, so Util::SafeUrl blocks it and
# Outbound#attachment_links falls back to a marker. Nothing told the sender
# that happened: the receipt carried no notes, so Features::Bridge#report_notes
# had nothing to relay back, unlike Discord's note_failed_upload.
RSpec.describe Rubotty::Adapters::Irc::Adapter do
  let(:telegram_file_url) { "https://api.telegram.org/file/bot123456789:AAHqwertyuiop-asdfghjkl/photos/f_1.jpg" }

  let(:client) { IrcFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:place) { endpoint("irc-general", adapter: :irc, settings: { channel: "#general" }) }

  subject(:adapter) do
    described_class.new(
      account: "irc", settings: { server: "irc.example.org", nick: "rubotty", tls: true },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [place]
    ).replace_client(client)
  end

  def telegram_attachment
    Rubotty::Core::Attachment.new(kind: :photo, url: telegram_file_url, filename: "f_1.jpg")
  end

  it "posts no part of the token" do
    adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    expect(client.messages.first[:text]).not_to include("AAHqwertyuiop")
  end

  it "still names the file in the channel, as the could-not-relay marker" do
    adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    expect(client.messages.first[:text]).to include("f_1.jpg, could not be relayed")
  end

  it "tells the sender the file did not cross" do
    receipt = adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    note = receipt.extra[:notes].first
    expect(note).to include("f_1.jpg")
    expect(note).to include("IRC")
  end

  it "carries a public url through with no note" do
    cdn = Rubotty::Core::Attachment.new(
      kind: :photo, url: "https://cdn.discordapp.com/attachments/1/2/pic.png", filename: "pic.png"
    )
    receipt = adapter.deliver(message(place, text: "look", attachments: [cdn]), place)
    expect(client.messages.first[:text]).to include("https://cdn.discordapp.com/attachments/1/2/pic.png")
    expect(receipt.extra).to eq({})
  end
end
