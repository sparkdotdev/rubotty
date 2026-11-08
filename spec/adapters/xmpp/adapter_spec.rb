# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Xmpp::Adapter do
  let(:client) { XmppFakes::Client.new }
  let(:dispatcher) { Fakes::RecordingDispatcher.new }

  let(:general) do
    endpoint("xmpp-general", adapter: :xmpp, settings: { room_jid: "room@conference.example.org" })
  end

  subject(:adapter) do
    described_class.new(
      account: "xm",
      settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
      dispatcher: dispatcher,
      logger: Rubotty::Log.null,
      endpoints: [general]
    ).replace_client(client)
  end

  describe "startup" do
    it "connects, joins each room under its nick, and reports itself running" do
      adapter.start
      expect(client.connected).to be(true)
      expect(client.joined).to eq([{ room: "room@conference.example.org", nick: "rubotty" }])
      expect(adapter.own_account_id).to eq("rubotty")
      expect(adapter).to be_running
    end

    it "defaults the nick to the JID local part when none is configured" do
      plain = described_class.new(
        account: "xm", settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(client)
      expect(plain.own_account_id).to eq("bridge")
    end

    # XMPP is federated, so SenderLabel composes the domain and the protocol
    # into "xmpp::ada@example.org".
    it "derives the origin label from its own JID's domain" do
      expect(adapter.origin_label).to eq("example.org")
    end

    it "reports its own protocol qualifier" do
      expect(adapter.origin_protocol).to eq("xmpp")
    end

    it "converts an unexpected start failure into an AdapterError" do
      allow(client).to receive(:connect).and_raise(RuntimeError.new("boom"))
      expect { adapter.start }.to raise_error(Rubotty::AdapterError, /failed to start.*boom/)
    end

    # One account is one password, so a missing one means "not yet connected"
    # rather than a fatal boot error.
    it "opts into graceful dormancy when its password is absent" do
      expect(described_class.dormant_on_missing_secret?).to be(true)
    end

    it "logs and skips a refused room rather than failing the whole adapter (issue #705)" do
      allow(client).to receive(:join).and_raise(Rubotty::AdapterError.new("refused the join: forbidden (403)",
                                                                          adapter: :xmpp))
      expect { adapter.start }.not_to raise_error
      expect(adapter).to be_running
    end
  end

  # A MUC nick collision (409) makes Client#join fall back to a different
  # nick in the ONE room it happened in, leaving every other room signed in
  # under the configured nick. LoopGuard registers own_account_ids instead:
  # every nick this account currently holds (issue #1498).
  describe "#own_account_ids" do
    it "reports only the configured nick when nothing fell back" do
      adapter.start
      expect(adapter.own_account_ids).to eq(["occupant:rubotty"])
    end

    it "reports every nick actually in use once a room's join has fallen back" do
      second = endpoint("xmpp-second", adapter: :xmpp, settings: { room_jid: "second@conference.example.org" })
      forked = described_class.new(
        account: "xm",
        settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general, second]
      ).replace_client(client)
      # Simulates what Client#join records once "general" refused "rubotty"
      # and fell back to "rubotty_", while "second" joined cleanly.
      allow(client).to receive(:join).and_wrap_original do |original, room_jid, nick|
        original.call(room_jid, room_jid == "room@conference.example.org" ? "#{nick}_" : nick)
      end

      forked.start

      expect(forked.own_account_ids).to contain_exactly("occupant:rubotty", "occupant:rubotty_")
    end
  end

  # #endpoint_for already reads the live snapshot; only the join itself has to
  # catch up, since XMPP has to actively join a room before it hears anything
  # in it.
  describe "live channel reconciliation (issue #700)" do
    let(:discovered) do
      endpoint("xmpp-discovered", adapter: :xmpp, settings: { room_jid: "new@conference.example.org" })
    end

    let(:resolver) do
      Class.new do
        def initialize(pairs) = @pairs = pairs

        def endpoints_for(_adapter, _account) = @pairs
      end
    end

    def build(endpoint_resolver:, logger: Rubotty::Log.null)
      described_class.new(
        account: "xm",
        settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
        dispatcher: dispatcher, logger: logger, endpoints: [general], endpoint_resolver: endpoint_resolver
      ).replace_client(client)
    end

    it "joins a room the live snapshot maps that boot time endpoints never named" do
      live = resolver.new([["room@conference.example.org", general], ["new@conference.example.org", discovered]])
      reconciling = build(endpoint_resolver: live)
      reconciling.start

      reconciling.reconcile_channels
      expect(client.joined.map { |j| j[:room] }).to include("new@conference.example.org")
    end

    # The periodic re-sync above needs a cleanup scheduler to re-arm against,
    # and an adapter can be constructed without one. #start alone, with no
    # manual #reconcile_channels call and no cleanup scheduler wired up, still
    # has to join everything the live snapshot maps.
    it "joins every live-snapshot room at boot with no YAML endpoints, no cleanup scheduler and no manual reconcile" do
      live = resolver.new([["room@conference.example.org", general], ["new@conference.example.org", discovered]])
      reconciling = described_class.new(
        account: "xm",
        settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [], endpoint_resolver: live
      ).replace_client(client)

      reconciling.start

      expect(client.joined.map { |j| j[:room] }).to contain_exactly(
        "room@conference.example.org", "new@conference.example.org"
      )
    end

    it "logs, rather than leaving, a room still joined that the live snapshot no longer maps" do
      logger = instance_spy(Logger)
      reconciling = build(endpoint_resolver: resolver.new([]), logger: logger)
      reconciling.start

      reconciling.reconcile_channels
      expect(logger).to have_received(:info).at_least(:twice) # boot join count, then the stale-join notice
      expect(client.joined.size).to eq(1) # nothing new was joined
    end

    it "does nothing with no live resolver, exactly as before this existed" do
      adapter.start
      expect { adapter.reconcile_channels }.not_to raise_error
    end
  end

  describe "capabilities" do
    it "declares plain text, no native edits, but native deletes and reactions (issue #707)" do
      expect(adapter.capabilities.edits?).to be(false)
      expect(adapter.capabilities.deletes?).to be(true)
      expect(adapter.capabilities.reactions?).to be(true)
    end

    # No way to ask a server its real XEP-0363 ceiling ahead of a slot
    # request, so this borrows the fetcher's own generic one.
    it "declares an upload ceiling now that XEP-0363 gives it somewhere to send bytes" do
      expect(adapter.capabilities.max_attachment_bytes).to eq(25 * 1024 * 1024)
    end

    it "can carry out MUC moderation, including delete (issue #723)" do
      %i[kick ban unban delete].each { |a| expect(adapter.capabilities.moderates?(a)).to be(true) }
    end
  end

  describe "inbound" do
    before { adapter.start }

    it "converts a MUC message into canonical form with the nick as author" do
      message = adapter.handle_message(XmppFakes.message_event(room_jid: "room@conference.example.org", body: "hi"))
      expect(dispatcher.last).to eq(message)
      expect(message.origin.id).to eq("xmpp-general")
      expect(message.author.username).to eq("ada")
      expect(message.author.native_id).to eq("occupant:ada")
      expect(message.body.text).to eq("hi")
    end

    it "ignores a message with no nick (a room subject) or an empty body" do
      subject_line = XmppFakes.message_event(room_jid: "room@conference.example.org", nick: nil)
      expect(adapter.handle_message(subject_line)).to be_nil
      empty = XmppFakes.message_event(room_jid: "room@conference.example.org", body: "")
      expect(adapter.handle_message(empty)).to be_nil
    end

    it "keeps a room nick resembling a trusted JID outside the account namespace" do
      message = adapter.handle_message(
        XmppFakes.message_event(room_jid: "room@conference.example.org", nick: "jid:someone@example.org")
      )

      expect(message.author.native_id).to eq("occupant:jid:someone@example.org")
      expect(Rubotty::Security::GrantIdentity.native_id(adapter: :xmpp, native_id: message.author.native_id)).to be_nil
    end

    it "ignores a room it has no endpoint for" do
      expect(adapter.handle_message(XmppFakes.message_event(room_jid: "other@conference.example.org"))).to be_nil
    end

    it "flows a message pushed by the client through the whole inbound path" do
      client.emit(XmppFakes.message_event(room_jid: "room@conference.example.org", nick: "grace", body: "yo"))
      expect(dispatcher.last.author.username).to eq("grace")
    end

    # Features::Greetings and Features::AntiRaid observe :join/:leave the same
    # way a Discord member add/remove reaches them.
    it "converts an occupant's presence into a canonical join or leave message" do
      client.emit_presence(XmppFakes.presence_event(room_jid: "room@conference.example.org", nick: "grace"))
      expect(dispatcher.last.kind).to eq(:join)
      expect(dispatcher.last.author.username).to eq("grace")

      client.emit_presence(XmppFakes.presence_event(room_jid: "room@conference.example.org", nick: "grace",
                                                     kind: "leave"))
      expect(dispatcher.last.kind).to eq(:leave)
    end

    it "ignores a presence for a room it has no endpoint for" do
      expect(adapter.handle_membership(XmppFakes.presence_event(room_jid: "other@conference.example.org"))).to be_nil
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
        account: "xm",
        settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general], control_lane: control_lane
      ).replace_client(client)
    end

    before { dm_adapter.start }

    it "hands a DM to the control lane and sends its reply back" do
      client.emit_dm(XmppFakes.dm_event(jid: "someone@example.org", body: "/role operator"))
      expect(control_lane.calls.first).to include(adapter: :xmpp, account: "xm", text: "/role operator")
      expect(control_lane.calls.first[:author].native_id).to eq("jid:someone@example.org")
      expect(client.dms_sent).to eq([{ jid: "someone@example.org", body: "filed it" }])
    end

    it "stays silent when the control lane has nothing to say" do
      client.emit_dm(XmppFakes.dm_event(jid: "someone@example.org", body: "hello"))
      expect(client.dms_sent).to be_empty
    end

    it "refuses a room-occupant resource masquerading as a direct account" do
      client.emit_dm(XmppFakes.dm_event(jid: "room@conference.example.org/ada", body: "/role operator"))

      expect(control_lane.calls).to be_empty
      expect(client.dms_sent).to be_empty
    end

    it "logs and drops the DM, rather than raising, with no control lane wired" do
      plain = described_class.new(
        account: "xm",
        settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD", nick: "rubotty" },
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: [general]
      ).replace_client(XmppFakes::Client.new)
      plain.start
      expect { plain.handle_dm(XmppFakes.dm_event) }.not_to raise_error
    end
  end

  describe "#send_admin_dm" do
    it "routes an authenticated account identity to its bare JID" do
      adapter.send_admin_dm("jid:someone@example.org", "a room needs you")

      expect(client.dms_sent).to eq([{ jid: "someone@example.org", body: "a room needs you" }])
    end
    before { adapter.start }

    it "says it can, and that it can delete one back" do
      expect(adapter.supports_admin_dm?).to be(true)
      expect(adapter.supports_admin_dm_delete?).to be(true)
    end

    it "sends a plain type=\"chat\" message, handing back a DmReceipt" do
      receipt = adapter.send_admin_dm("someone@example.org", "a room needs you")

      expect(receipt).to be_a(Rubotty::Core::DmReceipt)
      expect(client.dms_sent).to eq([{ jid: "someone@example.org", body: "a room needs you" }])
    end

    it "answers nil rather than sending, for blank text" do
      expect(adapter.send_admin_dm("someone@example.org", "  ")).to be_nil
      expect(client.dms_sent).to be_empty
    end
  end

  describe "#delete_admin_dm" do
    before { adapter.start }

    it "retracts one to one, addressed to the jid the receipt names" do
      receipt = adapter.send_admin_dm("someone@example.org", "a room needs you")

      expect(adapter.delete_admin_dm(receipt)).to be(true)
      expect(client.retracts).to eq([{ jid: "someone@example.org", target_id: receipt.native_id }])
    end

    it "answers false for a nil receipt" do
      expect(adapter.delete_admin_dm(nil)).to be(false)
    end
  end

  describe "outbound" do
    before { adapter.start }

    it "prefixes the sender and sends plain text to the room" do
      out = message(general, text: "hello").with(sender_label: "Ada")
      receipt = adapter.deliver(out, general)
      said = client.said.first
      expect(said[:room]).to eq("room@conference.example.org")
      expect(said[:body]).to eq("Ada: hello")
      expect(receipt.native_id).to eq("xmpp-1")
    end

    it "renders a structured sender label as plain text" do
      label = Rubotty::Core::SenderLabel.new(username: "ada", platform: "telegram", display_name: "Ada L")
      adapter.deliver(message(general, text: "hi").with(sender_label: label), general)
      expect(client.said.first[:body]).to eq("Ada L [ada@telegram]: hi")
    end

    it "quotes a reply as text, since XMPP has no native reply here" do
      preview = Rubotty::Core::ReplyPreview.new(body: Rubotty::Core::RichText.plain("the original"), label: "Grace")
      out = message(general, text: "agreed").with(sender_label: "Ada", reply_preview: preview,
                                                  reply_to: ref("tg-general", "9"))
      adapter.deliver(out, general)
      expect(client.said.first[:body]).to start_with("> Grace: the original")
    end

    it "relays a public attachment as a link and never leaks a credentialed URL" do
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")
      adapter.deliver(message(general, text: "look").with(sender_label: "Ada", attachments: [photo]), general)
      expect(client.said.first[:body]).to include("https://cdn.example/a.png")

      # The fetch itself is real code; only its transport is a stub, so this
      # never reaches the actual api.telegram.org.
      adapter.instance_variable_set(
        :@fetcher, Rubotty::Util::MediaFetcher.new(http: ->(_uri, _filename) { nil })
      )
      leaky = Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/a.jpg", filename: "a.jpg"
      )
      adapter.deliver(message(general, text: "look").with(sender_label: "Ada", attachments: [leaky]), general)
      expect(client.said.last[:body]).not_to include("AAsecret")
    end

    # No sender prefix, no attachments: nothing worth posting, a routine
    # decline rather than an attempted send that came back empty.
    it "signals a blank body as NOT_APPLICABLE rather than a bare nil" do
      blank = message(general, text: "")
      receipt = adapter.deliver(blank, general)
      expect(receipt).to equal(Rubotty::Core::DeliveryReceipt::NOT_APPLICABLE)
      expect(receipt).to be_nil
      expect(client.said).to be_empty
    end

    it "deletes via XEP-0424 retraction, only ever called once the router confirmed deletes? is true" do
      adapter.delete(general, "stanza-1")
      expect(client.retracts).to eq([{ room: "room@conference.example.org", target_id: "stanza-1" }])
    end

    it "sets the whole reaction set via XEP-0444, ignoring previous the way Telegram does" do
      thumbs = Rubotty::Core::Reaction.new(emoji: "\u{1F44D}")
      adapter.sync_reactions(general, "stanza-1", desired: [thumbs], previous: [])
      expect(client.reacts).to eq(
        [{ room: "room@conference.example.org", target_id: "stanza-1", emojis: ["\u{1F44D}"] }]
      )
    end
  end

  # xmpp/outbound.rb declared no way to relay a credentialed attachment: it
  # always fell back to "[label, could not be relayed]", which is what a
  # Telegram file URL (embedding the bot token) always hit. Client now
  # speaks XEP-0363, fetching credentialed ones through the hardened fetcher.
  describe "media (XEP-0363 upload)" do
    before { adapter.start }

    def stubbed_fetcher(&block)
      Rubotty::Util::MediaFetcher.new(http: block)
    end

    def fake_file(bytes)
      StringIO.new(bytes).tap { |io| io.define_singleton_method(:unlink) { nil } }
    end

    def leaky_attachment(filename: "a.jpg")
      Rubotty::Core::Attachment.new(
        kind: :photo, url: "https://api.telegram.org/file/bot123:AAsecret/#{filename}", filename: filename
      )
    end

    it "fetches and uploads a credentialed attachment, posting the hosted url instead of the marker" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("JPEGDATA") })
      allow(client).to receive(:upload).and_return("https://upload.example.org/abc/a.jpg")

      out = message(general, text: "look").with(sender_label: "Ada", attachments: [leaky_attachment])
      receipt = adapter.deliver(out, general)

      expect(client.said.first[:body]).to include("https://upload.example.org/abc/a.jpg")
      expect(client.said.first[:body]).not_to include("AAsecret")
      expect(client).to have_received(:upload).with("JPEGDATA", filename: "a.jpg", content_type: nil)
      expect(receipt.extra).to eq({})
    end

    it "falls back to the marker when the download itself fails" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| nil })
      expect(client).not_to receive(:upload)

      out = message(general, text: "look").with(sender_label: "Ada", attachments: [leaky_attachment])
      adapter.deliver(out, general)

      expect(client.said.first[:body]).to include("[a.jpg, could not be relayed]")
    end

    it "falls back to the marker, rather than raising, when the upload itself is refused" do
      adapter.instance_variable_set(:@fetcher, stubbed_fetcher { |_uri, _filename| fake_file("JPEGDATA") })
      allow(client).to receive(:upload)
        .and_raise(Rubotty::AdapterError.new("XMPP upload PUT was refused (413)", adapter: :xmpp))

      out = message(general, text: "look").with(sender_label: "Ada", attachments: [leaky_attachment])
      receipt = adapter.deliver(out, general)

      expect(client.said.first[:body]).to include("[a.jpg, could not be relayed]")
      expect(receipt.extra[:notes]).to include(a_string_matching(/could not relay a\.jpg/))
    end

    it "never bothers fetching a public attachment, uploading nothing" do
      expect(client).not_to receive(:upload)
      photo = Rubotty::Core::Attachment.new(kind: :photo, url: "https://cdn.example/a.png", filename: "a.png")

      adapter.deliver(message(general, text: "look").with(attachments: [photo]), general)

      expect(client.said.first[:body]).to include("https://cdn.example/a.png")
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

    it "kicks an occupant by nick" do
      expect(adapter.moderate(command(:kick, "troll"), general, nil).status).to eq(:done)
      expect(client.kicks.first).to include(room: "room@conference.example.org", nick: "troll")
    end

    it "bans and unbans a bare JID" do
      expect(adapter.moderate(command(:ban, "bad@example.org"), general, nil).status).to eq(:done)
      expect(client.bans.first).to include(jid: "bad@example.org")
      expect(adapter.moderate(command(:unban, "bad@example.org"), general, nil).status).to eq(:done)
      expect(client.unbans.first).to include(jid: "bad@example.org")
    end

    it "reports an unsupported action rather than raising" do
      expect(adapter.moderate(command(:pin, nil), general, nil).status).to eq(:unsupported)
    end

    it "reports a reply-less /delete with no target message as unsupported" do
      expect(adapter.moderate(command(:delete, nil), general, nil).status).to eq(:unsupported)
    end

    it "retracts the target message via XEP-0424 for a moderator's /delete (issue #723)" do
      expect(adapter.moderate(command(:delete, nil), general, "stanza-1").status).to eq(:done)
      expect(client.retracts).to eq([{ room: "room@conference.example.org", target_id: "stanza-1" }])
    end

    it "reports a moderation failure as failed" do
      allow(client).to receive(:kick).and_raise(Rubotty::AdapterError.new("no permission", adapter: :xmpp))
      expect(adapter.moderate(command(:kick, "troll"), general, nil).status).to eq(:failed)
    end
  end

  # XMPP gets both discovery halves: passively, a groupchat message names its
  # room; actively, XEP-0048 bookmarks and a disco#items sweep at connect. No
  # fixture carries an XMPP connection, so one is created here.
  describe "channel discovery (#38, #39)", :control_plane do
    let(:db) { migrated_db }
    let(:models) { build_models(db) }
    let(:now) { Time.now }
    let(:community) do
      models.community.create(slug: "xm", name: "XM", status: "active", settings: "{}",
                              created_at: now, updated_at: now)
    end
    # The coarse space id this adapter groups discovered rooms under is the MUC domain.
    let(:connection) do
      models.platform_connection.create(
        community_id: community.id, adapter: "xmpp", account: "xm",
        external_id: "conference.example.org", created_at: now, updated_at: now
      )
    end

    before { connection } # force the seeded space to exist before any test runs

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

    def build_adapter(muc_service: nil, endpoints: [], discovery_seam: discovery)
      described_class.new(
        account: "xm",
        settings: { jid: "bridge@example.org", password: "pw", password_env: "XMPP_PASSWORD",
                    nick: "rubotty", muc_service: muc_service }.compact,
        dispatcher: dispatcher, logger: Rubotty::Log.null, endpoints: endpoints, discovery: discovery_seam
      ).replace_client(client)
    end

    subject(:disco_adapter) { build_adapter }

    describe "passive: a groupchat message names its room" do
      it "learns a brand-new room and prompts the operator in an opted-in community" do
        enable_alerts
        disco_adapter.start
        disco_adapter.handle_message(XmppFakes.message_event(room_jid: "newroom@conference.example.org"))

        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["newroom@conference.example.org"])
        row = models.channel.where(adapter: "xmpp", route_key: "newroom@conference.example.org").first
        expect(row.json_value(:settings)).to eq("room_jid" => "newroom@conference.example.org")
      end

      it "prompts by default, without an explicit opt-in" do
        disco_adapter.start
        disco_adapter.handle_message(XmppFakes.message_event(room_jid: "newroom2@conference.example.org"))
        expect(notifier.prompts.map { |d| d[:route_key] }).to eq(["newroom2@conference.example.org"])
      end

      it "learns nothing once a community explicitly opts out" do
        disable_alerts
        disco_adapter.start
        disco_adapter.handle_message(XmppFakes.message_event(room_jid: "newroom@conference.example.org"))
        expect(notifier.prompts).to be_empty
        expect(models.channel.where(route_key: "newroom@conference.example.org").first).to be_nil
      end

      it "ignores a subject/system stanza with no nick (nothing to learn)" do
        enable_alerts
        disco_adapter.start
        event = XmppFakes.message_event(room_jid: "newroom@conference.example.org", nick: nil)
        expect { disco_adapter.handle_message(event) }.not_to raise_error
        expect(notifier.prompts).to be_empty
      end

      it "never consumes the update: a message in an already-mapped room still routes" do
        mapped = endpoint("xmpp-general", adapter: :xmpp, settings: { room_jid: "room@conference.example.org" })
        adapter_with_endpoint = build_adapter(endpoints: [mapped])
        adapter_with_endpoint.start

        message = adapter_with_endpoint.handle_message(
          XmppFakes.message_event(room_jid: "room@conference.example.org", body: "hi")
        )
        expect(message).not_to be_nil
        expect(dispatcher.last.body.text).to eq("hi")
      end

      it "does not fail the receive loop when discovery raises" do
        allow(discovery).to receive(:saw).and_raise(StandardError.new("boom"))
        disco_adapter.start
        expect do
          disco_adapter.handle_message(XmppFakes.message_event(room_jid: "room@conference.example.org"))
        end.not_to raise_error
      end
    end

    describe "active: bookmarks and disco#items enumeration at connect" do
      it "records bookmarked rooms so the mapping wizard lists them (#38)" do
        client.bookmarks = [{ id: "a@conference.example.org", name: "Room A" }]
        disco_adapter.start

        row = models.channel.where(adapter: "xmpp", route_key: "a@conference.example.org").first
        expect(row).not_to be_nil
        expect(row.label).to eq("Room A")
        # Dormant: recorded but in no room, so it does not bridge until mapped.
        expect(models.room_channel.where(channel_id: row.id).count).to eq(0)
      end

      it "records disco#items rooms from a configured muc_service" do
        client.set_disco_items("conference.example.org", [{ id: "b@conference.example.org", name: "Room B" }])
        build_adapter(muc_service: "conference.example.org").start

        row = models.channel.where(adapter: "xmpp", route_key: "b@conference.example.org").first
        expect(row).not_to be_nil
        expect(row.label).to eq("Room B")
      end

      it "skips disco entirely with no muc_service configured" do
        disco_adapter.start
        expect(client.disco_items).to eq({})
      end

      it "de-duplicates a room that is both bookmarked and listed by disco" do
        client.bookmarks = [{ id: "a@conference.example.org", name: "Bookmark Name" }]
        client.set_disco_items("conference.example.org", [{ id: "a@conference.example.org", name: "Disco Name" }])
        build_adapter(muc_service: "conference.example.org").start

        expect(models.channel.where(adapter: "xmpp", route_key: "a@conference.example.org").count).to eq(1)
      end

      it "records nothing for a room whose MUC domain owns no connection" do
        client.bookmarks = [{ id: "x@unrelated.example.org", name: "Elsewhere" }]
        disco_adapter.start
        expect(models.channel.where(route_key: "x@unrelated.example.org").first).to be_nil
      end

      it "does not enumerate at all without discovery wired" do
        client.bookmarks = [{ id: "a@conference.example.org", name: "A" }]
        plain = build_adapter(discovery_seam: nil)
        expect { plain.start }.not_to raise_error
        expect(models.channel.count).to eq(0)
      end

      it "does not fail start when enumeration raises" do
        allow(client).to receive(:bookmarked_rooms).and_raise(StandardError.new("boom"))
        expect { disco_adapter.start }.not_to raise_error
        expect(disco_adapter).to be_running
      end
    end
  end
end
