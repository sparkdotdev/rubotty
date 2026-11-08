# frozen_string_literal: true

require "spec_helper"

# A Telegram file URL embeds the bot token, so Util::SafeUrl blocks it,
# and Outbound#attachment_links used to fall back to a marker with the
# sender never told, unlike Discord's note_failed_upload. XEP-0363 upload
# now gives a credentialed attachment a real hosted url instead.
RSpec.describe Rubotty::Adapters::Xmpp::Adapter do
  let(:telegram_file_url) { "https://api.telegram.org/file/bot123456789:AAHqwertyuiop-asdfghjkl/photos/f_1.jpg" }

  let(:client) { XmppFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:place) { endpoint("xmpp-general", adapter: :xmpp, settings: { room_jid: "room@conference.example.org" }) }

  subject(:adapter) do
    described_class.new(
      account: "xm", settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
      dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [place]
    ).replace_client(client)
  end

  def telegram_attachment
    Rubotty::Core::Attachment.new(kind: :photo, url: telegram_file_url, filename: "f_1.jpg")
  end

  # Kept off the network: the fetch itself is real code (Util::MediaFetcher),
  # only the transport underneath it is swapped out, the same seam
  # spec/adapters/matrix/adapter_spec.rb stubs for its own media specs.
  before do
    fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { fake_file("JPEGDATA") })
    adapter.instance_variable_set(:@fetcher, fetcher)
  end

  def fake_file(bytes)
    StringIO.new(bytes).tap { |io| io.define_singleton_method(:unlink) { nil } }
  end

  it "posts no part of the token" do
    adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    expect(client.said.first[:body]).not_to include("AAHqwertyuiop")
  end

  it "still names the file in the room, as the could-not-relay marker, with no upload service configured" do
    adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    expect(client.said.first[:body]).to include("f_1.jpg, could not be relayed")
  end

  it "tells the sender the file did not cross" do
    receipt = adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)
    note = receipt.extra[:notes].first
    expect(note).to include("f_1.jpg")
    expect(note).to include("XMPP")
  end

  it "posts the XEP-0363 hosted url instead of the marker once the upload succeeds" do
    allow(client).to receive(:upload).and_return("https://upload.example.org/abc/f_1.jpg")

    receipt = adapter.deliver(message(place, text: "look", attachments: [telegram_attachment]), place)

    expect(client.said.first[:body]).to include("https://upload.example.org/abc/f_1.jpg")
    expect(client.said.first[:body]).not_to include("could not be relayed")
    expect(client.said.first[:body]).not_to include("AAHqwertyuiop")
    expect(receipt.extra).to eq({})
  end

  it "carries a public url through with no note, fetching and uploading nothing" do
    cdn = Rubotty::Core::Attachment.new(
      kind: :photo, url: "https://cdn.discordapp.com/attachments/1/2/pic.png", filename: "pic.png"
    )
    expect(client).not_to receive(:upload)

    receipt = adapter.deliver(message(place, text: "look", attachments: [cdn]), place)

    expect(client.said.first[:body]).to include("https://cdn.discordapp.com/attachments/1/2/pic.png")
    expect(receipt.extra).to eq({})
  end
end
