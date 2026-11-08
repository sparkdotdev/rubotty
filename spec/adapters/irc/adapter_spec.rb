# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Irc::Adapter do
  let(:client) { IrcFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  let(:general) do
    endpoint("irc-general", adapter: :irc, settings: { channel: "#general" })
  end

  subject(:adapter) do
    described_class.new(
      account: "irc",
      settings: { server: "irc.example.org", nick: "rubotty", tls: true },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general]
    ).replace_client(client)
  end

  describe "startup" do
    it "connects, joins each channel, and reports itself running" do
      adapter.start
      expect(client.connected).to be(true)
      expect(client.joined).to eq(["#general"])
      expect(adapter.own_account_id).to eq("rubotty")
      expect(adapter).to be_running
    end

    it "converts an unexpected start failure into an AdapterError" do
      allow(client).to receive(:connect).and_raise(RuntimeError.new("boom"))
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /failed to start.*boom/)
    end

    # One IRC account is headed for several server connections, which a single
    # per account dormancy flag cannot represent yet.
    it "does not opt into graceful dormancy yet" do
      expect(described_class.dormant_on_missing_secret?).to be(false)
    end

    # A bare nick means nothing across independent networks, so SenderLabel
    # composes host and protocol into "irc::ada@irc.example.org".
    it "derives the origin label from the server it connected to" do
      expect(adapter.origin_label).to eq("irc.example.org")
    end

    it "reports its own protocol qualifier" do
      expect(adapter.origin_protocol).to eq("irc")
    end

    it "stops reporting itself running once the client's read loop ends, with no #stop involved" do
      adapter.start
      client.kill_read_loop
      expect(adapter).not_to be_running
    end
  end

  describe "capabilities" do
    it "declares the platform the degradation policy exists for" do
      expect(adapter.capabilities.edits?).to be(false)
      expect(adapter.capabilities.deletes?).to be(false)
      expect(adapter.capabilities.reactions?).to be(false)
      expect(adapter.capabilities.replies?).to be(false)
    end

    it "can carry out channel moderation" do
      %i[kick ban unban].each { |a| expect(adapter.capabilities.moderates?(a)).to be(true) }
    end
  end

  # #capabilities is the static floor; #capabilities_for resolves what this
  # connection actually negotiated.
  describe "IRCv3 per-connection capabilities (issue #220)" do
    it "keeps #capabilities as the static, connection independent floor" do
      expect(adapter.capabilities).to equal(described_class::CAPABILITIES)
    end

    it "falls back to the floor for #capabilities_for before #start has negotiated anything" do
      caps = adapter.capabilities_for(general)
      expect(caps.replies?).to be(false)
      expect(caps.reactions?).to be(false)
      expect(caps.deletes?).to be(false)
    end

    it "upgrades replies and reactions once THIS connection negotiated message-tags and msgid" do
      client.negotiated_capabilities = %w[message-tags msgid]
      adapter.start
      caps = adapter.capabilities_for(general)
      expect(caps.replies?).to be(true)
      expect(caps.reactions?).to be(true)
      expect(caps.deletes?).to be(false) # draft/message-redaction was not negotiated
    end

    it "does not upgrade replies or reactions with only one of message-tags or msgid" do
      client.negotiated_capabilities = %w[message-tags]
      adapter.start
      expect(adapter.capabilities_for(general).replies?).to be(false)
      expect(adapter.capabilities_for(general).reactions?).to be(false)
    end

    it "upgrades deletes only once draft/message-redaction was itself negotiated" do
      client.negotiated_capabilities = %w[draft/message-redaction]
      adapter.start
      expect(adapter.capabilities_for(general).deletes?).to be(true)
    end

    # The :delete moderation verb rides the same grant as the deletes
    # capability: draft/message-redaction is the only wire form either one
    # has to carry it.
    it "upgrades the :delete moderation verb only once draft/message-redaction was itself negotiated" do
      client.negotiated_capabilities = %w[draft/message-redaction]
      adapter.start
      expect(adapter.capabilities_for(general).moderates?(:delete)).to be(true)
      expect(adapter.capabilities.moderates?(:delete)).to be(false) # the static floor stays untouched
    end

    it "leaves every other capability untouched" do
      client.negotiated_capabilities = %w[message-tags msgid draft/message-redaction]
      adapter.start
      caps = adapter.capabilities_for(general)
      # :delete rides the same grant as #deletes, tested above; nothing else moves.
      expect(caps.moderation - [:delete]).to eq(described_class::CAPABILITIES.moderation)
    end

    it "resolves independently per connection: one network upgrades while another does not" do
      modern = described_class.new(
        account: "modern", settings: { server: "modern.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(IrcFakes::Client.new(negotiated_capabilities: %w[message-tags msgid]))
      classic = described_class.new(
        account: "classic", settings: { server: "classic.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(IrcFakes::Client.new)

      modern.start
      classic.start

      expect(modern.capabilities_for(general).replies?).to be(true)
      expect(classic.capabilities_for(general).replies?).to be(false)
    end
  end

  describe "inbound" do
    before { adapter.start }

    it "converts a channel message into canonical form with the nick as author" do
      message = adapter.handle_message(IrcFakes.message_event(channel: "#general", nick: "ada", body: "hi"))
      expect(dispatcher.last).to eq(message)
      expect(message.origin.id).to eq("irc-general")
      expect(message.author.username).to eq("ada")
      expect(message.body.text).to eq("hi")
    end

    it "renders a CTCP action as '* nick does something'" do
      message = adapter.handle_message(
        IrcFakes.message_event(channel: "#general", nick: "ada", body: "waves", action: true)
      )
      expect(message.body.text).to eq("* ada waves")
    end

    it "matches channels case insensitively" do
      message = adapter.handle_message(IrcFakes.message_event(channel: "#GENERAL", body: "yo"))
      expect(message.origin.id).to eq("irc-general")
    end

    it "ignores a channel it has no endpoint for" do
      expect(adapter.handle_message(IrcFakes.message_event(channel: "#other"))).to be_nil
    end

    it "flows a message pushed by the client through the whole inbound path" do
      client.emit(IrcFakes.message_event(channel: "#general", nick: "grace", body: "hey"))
      expect(dispatcher.last.author.username).to eq("grace")
    end

    # Client only hands these over once negotiated, so what is left to check is
    # the adapter wiring them into the right Core::Message field.
    describe "msgid, replies and reactions (issue #220)" do
      it "uses a server assigned msgid as the message's native id instead of a synthetic one" do
        message = adapter.handle_message(
          IrcFakes.message_event(channel: "#general", nick: "ada", body: "hi", msgid: "srv-1")
        )
        expect(message.ref.native_id).to eq("srv-1")
      end

      it "falls back to a synthetic id with no msgid, exactly as before this existed" do
        message = adapter.handle_message(IrcFakes.message_event(channel: "#general", nick: "ada", body: "hi"))
        expect(message.ref.native_id).to start_with("ada-")
      end

      it "translates a +draft/reply target into a reply_to on this same endpoint" do
        message = adapter.handle_message(
          IrcFakes.message_event(channel: "#general", nick: "ada", body: "sure", msgid: "srv-2",
                                  reply_to: "srv-1")
        )
        expect(message.reply_to).to eq(ref("irc-general", "srv-1"))
      end

      it "carries the server-time timestamp through when Client supplies one" do
        stamp = Time.iso8601("2011-10-19T16:40:51.620Z")
        message = adapter.handle_message(
          IrcFakes.message_event(channel: "#general", nick: "ada", body: "hi", timestamp: stamp)
        )
        expect(message.timestamp).to eq(stamp)
      end

      it "converts a client-only +draft/react TAGMSG into a reaction_add message" do
        message = adapter.handle_message(
          IrcFakes.reaction_event(channel: "#general", nick: "ada", target_msgid: "srv-1", reaction: "\u{1F44D}")
        )
        expect(message.kind).to eq(:reaction_add)
        expect(message.ref).to eq(ref("irc-general", "srv-1"))
        expect(message.reaction).to eq(Rubotty::Core::Reaction.new(emoji: "\u{1F44D}"))
        expect(message.author.username).to eq("ada")
      end

      it "ignores a reaction on a channel it has no endpoint for" do
        event = IrcFakes.reaction_event(channel: "#other", target_msgid: "srv-1", reaction: "\u{1F44D}")
        expect(adapter.handle_message(event)).to be_nil
      end
    end

    describe "membership: JOIN, PART, QUIT and KICK (issue #704)" do
      it "converts a join event into a :join canonical message" do
        message = adapter.handle_message(IrcFakes.membership_event(channel: "#general", kind: "join", nick: "ada"))
        expect(message.kind).to eq(:join)
        expect(message.author.username).to eq("ada")
        expect(message.origin.id).to eq("irc-general")
      end

      it "converts a leave event into a :leave canonical message" do
        message = adapter.handle_message(IrcFakes.membership_event(channel: "#general", kind: "leave", nick: "ada"))
        expect(message.kind).to eq(:leave)
      end

      it "ignores a membership event on a channel it has no endpoint for" do
        event = IrcFakes.membership_event(channel: "#other", kind: "join")
        expect(adapter.handle_message(event)).to be_nil
      end
    end
  end

  describe "outbound" do
    before { adapter.start }

    it "prefixes the sender and sends to the channel" do
      out = message(general, text: "hello").with(sender_label: "Ada")
      adapter.deliver(out, general)
      said = client.messages.first
      expect(said[:channel]).to eq("#general")
      expect(said[:text]).to eq("Ada: hello")
    end

    it "renders a structured sender label as plain text" do
      label = Rubotty::Core::SenderLabel.new(username: "ada", platform: "telegram", display_name: "Ada L")
      adapter.deliver(message(general, text: "hi").with(sender_label: label), general)
      expect(client.messages.first[:text]).to eq("Ada L [ada@telegram]: hi")
    end

    it "quotes a reply as text, since IRC has no native reply" do
      preview = Rubotty::Core::ReplyPreview.new(body: Rubotty::Core::RichText.plain("the original"), label: "Grace")
      out = message(general, text: "agreed").with(sender_label: "Ada", reply_preview: preview,
                                                  reply_to: ref("tg-general", "9"))
      adapter.deliver(out, general)
      expect(client.messages.first[:text]).to start_with("> Grace: the original")
    end

    it "relays a public attachment as a link and never leaks a credentialed URL" do
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      adapter.deliver(message(general, text: "look").with(sender_label: "Ada", attachments: [photo]), general)
      expect(client.messages.first[:text]).to include("https://cdn.example/a.png")

      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )
      adapter.deliver(message(general, text: "look").with(sender_label: "Ada", attachments: [leaky]), general)
      expect(client.messages.last[:text]).not_to include("AAsecret")
    end

    # No room label, no sender prefix, no attachments: nothing worth posting,
    # a routine decline rather than an attempted send that came back empty.
    it "signals a blank body as NOT_APPLICABLE rather than a bare nil" do
      blank = message(general, text: "")
      receipt = adapter.deliver(blank, general)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
      expect(client.messages).to be_empty
    end
  end

  # These need a connection that actually negotiated the capabilities behind
  # them, so this block keeps its own adapter and client pair.
  describe "outbound: IRCv3 replies, reactions and deletes (issue #220)" do
    let(:upgraded_client) do
      IrcFakes::Client.new(negotiated_capabilities: %w[message-tags msgid draft/message-redaction])
    end

    subject(:upgraded_adapter) do
      described_class.new(
        account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(upgraded_client)
    end

    before { upgraded_adapter.start }

    it "attaches a native +draft/reply tag, with no text quote, for a reply to THIS endpoint" do
      preview = Rubotty::Core::ReplyPreview.new(body: Rubotty::Core::RichText.plain("the original"), label: "Grace")
      out = message(general, text: "agreed").with(sender_label: "Ada", reply_preview: preview,
                                                  reply_to: ref("irc-general", "srv-1"))
      upgraded_adapter.deliver(out, general)

      sent = upgraded_client.messages.first
      expect(sent[:tags]).to eq("+draft/reply" => "srv-1")
      expect(sent[:text]).to eq("Ada: agreed")
      expect(sent[:text]).not_to include("the original")
    end

    it "still falls back to a text quote when the reply targets a DIFFERENT endpoint" do
      preview = Rubotty::Core::ReplyPreview.new(body: Rubotty::Core::RichText.plain("the original"), label: "Grace")
      out = message(general, text: "agreed").with(sender_label: "Ada", reply_preview: preview,
                                                  reply_to: ref("tg-general", "9"))
      upgraded_adapter.deliver(out, general)

      sent = upgraded_client.messages.first
      expect(sent[:tags]).to eq({})
      expect(sent[:text]).to start_with("> Grace: the original")
    end

    it "captures a real msgid from #privmsg's return value as the delivery receipt's native id" do
      upgraded_client.next_native_id = "srv-9"
      receipt = upgraded_adapter.deliver(message(general, text: "hi").with(sender_label: "Ada"), general)
      expect(receipt.native_id).to eq("srv-9")
    end

    it "carries every id a wrapped send crossed as in the receipt's extra" do
      upgraded_client.next_native_id = "srv-9"
      upgraded_client.next_extra_ids = %w[srv-10 srv-11]
      receipt = upgraded_adapter.deliver(message(general, text: "a long message").with(sender_label: "Ada"), general)
      expect(receipt.extra[:ids]).to eq(%w[srv-9 srv-10 srv-11])
    end

    it "leaves extra empty for an ordinary single-line send" do
      upgraded_client.next_native_id = "srv-9"
      receipt = upgraded_adapter.deliver(message(general, text: "hi").with(sender_label: "Ada"), general)
      expect(receipt.extra).to eq({})
    end

    it "syncs added and removed reactions as identical TAGMSGs, since draft/react is a toggle" do
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")
      heart = Rubotty::Core::Reaction.new(emoji: "\u{2764}")
      upgraded_adapter.sync_reactions(general, "srv-1", desired: [heart], previous: [thumbs])

      expect(upgraded_client.reactions).to contain_exactly(
        { channel: "#general", msgid: "srv-1", emoji: "\u{2764}" },
        { channel: "#general", msgid: "srv-1", emoji: "\u{1F44D}" }
      )
    end

    it "deletes via REDACT, only ever called once the router already confirmed deletes? is true" do
      upgraded_adapter.delete(general, "srv-1")
      expect(upgraded_client.redactions).to eq([{ channel: "#general", msgid: "srv-1", reason: nil }])
    end
  end

  # per_room, the default, is every other test in this file: a plain endpoint
  # per channel with no room_label.
  describe "bridging modes" do
    describe ".validate_account" do
      it "requires hub_channel when mode is hub" do
        problems = described_class.validate_account({ mode: :hub }, "accounts.irc")
        expect(problems).not_to be_empty
      end

      it "rejects a hub_channel that is not a channel" do
        problems = described_class.validate_account({ mode: :hub, hub_channel: "not-a-channel" }, "accounts.irc")
        expect(problems).not_to be_empty
      end

      it "passes per_room with no hub_channel at all" do
        expect(described_class.validate_account({ mode: :per_room }, "accounts.irc")).to eq([])
      end

      it "passes hub once hub_channel is set" do
        problems = described_class.validate_account({ mode: :hub, hub_channel: "#sample" }, "accounts.irc")
        expect(problems).to eq([])
      end
    end

    describe ".route_key_for" do
      # group_by_channel and endpoint_for both downcase; route_key_for has to
      # match, or a capitalised YAML channel seeds a route_key inbound never
      # resolves.
      it "downcases the channel, matching every other place this adapter keys one" do
        capitalised = endpoint("irc-rubotty", adapter: :irc, settings: { channel: "#Rubotty" })
        expect(described_class.route_key_for(capitalised)).to eq("#rubotty")
      end

      it "leaves an already lower case channel untouched" do
        lower = endpoint("irc-general", adapter: :irc, settings: { channel: "#general" })
        expect(described_class.route_key_for(lower)).to eq("#general")
      end
    end

    describe "hub mode: several rooms mirrored into one channel" do
      let(:gaming_hub) do
        endpoint("irc-hub-gaming", adapter: :irc, receives: false,
                                   settings: { channel: "#sample", room_label: "gaming" })
      end
      let(:travel_hub) do
        # travel is the default room: the one endpoint on #sample that also receives.
        endpoint("irc-hub-travel", adapter: :irc, settings: { channel: "#sample", room_label: "travel" })
      end

      subject(:hub_adapter) do
        described_class.new(
          account: "irc-hub", settings: { server: "irc.example.org", nick: "rubotty", mode: :hub },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming_hub, travel_hub]
        ).replace_client(client)
      end

      it "joins the shared channel exactly once" do
        hub_adapter.start
        expect(client.joined).to eq(["#sample"])
      end

      it "labels a relayed message with its source room" do
        hub_adapter.start
        hub_adapter.deliver(message(gaming_hub, text: "who's on tonight?").with(sender_label: "Ada"), gaming_hub)
        hub_adapter.deliver(message(travel_hub, text: "flights booked").with(sender_label: "Grace"), travel_hub)

        # Each room name here is one word, so its derived code is its first two letters.
        texts = client.messages.map { |m| m[:text] }
        expect(texts).to contain_exactly("[gaming ga] Ada: who's on tonight?", "[travel tr] Grace: flights booked")
        expect(client.messages.map { |m| m[:channel] }.uniq).to eq(["#sample"])
      end

      it "routes an inbound hub-channel message to the configured default room only" do
        hub_adapter.start
        msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "hi all"))
        expect(msg.origin.id).to eq("irc-hub-travel")
      end

      it "routes a join event on the hub channel like a reaction, with no short-code parsing" do
        hub_adapter.start
        msg = hub_adapter.handle_message(IrcFakes.membership_event(channel: "#sample", kind: "join", nick: "ada"))
        expect(msg.kind).to eq(:join)
        expect(msg.origin.id).to eq("irc-hub-travel")
      end

      # A code typed in the shared channel picks which room the message reaches.
      describe "short-code addressing" do
        it "targets the named room, stripping the sigil and code from the relayed text" do
          hub_adapter.start
          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!ga who's raiding tonight?")
          )
          expect(msg.hub_target_room_id).to eq("irc-hub-gaming")
          expect(msg.body.text).to eq("who's raiding tonight?")
          # Still originates on the default endpoint, the only one with receives: true.
          expect(msg.origin.id).to eq("irc-hub-travel")
        end

        it "accepts every documented sigil" do
          hub_adapter.start
          %w[! . > :].each do |sigil|
            msg = hub_adapter.handle_message(
              IrcFakes.message_event(channel: "#sample", nick: "ada", body: "#{sigil}ga hello")
            )
            expect(msg.hub_target_room_id).to eq("irc-hub-gaming")
          end
        end

        it "excludes every hub endpoint on this channel from the fan-out, not only the origin" do
          hub_adapter.start
          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!ga hi")
          )
          expect(msg.hub_exclude_endpoint_ids).to contain_exactly("irc-hub-gaming", "irc-hub-travel")
        end

        it "posts a short ephemeral notice and relays nothing for a code that matches no room" do
          hub_adapter.start
          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!zz hello")
          )
          expect(msg).to be_nil
          expect(client.messages.size).to eq(1)
          expect(client.messages.first[:channel]).to eq("#sample")
          expect(client.messages.first[:text]).to match(/does not match a room/)
        end

        it "lists every room and its code on request, relaying nothing" do
          hub_adapter.start
          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!rooms")
          )
          expect(msg).to be_nil
          expect(client.messages.first[:text]).to eq("ga: gaming, tr: travel")
        end

        it "leaves an ordinary message with no sigil routed exactly as before" do
          hub_adapter.start
          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "no code here")
          )
          expect(msg.hub_target_room_id).to be_nil
          expect(msg.body.text).to eq("no code here")
        end

        it "never intercepts a real moderation command sharing the same sigil, and relays nothing extra" do
          hub_adapter.start
          # The command word is well past the two-letter code shape, so hub
          # routing leaves it untouched.
          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!delete")
          )
          expect(msg.hub_target_room_id).to be_nil
          expect(client.messages).to be_empty
        end

        it "does not treat a per_room channel as hub-addressable at all" do
          adapter.start
          msg = adapter.handle_message(IrcFakes.message_event(channel: "#general", nick: "ada", body: "!ga hello"))
          expect(msg.hub_target_room_id).to be_nil
          expect(msg.body.text).to eq("!ga hello")
        end
      end

      describe "the outbound short code, shown alongside room_label" do
        it "renders the code next to the label, teaching it passively" do
          hub_adapter.start
          hub_adapter.deliver(message(gaming_hub, text: "gg").with(sender_label: "Ada"), gaming_hub)
          expect(client.messages.first[:text]).to eq("[gaming ga] Ada: gg")
        end
      end

      describe "an explicit short_code override" do
        let(:gaming_hub_with_override) do
          endpoint("irc-hub-gaming", adapter: :irc, receives: false,
                                     settings: { channel: "#sample", room_label: "gaming", short_code: "GX" })
        end
        let(:override_adapter) do
          described_class.new(
            account: "irc-hub", settings: { server: "irc.example.org", nick: "rubotty", mode: :hub },
            dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming_hub_with_override, travel_hub]
          ).replace_client(client)
        end

        it "is taken as given, lowercased, never derived" do
          override_adapter.start
          msg = override_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!gx hello")
          )
          expect(msg.hub_target_room_id).to eq("irc-hub-gaming")
        end
      end
    end

    describe "hub mode with no default room: inbound is not relayed outward" do
      let(:gaming_hub) do
        endpoint("irc-hub-gaming", adapter: :irc, receives: false,
                                   settings: { channel: "#sample", room_label: "gaming" })
      end
      let(:travel_hub) do
        endpoint("irc-hub-travel", adapter: :irc, receives: false,
                                   settings: { channel: "#sample", room_label: "travel" })
      end

      subject(:hub_adapter) do
        described_class.new(
          account: "irc-hub", settings: { server: "irc.example.org", nick: "rubotty", mode: :hub },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming_hub, travel_hub]
        ).replace_client(client)
      end

      it "still fans outbound messages from both rooms into the one channel" do
        hub_adapter.start
        hub_adapter.deliver(message(gaming_hub, text: "gg").with(sender_label: "Ada"), gaming_hub)
        expect(client.messages.first[:text]).to eq("[gaming ga] Ada: gg")
      end

      it "drops a message typed in the hub channel: no origin room can receive it" do
        hub_adapter.start
        msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "hi"))
        expect(msg.origin.receives?).to be(false)
      end
    end

    describe "hub mode misconfigured with two default rooms on one channel" do
      let(:gaming_hub) { endpoint("irc-hub-gaming", adapter: :irc, settings: { channel: "#sample" }) }
      let(:travel_hub) { endpoint("irc-hub-travel", adapter: :irc, settings: { channel: "#sample" }) }
      let(:logger) { instance_spy(Logger) }

      subject(:hub_adapter) do
        described_class.new(
          account: "irc-hub", settings: { server: "irc.example.org", nick: "rubotty", mode: :hub },
          dispatcher: dispatcher, logger: logger, endpoints: [gaming_hub, travel_hub]
        ).replace_client(client)
      end

      it "does not raise: an operator mistake should not take the whole bridge down" do
        expect { hub_adapter }.not_to raise_error
      end

      it "logs the ambiguity clearly and still resolves inbound to exactly one of them" do
        hub_adapter.start
        expect(logger).to have_received(:error)
        msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "hi"))
        expect(msg.origin.id).to eq("irc-hub-gaming")
      end
    end

    # Hub mode's receives: disambiguation now applies under a live
    # control-plane resolver too, not only the boot-time index: #endpoint_for
    # hands every lookup straight to the resolver once one is wired, never
    # falling back to @index.
    describe "hub mode under a live control-plane resolver (issue #794)" do
      let(:gaming_hub) do
        endpoint("irc-hub-gaming", adapter: :irc, receives: false, settings: { channel: "#sample" })
      end
      let(:travel_hub) { endpoint("irc-hub-travel", adapter: :irc, settings: { channel: "#sample" }) }

      let(:resolver) do
        Class.new do
          def initialize(endpoint) = @endpoint = endpoint

          def endpoint_for(_adapter, _account, _route_key) = @endpoint

          # #reconcile_channels asks for this at #start; empty, so it has
          # nothing new to join and this stays a plain #endpoint_for test.
          def endpoints_for(_adapter, _account) = []
        end
      end

      def build_hub_adapter(resolved_endpoint)
        described_class.new(
          account: "irc-hub", settings: { server: "irc.example.org", nick: "rubotty", mode: :hub },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming_hub, travel_hub],
          endpoint_resolver: resolver.new(resolved_endpoint)
        ).replace_client(client)
      end

      it "resolves an inbound hub-channel message to whatever the live resolver answers with" do
        hub_adapter = build_hub_adapter(travel_hub)
        hub_adapter.start
        msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "hi all"))
        expect(msg.origin.id).to eq("irc-hub-travel")
      end

      it "never falls back to the boot-time index once a resolver is wired, even on a resolver miss" do
        hub_adapter = build_hub_adapter(nil)
        hub_adapter.start
        msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "hi all"))
        expect(msg).to be_nil
      end
    end

    # The section above still hands the adapter its hub group at boot, through
    # +endpoints:+; only the inbound address lookup goes live. This is the
    # rest of it: a hub group built with NO boot-time endpoints, using the
    # real ControlPlane::Registry/ChannelResolver/ChannelMapper against an in-memory database.
    describe "hub mode built entirely from live control-plane state", :control_plane do
      let(:db) { migrated_db }
      let(:models) { build_models(db) }
      let(:now) { Time.new(2026, 8, 24, 12, 0, 0) }
      let(:mapper) do
        Rubotty::ControlPlane::ChannelMapper.new(models: models, logger: Rubotty::Log.null, clock: -> { now })
      end
      let(:registry) { Rubotty::ControlPlane::Registry.build(models: models, accounts: {}) }
      let(:resolver) { Rubotty::ControlPlane::ChannelResolver.new(registry) }

      let(:community) do
        models.community.create(slug: "hub-live", name: "Hub Live", status: "active", settings: "{}",
                                 created_at: now, updated_at: now)
      end

      # An ordinary, non-hub channel mapping, made the same way any other
      # channel is: standing in for an operator having already bridged #sample
      # into the room "gaming" long before hub mode ever entered the picture.
      def seed_gaming_channel
        connection = models.platform_connection.create(
          community_id: community.id, adapter: "irc", account: "irc-hub",
          external_id: "irc-hub-gaming", created_at: now, updated_at: now
        )
        models.channel.create(
          community_id: community.id, platform_connection_id: connection.id,
          adapter: "irc", account: "irc-hub", route_key: "#sample", endpoint_key: "irc-hub-gaming",
          label: "gaming", receives: true, sends: true, relay: "{}", display_name: "{}",
          settings: JSON.generate(channel: "#sample", room_label: "gaming"), created_at: now, updated_at: now
        )
      end

      before do
        gaming = seed_gaming_channel
        mapper.map(community: community, selectors: [gaming.endpoint_key], room_key: "gaming", label: "Gaming")
      end

      def build_hub_adapter
        described_class.new(
          account: "irc-hub", settings: { server: "irc.example.org", nick: "rubotty", mode: :hub },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [], endpoint_resolver: resolver
        ).replace_client(client)
      end

      it "joins the shared channel with no boot-time endpoints, purely from the live snapshot" do
        hub_adapter = build_hub_adapter
        hub_adapter.start
        expect(client.joined).to eq(["#sample"])
      end

      it "carries no short code and excludes nobody until a second room actually shares the channel" do
        hub_adapter = build_hub_adapter
        hub_adapter.start
        msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "hi all"))
        expect(msg.origin.id).to eq("irc-hub-gaming")
        expect(msg.hub_target_room_id).to be_nil
      end

      describe "once ChannelMapper#add_hub_room shares the channel with a second room" do
        before do
          mapper.add_hub_room(community: community, anchor: "irc-hub-gaming", room_key: "travel",
                              room_label: "travel", label: "Travel")
        end

        it "resolves an inbound short code to the newly mapped room, live, with no adapter restart" do
          hub_adapter = build_hub_adapter
          hub_adapter.start

          msg = hub_adapter.handle_message(
            IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!tr flights booked")
          )

          expect(msg.hub_target_room_id).to eq("irc-hub-gaming:hub:travel")
          expect(msg.body.text).to eq("flights booked")
          expect(msg.origin.id).to eq("irc-hub-gaming") # still the only receives: true row
        end

        it "excludes both hub members from the fan-out once a code targets one of them" do
          hub_adapter = build_hub_adapter
          hub_adapter.start

          msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!tr hi"))

          expect(msg.hub_exclude_endpoint_ids).to contain_exactly("irc-hub-gaming", "irc-hub-gaming:hub:travel")
        end

        it "prefixes an outbound delivery from the new room with its live short code" do
          hub_adapter = build_hub_adapter
          hub_adapter.start
          travel_endpoint = registry.current.channel_by_endpoint_key("irc-hub-gaming:hub:travel").endpoint

          hub_adapter.deliver(message(travel_endpoint, text: "flights booked").with(sender_label: "Grace"),
                              travel_endpoint)

          expect(client.messages.first[:text]).to eq("[travel tr] Grace: flights booked")
          expect(client.messages.first[:channel]).to eq("#sample")
        end

        it "lists both rooms and their live codes on request" do
          hub_adapter = build_hub_adapter
          hub_adapter.start

          msg = hub_adapter.handle_message(IrcFakes.message_event(channel: "#sample", nick: "ada", body: "!rooms"))

          expect(msg).to be_nil
          expect(client.messages.first[:text]).to eq("ga: gaming, tr: travel")
        end

        it "still joins the physical channel exactly once" do
          hub_adapter = build_hub_adapter
          hub_adapter.start
          expect(client.joined).to eq(["#sample"])
        end
      end
    end

    describe "per_room mode: the standard 1:1 mapping" do
      let(:gaming) { endpoint("irc-gaming", adapter: :irc, settings: { channel: "#gaming" }) }
      let(:travel) { endpoint("irc-travel", adapter: :irc, settings: { channel: "#travel" }) }

      subject(:per_room_adapter) do
        described_class.new(
          account: "irc-per-room", settings: { server: "irc.example.org", nick: "rubotty", mode: :per_room },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [gaming, travel]
        ).replace_client(client)
      end

      it "joins one channel per room" do
        per_room_adapter.start
        expect(client.joined).to contain_exactly("#gaming", "#travel")
      end

      it "delivers each room's message to its own channel, with no room label" do
        per_room_adapter.start
        per_room_adapter.deliver(message(gaming, text: "gg").with(sender_label: "Ada"), gaming)
        per_room_adapter.deliver(message(travel, text: "landed").with(sender_label: "Grace"), travel)

        by_channel = client.messages.to_h { |m| [m[:channel], m[:text]] }
        expect(by_channel).to eq("#gaming" => "Ada: gg", "#travel" => "Grace: landed")
      end

      it "routes each channel's inbound message back to its own room" do
        per_room_adapter.start
        msg = per_room_adapter.handle_message(IrcFakes.message_event(channel: "#travel", nick: "grace"))
        expect(msg.origin.id).to eq("irc-travel")
      end
    end

    describe "channel privacy: a keyed (+k) channel" do
      let(:keyed) do
        endpoint("irc-secret", adapter: :irc, settings: { channel: "#secret-ops", channel_key: "hunter2" })
      end

      subject(:keyed_adapter) do
        described_class.new(
          account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
          dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [keyed]
        ).replace_client(client)
      end

      it "sends the key resolved from its env var when joining" do
        keyed_adapter.start
        expect(client.join_keys["#secret-ops"]).to eq("hunter2")
      end
    end
  end

  describe "moderation" do
    before { adapter.start }

    def command(action, target)
      Rubotty::Core::Moderation::Command.new(
        action: action,
        issuer: Rubotty::Core::Moderation::Operator.new(name: "mod"),
        origin: general,
        target_user_id: target
      )
    end

    it "kicks, bans and unbans a nick in the channel" do
      expect(adapter.moderate(command(:kick, "troll"), general, nil).status).to eq(:done)
      expect(client.kicks.first).to include(channel: "#general", nick: "troll")

      expect(adapter.moderate(command(:ban, "troll"), general, nil).status).to eq(:done)
      expect(client.bans.first).to include(channel: "#general", nick: "troll")

      expect(adapter.moderate(command(:unban, "troll"), general, nil).status).to eq(:done)
      expect(client.unbans.first).to include(channel: "#general", nick: "troll")
    end

    it "reports a reply-less /delete with no target message as unsupported" do
      expect(adapter.moderate(command(:delete, nil), general, nil).status).to eq(:unsupported)
    end

    it "redacts the target message for a moderator's /delete (issue #723)" do
      expect(adapter.moderate(command(:delete, nil), general, "srv-1").status).to eq(:done)
      expect(client.redactions.first).to include(channel: "#general", msgid: "srv-1")
    end

    it "reports a moderation failure as failed" do
      allow(client).to receive(:kick).and_raise(Rubotty::AdapterError.new("no op privileges", adapter: :irc))
      expect(adapter.moderate(command(:kick, "troll"), general, nil).status).to eq(:failed)
    end
  end

  # The receiving half: a DM reaches the control lane, and its reply, if any,
  # goes back to the sender.
  describe "direct messages (issue #726)" do
    let(:control_lane) do
      Class.new do
        attr_reader :calls

        def initialize = @calls = []

        def handle_dm(**kwargs)
          @calls << kwargs
          kwargs[:text] == "/role operator" ? "filed it" : nil
        end
      end.new
    end

    subject(:dm_adapter) do
      described_class.new(
        account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general], control_lane: control_lane
      ).replace_client(client)
    end

    before { dm_adapter.start }

    it "hands a DM to the control lane and sends its reply back" do
      client.emit_dm(IrcFakes.dm_event(nick: "ada", body: "/role operator"))
      expect(control_lane.calls.first).to include(adapter: :irc, account: "irc", text: "/role operator")
      expect(client.messages).to eq([{ channel: "ada", text: "filed it", tags: {} }])
    end

    it "stays silent when the control lane has nothing to say" do
      client.emit_dm(IrcFakes.dm_event(nick: "ada", body: "hello"))
      expect(client.messages).to be_empty
    end

    it "logs and drops the DM, rather than raising, with no control lane wired" do
      plain = described_class.new(
        account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(IrcFakes::Client.new)
      plain.start
      expect { plain.handle_dm(IrcFakes.dm_event) }.not_to raise_error
    end
  end

  describe "#send_admin_dm" do
    before { adapter.start }

    it "says it can, but not that it can delete one back" do
      expect(adapter.supports_admin_dm?).to be(true)
      expect(adapter.supports_admin_dm_delete?).to be(false)
    end

    it "PRIVMSGs the nick like any other send, handing back a DmReceipt" do
      receipt = adapter.send_admin_dm("ada", "a room needs you")

      expect(receipt).to be_a(Rubotty::Core::DmReceipt)
      expect(client.messages).to eq([{ channel: "ada", text: "a room needs you", tags: {} }])
    end

    it "answers nil rather than sending, for blank text" do
      expect(adapter.send_admin_dm("ada", "  ")).to be_nil
      expect(client.messages).to be_empty
    end

    it "falls back to a synthetic id when the server named no msgid" do
      receipt = adapter.send_admin_dm("ada", "a room needs you")

      expect(receipt.native_id).not_to be_empty
    end
  end

  # #endpoint_for already reads the live snapshot; only the join itself has to
  # catch up, since IRC has to actively join a channel before it hears
  # anything in it.
  describe "live channel reconciliation (issue #700)" do
    let(:discovered) { endpoint("irc-discovered", adapter: :irc, settings: { channel: "#discovered" }) }

    let(:resolver) do
      Class.new do
        def initialize(pairs) = @pairs = pairs

        def endpoints_for(_adapter, _account) = @pairs
      end
    end

    def build(endpoint_resolver:, logger: Rubotty::Log.null)
      described_class.new(
        account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: logger, endpoints: [general], endpoint_resolver: endpoint_resolver
      ).replace_client(client)
    end

    it "joins a channel the live snapshot maps that boot time endpoints never named" do
      live = resolver.new([["#general", general], ["#discovered", discovered]])
      reconciling = build(endpoint_resolver: live)
      reconciling.start

      reconciling.reconcile_channels
      expect(client.joined).to include("#discovered")
    end

    # The periodic re-sync above needs a cleanup scheduler to re-arm against,
    # and an adapter can be constructed without one. #start alone, with no
    # manual #reconcile_channels call and no cleanup scheduler wired up, still
    # has to join everything the live snapshot maps.
    it "joins every live-snapshot channel at boot with no YAML endpoints, no cleanup scheduler and no manual reconcile" do
      live = resolver.new([["#general", general], ["#discovered", discovered]])
      reconciling = described_class.new(
        account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [], endpoint_resolver: live
      ).replace_client(client)

      reconciling.start

      expect(client.joined).to contain_exactly("#general", "#discovered")
    end

    it "logs, rather than parting, a channel still joined that the live snapshot no longer maps" do
      logger = instance_spy(Logger)
      reconciling = build(endpoint_resolver: resolver.new([]), logger: logger)
      reconciling.start

      reconciling.reconcile_channels
      expect(logger).to have_received(:info).at_least(:twice) # boot join count, then the stale-join notice
      expect(client.joined).to eq(["#general"])
    end

    it "does nothing with no live resolver, exactly as before this existed" do
      adapter.start
      expect { adapter.reconcile_channels }.not_to raise_error
    end

    # route_key_for downcases, so the live snapshot's keys are always lower
    # case; a channel configured with different case in bridge.config.yaml
    # used to be seeded verbatim, never matching the live key, forcing a
    # redundant join and a permanent false "still joined" warning (issue #1497).
    it "does not rejoin or report a channel configured with different case than the live snapshot's key" do
      mixed_case = endpoint("irc-mixed", adapter: :irc, settings: { channel: "#General" })
      logger = instance_spy(Logger)
      live = resolver.new([["#general", mixed_case]])
      reconciling = described_class.new(
        account: "irc", settings: { server: "irc.example.org", nick: "rubotty" },
        dispatcher: dispatcher, logger: logger, endpoints: [mixed_case], endpoint_resolver: live
      ).replace_client(client)
      reconciling.start

      reconciling.reconcile_channels

      expect(client.joined).to eq(["#General"]) # the boot join only, no redundant reconcile join
      expect(logger).not_to have_received(:info).with(a_string_matching(/still joined/))
    end
  end
end
