# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Rubotty::Adapters::Telegram::Adapter do
  let(:http) { Fakes::TelegramHttp.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }
  let(:general) do
    endpoint("tg-general", adapter: :telegram, settings: { chat_id: "-1008000000001", thread_id: 142_483 })
  end
  let(:lobby) do
    endpoint("tg-lobby", adapter: :telegram, settings: { chat_id: "-1008000000001" })
  end

  subject(:adapter) do
    described_class.new(
      account: "tg",
      settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general, lobby]
    ).replace_client(
      Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http)
    )
  end

  # The operator alert names where a flagged message is, so a supergroup
  # link is the difference between a report and a search.
  describe "#message_permalink" do
    it "drops the supergroup prefix and threads the forum topic between" do
      expect(adapter.message_permalink(general, "9001"))
        .to eq("https://t.me/c/8000000001/142483/9001")
    end

    it "leaves the topic out for a supergroup that has none" do
      expect(adapter.message_permalink(lobby, "9001")).to eq("https://t.me/c/8000000001/9001")
    end

    it "answers nothing for a chat t.me publishes no history for" do
      basic = endpoint("tg-basic", adapter: :telegram, settings: { chat_id: "-4155" })
      private_chat = endpoint("tg-dm", adapter: :telegram, settings: { chat_id: "80000012" })

      expect(adapter.message_permalink(basic, "9001")).to be_nil
      expect(adapter.message_permalink(private_chat, "9001")).to be_nil
    end

    it "answers nothing without a message to point at" do
      expect(adapter.message_permalink(general, "")).to be_nil
    end
  end

  # A notice that names another room is somewhere the reader has to go and
  # find unless the name can be tapped.
  describe "#room_permalink" do
    it "points at the forum topic itself, with no message on the end" do
      expect(adapter.room_permalink(general)).to eq("https://t.me/c/8000000001/142483")
    end

    it "points at the whole supergroup when the endpoint has no topic" do
      expect(adapter.room_permalink(lobby)).to eq("https://t.me/c/8000000001")
    end

    it "answers nothing for a chat t.me publishes no history for" do
      basic = endpoint("tg-basic", adapter: :telegram, settings: { chat_id: "-4155" })

      expect(adapter.room_permalink(basic)).to be_nil
    end
  end

  def update(overrides = {})
    {
      "update_id" => 1,
      "message" => {
        "message_id" => 100,
        "date" => 1_700_000_000,
        "chat" => { "id" => -1008000000001, "type" => "supergroup", "is_forum" => true },
        "message_thread_id" => 142_483,
        "from" => { "id" => 55, "first_name" => "Ada", "username" => "ada", "is_bot" => false },
        "text" => "hello"
      }.merge(overrides)
    }
  end

  describe "identity and capabilities" do
    it "learns its own account id at start, which loop prevention depends on" do
      http.on("getMe", { "id" => 999, "username" => "bridgebot" })
      http.on("deleteWebhook", true)
      http.on("getUpdates", [])
      adapter.start
      expect(adapter.own_account_id).to eq("999")
      adapter.stop
    end

    it "refuses to start when the token is rejected, rather than looping silently" do
      http.error_on("getMe", code: 401, description: "Unauthorized")
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /could not authenticate/)
    end

    # The Bot API cannot read a chat's history and no library changes that, so
    # this has to stay a refusal. Answering yes and returning nothing would make
    # the history sweep report a clean run over messages it never saw.
    it "refuses backfill outright rather than reporting an empty success" do
      expect(adapter.supports_backfill?).to be(false)
      expect(adapter.supports_reaction_backfill?).to be(false)
    end

    # Threading on Telegram exists only as forum topics, so a topic-pinned
    # endpoint can address a thread and an ordinary chat cannot.
    it "reports threads only for an endpoint pinned to a forum topic" do
      expect(adapter.capabilities_for(general).threads?).to be(true)
      expect(adapter.capabilities_for(lobby).threads?).to be(false)
    end

    # One account is one bot token, so a missing one means "not yet connected"
    # rather than a fatal boot error.
    it "opts into graceful dormancy when its token is absent" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end

    # The cloud Bot API server's own download ceiling, both on the account this
    # adapter was built with (no api_base given) and read straight off settings
    # with no live adapter at all, the shape the dashboard uses.
    it "fetches at the cloud ceiling when api_base is unset" do
      expect(adapter.capabilities.max_fetch_bytes).to eq(described_class::MAX_BOT_DOWNLOAD_BYTES)
      expect(described_class.max_fetch_bytes_for({})).to eq(described_class::MAX_BOT_DOWNLOAD_BYTES)
    end

    # A deployment pointed at a self hosted Bot API server gets the ceiling it
    # paid for instead of being throttled to the cloud figure (#1771).
    it "fetches at the self hosted ceiling once api_base points away from the cloud default" do
      settings = { api_base: "https://bot-api.example.internal" }
      self_hosted = described_class.new(
        account: "tg", settings: settings, dispatcher: dispatcher, logger: Rubotty::Log.null
      )

      expect(self_hosted.capabilities.max_fetch_bytes).to eq(described_class::SELF_HOSTED_MAX_DOWNLOAD_BYTES)
      expect(described_class.max_fetch_bytes_for(settings)).to eq(described_class::SELF_HOSTED_MAX_DOWNLOAD_BYTES)
    end

    it "treats the cloud default url the same as unset" do
      settings = { api_base: Rubotty::Adapters::Telegram::ApiClient::DEFAULT_BASE }

      expect(described_class.max_fetch_bytes_for(settings)).to eq(described_class::MAX_BOT_DOWNLOAD_BYTES)
    end
  end

  # What gets published is Commands' own business; what matters here is that a
  # start publishes it at the right moment and a refusal cannot stop the boot.
  describe "publishing the command menu at start" do
    def boot(adapter)
      http.on("getMe", { "id" => 999, "username" => "bridgebot" })
      http.on("deleteWebhook", true)
      http.on("getUpdates", [])
      adapter.start
      adapter.stop
    end

    # Three scopes: everyone, private chats where the operator console answers,
    # and group administrators. None of them merge, so each is its own call.
    it "publishes the command list once the token is known good" do
      boot(adapter)
      expect(http.calls("setMyCommands").size).to eq(3)
    end

    it "publishes only after getMe, so a bad token never writes to the bot's menu" do
      http.error_on("getMe", code: 401, description: "Unauthorized")
      expect { adapter.start }.to raise_error(Rubotty::AdapterError)
      expect(http.called?("setMyCommands")).to be(false)
    end

    it "still starts when Telegram refuses the list, because the menu is cosmetic" do
      http.on("getMe", { "id" => 999, "username" => "bridgebot" })
      http.error_on("setMyCommands", code: 400, description: "Bad Request: BOT_COMMAND_INVALID")
      http.error_on("setMyCommands", code: 400, description: "Bad Request: BOT_COMMAND_INVALID")
      http.on("deleteWebhook", true)
      http.on("getUpdates", [])
      expect { adapter.start }.not_to raise_error
      expect(adapter.own_account_id).to eq("999")
      adapter.stop
    end

    # A bot's menu is global to its token, so it reaches every chat that token
    # serves, bridged by this deployment or not.
    it "publishes nothing when the account has opted out of owning the menu" do
      opted_out = described_class.new(
        account: "tg",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN",
                    register_commands: false },
        dispatcher: dispatcher,
        logger: Rubotty::Log.null,
        endpoints: [general, lobby]
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
      boot(opted_out)
      expect(http.called?("setMyCommands")).to be(false)
    end

    it "declares the setting in the account schema, so `rubotty schema` documents it" do
      field = described_class.account_schema.fields[:register_commands]
      expect(field).not_to be_nil
      expect(field.default).to be(true)
    end
  end

  describe "inbound" do
    it "converts a text message into a canonical message on the right endpoint" do
      adapter.handle_update(update)
      message = dispatcher.last
      expect(message.origin.id).to eq("tg-general")
      expect(message.body.text).to eq("hello")
      expect(message.author.username).to eq("ada")
      expect(message.ref.native_id).to eq("100")
    end

    it "routes a message with no thread id to the whole chat endpoint" do
      adapter.handle_update(update("message_thread_id" => nil))
      expect(dispatcher.last.origin.id).to eq("tg-lobby")
    end

    it "ignores a chat it has no endpoint for" do
      adapter.handle_update(update("chat" => { "id" => -1, "type" => "group" }))
      expect(dispatcher.messages).to be_empty
    end

    it "carries formatting across, with correct offsets past an emoji" do
      adapter.handle_update(update(
                              "text" => "🎉 party time",
                              "entities" => [{ "type" => "bold", "offset" => 3, "length" => 5 }]
                            ))
      body = dispatcher.last.body
      span = body.spans.first
      expect(body.text[span.begin_index...span.end_index]).to eq("party")
    end

    it "marks an edited message as an edit" do
      adapter.handle_update({ "update_id" => 2, "edited_message" => update["message"] })
      expect(dispatcher.last.kind).to eq(:edit)
    end

    it "recognises a join" do
      adapter.handle_update(update(
                              "text" => nil,
                              "new_chat_members" => [{ "id" => 7, "first_name" => "Bob" }]
                            ))
      expect(dispatcher.last.kind).to eq(:join)
      expect(dispatcher.last.author.first_name).to eq("Bob")
    end

    it "recognises a leave" do
      adapter.handle_update(update("text" => nil, "left_chat_member" => { "id" => 7, "first_name" => "Bob" }))
      expect(dispatcher.last.kind).to eq(:leave)
    end

    it "treats a channel post as authored by the channel, with no username" do
      adapter.handle_update(update(
                              "from" => nil,
                              "chat" => { "id" => -1008000000001, "title" => "Announcements" }
                            ))
      author = dispatcher.last.author
      expect(author.kind).to eq(:channel)
      expect(author.display_name).to eq("Announcements")
      # The absence must be nil, or the display name template renders empty parentheses.
      expect(author.username).to be_nil
      expect(author.first_name).to be_nil
    end

    it "records a reply pointer" do
      adapter.handle_update(update("reply_to_message" => { "message_id" => 90 }))
      expect(dispatcher.last.reply_to).to eq(ref("tg-general", "90"))
    end

    it "ignores the forum topic opener that Telegram reports as a reply target" do
      adapter.handle_update(update("reply_to_message" => { "message_id" => 142_483 }))
      expect(dispatcher.last.reply_to).to be_nil
    end

    # Telegram addresses a topic by message_thread_id and does not repeat its
    # name per message, so the name is left unknown here.
    it "captures the forum topic a message lives in" do
      adapter.handle_update(update)
      thread = dispatcher.last.thread
      expect(thread.native_id).to eq("142483")
      expect(thread).not_to be_named
    end

    it "carries no thread for a message outside any topic" do
      adapter.handle_update(update("message_thread_id" => nil))
      expect(dispatcher.last.thread).to be_nil
    end

    it "captures a photo as an attachment and resolves its URL" do
      http.on("getFile", { "file_path" => "photos/a.jpg" })
      adapter.handle_update(update(
                              "text" => nil,
                              "caption" => "look",
                              "photo" => [{ "file_id" => "small" }, { "file_id" => "large" }]
                            ))
      attachment = dispatcher.last.attachments.first
      expect(attachment.kind).to eq(:photo)
      # The largest size, which is the last entry.
      expect(attachment.native_ref).to eq("large")
      expect(attachment.url).to include("photos/a.jpg")
      expect(dispatcher.last.body.text).to eq("look")
    end

    it "records who a message was forwarded from" do
      adapter.handle_update(update(
                              "forward_origin" => {
                                "type" => "user",
                                "sender_user" => { "id" => 8, "first_name" => "Grace", "username" => "grace" }
                              }
                            ))
      expect(dispatcher.last.forwarded_from.username).to eq("grace")
    end
  end

  # Telegram carries a forum topic's name only on the forum_topic_created and
  # forum_topic_edited service messages, so the adapter learns it there and
  # stamps it onto later messages.
  describe "learning forum topic names (#40)" do
    before { adapter.storage = Rubotty::Storage::Memory.new }

    def topic_service(field, name, message_id: 142_483)
      {
        "update_id" => 2,
        "message" => {
          "message_id" => message_id, "date" => 1_700_000_000,
          "chat" => { "id" => -1008000000001, "type" => "supergroup" },
          "message_thread_id" => 142_483,
          field => { "name" => name }
        }
      }
    end

    it "names a later message in the topic from the topic-created service message" do
      adapter.handle_update(topic_service("forum_topic_created", "release chat"))
      adapter.handle_update(update)
      thread = dispatcher.last.thread
      expect(thread).to be_named
      expect(thread.name).to eq("release chat")
    end

    it "leaves the thread unnamed when the topic name was never learned" do
      adapter.handle_update(update)
      expect(dispatcher.last.thread).not_to be_named
    end

    it "updates the name when the topic is renamed" do
      adapter.handle_update(topic_service("forum_topic_created", "release chat"))
      adapter.handle_update(topic_service("forum_topic_edited", "release war room", message_id: 900))
      adapter.handle_update(update)
      expect(dispatcher.last.thread.name).to eq("release war room")
    end

    it "keeps the known name through an icon-only edit that carries no name" do
      adapter.handle_update(topic_service("forum_topic_created", "release chat"))
      icon_only = {
        "update_id" => 4,
        "message" => {
          "message_id" => 901, "date" => 1_700_000_002,
          "chat" => { "id" => -1008000000001, "type" => "supergroup" },
          "message_thread_id" => 142_483,
          "forum_topic_edited" => { "icon_custom_emoji_id" => "5312536423851630001" }
        }
      }
      adapter.handle_update(icon_only)
      adapter.handle_update(update)
      expect(dispatcher.last.thread.name).to eq("release chat")
    end

    it "stays dormant with no durable store wired, leaving the thread unnamed" do
      adapter.storage = nil
      adapter.handle_update(topic_service("forum_topic_created", "release chat"))
      adapter.handle_update(update)
      expect(dispatcher.last.thread).not_to be_named
    end
  end

  describe "outbound" do
    let(:outgoing) do
      message(general, text: "hello").with(sender_label: "Ada (ada)")
    end

    it "sends the composed message and returns a receipt" do
      http.on("sendMessage", { "message_id" => 501, "chat" => { "id" => -1008000000001 } })
      receipt = adapter.deliver(outgoing, general)
      call = http.last("sendMessage")
      expect(call.params["chat_id"]).to eq("-1008000000001")
      expect(call.params["message_thread_id"]).to eq(142_483)
      expect(call.params["parse_mode"]).to eq("HTML")
      expect(receipt.native_id).to eq("501")
    end

    it "prepends the sender name, since a bot cannot post under another name" do
      adapter.deliver(outgoing, general)
      expect(http.last("sendMessage").params["text"]).to start_with("<b>Ada (ada)</b>:\n")
    end

    it "escapes HTML in the sender name and the body" do
      hostile = message(general, text: "a < b").with(sender_label: "<script>")
      adapter.deliver(hostile, general)
      text = http.last("sendMessage").params["text"]
      expect(text).to include("&lt;script&gt;")
      expect(text).to include("a &lt; b")
    end

    it "attaches a native reply only when the parent lives on this endpoint" do
      local = outgoing.with(reply_to: ref("tg-general", "90"))
      adapter.deliver(local, general)
      expect(http.last("sendMessage").params["reply_to_message_id"]).to eq(90)
    end

    it "does not attach a reply id belonging to another endpoint" do
      foreign = outgoing.with(reply_to: ref("dc-general", "1234567890"))
      adapter.deliver(foreign, general)
      expect(http.last("sendMessage").params["reply_to_message_id"]).to be_nil
    end

    it "sends a photo by URL rather than downloading and re uploading it" do
      attachment = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png")
      adapter.deliver(outgoing.with(attachments: [attachment]), general)
      expect(http.called?("sendPhoto")).to be(true)
      expect(http.last("sendPhoto").params["photo"]).to eq("https://cdn.example/a.png")
      expect(http.last("sendPhoto").params["caption"]).to include("Ada (ada)")
    end

    it "does not send a caption with a sticker, which Telegram rejects" do
      attachment = Rubotty::Core::Attachment.new(kind: :sticker, native_ref: "CAAC")
      adapter.deliver(outgoing.with(attachments: [attachment]), general)
      expect(http.last("sendSticker").params).not_to have_key("caption")
    end

    # A blank url is not nil, so `url || native_ref` let it through as a
    # source and Telegram rejected the empty string with a 400.
    it "falls back to plain text rather than sending a blank photo url" do
      attachment = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "a.png")
      adapter.deliver(outgoing.with(attachments: [attachment]), general)
      expect(http.called?("sendPhoto")).to be(false)
      expect(http.called?("sendMessage")).to be(true)
    end

    # The lead attachment degrades to plain text; a later one in the same send
    # degrades to a reference line instead, once the lead call already crossed.
    it "notes a later attachment that had a blank url, rather than posting an empty caption" do
      good = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png")
      blank = Rubotty::Core::Attachment.new(kind: :photo, url: "", filename: "b.png")
      adapter.deliver(outgoing.with(attachments: [good, blank]), general)
      texts = http.calls("sendMessage").map { |call| call.params["text"] }
      expect(texts).to include(a_string_including("[b.png, could not be relayed]"))
    end

    # A relay's whole job is not losing what it carries; these three cover the
    # ways the same message can arrive with more than one attachment.
    describe "a message with more than one attachment" do
      it "sends every document rather than only the first of three" do
        http.on("sendDocument", { "message_id" => 601 })
        http.on("sendDocument", { "message_id" => 602 })
        http.on("sendDocument", { "message_id" => 603 })
        docs = %w[a.pdf b.pdf c.pdf].map do |name|
          Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn.example/#{name}", filename: name)
        end

        receipt = adapter.deliver(outgoing.with(attachments: docs), general)

        expect(http.calls("sendDocument").map { |c| c.params["document"] }).to eq(docs.map(&:url))
        expect(receipt.extra[:group_ids]).to eq(%w[601 602 603])
      end

      it "sends both a photo and a document rather than dropping the document, a mixed pair" do
        http.on("sendPhoto", { "message_id" => 701 })
        http.on("sendDocument", { "message_id" => 702 })
        photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/shot.png")
        doc = Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn.example/notes.pdf", filename: "notes.pdf")

        adapter.deliver(outgoing.with(attachments: [photo, doc]), general)

        expect(http.called?("sendPhoto")).to be(true)
        expect(http.last("sendDocument").params["document"]).to eq("https://cdn.example/notes.pdf")
      end

      it "does not lose the last two photos of a twelve photo album, splitting past the album maximum" do
        http.on("sendMediaGroup", (801..810).map { |id| { "message_id" => id } })
        http.on("sendMediaGroup", (811..812).map { |id| { "message_id" => id } })
        photos = (1..12).map { |n| Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/p#{n}.png") }

        receipt = adapter.deliver(outgoing.with(attachments: photos), general)

        expect(http.calls("sendMediaGroup").size).to eq(2)
        expect(http.calls("sendMediaGroup").sum { |c| c.params["media"].size }).to eq(12)
        expect(receipt.extra[:group_ids].size).to eq(12)
      end

      # Before the fix, a failure on any call but the first propagated straight
      # out of #deliver, past the files that had already posted. The bridge's
      # retry policy wraps the whole of #deliver, so that raise sent the retry
      # back to the top and resent the earlier files a second time.
      describe "when one call in the middle fails" do
        def three_documents
          %w[a.pdf b.pdf c.pdf].map do |name|
            Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn.example/#{name}", filename: name)
          end
        end

        it "does not raise, and returns a receipt for the files that already crossed" do
          http.on("sendDocument", { "message_id" => 601 })
          http.error_on("sendDocument", code: 429, description: "Too Many Requests",
                                        parameters: { "retry_after" => 5 })
          http.on("sendDocument", { "message_id" => 603 })

          receipt = nil
          expect { receipt = adapter.deliver(outgoing.with(attachments: three_documents), general) }
            .not_to raise_error

          expect(receipt.native_id).to eq("601")
          # 602 never posted, so it is left out rather than referencing a message
          # that does not exist.
          expect(receipt.extra[:group_ids]).to eq(%w[601 603])
        end

        it "attempts every call rather than giving up after the first failure" do
          http.on("sendDocument", { "message_id" => 601 })
          http.error_on("sendDocument", code: 429, description: "Too Many Requests",
                                        parameters: { "retry_after" => 5 })
          http.on("sendDocument", { "message_id" => 603 })

          adapter.deliver(outgoing.with(attachments: three_documents), general)

          expect(http.calls("sendDocument").size).to eq(3)
        end

        it "reports the loss as a note, the same way a Discord upload failure does" do
          http.on("sendDocument", { "message_id" => 601 })
          http.error_on("sendDocument", code: 429, description: "Too Many Requests",
                                        parameters: { "retry_after" => 5 })
          http.on("sendDocument", { "message_id" => 603 })

          receipt = adapter.deliver(outgoing.with(attachments: three_documents), general)

          expect(receipt.extra[:notes]).to eq(["1 of 3 parts of this message could not be sent to Telegram"])
        end
      end

      # Only the first id is ever written to the message map or an ephemeral row,
      # so deleting by that id alone left the rest of the album in the chat.
      describe "deleting what a group crossed as" do
        def deliver_album
          http.on("sendDocument", { "message_id" => 601 })
          http.on("sendDocument", { "message_id" => 602 })
          http.on("sendDocument", { "message_id" => 603 })
          docs = %w[a.pdf b.pdf c.pdf].map do |name|
            Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn.example/#{name}", filename: name)
          end
          adapter.deliver(outgoing.with(attachments: docs), general)
        end

        it "removes every message of the group, not only the id the receipt named" do
          receipt = deliver_album

          adapter.delete(general, receipt.native_id)

          expect(http.calls("deleteMessage").map { |c| c.params["message_id"] }).to eq([601, 602, 603])
        end

        it "issues one call for an ordinary message that never crossed as a group" do
          http.on("sendMessage", { "message_id" => 501 })
          receipt = adapter.deliver(outgoing, general)

          adapter.delete(general, receipt.native_id)

          expect(http.calls("deleteMessage").map { |c| c.params["message_id"] }).to eq([501])
        end

        it "does not repeat the whole group when the same id is deleted twice" do
          receipt = deliver_album
          adapter.delete(general, receipt.native_id)
          adapter.delete(general, receipt.native_id)

          expect(http.calls("deleteMessage").map { |c| c.params["message_id"] }).to eq([601, 602, 603, 601])
        end

        it "tolerates a message of the group already being gone" do
          receipt = deliver_album
          http.error_on("deleteMessage", code: 400, description: "Bad Request: message to delete not found")

          expect { adapter.delete(general, receipt.native_id) }.not_to raise_error
          expect(http.calls("deleteMessage").size).to eq(3)
        end

        it "takes the whole group down through a /delete, not only its first message" do
          receipt = deliver_album
          command = Rubotty::Core::Moderation::Command.new(
            action: :delete, issuer: nil, origin: general, target_ref: ref("tg-general", receipt.native_id)
          )

          expect(adapter.moderate(command, general, receipt.native_id).status).to eq(:done)
          expect(http.calls("deleteMessage").map { |c| c.params["message_id"] }).to eq([601, 602, 603])
        end
      end

      it "still raises when the FIRST call of several fails, since nothing has crossed yet" do
        http.error_on("sendDocument", code: 429, description: "Too Many Requests",
                                      parameters: { "retry_after" => 5 })
        docs = %w[a.pdf b.pdf].map do |name|
          Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn.example/#{name}", filename: name)
        end

        expect { adapter.deliver(outgoing.with(attachments: docs), general) }
          .to raise_error(Rubotty::RateLimitedError)
        expect(http.calls("sendDocument").size).to eq(1)
      end
    end

    it "renders a membership event as a sentence" do
      joined = message(general, text: "", kind: :join).with(sender_label: "Bob")
      adapter.deliver(joined, general)
      expect(http.last("sendMessage").params["text"]).to eq("<b>Bob</b> <i>joined the chat</i>")
    end

    it "notes a forward" do
      forwarded = outgoing.with(forwarded_from: author(first_name: "Grace", username: "grace"))
      adapter.deliver(forwarded, general)
      expect(http.last("sendMessage").params["text"]).to include("forwarded from")
    end

    it "truncates an over long message without breaking the HTML" do
      long = message(general, text: "x" * 5000).with(sender_label: "Ada")
      adapter.deliver(long, general)
      text = http.last("sendMessage").params["text"]
      expect(Rubotty::Util::Utf16.length(text)).to be <= 4096
      expect(text.scan("<b>").size).to eq(text.scan("</b>").size)
    end

    it "edits a text message in place" do
      adapter.edit(outgoing.with(body: Rubotty::Core::RichText.plain("fixed")), general, "501")
      call = http.last("editMessageText")
      expect(call.params["message_id"]).to eq(501)
      expect(call.params["text"]).to include("fixed")
    end

    it "deletes a message" do
      adapter.delete(general, "501")
      expect(http.last("deleteMessage").params["message_id"]).to eq(501)
    end

    it "treats an already deleted message as success rather than an error" do
      http.error_on("deleteMessage", code: 400, description: "Bad Request: message to delete not found")
      expect { adapter.delete(general, "501") }.not_to raise_error
    end

    it "raises a rate limit error carrying the retry hint" do
      http.error_on("sendMessage", code: 429, description: "Too Many Requests",
                                   parameters: { "retry_after" => 12 })
      expect { adapter.deliver(outgoing, general) }
        .to raise_error(Rubotty::RateLimitedError) { |e| expect(e.retry_after).to eq(12) }
    end

    it "raises a permission error when the bot was removed from the chat" do
      http.error_on("sendMessage", code: 403, description: "Forbidden: bot was kicked")
      expect { adapter.deliver(outgoing, general) }.to raise_error(Rubotty::PermissionError)
    end
  end

  # A DM to the bot owns no channel, so it misses the resolver; a wired control
  # lane gets the gesture instead of the update being dropped.
  describe "DM control gestures" do
    # Records the DM it is handed and answers with a canned line.
    let(:lane) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def handle_dm(adapter:, account:, author:, text:, quoted: nil, subject: nil)
          @calls << { adapter: adapter, account: account, author: author, text: text,
                      quoted: quoted, subject: subject }
          "request received"
        end
      end.new
    end

    subject(:adapter_with_lane) do
      described_class.new(
        account: "tg",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
        dispatcher: dispatcher,
        logger: Rubotty::Log.null,
        endpoints: [general, lobby],
        control_lane: lane
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    def dm(text)
      {
        "update_id" => 5,
        "message" => {
          "message_id" => 200, "date" => 1_700_000_000,
          "chat" => { "id" => 55, "type" => "private" },
          "from" => { "id" => 55, "username" => "ada", "first_name" => "Ada", "is_bot" => false },
          "text" => text
        }
      }
    end

    # Answering one of the bot's own alerts means replying to it, so the quoted
    # text has to travel with the DM for the console to read the code back out.
    it "carries the replied-to text so an alert can be answered by replying to it" do
      update = dm("/vindicate he was quoting somebody")
      update["message"]["reply_to_message"] = { "message_id" => 199, "text" => "Answer with /vindicate bq7k <why>." }
      adapter_with_lane.handle_update(update)

      expect(lane.calls.first[:quoted]).to include("/vindicate bq7k")
    end

    it "carries a caption when the replied-to message had no text of its own" do
      update = dm("/vindicate")
      update["message"]["reply_to_message"] = { "message_id" => 199, "caption" => "a caption" }
      adapter_with_lane.handle_update(update)

      expect(lane.calls.first[:quoted]).to eq("a caption")
    end

    it "carries nothing when the DM replied to nothing" do
      adapter_with_lane.handle_update(dm("help"))

      expect(lane.calls.first[:quoted]).to be_nil
    end

    it "hands a private-chat message to the control lane with the author and account" do
      adapter_with_lane.handle_update(dm("/operator request"))
      expect(lane.calls.size).to eq(1)
      call = lane.calls.first
      expect(call[:adapter]).to eq(:telegram)
      expect(call[:account]).to eq("tg")
      expect(call[:text]).to eq("/operator request")
      expect(call[:author].native_id).to eq("55")
      expect(call[:author].username).to eq("ada")
    end

    it "sends the lane's reply back to the DM chat" do
      adapter_with_lane.handle_update(dm("operator"))
      sent = http.last("sendMessage")
      expect(sent.params["chat_id"]).to eq(55)
      expect(sent.params["text"]).to eq("request received")
    end

    it "does not route a DM as a normal message" do
      adapter_with_lane.handle_update(dm("operator request"))
      expect(dispatcher.messages).to be_empty
    end

    it "leaves group messages untouched: they route normally, not to the lane" do
      adapter_with_lane.handle_update(update)
      expect(lane.calls).to be_empty
      expect(dispatcher.last.origin.id).to eq("tg-general")
    end

    it "drops a private message with no control lane wired, exactly as before" do
      adapter.handle_update(dm("operator request"))
      expect(dispatcher.messages).to be_empty
      expect(http.called?("sendMessage")).to be(false)
    end
  end

  # setMessageReaction REPLACES what the bot holds, so an empty list is how a
  # reaction is REMOVED. Sending one for a set Telegram simply cannot show takes
  # a correct emoji off a message nobody asked to change.
  describe "#sync_reactions" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:avocado) { Rubotty::Core::Reaction.new(emoji: "🥑") }

    def sync(desired:, previous: [])
      adapter.sync_reactions(general, "900", desired: desired, previous: previous)
    end

    def last_set = http.last("setMessageReaction").params["reaction"]

    # A second adapter over the same fake HTTP, for the cases that turn on the
    # account's own policy or need to read what was logged.
    def adapter_with(extra, logger: Rubotty::Log.null)
      described_class.new(
        account: "tg",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" }.merge(extra),
        dispatcher: dispatcher, logger: logger, endpoints: [general, lobby]
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    it "places the emoji the set maps onto" do
      sync(desired: [thumbs])
      expect(last_set).to eq([{ "type" => "emoji", "emoji" => "👍" }])
    end

    # capabilities.max_reactions is 1 for a non-premium bot; two representable
    # reactions in one set still only ever place the oldest.
    it "holds only as many reactions as the endpoint's capabilities allow" do
      sync(desired: [thumbs, Rubotty::Core::Reaction.new(emoji: "🎉")])
      expect(last_set).to eq([{ "type" => "emoji", "emoji" => "👍" }])
    end

    it "leaves the message alone when nothing held maps onto the whitelist" do
      sync(desired: [avocado])
      expect(http.called?("setMessageReaction")).to be(false)
    end

    it "leaves it alone for a custom emoji, which a bot may never set on Telegram" do
      sync(desired: [Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")])
      expect(http.called?("setMessageReaction")).to be(false)
    end

    # Under nearest a laughing face becomes 🤣; under drop it maps onto nothing,
    # which is the same situation an emoji outside the whitelist entirely is in.
    it "leaves it alone under the drop policy, where nothing is substituted" do
      adapter_with({ reaction_policy: :drop })
        .sync_reactions(general, "900", desired: [Rubotty::Core::Reaction.new(emoji: "😂")], previous: [])
      expect(http.called?("setMessageReaction")).to be(false)
    end

    it "sends the empty list when the set is genuinely empty, which is a removal" do
      sync(desired: [], previous: [thumbs])
      expect(last_set).to eq([])
    end

    # The emoji this bridge placed is no longer held by anybody, and only
    # unshowable ones are left, so taking it off is the honest state.
    it "takes its own emoji off once only unshowable ones are left" do
      sync(desired: [avocado], previous: [thumbs, avocado])
      expect(last_set).to eq([])
    end

    it "says at debug level that it left the message alone" do
      logs = StringIO.new
      adapter_with({}, logger: Rubotty::Log.build(level: "debug", io: logs))
        .sync_reactions(general, "900", desired: [avocado], previous: [])
      expect(logs.string).to include("nothing held maps onto Telegram")
    end
  end

  # Telegram has no native kick: /kick is a banChatMember immediately reversed
  # by an unbanChatMember, so the member is removed but free to rejoin. A
  # failure on the unban leaves them banned outright, the opposite of what
  # /kick promised, and that must never look like an ordinary kick failure.
  describe "#moderate (:kick)" do
    def kick_command
      Rubotty::Core::Moderation::Command.new(
        action: :kick, issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"), origin: general,
        target_user_id: "55"
      )
    end

    it "bans then unbans, reporting done" do
      result = adapter.moderate(kick_command, general, nil)

      expect(result.status).to eq(:done)
      expect(http.called?("banChatMember")).to be(true)
      expect(http.called?("unbanChatMember")).to be(true)
    end

    it "still bans the target even though the follow-up unban is about to fail" do
      http.error_on("unbanChatMember", code: 429, description: "Too Many Requests")

      adapter.moderate(kick_command, general, nil)

      expect(http.last("banChatMember").params["user_id"]).to eq(55)
    end

    # Before the fix this came back as a plain :failed, identical to a kick
    # whose ban never even reached Telegram, so nobody could tell the member
    # was actually banned rather than merely removed.
    it "reports a detail naming the member as left banned, rather than a plain failure" do
      http.error_on("unbanChatMember", code: 429, description: "Too Many Requests")

      result = adapter.moderate(kick_command, general, nil)

      expect(result.status).to eq(:failed)
      expect(result.detail).to include("banned")
      expect(result.detail).to include("55")
    end
  end

  # The bot being added to a group is a my_chat_member update; a wired join
  # guard decides whether it stays, and with no guard the update is ignored.
  describe "auto-leave on being added to a group (#35)" do
    # A recording join guard that returns a canned decision.
    let(:guard) do
      Class.new do
        attr_reader :calls
        attr_accessor :decision

        def initialize
          @calls = []
          @decision = Rubotty::ControlPlane::JoinGuard::Decision.new(action: :leave, notice: "private bot, leaving")
          @leave_failures = []
        end

        def on_join(adapter:, account:, external_id:, title: nil, inviter: nil, channel_sample: [])
          @calls << { adapter: adapter, account: account, external_id: external_id, title: title,
                      inviter: inviter, channel_sample: channel_sample }
          @decision
        end

        # Mirrors the real JoinGuard#record_leave_failure: true the first time a
        # space is reported stuck, false on every later call.
        def record_leave_failure(adapter:, account:, external_id:)
          key = [adapter, account, external_id]
          return false if @leave_failures.include?(key)

          @leave_failures << key
          true
        end
      end.new
    end

    subject(:adapter_with_guard) do
      described_class.new(
        account: "tg",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
        dispatcher: dispatcher,
        logger: Rubotty::Log.null,
        endpoints: [general, lobby],
        join_guard: guard
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    def added(chat_type: "supergroup", old_status: "left", new_status: "member", chat_id: -1_009_999)
      {
        "update_id" => 9,
        "my_chat_member" => {
          "chat" => { "id" => chat_id, "type" => chat_type, "title" => "Rando" },
          "from" => { "id" => 77, "first_name" => "Rando" },
          "date" => 1_700_000_000,
          "old_chat_member" => { "user" => { "id" => 999, "is_bot" => true }, "status" => old_status },
          "new_chat_member" => { "user" => { "id" => 999, "is_bot" => true }, "status" => new_status }
        }
      }
    end

    it "asks the guard about the group with the chat id as the space id and the chat title (#118)" do
      adapter_with_guard.handle_update(added)
      expect(guard.calls.size).to eq(1)
      call = guard.calls.first
      expect(call).to include(adapter: :telegram, account: "tg", external_id: "-1009999", title: "Rando")
      expect(call[:channel_sample]).to eq([])
    end

    it "captures who performed the join as the signal's inviter (#169)" do
      adapter_with_guard.handle_update(added)
      inviter = guard.calls.first[:inviter]
      expect(inviter).to be_a(Rubotty::Core::Author)
      expect(inviter.native_id).to eq("77")
      expect(inviter.first_name).to eq("Rando")
    end

    it "posts the notice and leaves an unauthorized group" do
      adapter_with_guard.handle_update(added)
      expect(http.last("sendMessage").params["text"]).to eq("private bot, leaving")
      expect(http.last("leaveChat").params["chat_id"]).to eq(-1_009_999)
    end

    it "leaves even when the notice fails to post" do
      http.error_on("sendMessage", code: 403, description: "bot was blocked")
      adapter_with_guard.handle_update(added)
      expect(http.called?("leaveChat")).to be(true)
    end

    it "posts the inert fallback notice when the leave call itself fails (#169)" do
      http.error_on("leaveChat", code: 403, description: "bot lacks permission to leave")
      adapter_with_guard.handle_update(added)
      texts = http.calls("sendMessage").map { |request| request.params["text"] }
      expect(texts).to include(Rubotty::ControlPlane::JoinGuard::INERT_NOTICE)
    end

    it "posts the inert fallback notice only once per chat (#169)" do
      http.error_on("leaveChat", code: 403, description: "bot lacks permission to leave")
      adapter_with_guard.handle_update(added)
      http.error_on("leaveChat", code: 403, description: "bot lacks permission to leave")
      adapter_with_guard.handle_update(added)

      texts = http.calls("sendMessage").map { |request| request.params["text"] }
      expect(texts.count(Rubotty::ControlPlane::JoinGuard::INERT_NOTICE)).to eq(1)
    end

    it "stays in an authorized group, posting nothing and leaving nothing" do
      guard.decision = Rubotty::ControlPlane::JoinGuard::Decision.new(action: :stay)
      adapter_with_guard.handle_update(added)
      expect(http.called?("leaveChat")).to be(false)
      expect(http.called?("sendMessage")).to be(false)
    end

    it "ignores a membership change that is not a genuine join" do
      # old and new both present (a permission change), not a join.
      adapter_with_guard.handle_update(added(old_status: "member", new_status: "administrator"))
      expect(guard.calls).to be_empty
      expect(http.called?("leaveChat")).to be(false)
    end

    it "ignores the bot being removed from a group" do
      adapter_with_guard.handle_update(added(old_status: "member", new_status: "left"))
      expect(guard.calls).to be_empty
    end

    it "does not route a membership update as a normal message" do
      adapter_with_guard.handle_update(added)
      expect(dispatcher.messages).to be_empty
    end

    it "does nothing on a membership change when no join guard is wired" do
      adapter.handle_update(added)
      expect(http.called?("leaveChat")).to be(false)
      expect(dispatcher.messages).to be_empty
    end
  end

  describe "channel management (issue #227)" do
    # Channel management runs only under the control plane, where every
    # endpoint carries the community that owns it, so these two do.
    let(:general) do
      endpoint("tg-general", adapter: :telegram, community_id: 7,
                             settings: { chat_id: "-1008000000001", thread_id: 142_483 })
    end
    let(:lobby) do
      endpoint("tg-lobby", adapter: :telegram, community_id: 7, settings: { chat_id: "-1008000000001" })
    end

    it "reports support unconditionally: whether topics are enabled can only be learned by trying" do
      expect(adapter.supports_channel_management?).to be(true)
    end

    it "creates a forum topic in the account's one known chat" do
      http.on("createForumTopic", { "message_thread_id" => 555, "name" => "Gaming" })

      native_id = adapter.create_channel(name: "Gaming", community_id: 7)

      expect(native_id).to eq("-1008000000001/555")
      expect(http.calls("createForumTopic").first.params).to include(
        "chat_id" => "-1008000000001", "name" => "Gaming"
      )
    end

    it "raises a plain AdapterError when the target chat has no topics enabled" do
      http.error_on("createForumTopic", code: 400, description: "Bad Request: forum topics disabled")

      expect do
        adapter.create_channel(name: "Gaming", community_id: 7)
      end.to raise_error(Rubotty::AdapterError, /forum topics/)
    end

    it "deletes a topic addressed as chat_id/thread_id, the shape #create_channel returns" do
      http.on("deleteForumTopic", true)

      expect(adapter.delete_channel("-1008000000001/555", community_id: 7)).to be(true)
      expect(http.calls("deleteForumTopic").first.params).to include(
        "chat_id" => "-1008000000001", "message_thread_id" => 555
      )
    end

    it "resolves a bare thread id against the chat the community bridges" do
      http.on("deleteForumTopic", true)

      adapter.delete_channel("555", community_id: 7)

      expect(http.calls("deleteForumTopic").first.params).to include("chat_id" => "-1008000000001")
    end

    it "has nothing to copy: permissions are group-wide, not per topic" do
      expect(adapter.copy_channel_permissions(from: "1", to: "2")).to be(false)
    end
  end

  # When the guard says "leave" and a pending-spaces service is wired, the
  # adapter consults the service instead of leaving immediately, and posts or
  # withholds the one-time notice according to the Outcome.
  describe "the pending-review flow when a pending-spaces service is wired (#170)" do
    let(:guard) do
      Class.new do
        def on_join(adapter:, account:, external_id:, title: nil, inviter: nil, channel_sample: [])
          Rubotty::ControlPlane::JoinGuard::Decision.new(action: :leave, notice: "unused")
        end
      end.new
    end

    # Records every call it receives and hands back a canned Outcome.
    let(:pending_spaces) do
      Class.new do
        attr_reader :calls, :marked, :reconfirmed
        attr_accessor :outcome

        def initialize
          row = Struct.new(:id, :notice_posted_at).new(1, nil)
          @outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :pending, row: row, post_notice: true)
          @calls = []
          @marked = []
          @reconfirmed = []
        end

        def on_join!(**kwargs)
          @calls << kwargs
          @outcome
        end

        def mark_notice_posted!(row) = @marked << row

        def reconfirm_denied!(row) = @reconfirmed << row
      end.new
    end

    subject(:adapter_with_pending) do
      described_class.new(
        account: "tg", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general, lobby],
        join_guard: guard, pending_spaces: pending_spaces
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    def added_by(inviter_id: 77, username: "inviter", first_name: "Ivy", chat_id: -1_009_999, title: "New Space")
      {
        "update_id" => 9,
        "my_chat_member" => {
          "chat" => { "id" => chat_id, "type" => "supergroup", "title" => title },
          "from" => { "id" => inviter_id, "username" => username, "first_name" => first_name },
          "date" => 1_700_000_000,
          "old_chat_member" => { "user" => { "id" => 999, "is_bot" => true }, "status" => "left" },
          "new_chat_member" => { "user" => { "id" => 999, "is_bot" => true }, "status" => "member" }
        }
      }
    end

    it "consumes the normalized join signal: platform, account, space id/name, inviter" do
      adapter_with_pending.handle_update(added_by)
      expect(pending_spaces.calls.size).to eq(1)
      expect(pending_spaces.calls.first).to include(
        adapter: :telegram, account: "tg", external_id: "-1009999", name: "New Space",
        inviter_native_id: 77, inviter_username: "inviter", inviter_display: "Ivy", sample_channels: []
      )
    end

    it "captures the chat member count for the pending card when the Bot API reports one" do
      http.on("getChatMemberCount", 42)
      adapter_with_pending.handle_update(added_by)
      expect(pending_spaces.calls.first[:member_count]).to eq(42)
    end

    it "leaves member_count nil, without raising, when the count cannot be read" do
      http.error_on("getChatMemberCount", code: 400, description: "not enough rights")
      adapter_with_pending.handle_update(added_by)
      expect(pending_spaces.calls.first[:member_count]).to be_nil
    end

    it "posts the pending notice and records that it did, when the outcome says to" do
      adapter_with_pending.handle_update(added_by)
      expect(http.last("sendMessage").params["text"]).to eq(Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE)
      expect(http.called?("leaveChat")).to be(false)
      expect(pending_spaces.marked.size).to eq(1)
    end

    it "does not post the notice again once the service says it already was" do
      pending_spaces.outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(
        action: :pending, row: pending_spaces.outcome.row, post_notice: false
      )
      adapter_with_pending.handle_update(added_by)
      expect(http.called?("sendMessage")).to be(false)
    end

    it "reconfirms a denied (blacklisted) re-add through the service, posting nothing itself" do
      pending_spaces.outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(
        action: :leave, row: pending_spaces.outcome.row, post_notice: false
      )
      adapter_with_pending.handle_update(added_by)
      expect(pending_spaces.reconfirmed.size).to eq(1)
      expect(http.called?("sendMessage")).to be(false)
      expect(http.called?("leaveChat")).to be(false)
    end

    it "does nothing further for a :stay outcome (defense in depth)" do
      pending_spaces.outcome = Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :stay, row: nil)
      adapter_with_pending.handle_update(added_by)
      expect(http.called?("sendMessage")).to be(false)
      expect(http.called?("leaveChat")).to be(false)
    end

    # An unmapped space mid-onboarding must never be pended, so this runs a real
    # JoinGuard over the seeded control plane to prove the guard's own decision.
    describe "never pends a space while an onboarding is in progress", :control_plane do
      let(:seeded) { seeded_sample }
      let(:models) { seeded[1] }
      let(:onboarding) do
        instance_double(Rubotty::ControlPlane::OnboardingRegistry).tap do |double|
          allow(double).to receive(:in_progress?).and_return(true)
        end
      end
      let(:real_guard) do
        Rubotty::ControlPlane::JoinGuard.new(
          authorization: Rubotty::ControlPlane::AuthorizationDirectory.new(models: models),
          onboarding: onboarding, logger: Rubotty::Log.null
        )
      end

      subject(:adapter_onboarding) do
        described_class.new(
          account: "tg", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general, lobby],
          join_guard: real_guard, pending_spaces: pending_spaces
        ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
      end

      it "stays, and never calls the pending-spaces service at all" do
        adapter_onboarding.handle_update(added_by(chat_id: -100_424_242, title: "Not Yet Mapped"))
        expect(pending_spaces.calls).to be_empty
        expect(http.called?("sendMessage")).to be(false)
        expect(http.called?("leaveChat")).to be(false)
      end
    end
  end

  # Telegram bots cannot enumerate forum topics, so discovery here is passive: a
  # message carrying a message_thread_id reveals a topic and its thread id.
  describe "passive forum-topic discovery (#38, #39)", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community) { models.community.first }
    let(:telegram_connection) { models.platform_connection.where(adapter: "telegram").first }

    let(:store) do
      Class.new do
        def initialize = @h = {}

        def get_state(key)
          row = @h[key]
          row && (row[:expires_at].nil? || row[:expires_at] > Time.now) ? row[:value] : nil
        end

        def put_state(key, value, expires_at: nil) = @h[key] = { value: value, expires_at: expires_at }
      end.new
    end

    let(:notifier) do
      Class.new do
        attr_reader :prompts

        def initialize = @prompts = []

        def prompt(community:, descriptor:) = @prompts << descriptor
      end.new
    end

    let(:watch) { Rubotty::ControlPlane::NewChannelWatch.new(models: models, store: store) }
    let(:discovery) do
      Rubotty::ControlPlane::ChannelDiscovery.new(models: models, watch: watch, notifier: notifier)
    end

    # A seeded topic endpoint, so a message in a known topic still routes while
    # discovery also observes it.
    let(:gaming) do
      endpoint("tg-gaming", adapter: :telegram, settings: { chat_id: "-1008000000001", thread_id: 142_483 })
    end

    subject(:adapter) do
      described_class.new(
        account: "telegram",
        settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming], discovery: discovery
      ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
    end

    def enable_alerts
      settings = community.json_value(:settings)
      settings["new_channel_alerts"] = { "enabled" => true, "ignore" => [] }
      community.update(settings: JSON.generate(settings))
    end

    def disable_alerts
      settings = community.json_value(:settings)
      settings["new_channel_alerts"] = { "enabled" => false }
      community.update(settings: JSON.generate(settings))
    end

    def topic_message(thread_id:, name: nil, text: "hello", chat_title: nil, chat_id: -1008000000001,
                       is_forum: true)
      chat = { "id" => chat_id, "type" => "supergroup", "is_forum" => is_forum }
      chat["title"] = chat_title if chat_title
      message = {
        "message_id" => 5, "date" => 1_700_000_000, "chat" => chat,
        "message_thread_id" => thread_id,
        "from" => { "id" => 55, "first_name" => "Ada", "username" => "ada", "is_bot" => false },
        "text" => text
      }
      message["forum_topic_created"] = { "name" => name } if name
      { "update_id" => 2, "message" => message }
    end

    # Telegram attaches the topic's opening forum_topic_created message as
    # reply_to_message on every message in that topic, so even a topic that
    # existed before the bot joined can be named from ordinary traffic.
    describe "naming a topic from the opener Telegram attaches to every message in it" do
      def message_in_topic(thread_id:, topic_name:, text: "just chatting")
        update = topic_message(thread_id: thread_id, text: text, chat_title: "Example Travel")
        update["message"]["reply_to_message"] = {
          "message_id" => thread_id, "message_thread_id" => thread_id,
          "chat" => update["message"]["chat"],
          "forum_topic_created" => { "name" => topic_name }
        }
        update
      end

      it "discovers the topic under its real name on the very first ordinary message" do
        enable_alerts
        adapter.handle_update(message_in_topic(thread_id: 777_001, topic_name: "Banking in Portugal"))

        row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/777001").first
        expect(row.label).to eq("Banking in Portugal")
      end

      it "gives two different topics two different names, not one shared placeholder" do
        enable_alerts
        adapter.handle_update(message_in_topic(thread_id: 777_002, topic_name: "Legal Action"))
        adapter.handle_update(message_in_topic(thread_id: 777_003, topic_name: "Life in Portugal"))

        labels = %w[777002 777003].map do |id|
          models.channel.where(route_key: "-1008000000001/#{id}").first.label
        end
        expect(labels).to eq(["Legal Action", "Life in Portugal"])
      end

      it "corrects a channel already stuck with the derived placeholder once the real name arrives" do
        # Discovered nameless first, so it carries the parent chat's title plus
        # the topic id.
        adapter.handle_update(topic_message(thread_id: 777_004, chat_title: "Example Travel"))
        stuck = models.channel.where(route_key: "-1008000000001/777004").first
        expect(stuck.label).to eq("Example Travel (topic 777004)")

        adapter.handle_update(message_in_topic(thread_id: 777_004, topic_name: "Awaiting Biometrics"))

        expect(models.channel.where(route_key: "-1008000000001/777004").first.label).to eq("Awaiting Biometrics")
      end

      it "never lets passive traffic overwrite a name an operator chose" do
        adapter.handle_update(message_in_topic(thread_id: 777_005, topic_name: "Original"))
        models.channel.where(route_key: "-1008000000001/777005").first.update(label: "Operator's Name")

        # Only the adapter's own placeholder is replaceable, so the operator's
        # choice survives however often Telegram reports its own name.
        3.times { adapter.handle_update(message_in_topic(thread_id: 777_005, topic_name: "Original")) }

        expect(models.channel.where(route_key: "-1008000000001/777005").first.label).to eq("Operator's Name")
      end
    end

    it "learns a brand-new topic and prompts the operator in an opted-in community" do
      enable_alerts
      adapter.handle_update(topic_message(thread_id: 999_999, name: "new-topic"))

      expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["-1008000000001/999999"])
      row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/999999").first
      expect(row.label).to eq("new-topic")
      expect(row.json_value(:settings)).to eq("chat_id" => "-1008000000001", "thread_id" => 999_999)
    end

    it "prompts by default, without an explicit opt-in" do
      adapter.handle_update(topic_message(thread_id: 999_999, name: "new-topic"))
      expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["-1008000000001/999999"])
    end

    it "learns nothing once a community explicitly opts out" do
      disable_alerts
      adapter.handle_update(topic_message(thread_id: 999_999, name: "new-topic"))
      expect(notifier.prompts).to be_empty
      expect(models.channel.where(route_key: "-1008000000001/999999").first).to be_nil
    end

    it "does not prompt for a topic that is already a known channel row" do
      enable_alerts
      adapter.handle_update(topic_message(thread_id: 142_483))
      expect(notifier.prompts).to be_empty
    end

    it "learns the bare chat_id channel from a General-topic (or flat-group) message with no thread id" do
      # This block's usual chat already has a real channel at its bare chat_id,
      # so a second, unmapped chat is used here. A flat group's messages, and a
      # forum's own General topic, never carry a message_thread_id.
      now = Time.now
      models.platform_connection.create(
        community_id: community.id, adapter: "telegram", account: "telegram", external_id: "-1002000000000",
        created_at: now, updated_at: now
      )
      enable_alerts

      update = topic_message(thread_id: 999_999, chat_title: "The Flat Group", chat_id: -1_002_000_000_000)
      update["message"].delete("message_thread_id")
      adapter.handle_update(update)

      expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["-1002000000000"])
      row = models.channel.where(adapter: "telegram", route_key: "-1002000000000").first
      expect(row.label).to eq("The Flat Group")
    end

    it "ignores a reply-thread id in a NON-forum chat, routing on the bare chat_id instead" do
      # Telegram overloads message_thread_id for reply-chain grouping in an
      # ordinary group, so chat.is_forum is the only reliable signal that a
      # thread id names a real forum topic.
      now = Time.now
      models.platform_connection.create(
        community_id: community.id, adapter: "telegram", account: "telegram", external_id: "-1002000000001",
        created_at: now, updated_at: now
      )
      enable_alerts

      update = topic_message(thread_id: 930, chat_title: "Flat Reply Group", chat_id: -1_002_000_000_001,
                              is_forum: false)
      adapter.handle_update(update)

      expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["-1002000000001"])
      expect(models.channel.where(route_key: "-1002000000001/930").first).to be_nil
    end

    # The parsed message carries the same reading the routing above does: read
    # bare, an ordinary group's reply grouping arrived as a ThreadRef, and any
    # feature skipping a threaded message then skipped ordinary replies. The
    # routing half of this is the non-forum spec above.
    it "gives a message in a real forum topic its thread" do
      adapter.handle_update(update)

      expect(dispatcher.last.thread&.native_id.to_s).to eq("142483")
    end

    it "never consumes the update: a topic message still routes normally" do
      enable_alerts
      adapter.handle_update(topic_message(thread_id: 142_483, text: "in the gaming topic"))
      # The known topic prompts nothing, but the message still bridges.
      expect(dispatcher.messages).not_to be_empty
      expect(dispatcher.last.body.text).to eq("in the gaming topic")
    end

    # A topic's name rides only on its forum_topic_created or edited service
    # message, which is rarely the message that trips discovery in a busy chat.
    describe "naming a topic discovery does not itself see the service message for (#40's store)" do
      it "resolves the name from the already-learned thread-name store" do
        adapter.storage = store
        # As if the bot had witnessed the topic's creation earlier, which
        # #note_forum_topic learns from unconditionally.
        Rubotty::Core::ThreadNames.new(store: store).learn(
          scope: "-1008000000001", native_id: 999_999, name: "Lisbon Meetup"
        )
        enable_alerts

        adapter.handle_update(topic_message(thread_id: 999_999, text: "just chatting"))

        expect(notifier.prompts.map { |d| d[:name] }).to eq(["Lisbon Meetup"])
        row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/999999").first
        expect(row.label).to eq("Lisbon Meetup")
      end

      it "backfills the row once the real name shows up, after being discovered nameless" do
        adapter.storage = store
        enable_alerts

        adapter.handle_update(topic_message(thread_id: 999_999, text: "just chatting"))
        row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/999999").first
        expect(row.label).to be_nil

        adapter.handle_update(topic_message(thread_id: 999_999, name: "Lisbon Meetup"))

        expect(row.reload.label).to eq("Lisbon Meetup")
      end

      it "falls back to the parent chat's title, never a bare id, when the name was never learnable" do
        adapter.storage = store
        enable_alerts

        adapter.handle_update(
          topic_message(thread_id: 999_999, text: "just chatting", chat_title: "Example Travel")
        )

        row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/999999").first
        expect(row.label).to eq("Example Travel (topic 999999)")
      end

      # Turns "two topics share a label" into a log grep.
      it "debug-logs which of the three sources resolved the name" do
        io = StringIO.new
        traced = described_class.new(
          account: "telegram", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.build(level: "debug", io: io), endpoints: [gaming],
          discovery: discovery
        ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
        traced.storage = store
        Rubotty::Core::ThreadNames.new(store: store).learn(
          scope: "-1008000000001", native_id: 999_999, name: "Lisbon Meetup"
        )

        traced.handle_update(topic_message(thread_id: 999_999, text: "just chatting"))

        expect(io.string).to include("topic name for -1008000000001/999999 resolved via known_store")
        expect(io.string).to include('"Lisbon Meetup"')
      end
    end

    it "does not fail the receive loop when discovery raises" do
      allow(discovery).to receive(:saw).and_raise(StandardError.new("boom"))
      expect { adapter.handle_update(topic_message(thread_id: 142_483)) }.not_to raise_error
      expect(dispatcher.messages).not_to be_empty
    end

    # A message #endpoint_for cannot resolve never becomes a Core::Message, so
    # the pipeline-level Features::IdentifyTopic can never reach this case.
    describe "the /identify-topic fallback for a thread endpoint_for could not resolve" do
      def unresolved_identify(text, thread_id: 999_999)
        topic_message(thread_id: thread_id, text: text)
      end

      # Snapshot's route index carries every channel a community owns, mapped or
      # not, so a discovered topic resolves, skips this fallback, and is then
      # dropped by Dispatcher#call for belonging to no room.
      it "still answers in a topic that resolves to a discovered channel no room contains" do
        connection = models.platform_connection.where(adapter: "telegram").first
        now = Time.now
        models.channel.create(
          community_id: community.id, platform_connection_id: connection.id,
          adapter: "telegram", account: "telegram", route_key: "-1008000000001/555555",
          endpoint_key: "discovered:telegram:telegram:-1008000000001/555555",
          label: "SAMPLE (topic 555555)", created_at: now, updated_at: now
        )
        stranded = Rubotty::Core::Endpoint.new(
          id: "discovered:telegram:telegram:-1008000000001/555555", adapter_name: :telegram,
          account: "telegram", settings: { chat_id: "-1008000000001", thread_id: 555_555 }
        )
        # Resolves (the row exists) but belongs to no room, exactly the live state.
        resolver = Class.new do
          def initialize(endpoint) = @endpoint = endpoint

          def endpoint_for(_adapter, _account, route_key)
            route_key == "-1008000000001/555555" ? @endpoint : nil
          end
        end.new(stranded)
        roomless_dispatcher = Class.new do
          attr_reader :messages, :topology

          def initialize = (@messages = []; @topology = Rubotty::Core::Topology.new([]))

          def call(message) = @messages << message
        end.new

        adapter = described_class.new(
          account: "telegram", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
          dispatcher: roomless_dispatcher, logger: Rubotty::Log.null,
          endpoint_resolver: resolver, discovery: discovery
        ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))

        adapter.handle_update(unresolved_identify("/identify-topic Early Applicants", thread_id: 555_555))

        row = models.channel.where(route_key: "-1008000000001/555555").first
        expect(row.label).to eq("Early Applicants")
        sent = http.requests.find { |r| r.method_name == "sendMessage" }
        expect(sent).not_to be_nil
        expect(sent.params["message_thread_id"]).to eq(555_555)
      end

      it "records a SUGGESTED channel row for a non-operator" do
        adapter.handle_update(unresolved_identify("/identify-topic Lisbon Meetup"))

        row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/999999").first
        expect(row).not_to be_nil
        expect(row.label).to eq("Lisbon Meetup")
        expect(row.suggested).to be(true)
      end

      # ChannelDiscovery#operator_for? resolves the community itself, so an
      # operator's /identify-topic takes effect immediately even in a topic with
      # no channel row yet.
      it "identifies IMMEDIATELY (not suggested) when the asker is a real operator" do
        now = Time.now
        person = models.person.create(community_id: community.id, name: "Ada", created_at: now, updated_at: now)
        models.person_identity.create(
          person_id: person.id, adapter: "telegram", native_id: "55", username: "ada", created_at: now
        )
        models.operator.create(
          community_id: community.id, person_id: person.id, actions: '"all"', scope: '"all"',
          granted_at: now, granted_by: "test"
        )
        operators = Rubotty::ControlPlane::OperatorFlow.new(models: models)
        discovery_with_operators = Rubotty::ControlPlane::ChannelDiscovery.new(
          models: models, watch: watch, notifier: notifier, operators: operators
        )
        operator_adapter = described_class.new(
          account: "telegram", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming], discovery: discovery_with_operators
        ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))

        operator_adapter.handle_update(unresolved_identify("/identify-topic Lisbon Meetup"))

        row = models.channel.where(adapter: "telegram", route_key: "-1008000000001/999999").first
        expect(row.suggested).to be(false)
        sent = http.requests.find { |r| r.method_name == "sendMessage" }
        expect(sent.params["text"]).to include("Identified")
        expect(sent.params["text"]).to include("mapping into a room")
      end

      it "replies in the same chat/thread, since no live endpoint resolved to reply through normally" do
        adapter.handle_update(unresolved_identify("/identify-topic Lisbon Meetup"))

        sent = http.requests.find { |r| r.method_name == "sendMessage" }
        expect(sent).not_to be_nil
        expect(sent.params["chat_id"]).to eq("-1008000000001")
        expect(sent.params["message_thread_id"]).to eq(999_999)
        expect(sent.params["text"]).to include("Suggested")
        expect(sent.params["text"]).to include("Lisbon Meetup")
      end

      it "replies with a usage reminder when the name is left blank, without ever calling identify" do
        expect(discovery).not_to receive(:identify)
        adapter.handle_update(unresolved_identify("/identify-topic"))

        sent = http.requests.find { |r| r.method_name == "sendMessage" }
        expect(sent.params["text"]).to eq("Usage: /identify-topic &lt;name&gt;")
      end

      it "does nothing (and sends nothing) for an ordinary unresolved message that is not the command" do
        # Passive discovery records a row here either way, so what this pins is
        # that the fallback adds nothing: no reply, and no #identify.
        expect(discovery).not_to receive(:identify)
        adapter.handle_update(unresolved_identify("just chatting, nothing to see here"))

        expect(http.requests).to be_empty
      end

      it "never touches an already-known channel row (that message would have resolved normally instead)" do
        adapter.handle_update(unresolved_identify("/identify-topic Renamed", thread_id: 142_483))

        # tg-gaming resolved fine, so this took the normal pipeline path and the
        # fallback's own row creation never ran.
        expect(dispatcher.messages).not_to be_empty
      end

      it "still replies with an honest, actionable message when the fallback itself raises" do
        # A DB error inside #identify was only logged, so the asker got nothing
        # back at all.
        allow(discovery).to receive(:identify).and_raise(StandardError.new("boom"))
        expect { adapter.handle_update(unresolved_identify("/identify-topic Lisbon Meetup")) }.not_to raise_error

        sent = http.requests.find { |r| r.method_name == "sendMessage" }
        expect(sent).not_to be_nil
        expect(sent.params["text"]).to eq(
          "Sorry, something went wrong identifying this channel. Try again, or check the logs."
        )
      end

      # Regression coverage for a report that /identify-topic answered in one
      # topic and not the others; neither case reproduces it from this adapter's
      # own logic.
      it "replies for a second distinct unresolved topic, not just the first" do
        adapter.handle_update(unresolved_identify("/identify-topic First", thread_id: 111_111))
        adapter.handle_update(unresolved_identify("/identify-topic Second", thread_id: 222_222))

        sent = http.requests.select { |r| r.method_name == "sendMessage" }
        expect(sent.map { |r| r.params["message_thread_id"] }).to eq([111_111, 222_222])
      end

      it "still replies for a topic that already carries a discovered-but-unmapped row" do
        adapter.handle_update(topic_message(thread_id: 333_333, text: "just chatting"))
        adapter.handle_update(unresolved_identify("/identify-topic Third", thread_id: 333_333))

        sent = http.requests.select { |r| r.method_name == "sendMessage" }
        expect(sent.last.params["text"]).to include("Suggested")
      end

      # An adapter is handed the ephemeral primitive after construction, the way
      # it is handed the durable store; a Feature gets it at construction.
      describe "with the ephemeral primitive wired, as the runtime wires it" do
        let(:fired) { [] }
        let(:cleanup) do
          Class.new do
            def initialize(fired) = @fired = fired

            def after(delay, &block) = @fired << delay.tap { block.call }
          end.new(fired)
        end

        before do
          http.on("sendMessage", { "message_id" => 777, "chat" => { "id" => -1008000000001 } })
          adapter.ephemeral = Rubotty::Core::EphemeralMessage.new(
            adapters: { [:telegram, "telegram"] => adapter }, session_id: "spec", logger: Rubotty::Log.null
          )
          adapter.cleanup = cleanup
        end

        it "removes the reply and the invocation together" do
          adapter.handle_update(unresolved_identify("/identify-topic Lisbon Meetup"))

          deleted = http.requests.select { |r| r.method_name == "deleteMessage" }
          expect(deleted.map { |r| r.params["message_id"].to_s }).to contain_exactly("777", "5")
          expect(fired).to eq([Rubotty::Core::CommandAck::DEFAULT_TTL_SECONDS])
        end

        it "answers in the topic it was asked in, exactly as the plain reply did" do
          adapter.handle_update(unresolved_identify("/identify-topic Lisbon Meetup"))

          sent = http.requests.find { |r| r.method_name == "sendMessage" }
          expect(sent.params["message_thread_id"]).to eq(999_999)
          expect(sent.params["text"]).to include("Lisbon Meetup")
        end

        it "still removes the reply when the usage reminder is what was posted" do
          adapter.handle_update(unresolved_identify("/identify-topic"))

          deleted = http.requests.select { |r| r.method_name == "deleteMessage" }
          expect(deleted.map { |r| r.params["message_id"].to_s }).to contain_exactly("777", "5")
        end
      end
    end
  end

  # A Telegram DM is sendMessage with the recipient's own id as chat_id, and
  # deleting one is deleteMessage against that same chat.
  describe "direct messages to an operator" do
    it "says it can send and delete, so the callers that check first will use it" do
      expect(adapter.supports_admin_dm?).to be(true)
      expect(adapter.supports_admin_dm_delete?).to be(true)
    end

    it "sends the message to the id it was given, and hands back a receipt" do
      http.on("sendMessage", { "message_id" => 42 })

      receipt = adapter.send_admin_dm("55", "a room needs you")

      sent = http.last("sendMessage")
      expect(sent.params).to eq({ "chat_id" => "55", "text" => "a room needs you" })
      expect(receipt).to be_a(Rubotty::Core::DmReceipt)
      expect(receipt.native_id).to eq("42")
      expect(receipt.channel_ref).to eq("55")
    end

    it "sends nothing for an empty message" do
      expect(adapter.send_admin_dm("55", "   ")).to be_nil
      expect(http.called?("sendMessage")).to be(false)
    end

    it "answers nil rather than raising when Telegram refuses the send" do
      http.error_on("sendMessage", code: 403, description: "Forbidden: bot was blocked by the user")

      expect { expect(adapter.send_admin_dm("55", "hi")).to be_nil }.not_to raise_error
    end

    it "deletes the message the receipt points at" do
      receipt = Rubotty::Core::DmReceipt.new(native_id: "42", channel_ref: "55")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
      deleted = http.last("deleteMessage")
      expect(deleted.params).to eq({ "chat_id" => "55", "message_id" => "42" })
    end

    it "counts an already-gone message as deleted rather than a failure" do
      http.error_on("deleteMessage", code: 400, description: "Bad Request: message to delete not found")
      receipt = Rubotty::Core::DmReceipt.new(native_id: "42", channel_ref: "55")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
    end

    it "is falsy for a receipt with nothing to delete" do
      expect(adapter.delete_admin_dm(nil)).to be(false)
    end
  end
end

# For RehostedFiles' download-serve ceiling; see ControlPlane::CommunityMembers.
# Public so a control-plane service outside the adapter can reach it, unlike
# the pending-card read it wraps.
RSpec.describe Rubotty::Adapters::Telegram::Adapter, "#community_member_count" do
  let(:http) { Fakes::TelegramHttp.new }
  let(:adapter) do
    described_class.new(
      account: "tg", settings: { token: "123:abc", transport: :long_polling, token_env: "TG_TOKEN" },
      dispatcher: Fakes::RecordingDispatcher.new, logger: Rubotty::Log.null, endpoints: []
    ).replace_client(Rubotty::Adapters::Telegram::ApiClient.new(token: "123:abc", http: http))
  end

  it "answers the Bot API's live count for a known chat" do
    http.on("getChatMemberCount", 340)

    expect(adapter.community_member_count("-1008000000001")).to eq(340)
  end

  it "answers nil rather than raise when the Bot API refuses the call" do
    http.error_on("getChatMemberCount", code: 400, description: "Bad Request: chat not found")

    expect(adapter.community_member_count("0")).to be_nil
  end
end
