# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Stoat::Adapter do
  let(:client) do
    StoatFakes::Client.new(
      users: {
        "u-ada" => { "username" => "ada", "display_name" => "Ada L",
                     "avatar" => { "_id" => "av1", "filename" => "a.png" } },
        # Nobody has to set an account display name, and most Stoat members never do.
        "u-nemo" => { "username" => "nemo" }
      }
    )
  end
  let(:gateway) { StoatFakes::Gateway.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  # Masquerade is the default; a second endpoint turns it off for the text prefix fallback.
  let(:general) do
    endpoint("st-general", adapter: :stoat, settings: { channel_id: "CHAN01" })
  end
  let(:plain) do
    endpoint("st-plain", adapter: :stoat,
                         settings: { channel_id: "CHAN02", masquerade: :off })
  end

  subject(:adapter) do
    described_class.new(
      account: "st",
      settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general, plain]
    ).replace_client(client).replace_gateway(gateway)
  end

  # Swaps in a fetcher whose transport is a plain lambda, so an attachment
  # "download" never touches the network. Mirrors how the Discord adapter
  # specs stub the same shared fetcher.
  def stub_fetcher(target, bytes)
    fetcher = Rubotty::Util::MediaFetcher.new(
      http: ->(_uri, _filename) { StringIO.new(bytes).tap { |io| io.define_singleton_method(:unlink) { nil } } }
    )
    target.instance_variable_set(:@fetcher, fetcher)
  end

  def fail_fetcher(target)
    fetcher = Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { nil })
    target.instance_variable_set(:@fetcher, fetcher)
  end

  describe "startup" do
    it "learns its own account id and starts the gateway" do
      adapter.start
      expect(adapter.own_account_id).to eq("bot-stoat")
      expect(gateway.started).to be(true)
      expect(adapter).to be_running
    end

    it "refuses to start if it cannot learn its own id, so loop prevention is safe" do
      allow(client).to receive(:own_id).and_return(nil)
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /loop prevention/)
    end

    it "converts an unexpected start failure into an AdapterError" do
      allow(client).to receive(:own_id).and_raise(RuntimeError.new("boom"))
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /failed to start.*boom/)
    end

    # One account is one bot token, so a missing one means "not yet connected"
    # rather than a fatal boot error.
    it "opts into graceful dormancy when its token is absent" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end

    # Runtime#build_adapters passes join_guard: and discovery: to every adapter,
    # and one that does not declare them raises ArgumentError at boot.
    it "accepts join_guard and discovery like every other adapter (issue #203)" do
      expect do
        described_class.new(
          account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [],
          join_guard: nil, discovery: nil
        )
      end.not_to raise_error
    end

    # An account mapped into zero rooms is how Stoat comes online before an
    # operator has mapped any of its channels.
    it "starts and runs with zero endpoints" do
      bare = described_class.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: []
      ).replace_client(client).replace_gateway(StoatFakes::Gateway.new)
      bare.start
      expect(bare).to be_running
    end
  end

  describe "capabilities" do
    it "reports reactions with no practical limit" do
      expect(adapter.capabilities.reactions?).to be(true)
      expect(adapter.capabilities.max_reactions).to be_nil
    end

    it "reports the moderation actions it can carry out" do
      # FEATURE_ACTIONS never reach adapter dispatch at all: Features::Moderation
      # carries them out itself. unpinall is a real capability and an optional
      # one, which Stoat's protocol has no bulk call for.
      expected = Rubotty::Core::Moderation::ACTIONS - Rubotty::Core::Moderation::FEATURE_ACTIONS - [:unpinall]
      expected.each do |action|
        expect(adapter.capabilities.moderates?(action)).to be(true)
      end
      expect(adapter.capabilities.moderates?(:unpinall)).to be(false)
    end
  end

  describe "inbound" do
    def event(**rest) = StoatFakes.message_event(channel: "CHAN01", **rest)

    it "converts a Message event into canonical form" do
      message = adapter.handle_event(event(id: "700", content: "hello"))
      expect(dispatcher.last).to eq(message)
      expect(message.origin.id).to eq("st-general")
      expect(message.body.text).to eq("hello")
      expect(message.ref.native_id).to eq("700")
    end

    it "resolves the author's name through the user resolver" do
      message = adapter.handle_event(event(author: "u-ada"))
      expect(message.author.username).to eq("ada")
      expect(message.author.display_name).to eq("Ada L")
      expect(message.author.avatar_url).to include("av1/a.png")
    end

    # A Stoat filename is whatever the uploader called it, so it can hold a
    # space or another character a URL cannot carry as-is. Handed straight
    # to a Discord or Fluxer webhook as avatar_url, an unescaped one could
    # make that platform's API refuse the send, reading as bot posting.
    it "builds an avatar url a target platform's webhook API will accept, even from an unsafe filename" do
      users = client.instance_variable_get(:@users)
      users["u-spacey"] = { "username" => "spacey",
                             "avatar" => { "_id" => "av2", "filename" => "my photo.png" } }

      message = adapter.handle_event(event(author: "u-spacey"))

      expect { URI.parse(message.author.avatar_url) }.not_to raise_error
      expect(message.author.avatar_url).not_to include(" ")
    end

    # Stoat keeps a per server nickname on the member and the chosen name on the
    # account, and shows the nickname where there is one.
    describe "the name a Stoat speaker relays under" do
      it "prefers the nickname from the member the Message event carries" do
        message = adapter.handle_event(
          event(author: "u-ada", member: { "nickname" => "Ada in SAMPLE" })
        )
        expect(message.author.display_name).to eq("Ada in SAMPLE")
        expect(message.author.nickname).to eq("Ada in SAMPLE")
      end

      it "falls back to the account display name when the member set no nickname" do
        message = adapter.handle_event(event(author: "u-ada", member: { "nickname" => nil }))
        expect(message.author.display_name).to eq("Ada L")
      end

      it "leaves the display name empty when the account never set one either" do
        message = adapter.handle_event(event(author: "u-nemo"))
        expect(message.author.display_name).to be_nil
      end

      # A Message event on a channel Stoat sends no member with still has to name
      # the speaker, so the member is looked up and then remembered.
      describe "when the event carries no member" do
        let(:client) do
          StoatFakes::Client.new(
            users: { "u-nemo" => { "username" => "nemo" } },
            members: { "SRV1/u-nemo" => { "nickname" => "Nemo in SAMPLE" } }
          )
        end
        let(:in_server) do
          endpoint("st-server", adapter: :stoat,
                                settings: { channel_id: "CHAN03", server_id: "SRV1" })
        end

        subject(:adapter) do
          described_class.new(
            account: "st",
            settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
            dispatcher: dispatcher,
            logger: Rubotty::Log.null,
            endpoints: [in_server]
          ).replace_client(client).replace_gateway(gateway)
        end

        it "looks the member up through the channel's server" do
          message = adapter.handle_event(StoatFakes.message_event(channel: "CHAN03", author: "u-nemo"))
          expect(message.author.display_name).to eq("Nemo in SAMPLE")
        end

        it "looks a member up once and remembers the answer" do
          2.times { adapter.handle_event(StoatFakes.message_event(channel: "CHAN03", author: "u-nemo")) }
          expect(client.fetched_members).to eq(["SRV1/u-nemo"])
        end
      end
    end

    it "parses Stoat markdown into canonical spans" do
      message = adapter.handle_event(event(content: "a **bold** word"))
      expect(message.body.text).to eq("a bold word")
      expect(message.body.spans.map(&:kind)).to eq([:bold])
    end

    it "captures attachments with their CDN URLs" do
      file = { "_id" => "f1", "filename" => "a.png", "content_type" => "image/png",
               "metadata" => { "type" => "Image" } }
      message = adapter.handle_event(event(attachments: [file]))
      captured = message.attachments.first
      expect(captured.kind).to eq(:photo)
      expect(captured.url).to include("attachments/f1/a.png")
    end

    it "records the parent of a reply so the router can translate it" do
      message = adapter.handle_event(event(replies: ["600"]))
      expect(message.reply_to).to eq(ref("st-general", "600"))
    end

    it "relays a genuine edit and ignores an update that changed no content" do
      edited = adapter.handle_event(
        "type" => "MessageUpdate", "id" => "700", "channel" => "CHAN01",
        "data" => { "content" => "fixed" }
      )
      expect(edited.kind).to eq(:edit)
      expect(edited.body.text).to eq("fixed")

      noise = adapter.handle_event(
        "type" => "MessageUpdate", "id" => "700", "channel" => "CHAN01", "data" => {}
      )
      expect(noise).to be_nil
    end

    it "turns a MessageDelete into a delete message" do
      message = adapter.handle_event("type" => "MessageDelete", "id" => "700", "channel" => "CHAN01")
      expect(message.kind).to eq(:delete)
      expect(message.ref).to eq(ref("st-general", "700"))
    end

    # Clearing a raid fires BulkMessageDelete, declared in
    # crates/core/database/src/events/client.rs. Nothing handled it, so the
    # moderator got the opposite of what they asked for: the messages went
    # from Stoat and every mirrored copy stayed up.
    it "turns a BulkMessageDelete into one delete per id" do
      produced = adapter.handle_event(
        "type" => "BulkMessageDelete", "channel" => "CHAN01", "ids" => %w[700 701 702]
      )
      expect(produced.map(&:kind)).to eq(%i[delete delete delete])
      expect(dispatcher.messages.map { |message| message.ref.native_id }).to eq(%w[700 701 702])
    end

    it "ignores a bulk delete in a channel it has no endpoint for" do
      expect(adapter.handle_event("type" => "BulkMessageDelete", "channel" => "UNKNOWN", "ids" => %w[700]))
        .to be_empty
      expect(dispatcher.messages).to be_empty
    end

    it "turns a reaction into a reaction event" do
      message = adapter.handle_event(
        "type" => "MessageReact", "id" => "700", "channel_id" => "CHAN01",
        "user_id" => "u-ada", "emoji_id" => "👍"
      )
      expect(message.kind).to eq(:reaction_add)
      expect(message.reaction.emoji).to eq("👍")
    end

    it "recognises a custom (ULID) emoji as a custom reaction" do
      message = adapter.handle_event(
        "type" => "MessageReact", "id" => "700", "channel_id" => "CHAN01",
        "user_id" => "u-ada", "emoji_id" => "01F0Q2X3Y4Z5A6B7C8D9E0F1G2"
      )
      expect(message.reaction).to be_custom
    end

    # Bonfire's MessageRemoveReaction fires when an author or moderator
    # clears every instance of one emoji, and it carries no user_id.
    it "turns a MessageRemoveReaction into a reaction_clear naming that emoji, and no author" do
      message = adapter.handle_event(
        "type" => "MessageRemoveReaction", "id" => "700", "channel_id" => "CHAN01", "emoji_id" => "👍"
      )
      expect(message.kind).to eq(:reaction_clear)
      expect(message.reaction.emoji).to eq("👍")
      expect(message.author.native_id).to be_nil
    end

    it "ignores a channel it has no endpoint for" do
      expect(adapter.handle_event(StoatFakes.message_event(channel: "UNKNOWN"))).to be_nil
    end

    # The Bulk envelope wraps several events into one frame; before this every
    # event inside it fell out of the dispatch switch untouched.
    it "unpacks a Bulk envelope, processing each event inside it" do
      messages = adapter.handle_event(
        StoatFakes.bulk_event(event(id: "701", content: "one"), event(id: "702", content: "two"))
      )
      expect(messages.map { |m| m.body.text }).to eq(%w[one two])
      expect(dispatcher.messages.map(&:ref)).to eq(messages.map(&:ref))
    end
  end

  # Bonfire sends both of these from crates/bonfire/src/websocket.rs and both
  # used to fall out of the dispatch case, so a refused or reset token left the
  # adapter reconnecting in silence while still reporting itself as running.
  describe "a session the server ends" do
    let(:sink) { StringIO.new }

    subject(:adapter) do
      described_class.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.build(level: "warn", io: sink),
        endpoints: [general, plain]
      ).replace_client(client).replace_gateway(gateway)
    end

    before { adapter.start }

    it "names the token env var when the handshake is refused outright" do
      adapter.handle_event("type" => "Error", "error" => "InvalidSession")
      expect(sink.string).to include("InvalidSession")
      expect(sink.string).to include("STOAT_BOT_TOKEN")
    end

    it "says the token was reset when the session is invalidated" do
      adapter.handle_event("type" => "Logout")
      expect(sink.string).to include("reset or revoked")
    end

    it "stops reporting itself as running, so /health shows the deafness" do
      expect(adapter).to be_running
      adapter.handle_event("type" => "Logout")
      expect(gateway.refusals).to eq(["Logout"])
      expect(adapter).not_to be_running
    end

    it "relays nothing to the dispatcher for either frame" do
      adapter.handle_event("type" => "Error", "error" => "InvalidSession")
      adapter.handle_event("type" => "Logout")
      expect(dispatcher.messages).to be_empty
    end
  end

  # ServerMemberJoin and ServerMemberLeave name no channel, only the server,
  # so the message fans out to every bridged channel of it.
  describe "membership" do
    def learn_general
      adapter.handle_event(
        StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN01", server: "SRV1", name: "general"))
      )
    end

    it "produces a :join Core::Message for each bridged channel of the server" do
      learn_general
      messages = adapter.handle_event(StoatFakes.member_event(type: "ServerMemberJoin", server: "SRV1", user: "u-ada"))
      expect(messages.map(&:kind)).to eq([:join])
      expect(messages.first.origin.id).to eq("st-general")
      expect(dispatcher.last).to eq(messages.first)
    end

    it "produces a :leave Core::Message the same way" do
      learn_general
      messages = adapter.handle_event(StoatFakes.member_event(type: "ServerMemberLeave", server: "SRV1", user: "u-ada"))
      expect(messages.map(&:kind)).to eq([:leave])
    end

    it "names the member from the member object the join carries" do
      learn_general
      messages = adapter.handle_event(
        StoatFakes.member_event(type: "ServerMemberJoin", server: "SRV1", user: "u-ada",
                                member: { "nickname" => "Ada in SAMPLE" })
      )
      expect(messages.first.author.display_name).to eq("Ada in SAMPLE")
    end

    it "produces nothing for a server with no bridged channel" do
      event = StoatFakes.member_event(type: "ServerMemberJoin", server: "SRV-UNKNOWN", user: "u-ada")
      messages = adapter.handle_event(event)
      expect(messages).to eq([])
    end
  end

  # ControlPlane::GuildResolver's hook: what lets a seeded connection's sentinel
  # resolve, the same way Discord's guild_id_for_channel already does.
  describe "#guild_id_for_channel" do
    it "answers from the cache once a channel's server is known" do
      adapter.handle_event(
        StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN01", server: "SRV1", name: "general"))
      )
      expect(adapter.guild_id_for_channel("CHAN01")).to eq("SRV1")
    end

    it "falls back to a fetch for a channel this boot has not seen yet" do
      fetching_client = StoatFakes::Client.new(
        channels: { "CHAN50" => StoatFakes.channel(id: "CHAN50", server: "SRV9", name: "welcome") }
      )
      fetching = described_class.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: []
      ).replace_client(fetching_client)

      expect(fetching.guild_id_for_channel("CHAN50")).to eq("SRV9")
      expect(fetching_client.fetched_channels).to eq(["CHAN50"])
    end

    it "answers nil for a channel it cannot see" do
      expect(adapter.guild_id_for_channel("UNKNOWN")).to be_nil
    end
  end

  describe "outbound with masquerade (the default)" do
    let(:label) do
      Rubotty::Core::SenderLabel.new(username: "ada", platform: "telegram", display_name: "Ada L")
    end
    let(:author) { Rubotty::Core::Author.new(username: "ada", avatar_url: "https://cdn.example/a.png") }
    let(:outgoing) do
      message(general, text: "hello", author: author).with(sender_label: label)
    end

    it "posts under the sender's masquerade name and avatar, with no text prefix" do
      receipt = adapter.deliver(outgoing, general)
      body = client.sent.first[:body]
      expect(body[:masquerade][:name]).to eq(label.to_s)
      expect(body[:masquerade][:avatar]).to eq("https://cdn.example/a.png")
      expect(body[:content]).to eq("hello")
      expect(receipt.native_id).to eq("sent-1")
    end

    it "carries a nonce for idempotency" do
      adapter.deliver(outgoing, general)
      expect(client.sent.first[:body][:nonce]).to eq(outgoing.correlation_id)
    end

    # A Telegram file URL embeds the bot token, so it is never fit to post as a
    # link; the fix is fetching the bytes ourselves and uploading them, so the
    # token stays on this side and never reaches the room either way.
    it "downloads and uploads a credentialed source URL rather than relaying it as a link" do
      stub_fetcher(adapter, "PHOTOBYTES")
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/photos/a.jpg", filename: "a.jpg"
      )
      adapter.deliver(outgoing.with(attachments: [leaky]), general)
      body = client.sent.first[:body]
      expect(body[:content]).not_to include("bot123:AAsecret")
      expect(body[:content]).not_to include("could not be relayed")
      expect(body[:attachments]).to eq([client.upload_result])
      expect(client.uploads.first[:bytes]).to eq("PHOTOBYTES")
    end

    it "uploads a public attachment too, rather than only linking it" do
      stub_fetcher(adapter, "PNGDATA")
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      adapter.deliver(outgoing.with(attachments: [photo]), general)
      expect(client.sent.first[:body][:attachments]).to eq([client.upload_result])
    end

    it "falls back to a link when the upload cannot happen and the source URL is safe to show" do
      fail_fetcher(adapter)
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      adapter.deliver(outgoing.with(attachments: [photo]), general)
      body = client.sent.first[:body]
      expect(body[:content]).to include("https://cdn.example/a.png")
      expect(body[:attachments]).to be_nil
    end

    it "falls back to a marker, never the link, when the upload of a credentialed URL fails" do
      fail_fetcher(adapter)
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/photos/a.jpg", filename: "a.jpg"
      )
      adapter.deliver(outgoing.with(attachments: [leaky]), general)
      content = client.sent.first[:body][:content]
      expect(content).not_to include("bot123:AAsecret")
      expect(content).to include("could not be relayed")
    end

    it "tells the router about a file that could not be relayed" do
      fail_fetcher(adapter)
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      receipt = adapter.deliver(outgoing.with(attachments: [photo]), general)
      expect(receipt.extra[:notes].join).to include("could not relay a.png to Stoat")
    end

    it "attaches a native reply when the parent lives on this endpoint" do
      local = outgoing.with(reply_to: ref("st-general", "600"))
      adapter.deliver(local, general)
      expect(client.sent.first[:body][:replies]).to eq([{ id: "600", mention: false }])
    end

    it "quotes the parent when a native reply is impossible" do
      preview = Rubotty::Core::ReplyPreview.new(
        body: Rubotty::Core::RichText.plain("the original"), label: "Grace"
      )
      foreign = outgoing.with(reply_to: ref("tg-general", "42"), reply_preview: preview)
      adapter.deliver(foreign, general)
      body = client.sent.first[:body]
      expect(body[:content]).to start_with("> **Grace**: the original")
      expect(body[:replies]).to be_nil
    end

    it "truncates content past Stoat's limit" do
      long = message(general, text: "x" * 3000, author: author).with(sender_label: label)
      adapter.deliver(long, general)
      expect(client.sent.first[:body][:content].length).to be <= 2000
    end
  end

  # message_send.rs runs throw_if_lacking_channel_permission for Masquerade
  # whenever the field is present, and refuses the whole send with a 403. That
  # became abandoned in Bridge, so a channel missing the one permission relayed
  # nothing at all, forever, with nothing but an error line to say why.
  describe "a channel where Stoat refuses the masquerade" do
    let(:label) do
      Rubotty::Core::SenderLabel.new(username: "ada", platform: "telegram", display_name: "Ada L")
    end
    let(:outgoing) { message(general, text: "hello").with(sender_label: label) }

    before { client.refuse_masquerade! }

    it "still delivers the message, under a sender name prefix" do
      receipt = adapter.deliver(outgoing, general)
      body = client.sent.first[:body]
      expect(receipt.native_id).to eq("sent-1")
      expect(body[:masquerade]).to be_nil
      expect(body[:content]).to include("Ada L")
      expect(body[:content]).to include("hello")
    end

    it "stops offering the field at all, so the channel costs one refusal and not one per message" do
      3.times { adapter.deliver(outgoing, general) }
      expect(client.sent.size).to eq(3)
      expect(client.sent.map { |sent| sent[:body][:masquerade] }).to all(be_nil)
    end

    it "says what happened and how to fix it, once" do
      sink = StringIO.new
      talkative = described_class.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.build(level: "warn", io: sink),
        endpoints: [general, plain]
      ).replace_client(client).replace_gateway(StoatFakes::Gateway.new)

      2.times { talkative.deliver(outgoing, general) }
      lines = sink.string.lines.grep(/refused a masquerade/)
      expect(lines.size).to eq(1)
      expect(lines.first).to include("Masquerade permission")
    end

    # A channel the bot cannot post in at all still has to report the refusal,
    # rather than being retried forever under a fallback that cannot work.
    it "still raises a refusal that has nothing to do with the masquerade" do
      out = message(plain, text: "hello").with(sender_label: "Ada")
      allow(client).to receive(:send_message)
        .and_raise(Rubotty::PermissionError.new("Stoat refused POST (403): MissingPermission", adapter: :stoat))
      expect { adapter.deliver(out, plain) }.to raise_error(Rubotty::PermissionError)
    end

    # A channel missing SendMessage entirely still hits the masquerade
    # attempt first, so the same PermissionError this rescue catches for a
    # real masquerade refusal arrives here too. Blaming it on masquerade
    # would retry under a fallback that cannot fix a permission the retry never touches.
    describe "a channel missing SendMessage rather than Masquerade" do
      before { client.refuse_send_message! }

      it "raises rather than retrying under the masquerade-refused fallback" do
        expect { adapter.deliver(outgoing, general) }.to raise_error(Rubotty::PermissionError, /SendMessage/)
      end

      it "does not mark masquerade as refused, so a later SendMessage grant is not left orphaned" do
        expect { adapter.deliver(outgoing, general) }.to raise_error(Rubotty::PermissionError)
        expect(adapter.masquerade_refused?(general)).to be(false)
      end
    end
  end

  describe "outbound without masquerade" do
    it "prefixes the sender name into the text instead" do
      out = message(plain, text: "hello").with(sender_label: "Ada")
      adapter.deliver(out, plain)
      body = client.sent.first[:body]
      expect(body[:masquerade]).to be_nil
      expect(body[:content]).to start_with("**Ada")
    end
  end

  # No sender prefix, no attachments: nothing worth posting, a routine
  # decline rather than an attempted send that came back empty.
  describe "outbound with nothing to say" do
    it "signals the decline as NOT_APPLICABLE rather than a bare nil" do
      blank = message(general, text: "")
      receipt = adapter.deliver(blank, general)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
      expect(client.sent).to be_empty
    end
  end

  describe "system notices" do
    it "always post as the bot, never under a masquerade" do
      notice = Rubotty::Core::Message.new(
        kind: :system,
        ref: Rubotty::Core::MessageRef.new("st-general", "n1"),
        origin: general,
        author: Rubotty::Core::Author.new(kind: :system),
        body: Rubotty::Core::RichText.plain("Bridge started."),
        sender_label: "bridge"
      )
      adapter.deliver(notice, general)
      expect(client.sent.first[:body][:masquerade]).to be_nil
      expect(client.sent.first[:body][:content]).to eq("Bridge started.")
    end
  end

  describe "edit and delete" do
    let(:outgoing) { message(general, text: "hello").with(sender_label: "Ada") }

    it "edits a message in place" do
      adapter.edit(outgoing.with(body: Rubotty::Core::RichText.plain("fixed")), general, "900")
      edit = client.edited.first
      expect(edit[:id]).to eq("900")
      expect(edit[:body][:content]).to include("fixed")
    end

    it "deletes a message" do
      adapter.delete(general, "900")
      expect(client.deleted.first[:id]).to eq("900")
    end

    it "treats a late edit or delete of a gone message as success" do
      allow(client).to receive(:delete_message)
        .and_raise(Rubotty::AdapterError.new("Stoat DELETE failed (404): NotFound", adapter: :stoat))
      expect { adapter.delete(general, "gone") }.not_to raise_error
    end
  end

  describe "reactions" do
    let(:thumbs) { Rubotty::Core::Reaction.new(emoji: "👍") }
    let(:party) { Rubotty::Core::Reaction.new(emoji: "🎉") }

    it "adds newly desired reactions and removes those no longer desired" do
      adapter.sync_reactions(general, "900", desired: [thumbs, party], previous: [])
      expect(client.reactions_added.map { |r| r[:emoji] }).to eq(%w[👍 🎉])

      adapter.sync_reactions(general, "900", desired: [party], previous: [thumbs, party])
      expect(client.reactions_removed.map { |r| r[:emoji] }).to eq(["👍"])
    end

    it "skips a foreign custom emoji that Stoat has no equivalent for" do
      custom = Rubotty::Core::Reaction.new(custom_id: "999", custom_name: "parrot")
      adapter.sync_reactions(general, "900", desired: [custom], previous: [])
      expect(client.reactions_added).to be_empty
    end

    # Swallowing these left the bridge recording the mirror as placed, and
    # storage then holds an emoji the message does not have, with nothing that
    # ever reconciles the two.
    it "lets a refused add out, rather than reporting an emoji it did not place" do
      allow(client).to receive(:add_reaction)
        .and_raise(Rubotty::PermissionError.new("Stoat PUT failed (403): Forbidden", adapter: :stoat))
      expect { adapter.sync_reactions(general, "900", desired: [thumbs], previous: []) }
        .to raise_error(Rubotty::PermissionError)
    end

    it "lets a rate limited remove out too" do
      allow(client).to receive(:remove_own_reaction)
        .and_raise(Rubotty::RateLimitedError.new("Stoat DELETE failed (429): Too Many Requests",
                                                 adapter: :stoat))
      expect { adapter.sync_reactions(general, "900", desired: [], previous: [thumbs]) }
        .to raise_error(Rubotty::RateLimitedError)
    end

    it "still treats a reaction on a message that is already gone as done" do
      allow(client).to receive(:add_reaction)
        .and_raise(Rubotty::AdapterError.new("Stoat PUT failed (404): NotFound", adapter: :stoat))
      expect { adapter.sync_reactions(general, "900", desired: [thumbs], previous: []) }
        .not_to raise_error
    end
  end

  describe "moderation" do
    def command(action)
      Rubotty::Core::Moderation::Command.new(
        action: action,
        issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general,
        target_user_id: "u-bad"
      )
    end

    let(:server_endpoint) do
      endpoint("st-mod", adapter: :stoat, settings: { channel_id: "CHAN01", server_id: "SRV1" })
    end

    it "deletes the target message and reports success" do
      result = adapter.moderate(command(:delete), general, "900")
      expect(result.status).to eq(:done)
      expect(client.deleted.first[:id]).to eq("900")
    end

    it "bans a member through the configured server" do
      result = adapter.moderate(command(:ban), server_endpoint, nil)
      expect(result.status).to eq(:done)
      expect(client.bans.first).to include(server: "SRV1", user: "u-bad")
    end

    it "kicks a member" do
      result = adapter.moderate(command(:kick), server_endpoint, nil)
      expect(result.status).to eq(:done)
      expect(client.kicks.first).to include(server: "SRV1", user: "u-bad")
    end

    it "reports a ban with no configured server as failed rather than raising" do
      expect(adapter.moderate(command(:ban), general, nil).status).to eq(:failed)
    end

    it "reports an action outside its vocabulary as unsupported" do
      expect(adapter.moderate(command(:warn), general, nil).status).to eq(:unsupported)
    end

    it "mutes a member through the configured server" do
      result = adapter.moderate(command(:mute), server_endpoint, nil)
      expect(result.status).to eq(:done)
      timeout = client.timeouts.first
      expect(timeout).to include(server: "SRV1", user: "u-bad")
      expect(Time.parse(timeout[:until])).to be_within(5).of(Time.now.utc + (60 * 60))
    end

    it "unmutes a member through the configured server" do
      result = adapter.moderate(command(:unmute), server_endpoint, nil)
      expect(result.status).to eq(:done)
      expect(client.timeout_clears.first).to include(server: "SRV1", user: "u-bad")
    end

    it "pins the target message" do
      result = adapter.moderate(command(:pin), general, "900")
      expect(result.status).to eq(:done)
      expect(client.pins.first).to eq(channel: "CHAN01", id: "900")
    end

    it "unpins the target message" do
      result = adapter.moderate(command(:unpin), general, "900")
      expect(result.status).to eq(:done)
      expect(client.unpins.first).to eq(channel: "CHAN01", id: "900")
    end

    it "reports a mute with no configured server as failed rather than raising" do
      expect(adapter.moderate(command(:mute), general, nil).status).to eq(:failed)
    end
  end

  # Against the real ChannelDiscovery and NewChannelWatch over the seeded SAMPLE
  # control plane, which carries no Stoat connection, so one is created here.
  describe "channel discovery (issue #203)", :control_plane do
    let(:seeded) { seeded_sample }
    let(:models) { seeded[1] }
    let(:community) { models.community.first }

    let!(:stoat_connection) do
      now = Time.now
      models.platform_connection.create(
        community_id: community.id, adapter: "stoat", account: "st",
        external_id: "SRV1", created_at: now, updated_at: now
      )
    end

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

    def build_adapter(client: StoatFakes::Client.new, endpoints: [], discovery_seam: discovery, pending_spaces: nil)
      described_class.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: endpoints,
        discovery: discovery_seam, pending_spaces: pending_spaces
      ).replace_client(client)
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

    describe "Ready (the bulk sweep, #38)" do
      it "records every text channel of a known server, skipping a voice channel" do
        ready = StoatFakes.ready_event(
          servers: [StoatFakes.server(id: "SRV1", name: "SAMPLE", channels: %w[CHAN01 CHAN02 VOICE01])],
          channels: [
            StoatFakes.channel(id: "CHAN01", server: "SRV1", name: "general"),
            StoatFakes.channel(id: "CHAN02", server: "SRV1", name: "off-topic"),
            StoatFakes.channel(id: "VOICE01", server: "SRV1", name: "Hangout", channel_type: "VoiceChannel")
          ]
        )
        build_adapter.handle_event(ready)

        rows = models.channel.where(adapter: "stoat").all
        expect(rows.map(&:route_key)).to contain_exactly("CHAN01", "CHAN02")
        general = rows.find { |r| r.route_key == "CHAN01" }
        expect(general.label).to eq("general")
        # The addressing a discovered row needs to project to a working endpoint once mapped.
        expect(general.json_value(:settings)).to eq("channel_id" => "CHAN01")
        # Dormant: recorded but in no room, so nothing bridges until mapped.
        expect(models.room_channel.where(channel_id: general.id).count).to eq(0)
      end

      it "does nothing for a server no connection owns" do
        ready = StoatFakes.ready_event(
          servers: [StoatFakes.server(id: "SRV-STRANGER", name: "Elsewhere", channels: %w[CHAN99])],
          channels: [StoatFakes.channel(id: "CHAN99", server: "SRV-STRANGER", name: "general")]
        )
        build_adapter.handle_event(ready)
        expect(models.channel.where(route_key: "CHAN99").first).to be_nil
      end

      it "does not raise, and routes no message, without a discovery seam wired" do
        plain = build_adapter(discovery_seam: nil)
        expect { plain.handle_event(StoatFakes.ready_event) }.not_to raise_error
        expect(dispatcher.messages).to be_empty
      end
    end

    describe "ServerCreate (a newly joined server, #38)" do
      it "fetches each of the server's channels by id and records the text ones" do
        client = StoatFakes::Client.new(
          channels: {
            "CHAN10" => StoatFakes.channel(id: "CHAN10", server: "SRV1", name: "welcome"),
            "VOICE10" => StoatFakes.channel(id: "VOICE10", server: "SRV1", name: "Hangout",
                                            channel_type: "VoiceChannel")
          }
        )
        build_adapter(client: client).handle_event(
          StoatFakes.server_create_event(StoatFakes.server(id: "SRV1", name: "SAMPLE", channels: %w[CHAN10 VOICE10]))
        )

        expect(client.fetched_channels).to eq(%w[CHAN10 VOICE10])
        row = models.channel.where(adapter: "stoat", route_key: "CHAN10").first
        expect(row.label).to eq("welcome")
        expect(models.channel.where(route_key: "VOICE10").first).to be_nil
      end
    end

    # The first listing of a server happens while its space is still pending, so
    # it has no platform connection and is dropped; approval asks again here.
    describe "re-enumerating one server on demand (issue #584)" do
      let(:client) do
        StoatFakes::Client.new(
          channels: {
            "CHAN01" => StoatFakes.channel(id: "CHAN01", server: "SRV1", name: "general"),
            "CHAN02" => StoatFakes.channel(id: "CHAN02", server: "SRV1", name: "off-topic")
          }
        )
      end

      let(:ready) do
        StoatFakes.ready_event(
          servers: [StoatFakes.server(id: "SRV1", name: "SAMPLE", channels: %w[CHAN01 CHAN02])],
          channels: [
            StoatFakes.channel(id: "CHAN01", server: "SRV1", name: "general"),
            StoatFakes.channel(id: "CHAN02", server: "SRV1", name: "off-topic")
          ]
        )
      end

      it "declares the seam the approval flow reaches for" do
        expect(build_adapter(client: client).supports_space_enumeration?).to be(true)
      end

      it "records the server's channels again, from the ids Ready already told it" do
        adapter = build_adapter(client: client)
        adapter.handle_event(ready)
        models.channel.where(adapter: "stoat").delete

        expect(adapter.enumerate_space("SRV1")).to be(true)

        expect(models.channel.where(adapter: "stoat").order(:route_key).map(&:route_key))
          .to eq(%w[CHAN01 CHAN02])
      end

      it "answers false for a server it was never told the channels of" do
        expect(build_adapter(client: client).enumerate_space("SRV-UNKNOWN")).to be(false)
      end

      it "refuses a blank server id" do
        expect(build_adapter(client: client).enumerate_space("")).to be(false)
      end
    end

    describe "ChannelCreate (a new channel in a known server, #39)" do
      it "prompts and records in a community that opted in" do
        enable_alerts
        build_adapter.handle_event(
          StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN20", server: "SRV1", name: "fresh-channel"))
        )
        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["CHAN20"])
        expect(models.channel.where(route_key: "CHAN20").count).to eq(1)
      end

      it "prompts by default, without an explicit opt-in" do
        build_adapter.handle_event(
          StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN21", server: "SRV1", name: "fresh-channel"))
        )
        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["CHAN21"])
      end

      it "learns nothing once a community explicitly opts out" do
        disable_alerts
        build_adapter.handle_event(
          StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN22", server: "SRV1", name: "fresh-channel"))
        )
        expect(notifier.prompts).to be_empty
        expect(models.channel.where(route_key: "CHAN22").first).to be_nil
      end

      it "ignores a channel that is not a server text channel" do
        enable_alerts
        build_adapter.handle_event(
          StoatFakes.channel_create_event(
            StoatFakes.channel(id: "VOICE20", server: "SRV1", name: "Hangout", channel_type: "VoiceChannel")
          )
        )
        expect(notifier.prompts).to be_empty
      end
    end

    # The passive path is a fallback for a channel whose ChannelCreate was
    # missed; it names a channel's server from the cache Ready, ServerCreate and
    # ChannelCreate populate.
    describe "a live message (the passive fallback, #39)" do
      it "records a sighting once the channel's server is known from Ready" do
        enable_alerts
        adapter = build_adapter
        # CHAN30 is absent from SRV1's own channel list, so only Ready's full
        # `channels` array teaches the cache its server.
        adapter.handle_event(StoatFakes.ready_event(
                                servers: [StoatFakes.server(id: "SRV1", name: "SAMPLE", channels: [])],
                                channels: [StoatFakes.channel(id: "CHAN30", server: "SRV1", name: "quiet")]
                              ))

        adapter.handle_event(StoatFakes.message_event(channel: "CHAN30"))

        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["CHAN30"])
      end

      it "skips a channel whose server is not yet known, rather than guessing" do
        enable_alerts
        build_adapter.handle_event(StoatFakes.message_event(channel: "CHAN99"))
        expect(notifier.prompts).to be_empty
        expect(models.channel.where(route_key: "CHAN99").first).to be_nil
      end

      it "still relays the message normally alongside the passive sighting" do
        mapped = endpoint("st-general", adapter: :stoat, settings: { channel_id: "CHAN01" })
        adapter = build_adapter(endpoints: [mapped])
        message = adapter.handle_event(StoatFakes.message_event(channel: "CHAN01", content: "hi"))
        expect(message.body.text).to eq("hi")
        expect(dispatcher.last).to eq(message)
      end
    end

    # A permission change wraps the ChannelCreate it produces in a Bulk
    # envelope; before this the whole frame fell out of the dispatch switch
    # untouched and the channel was never discovered.
    describe "a ChannelCreate wrapped in a Bulk envelope" do
      it "still prompts and records the channel" do
        enable_alerts
        build_adapter.handle_event(
          StoatFakes.bulk_event(
            StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN40", server: "SRV1", name: "fresh-channel"))
          )
        )
        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["CHAN40"])
        expect(models.channel.where(route_key: "CHAN40").count).to eq(1)
      end
    end

    # The channel-to-server map is written from the gateway thread and read
    # by enumerate_space off the durable scheduler's own thread; a plain
    # example passes whether or not the two are locked against each other.
    describe "@channel_servers under concurrent access" do
      # The deterministic half: a plain example passes whether or not the
      # gateway-thread write and the scheduler-thread read of the same hash
      # are actually locked against each other, so this checks the lock is
      # really taken rather than timing a race.
      it "takes @cache_monitor around both the ChannelCreate write and enumerate_space's read" do
        adapter = build_adapter(
          client: StoatFakes::Client.new(channels: { "CHAN01" => StoatFakes.channel(id: "CHAN01", server: "SRV1",
                                                                                     name: "general") })
        )
        monitor = adapter.instance_variable_get(:@cache_monitor)
        expect(monitor).to receive(:synchronize).at_least(:twice).and_call_original

        adapter.handle_event(StoatFakes.channel_create_event(StoatFakes.channel(id: "CHAN01", server: "SRV1",
                                                                                 name: "general")))
        adapter.enumerate_space("SRV1")
      end

      # The stress half: a write hammering the gateway thread's path while
      # enumerate_space repeatedly iterates off another, so a lock that only
      # sometimes engages still gets exercised.
      it "does not raise, and enumerates every channel, when a write lands during enumerate_space's iteration" do
        channels = (1..300).to_h do |i|
          ["CHAN#{i}", StoatFakes.channel(id: "CHAN#{i}", server: "SRV1", name: "c#{i}")]
        end
        adapter = build_adapter(client: StoatFakes::Client.new(channels: channels))
        errors = Queue.new

        writer = Thread.new do
          1.upto(300) do |i|
            adapter.handle_event(StoatFakes.channel_create_event(channels["CHAN#{i}"]))
          rescue StandardError => e
            errors << e
          end
        end
        reader = Thread.new do
          40.times do
            adapter.enumerate_space("SRV1")
          rescue StandardError => e
            errors << e
          end
        end
        [writer, reader].each(&:join)

        expect(errors).to be_empty
        adapter.enumerate_space("SRV1")
        expect(models.channel.where(adapter: "stoat").count).to eq(300)
      end
    end

    # Stoat never pended a space at all; #initialize did not even accept
    # pending_spaces:, so Runtime#accepts_pending_spaces? declined to hand it
    # one.
    describe "pending review on a newly joined server" do
      let(:authorization) { Rubotty::ControlPlane::AuthorizationDirectory.new(models: models) }
      let(:pending_spaces) { Rubotty::ControlPlane::PendingSpaces.new(models: models, authorization: authorization) }

      it "accepts pending_spaces, so Runtime hands it the shared service" do
        params = described_class.instance_method(:initialize).parameters
        expect(params).to include([:key, :pending_spaces])
      end

      it "pends a server nothing maps yet, and posts the notice into one of its channels" do
        client = StoatFakes::Client.new(
          channels: { "CHAN01" => StoatFakes.channel(id: "CHAN01", server: "SRV-NEW", name: "general") }
        )
        adapter = build_adapter(client: client, pending_spaces: pending_spaces)

        adapter.handle_event(
          StoatFakes.server_create_event(StoatFakes.server(id: "SRV-NEW", name: "New Server", channels: %w[CHAN01]))
        )

        row = models.pending_space.where(adapter: "stoat", external_id: "SRV-NEW").first
        expect(row).not_to be_nil
        expect(row.state).to eq("pending")
        expect(row.notice_posted_at).not_to be_nil
        expect(client.sent.first).to eq(
          channel: "CHAN01", body: { content: Rubotty::ControlPlane::PendingSpaces::PENDING_NOTICE }
        )
      end

      it "never pends a server a connection already maps to a community" do
        adapter = build_adapter(pending_spaces: pending_spaces)
        adapter.handle_event(StoatFakes.server_create_event(StoatFakes.server(id: "SRV1", name: "SAMPLE", channels: [])))

        expect(models.pending_space.where(adapter: "stoat", external_id: "SRV1").first).to be_nil
      end
    end
  end

  # Stoat needs a DM channel opened first, then posts to it like any other
  # channel; deleting one is the ordinary channel-message delete.
  describe "direct messages to an operator" do
    it "says it can send and delete, so the callers that check first will use it" do
      expect(adapter.supports_admin_dm?).to be(true)
      expect(adapter.supports_admin_dm_delete?).to be(true)
    end

    it "opens the DM channel, sends the message, and hands back a receipt" do
      receipt = adapter.send_admin_dm("u-ada", "a room needs you")

      expect(client.dms_opened).to eq(["u-ada"])
      expect(client.sent.first).to eq(channel: "dm-channel-u-ada", body: { content: "a room needs you" })
      expect(receipt).to be_a(Rubotty::Core::DmReceipt)
      expect(receipt.native_id).not_to be_empty
      expect(receipt.channel_ref).to eq("dm-channel-u-ada")
    end

    it "sends nothing for an empty message" do
      expect(adapter.send_admin_dm("u-ada", "   ")).to be_nil
      expect(client.dms_opened).to be_empty
    end

    it "answers nil rather than raising when Stoat refuses to open the DM" do
      allow(client).to receive(:open_dm)
        .and_raise(Rubotty::AdapterError.new("Stoat POST failed (403): Forbidden", adapter: :stoat))

      expect { expect(adapter.send_admin_dm("u-ada", "hi")).to be_nil }.not_to raise_error
    end

    it "deletes the message the receipt points at" do
      receipt = adapter.send_admin_dm("u-ada", "a room needs you")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
      expect(client.deleted).to include(channel: "dm-channel-u-ada", id: receipt.native_id)
    end

    it "treats a late delete of a gone message as success" do
      allow(client).to receive(:delete_message)
        .and_raise(Rubotty::AdapterError.new("Stoat DELETE failed (404): NotFound", adapter: :stoat))
      receipt = Rubotty::Core::DmReceipt.new(native_id: "1", channel_ref: "dm-channel-u-ada")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
    end

    it "is falsy for a receipt with nothing to delete" do
      expect(adapter.delete_admin_dm(nil)).to be(false)
    end
  end

  # A DM to the bot arrives as an ordinary Message with no endpoint, so it was
  # dropped with nothing in the log; control_lane was taken but never called.
  describe "the operator console reached by DM" do
    let(:control_lane) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def handle_dm(**kwargs)
          @calls << kwargs
          "reply text"
        end
      end.new
    end

    subject(:adapter) do
      described_class.new(
        account: "st", settings: { token: "t", token_env: "STOAT_BOT_TOKEN" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general],
        control_lane: control_lane
      ).replace_client(client).replace_gateway(gateway)
    end

    before do
      client.instance_variable_get(:@channels)["dm-chan"] = { "_id" => "dm-chan", "channel_type" => "DirectMessage" }
      adapter.start
    end

    it "hands an inbound DM to the console and posts its reply" do
      result = adapter.handle_event(
        "type" => "Message", "_id" => "m1", "channel" => "dm-chan", "author" => "u-ada", "content" => "/help"
      )
      expect(result).to be_nil
      expect(control_lane.calls.first).to include(adapter: :stoat, account: "st", text: "/help")
      expect(client.sent.first).to eq(channel: "dm-chan", body: { content: "reply text" })
    end

    it "leaves an ordinary bridged channel message alone" do
      result = adapter.handle_event(StoatFakes.message_event(channel: "CHAN01", content: "hello"))
      expect(result).not_to be_nil
      expect(control_lane.calls).to be_empty
    end

    it "ignores its own reply instead of answering itself" do
      adapter.handle_event(
        "type" => "Message", "_id" => "m2", "channel" => "dm-chan", "author" => "bot-stoat", "content" => "reply text"
      )
      expect(control_lane.calls).to be_empty
    end

    it "does nothing for an empty DM" do
      adapter.handle_event(
        "type" => "Message", "_id" => "m3", "channel" => "dm-chan", "author" => "u-ada", "content" => "  "
      )
      expect(control_lane.calls).to be_empty
    end
  end
end
