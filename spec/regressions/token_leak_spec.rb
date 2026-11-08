# frozen_string_literal: true

require "spec_helper"

# A Telegram file URL embeds the bot token, so posting one into a Discord channel
# puts a working credential into that channel's history permanently. The leak was
# in the fallback taken when an upload fails, which happens on a network error, a
# Telegram CDN 5xx, a redirect problem, or any file over max_upload_bytes.
RSpec.describe "a Telegram file URL never reaches another platform" do
  TELEGRAM_FILE_URL = "https://api.telegram.org/file/bot123456789:AAHqwertyuiop-asdfghjkl/photos/f_1.jpg"

  let(:client) { DiscordFakes::Client.new }
  let(:hook) { DiscordFakes::WebhookClient.new }
  let(:channel) { client.channel("111") }

  # Every fetch fails, which is the condition that triggers the fallback.
  let(:failing_fetcher) { Rubotty::Util::MediaFetcher.new(http: ->(_uri, _name) { nil }) }

  def adapter_for(place)
    Rubotty::Adapters::Discord::Adapter.new(
      account: "dc", settings: { token: "t", token_env: "DC" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
      endpoints: [place]
    ).replace_client(client).tap do |adapter|
      adapter.start
      adapter.instance_variable_set(:@fetcher, failing_fetcher)
    end
  end

  def telegram_attachment
    Rubotty::Core::Attachment.new(kind: :photo, url: TELEGRAM_FILE_URL, filename: "f_1.jpg")
  end

  describe "posting as the bot" do
    let(:place) { endpoint("dc", adapter: :discord, settings: { channel_id: "111", webhook: :off }) }

    it "posts no part of the token when the upload fails" do
      outgoing = message(place, text: "look").with(
        sender_label: "Alex", attachments: [telegram_attachment]
      )
      adapter_for(place).deliver(outgoing, place)

      posted = channel.sent.map { |m| m[:content] }.join("\n")
      expect(posted).not_to include("/bot")
      expect(posted).not_to include("AAHqwertyuiop")
      expect(posted).not_to include("api.telegram.org")
    end

    it "still tells the reader something was attached" do
      outgoing = message(place, text: "look").with(
        sender_label: "Alex", attachments: [telegram_attachment]
      )
      adapter_for(place).deliver(outgoing, place)
      expect(channel.sent.first[:content]).to include("f_1.jpg")
    end

    # The same fallback is correct for Discord-sourced media, where the URL is a
    # public CDN link.
    it "still relays a public CDN link when the upload fails" do
      cdn = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://cdn.discordapp.com/attachments/1/2/pic.png", filename: "pic.png"
      )
      outgoing = message(place, text: "look").with(sender_label: "Alex", attachments: [cdn])
      adapter_for(place).deliver(outgoing, place)
      expect(channel.sent.first[:content]).to include("https://cdn.discordapp.com/attachments/1/2/pic.png")
    end
  end

  describe "posting through a webhook" do
    let(:place) { endpoint("dc", adapter: :discord, settings: { channel_id: "111", webhook: :auto }) }

    it "posts no part of the token when the upload fails" do
      adapter = adapter_for(place)
      allow(adapter.instance_variable_get(:@webhooks)).to receive(:for).and_return(hook)
      outgoing = message(place, text: "look").with(
        sender_label: "Alex", attachments: [telegram_attachment]
      )
      adapter.deliver(outgoing, place)

      posted = hook.executed.map { |e| e[:content] }.join("\n")
      expect(posted).not_to include("/bot")
      expect(posted).not_to include("AAHqwertyuiop")
    end
  end

  describe "avatars" do
    it "refuses a credentialed URL" do
      expect(Rubotty::Util::SafeUrl.public(TELEGRAM_FILE_URL)).to be_nil
    end

    it "allows a Discord CDN avatar" do
      url = "https://cdn.discordapp.com/avatars/1/a.png"
      expect(Rubotty::Util::SafeUrl.public(url)).to eq(url)
    end
  end
end

RSpec.describe Rubotty::Util::SafeUrl do
  describe ".credentialed?" do
    it "recognises a Telegram file URL" do
      expect(described_class.credentialed?("https://api.telegram.org/file/bot42:XYZ/a.jpg")).to be(true)
    end

    it "recognises one on the file host even if the token shape changes" do
      expect(described_class.credentialed?("https://api.telegram.org/file/whatever/a.jpg")).to be(true)
    end

    # A Discord attachment named bot.png has a path containing "/bot" and must
    # stay relayable.
    it "does not flag an ordinary file called bot.png" do
      expect(described_class.credentialed?("https://cdn.discordapp.com/attachments/1/2/bot.png")).to be(false)
    end

    it "does not flag an ordinary URL" do
      expect(described_class.credentialed?("https://example.com/robot/photo.jpg")).to be(false)
    end

    it "handles nil" do
      expect(described_class.credentialed?(nil)).to be(false)
    end
  end

  describe ".public" do
    it "returns nil for a credentialed url" do
      expect(described_class.public("https://api.telegram.org/file/bot42:XYZ/a.jpg")).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.public(nil)).to be_nil
    end

    # A blank url is not nil, so a caller's `public(url) || fallback` pattern
    # only reaches the fallback if this also treats blank as absent.
    it "returns nil for an empty string rather than handing the empty string back" do
      expect(described_class.public("")).to be_nil
    end

    it "returns nil for a whitespace only string" do
      expect(described_class.public("   ")).to be_nil
    end

    it "returns an ordinary url unchanged" do
      url = "https://cdn.discordapp.com/a.png"
      expect(described_class.public(url)).to eq(url)
    end
  end

  describe ".redact" do
    it "removes the token but keeps the shape" do
      redacted = described_class.redact("https://api.telegram.org/file/bot42:SECRET/a.jpg")
      expect(redacted).not_to include("SECRET")
      expect(redacted).to include("api.telegram.org")
    end

    it "leaves a safe URL alone" do
      url = "https://cdn.discordapp.com/a.png"
      expect(described_class.redact(url)).to eq(url)
    end
  end
end
