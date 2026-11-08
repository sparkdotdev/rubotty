# frozen_string_literal: true

require "spec_helper"

# Behavioural regressions against TediCross 0.12.3.
RSpec.describe "parity with the retired bridge" do
  describe "Discord server nicknames win over global display names" do
    let(:inbound) do
      Rubotty::Adapters::Discord::Inbound.new(
        endpoint_for: ->(_id) { endpoint("dc", adapter: :discord) }
      )
    end
    let(:channel) { DiscordFakes::Channel.new(id: "1") }

    def author_for(**user_fields)
      user = DiscordFakes.user(**user_fields)
      event = DiscordFakes::MessageEvent.new(
        message: DiscordFakes::Message.new(id: "1", content: "hi", author: user),
        channel: channel
      )
      inbound.message(event).author
    end

    # discord.js's member.displayName is nickname ?? globalName ?? username, and
    # TediCross ran useNickname: true.
    it "shows the guild nickname when there is one" do
      expect(author_for(username: "mattsz", global_name: "Alex S", nick: "Alex in SAMPLE").any_name)
        .to eq("Alex in SAMPLE")
    end

    it "falls back to the global display name" do
      expect(author_for(username: "mattsz", global_name: "Alex S").any_name).to eq("Alex S")
    end

    it "falls back to the username" do
      expect(author_for(username: "mattsz").any_name).to eq("mattsz")
    end

    it "still exposes the raw nickname for a template that wants it" do
      expect(author_for(username: "mattsz", global_name: "Alex S", nick: "Alex in SAMPLE").nickname)
        .to eq("Alex in SAMPLE")
    end
  end

  describe "Telegram locations" do
    let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" }) }
    let(:inbound) do
      Rubotty::Adapters::Telegram::Inbound.new(endpoint_for: ->(_chat, _thread) { place })
    end

    def parse(payload)
      inbound.call(
        "update_id" => 1,
        "message" => {
          "message_id" => 1, "date" => 1_700_000_000,
          "chat" => { "id" => -100_111 },
          "from" => { "id" => 55, "first_name" => "Alex" }
        }.merge(payload)
      )
    end

    # Without this the message has no text and no attachment, so the router
    # correctly discards it as empty and the location silently never arrives.
    it "relays a location as a maps link" do
      message = parse("location" => { "latitude" => 51.5074, "longitude" => -0.1278 })
      expect(message.body.text).to include("51.5074,-0.1278")
      expect(message.body.text).to start_with("https://www.google.com/maps/")
    end

    it "is not discarded as an empty message" do
      message = parse("location" => { "latitude" => 1.0, "longitude" => 2.0 })
      expect(message).not_to be_empty
    end

    it "includes the name and address of a venue" do
      message = parse(
        "venue" => {
          "location" => { "latitude" => 51.5, "longitude" => -0.1 },
          "title" => "The Pub", "address" => "1 High Street"
        }
      )
      expect(message.body.text).to include("The Pub")
      expect(message.body.text).to include("1 High Street")
      expect(message.body.text).to include("maps")
    end

    it "leaves an ordinary text message alone" do
      expect(parse("text" => "hello").body.text).to eq("hello")
    end
  end

  describe "animated stickers" do
    let(:place) { endpoint("tg", adapter: :telegram, settings: { chat_id: "-100111" }) }
    let(:inbound) do
      Rubotty::Adapters::Telegram::Inbound.new(
        endpoint_for: ->(_chat, _thread) { place },
        file_resolver: ->(id) { "https://example.test/#{id}" }
      )
    end

    def sticker(**fields)
      inbound.call(
        "update_id" => 1,
        "message" => {
          "message_id" => 1, "date" => 1_700_000_000,
          "chat" => { "id" => -100_111 },
          "from" => { "id" => 55, "first_name" => "Alex" },
          "sticker" => fields
        }
      ).attachments.first
    end

    # A .tgs is gzipped Lottie JSON, which renders only in a Telegram client, so
    # the static thumbnail is the only thing a reader elsewhere can see.
    it "sends the static thumbnail for an animated sticker" do
      attachment = sticker(
        "file_id" => "anim", "is_animated" => true,
        "thumbnail" => { "file_id" => "thumb" }
      )
      expect(attachment.native_ref).to eq("thumb")
    end

    it "handles the older thumb spelling" do
      attachment = sticker(
        "file_id" => "anim", "is_animated" => true, "thumb" => { "file_id" => "thumb" }
      )
      expect(attachment.native_ref).to eq("thumb")
    end

    # A video sticker is a .webm Discord plays inline, so the real file crosses,
    # named .webm so Discord treats it as a video rather than an unknown download.
    it "sends the video sticker itself, named so Discord plays it" do
      attachment = sticker(
        "file_id" => "vid", "is_video" => true, "thumbnail" => { "file_id" => "thumb" }
      )
      expect(attachment.native_ref).to eq("vid")
      expect(attachment.filename).to eq("sticker.webm")
    end

    # Telegram can flag a sticker both ways; the format that actually renders on
    # Discord wins, so a video sticker is never downgraded to its thumbnail.
    it "prefers the video file when a sticker is flagged animated and video" do
      attachment = sticker(
        "file_id" => "vid", "is_animated" => true, "is_video" => true,
        "thumbnail" => { "file_id" => "thumb" }
      )
      expect(attachment.native_ref).to eq("vid")
      expect(attachment.filename).to eq("sticker.webm")
    end

    # An animated .tgs keeps falling back to its thumbnail: nothing outside
    # Telegram renders Lottie and there is no converter.
    it "still sends the thumbnail for an animated (non video) sticker" do
      attachment = sticker(
        "file_id" => "anim", "is_animated" => true,
        "thumbnail" => { "file_id" => "thumb" }
      )
      expect(attachment.native_ref).to eq("thumb")
    end

    it "sends the sticker itself when it is a static one" do
      expect(sticker("file_id" => "static").native_ref).to eq("static")
    end

    # Better an unopenable file than no file at all.
    it "falls back to the sticker when there is no thumbnail" do
      expect(sticker("file_id" => "anim", "is_animated" => true).native_ref).to eq("anim")
    end
  end

  # discordrb expands MESSAGE_DELETE_BULK into one MessageDeleteEvent per id, so
  # the existing message_delete handler covers it with no separate registration.
  # Pinned because a library upgrade could change it.
  describe "Discord bulk deletes" do
    let(:place) { endpoint("dc", adapter: :discord, settings: { channel_id: "1" }) }
    let(:inbound) do
      Rubotty::Adapters::Discord::Inbound.new(endpoint_for: ->(_id) { place })
    end
    let(:channel) { DiscordFakes::Channel.new(id: "1") }

    it "handles each id of a bulk delete as an ordinary delete" do
      events = %w[10 11 12].map { |id| DiscordFakes::DeleteEvent.new(id: id, channel: channel) }
      produced = events.map { |event| inbound.delete(event) }
      expect(produced.map(&:kind)).to eq(%i[delete delete delete])
      expect(produced.map { |m| m.ref.native_id }).to eq(%w[10 11 12])
    end
  end

  describe "a file that could not be relayed" do
    let(:client) { DiscordFakes::Client.new }
    let(:place) do
      endpoint("dc", adapter: :discord, settings: { channel_id: "1", webhook: :off })
    end
    let(:adapter) do
      Rubotty::Adapters::Discord::Adapter.new(
        account: "dc", settings: { token: "t", token_env: "DC", max_upload_bytes: 1024 },
        dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null,
        endpoints: [place]
      ).replace_client(client).tap do |a|
        a.start
        a.instance_variable_set(
          :@fetcher, Rubotty::Util::MediaFetcher.new(http: ->(_uri, _n) { nil })
        )
      end
    end

    # Silence is the worst outcome: the sender believes the file crossed.
    it "puts a note on the receipt saying why" do
      attachment = Rubotty::Core::Attachment.new(
        kind: :document, url: "https://cdn.discordapp.com/a.zip", filename: "big.zip",
        size: 50 * 1024 * 1024
      )
      outgoing = message(place, text: "here").with(sender_label: "Alex", attachments: [attachment])
      receipt = adapter.deliver(outgoing, place)

      expect(receipt.extra[:notes].join).to include("big.zip")
      expect(receipt.extra[:notes].join).to include("limit")
    end

    it "says the upload failed when the size is not the reason" do
      attachment = Rubotty::Core::Attachment.new(
        kind: :document, url: "https://cdn.discordapp.com/a.zip", filename: "small.zip"
      )
      outgoing = message(place, text: "here").with(sender_label: "Alex", attachments: [attachment])
      expect(adapter.deliver(outgoing, place).extra[:notes].join).to include("upload failed")
    end

    it "leaves no note when everything went through" do
      outgoing = message(place, text: "just text").with(sender_label: "Alex")
      expect(adapter.deliver(outgoing, place).extra[:notes]).to be_empty
    end
  end
