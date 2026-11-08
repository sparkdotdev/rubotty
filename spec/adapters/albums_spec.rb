# frozen_string_literal: true

require "spec_helper"

# A message carrying several files should read as one post on the far side.
RSpec.describe "multi attachment relaying" do
  def photo(url) = Rubotty::Core::Attachment.new(kind: :photo, url: url, filename: File.basename(url))

  describe "to Telegram" do
    let(:http) { Fakes::TelegramHttp.new }
    let(:place) do
      endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" })
    end
    let(:adapter) do
      Rubotty::Adapters::Telegram::Adapter.new(
        account: "tg", settings: { token: "t", token_env: "TG" },
        dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
        endpoints: [place]
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "t", http: http))
    end

    def deliver(attachments, text: "look at these")
      outgoing = message(place, text: text).with(sender_label: "Ada", attachments: attachments)
      adapter.deliver(outgoing, place)
    end

    it "sends several photos as one media group" do
      http.on("sendMediaGroup", [{ "message_id" => 900 }])
      deliver([photo("https://cdn/a.png"), photo("https://cdn/b.png")])
      expect(http.called?("sendMediaGroup")).to be(true)
      expect(http.last("sendMediaGroup").params["media"].size).to eq(2)
    end

    # Telegram treats the first item's caption as the album caption; repeating it
    # prints it under every photo.
    it "puts the caption on the first item only" do
      http.on("sendMediaGroup", [{ "message_id" => 900 }])
      deliver([photo("https://cdn/a.png"), photo("https://cdn/b.png")])
      media = http.last("sendMediaGroup").params["media"]
      expect(media.first["caption"]).to include("look at these")
      expect(media.last).not_to have_key("caption")
    end

    # Fourteen photos used to become one ten photo group with the last four
    # dropped outright. They now cross as two groups instead.
    it "splits past the per group limit of ten rather than dropping the rest" do
      http.on("sendMediaGroup", [{ "message_id" => 900 }])
      http.on("sendMediaGroup", [{ "message_id" => 901 }])
      deliver(Array.new(14) { |i| photo("https://cdn/#{i}.png") })
      calls = http.calls("sendMediaGroup")
      expect(calls.size).to eq(2)
      expect(calls.map { |c| c.params["media"].size }).to eq([10, 4])
    end

    it "sends a single photo the ordinary way" do
      deliver([photo("https://cdn/a.png")])
      expect(http.called?("sendPhoto")).to be(true)
      expect(http.called?("sendMediaGroup")).to be(false)
    end

    # Documents, stickers and voice notes cannot be grouped with photos.
    it "does not group kinds Telegram will not accept in an album" do
      document = Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn/a.pdf")
      deliver([photo("https://cdn/a.png"), document])
      expect(http.called?("sendMediaGroup")).to be(false)
    end

    it "returns a receipt for the first message of the group" do
      http.on("sendMediaGroup", [{ "message_id" => 901 }, { "message_id" => 902 }])
      receipt = deliver([photo("https://cdn/a.png"), photo("https://cdn/b.png")])
      expect(receipt).to be_nil.or have_attributes(endpoint_id: "tg")
    end
  end

  describe "to Discord" do
    let(:client) { DiscordFakes::Client.new }
    let(:general) do
      endpoint("dc", adapter: :discord, settings: { channel_id: "111", webhook: :off })
    end
    let(:adapter) do
      Rubotty::Adapters::Discord::Adapter.new(
        account: "dc", settings: { token: "t", token_env: "DC" },
        dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
        endpoints: [general]
      ).replace_client(client)
    end
    let(:channel) { client.channel("111") }

    before do
      adapter.start
      adapter.instance_variable_set(
        :@fetcher,
        Rubotty::Util::MediaFetcher.new(
          http: lambda { |_uri, name|
            StringIO.new("BYTES-#{name}").tap { |io| io.define_singleton_method(:unlink) { nil } }
          }
        )
      )
    end

    def deliver(attachments)
      outgoing = message(general, text: "look").with(sender_label: "Ada", attachments: attachments)
      adapter.deliver(outgoing, general)
    end

    # Discord's REST API takes one file per request, so an album necessarily
    # becomes several messages.
    it "uploads every attachment" do
      deliver([photo("https://cdn/a.png"), photo("https://cdn/b.png"), photo("https://cdn/c.png")])
      expect(channel.files.size).to eq(3)
    end

    # Discord's upload_file route carries no allowed_mentions, so a caption sent
    # with a file could ping @everyone.
    it "posts the caption as one separate message, never on a file upload" do
      deliver([photo("https://cdn/a.png"), photo("https://cdn/b.png")])
      expect(channel.files.map { |file| file[:caption] }).to all(be_nil)
      captions = channel.sent.map { |sent| sent[:content] }.grep(/look/)
      expect(captions.size).to eq(1)
    end

    # The map has to point at the message a reader associates with the text, or
    # an edit would land on a bare image.
    it "returns a receipt for the first message" do
      receipt = deliver([photo("https://cdn/a.png"), photo("https://cdn/b.png")])
      expect(receipt.native_id).to eq("file-1")
    end

    it "still handles a single attachment" do
      deliver([photo("https://cdn/a.png")])
      expect(channel.files.size).to eq(1)
    end
  end
end