end

RSpec.describe "the sender is told when part of a message did not cross" do
  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc") }
  let(:storage) { Rubotty::Storage::Memory.new }

  # An adapter that always reports a note, so the router path is what is tested.
  let(:noting) do
    Class.new(Fakes::RecordingAdapter) do
      def deliver(message, endpoint)
        receipt = super
        return receipt if message.system_notice?

        Rubotty::Core::DeliveryReceipt.new(
          endpoint_id: receipt.endpoint_id, native_id: receipt.native_id,
          extra: { notes: ["could not relay big.zip to Discord: it is 50MB, over the 25MB limit"] }
        )
      end
    end.new
  end

  def route(suppress: false)
    Rubotty::Core::Router.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(noting), storage: storage,
      loop_guard: Rubotty::Core::LoopGuard.new(storage: storage),
      logger: Rubotty::Log.null, suppress_notices: suppress
    ).handle(message(tg, text: "here is a file"))
  end

  it "posts the reason back to the endpoint the message came from" do
    route
    notice = noting.delivered.find { |(id, m)| id == "tg" && m.system_notice? }
    expect(notice).not_to be_nil
    expect(notice.last.body.text).to include("over the 25MB limit")
  end

  it "attaches the notice to the offending message" do
    route
    notice = noting.delivered.find { |(id, m)| id == "tg" && m.system_notice? }
    expect(notice.last.reply_to).to eq(ref("tg", "1"))
  end

  it "can be suppressed, matching suppressFileTooBigMessages" do
    route(suppress: true)
    expect(noting.delivered.any? { |(id, m)| id == "tg" && m.system_notice? }).to be(false)
  end
end
