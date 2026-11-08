# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Xmpp::Client do
  # A scripted stand in for the TCP/TLS socket: the C2S handshake is lock step,
  # so a queue of replies in order drives the whole exchange, and readpartial
  # blocks on that queue as a real socket blocks between stanzas.
  class ScriptedSocket
    def initialize(replies)
      @replies = Thread::Queue.new
      replies.each { |reply| @replies << reply }
      @writes = []
      @mutex = Mutex.new
    end

    def writes = @mutex.synchronize { @writes.dup }

    def write(data)
      @mutex.synchronize { @writes << data }
      data.bytesize
    end

    def readpartial(_max) = @replies.pop

    def feed(reply) = (@replies << reply)

    def close = nil
  end

  # The replies a compliant server sends through a successful handshake.
  def handshake_replies
    header = %(<stream:stream xmlns="jabber:client" xmlns:stream="http://etherx.jabber.org/streams" id="s">)
    [
      header + %(<stream:features><starttls xmlns="urn:ietf:params:xml:ns:xmpp-tls"/></stream:features>),
      %(<proceed xmlns="urn:ietf:params:xml:ns:xmpp-tls"/>),
      header + %(<stream:features><mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl">) +
        %(<mechanism>PLAIN</mechanism></mechanisms></stream:features>),
      %(<success xmlns="urn:ietf:params:xml:ns:xmpp-sasl"/>),
      header + %(<stream:features><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind"/></stream:features>),
      %(<iq type="result" id="i"><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">) +
        %(<jid>bridge@example.org/x</jid></bind></iq>)
    ]
  end

  let(:socket) { ScriptedSocket.new(handshake_replies) }

  subject(:client) do
    described_class.new(jid: "bridge@example.org", password: "s3cr3t", nick: "rubotty", logger: Rubotty::Log.null)
  end

  before do
    # Own the socket without a network, and make the TLS upgrade a no op.
    allow(client).to receive(:open_socket).and_return(socket)
    allow(client).to receive(:upgrade_to_tls) { |sock, _domain| sock }
  end

  describe "the load path (issue #134)" do
    it "loads on this Ruby from the standard library, without the broken xmpp4r gem" do
      expect(defined?(Rubotty::Adapters::Xmpp::Client)).to eq("constant")
      expect(defined?(Rubotty::Adapters::Xmpp::Protocol)).to eq("constant")
      # xmpp4r must not be pulled in: it loads but cannot receive on Ruby 4.0.
      expect(defined?(Jabber)).to be_nil
      expect($LOADED_FEATURES.grep(/xmpp4r/)).to be_empty
      # The XML parser we do depend on is the bundled standard library REXML.
      expect { require "rexml/document" }.not_to raise_error
      expect(defined?(REXML)).to eq("constant")
    end
  end

  describe "#connect" do
    it "runs the handshake: stream open, STARTTLS, SASL PLAIN, bind, then presence" do
      client.connect
      written = socket.writes.join

      expect(written).to include(%(<stream:stream to="example.org"))
      expect(written).to include("<starttls")
      auth = socket.writes.find { |w| w.include?("mechanism=\"PLAIN\"") }
      expect(auth[/>([^<]+)</, 1].unpack1("m0")).to eq("\x00bridge\x00s3cr3t")
      expect(written).to include("<bind")
      expect(socket.writes.last).to eq("<presence/>")
    ensure
      client.close
    end

    it "raises an AdapterError when the server does not offer STARTTLS" do
      plain = %(<stream:stream id="s"><stream:features/>)
      allow(client).to receive(:open_socket).and_return(ScriptedSocket.new([plain]))
      expect { client.connect }.to raise_error(Rubotty::AdapterError, /did not offer STARTTLS/)
    end

    it "raises an AdapterError when authentication is rejected" do
      replies = handshake_replies
      replies[3] = %(<failure xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><not-authorized/></failure>)
      allow(client).to receive(:open_socket).and_return(ScriptedSocket.new(replies))
      expect { client.connect }.to raise_error(Rubotty::AdapterError, /authentication was rejected/)
    end

    it "raises an AdapterError on a failed bind even when the server single-quotes type='error'" do
      replies = handshake_replies
      replies[5] = %(<iq type='error' id="i"><error type='cancel'><not-allowed/></error></iq>)
      allow(client).to receive(:open_socket).and_return(ScriptedSocket.new(replies))
      expect { client.connect }.to raise_error(Rubotty::AdapterError, /resource bind failed/)
    end
  end

  describe "after connecting" do
    before { client.connect }
    after { client.close }

    # #join blocks for the server's own presence about the nick just sent
    # (XEP-0045 7.2), so every test that joins needs one fed back. Waits for
    # the write to land before feeding the reply, the same idiom the IQ
    # round trips below use.
    def join_confirmed(room_jid, nick = "rubotty")
      responder = Thread.new do
        write = nil
        until write
          write = socket.writes.find { |w| w.start_with?("<presence") && w.include?(%(to="#{room_jid}/#{nick}")) }
        end
        socket.feed(
          %(<presence from="#{room_jid}/#{nick}"><x xmlns="http://jabber.org/protocol/muc#user">) +
            %(<status code="110"/></x></presence>)
        )
      end
      client.join(room_jid, nick)
    ensure
      responder&.join
    end

    it "joins a MUC room under the given nick, once the server confirms it" do
      join_confirmed("room@conf.example.org", "rubotty")
      join = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty")) }
      expect(join).to include("<x xmlns=\"http://jabber.org/protocol/muc\">")
    end

    it "raises with the error condition when the server refuses the join (issue #705)" do
      responder = Thread.new do
        write = nil
        write = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty")) } until write
        socket.feed(
          %(<presence from="room@conf.example.org/rubotty" type="error">) +
            %(<x xmlns="http://jabber.org/protocol/muc"/>) +
            %(<error type="auth"><not-authorized xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error>) +
            %(</presence>)
        )
      end
      expect { client.join("room@conf.example.org", "rubotty") }
        .to raise_error(Rubotty::AdapterError, /refused the join: not-authorized \(401\)/)
      responder.join
    end

    it "raises rather than believing itself joined when the server never confirms at all" do
      expect { client.join("room@conf.example.org", "rubotty", timeout: 0.05) }
        .to raise_error(Rubotty::AdapterError, /did not confirm the join/)
    end

    def conflict_presence(nick)
      %(<presence from="room@conf.example.org/#{nick}" type="error">) +
        %(<x xmlns="http://jabber.org/protocol/muc"/>) +
        %(<error type="cancel"><conflict xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error>) +
        %(</presence>)
    end

    it "retries under a fallback nick when the join is refused over a 409 nick collision" do
      responder = Thread.new do
        first = nil
        first = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty")) } until first
        socket.feed(conflict_presence("rubotty"))

        second = nil
        second = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty_")) } until second
        socket.feed(
          %(<presence from="room@conf.example.org/rubotty_">) +
            %(<x xmlns="http://jabber.org/protocol/muc#user"><status code="110"/></x></presence>)
        )
      end
      client.join("room@conf.example.org", "rubotty")
      expect(client.nick).to eq("rubotty_")
      responder.join
    end

    # #nick only ever holds the LAST fallback that landed, across every room;
    # #nicks is what a caller needs once one room has fallen back and another
    # has not, since the account is genuinely signed in under both at once.
    it "keeps the base nick alongside a fallback one, rather than losing it once another room falls back" do
      # conflict_presence answers "from" a fixed room@conf.example.org, so
      # this one is the room that falls back.
      responder = Thread.new do
        first = nil
        first = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty")) } until first
        socket.feed(conflict_presence("rubotty"))

        second = nil
        second = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty_")) } until second
        socket.feed(
          %(<presence from="room@conf.example.org/rubotty_">) +
            %(<x xmlns="http://jabber.org/protocol/muc#user"><status code="110"/></x></presence>)
        )
      end
      client.join("room@conf.example.org", "rubotty")
      responder.join

      join_confirmed("lobby@conf.example.org", "rubotty")

      expect(client.nicks).to contain_exactly("rubotty", "rubotty_")
    end

    it "fails the join once the fallback-nick retries are exhausted" do
      stub_const("#{described_class}::MAX_NICK_RETRIES", 1)
      responder = Thread.new do
        first = nil
        first = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty")) } until first
        socket.feed(conflict_presence("rubotty"))

        second = nil
        second = socket.writes.find { |w| w.include?(%(to="room@conf.example.org/rubotty_")) } until second
        socket.feed(conflict_presence("rubotty_"))
      end
      expect { client.join("room@conf.example.org", "rubotty") }
        .to raise_error(Rubotty::AdapterError, /refused the join: conflict \(409\)/)
      responder.join
    end

    it "answers an unsolicited iq get (a server ping) with a service-unavailable error rather than silence" do
      client.send(:handle_stanza, %(<iq from="conf.example.org" type="get" id="ping1"><ping xmlns="urn:xmpp:ping"/></iq>))
      expect(socket.writes.last).to eq(
        %(<iq type="error" id="ping1" to="conf.example.org">) +
          %(<error type="cancel"><service-unavailable xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>)
      )
    end

    it "sends a groupchat message to a joined room and returns a client id" do
      join_confirmed("room@conf.example.org", "rubotty")
      id = client.say("room@conf.example.org", "hello")
      expect(id).to match(/\Axmpp-/)
      expect(socket.writes.last).to eq(
        %(<message to="room@conf.example.org" type="groupchat" id="#{id}"><body>hello</body>) +
        %(<origin-id xmlns="urn:xmpp:sid:0" id="#{id}"/></message>)
      )
    end

    it "refuses to send to a room it has not joined" do
      expect { client.say("other@conf.example.org", "hi") }
        .to raise_error(Rubotty::AdapterError, /not joined/)
    end

    it "emits a MUC admin IQ for a kick" do
      join_confirmed("room@conf.example.org", "rubotty")
      client.kick("room@conf.example.org", "troll", reason: "spam")
      kick = socket.writes.last
      expect(kick).to include(%(<item nick="troll" role="none">))
      expect(kick).to include("<reason>spam</reason>")
    end

    it "retracts a message it posted (issue #707)" do
      join_confirmed("room@conf.example.org", "rubotty")
      client.retract("room@conf.example.org", "stanza-1")
      retracted = socket.writes.last
      expect(retracted).to include(%(<retract id="stanza-1" xmlns="urn:xmpp:message-retract:1"/>))
    end

    it "sets its whole reaction set on a message (issue #707)" do
      join_confirmed("room@conf.example.org", "rubotty")
      client.react("room@conf.example.org", "stanza-1", ["\u{1F44D}", "\u{2764}"])
      reacted = socket.writes.last
      expect(reacted).to include(%(<reactions id="stanza-1" xmlns="urn:xmpp:reactions:0">))
      expect(reacted).to include("<reaction>\u{1F44D}</reaction>")
      expect(reacted).to include("<reaction>\u{2764}</reaction>")
    end

    it "sends a one to one message to a bare JID (issue #726)" do
      client.send_dm("someone@example.org", "hello there")
      dm = socket.writes.last
      expect(dm).to include(%(to="someone@example.org" type="chat"))
      expect(dm).to include("<body>hello there</body>")
    end
  end

  describe "receiving" do
    it "delivers an inbound groupchat message using the stanza's own id (issue #706)" do
      events = []
      client.on_message { |event| events << event }
      client.send(:handle_stanza,
                  %(<message from="room@conf.example.org/grace" type="groupchat" id="w"><body>yo</body></message>))

      expect(events.size).to eq(1)
      expect(events.first).to include("room_jid" => "room@conf.example.org", "nick" => "grace", "body" => "yo")
      expect(events.first["id"]).to eq("w")
    end

    it "prefers the room's own XEP-0359 stanza-id over the stanza's plain id attribute" do
      events = []
      client.on_message { |event| events << event }
      client.send(
        :handle_stanza,
        %(<message from="room@conf.example.org/grace" type="groupchat" id="client-1">) +
          %(<body>yo</body>) +
          %(<stanza-id xmlns="urn:xmpp:sid:0" id="server-9" by="room@conf.example.org"/>) +
          %(</message>)
      )
      expect(events.first["id"]).to eq("server-9")
    end

    it "falls back to our own origin-id when a room rewrites the id and stamps no stanza-id (issue #1499)" do
      client.instance_variable_set(:@rooms, { "room@conf.example.org" => "rubotty" })
      sent_id = client.say("room@conf.example.org", "hi")
      events = []
      client.on_message { |event| events << event }
      client.send(
        :handle_stanza,
        %(<message from="room@conf.example.org/rubotty" type="groupchat" id="rewritten-by-room">) +
          %(<body>hi</body><origin-id xmlns="urn:xmpp:sid:0" id="#{sent_id}"/></message>)
      )
      expect(events.first["id"]).to eq(sent_id)
    end

    it "mints a synthetic id only when the stanza carries neither a stanza-id nor an id attribute" do
      events = []
      client.on_message { |event| events << event }
      client.send(:handle_stanza,
                  %(<message from="room@conf.example.org/grace" type="groupchat"><body>yo</body></message>))
      expect(events.first["id"]).to match(/\Axmpp-/)
    end

    it "ignores a stanza that is not a groupchat message" do
      events = []
      client.on_message { |event| events << event }
      client.send(:handle_stanza, %(<presence from="room@conf.example.org/grace"/>))
      expect(events).to be_empty
    end

    it "delivers an occupant's join and leave presence to on_presence, but never its own (issue #705)" do
      presences = []
      client.on_presence { |event| presences << event }
      client.send(
        :handle_stanza,
        %(<presence from="room@conf.example.org/grace"><x xmlns="http://jabber.org/protocol/muc#user"/></presence>)
      )
      client.send(
        :handle_stanza,
        %(<presence from="room@conf.example.org/grace" type="unavailable">) +
          %(<x xmlns="http://jabber.org/protocol/muc#user"/></presence>)
      )
      client.send(
        :handle_stanza,
        %(<presence from="room@conf.example.org/rubotty">) +
          %(<x xmlns="http://jabber.org/protocol/muc#user"><status code="110"/></x></presence>)
      )

      expect(presences).to eq(
        [
          { "room_jid" => "room@conf.example.org", "nick" => "grace", "kind" => "join" },
          { "room_jid" => "room@conf.example.org", "nick" => "grace", "kind" => "leave" }
        ]
      )
    end

    it "does not relay an occupant's own nick change as a spurious leave (XEP-0045 7.6, status 303)" do
      presences = []
      client.on_presence { |event| presences << event }
      client.send(
        :handle_stanza,
        %(<presence from="room@conf.example.org/grace" type="unavailable">) +
          %(<x xmlns="http://jabber.org/protocol/muc#user"><status code="303"/><status code="110"/></x></presence>)
      )
      client.send(
        :handle_stanza,
        %(<presence from="room@conf.example.org/grace2"><x xmlns="http://jabber.org/protocol/muc#user"/></presence>)
      )

      expect(presences).to eq([{ "room_jid" => "room@conf.example.org", "nick" => "grace2", "kind" => "join" }])
    end

    it "untracks the room, rather than relaying anything, once its own presence goes unavailable (a kick or ban)" do
      client.instance_variable_set(:@rooms, { "room@conf.example.org" => "rubotty" })
      presences = []
      client.on_presence { |event| presences << event }
      client.send(
        :handle_stanza,
        %(<presence from="room@conf.example.org/rubotty" type="unavailable">) +
          %(<x xmlns="http://jabber.org/protocol/muc#user"><status code="307"/></x></presence>)
      )

      expect(presences).to be_empty
      expect { client.say("room@conf.example.org", "hi") }.to raise_error(Rubotty::AdapterError, /not joined/)
    end

    it "delivers a direct message from a bare JID to on_dm, and ignores a MUC private message (issue #726)" do
      dms = []
      client.on_dm { |event| dms << event }
      client.send(:handle_stanza, %(<message from="someone@example.org" type="chat"><body>hi</body></message>))
      client.send(
        :handle_stanza,
        %(<message from="room@conf.example.org/grace" type="chat"><body>psst</body></message>)
      )

      expect(dms.size).to eq(1)
      expect(dms.first).to include("jid" => "someone@example.org", "body" => "hi")
    end

    it "drives a message off the socket through the reader thread end to end" do
      delivered = Thread::Queue.new
      client.on_message { |event| delivered << event }
      client.connect
      socket.feed(%(<message from="room@conf.example.org/ada" type="groupchat" id="r"><body>live</body></message>))

      event = delivered.pop(timeout: 5)
      expect(event).not_to be_nil
      expect(event["body"]).to eq("live")
    ensure
      client.close
    end
  end

  # Both queries are request/reply IQs correlated by id, so a reply can only be
  # fed once the request has been written and its id is known.
  describe "active room enumeration (#38)" do
    before { client.connect }
    after { client.close }

    # Waits for a write matching +pattern+, then feeds +stanza+ back with "ID"
    # replaced by that write's own id.
    def reply_when_written(pattern, stanza)
      Thread.new do
        write = nil
        write = socket.writes.find { |w| pattern.match?(w) } until write
        id = write[/ id="([^"]+)"/, 1]
        socket.feed(stanza.sub("ID", id))
      end
    end

    it "resolves bookmarked rooms from a correlated XEP-0048 reply" do
      responder = reply_when_written(
        /storage:bookmarks/,
        %(<iq type="result" id="ID"><query xmlns="jabber:iq:private"><storage xmlns="storage:bookmarks">) +
          %(<conference jid="room@conf.example.org" name="General"/></storage></query></iq>)
      )
      rooms = client.bookmarked_rooms(timeout: 2)
      responder.join
      expect(rooms).to eq([{ id: "room@conf.example.org", name: "General" }])
    end

    it "resolves a disco#items sweep of a configured MUC service" do
      responder = reply_when_written(
        /disco#items/,
        %(<iq type="result" id="ID"><query xmlns="http://jabber.org/protocol/disco#items">) +
          %(<item jid="a@conf.example.org" name="A"/><item jid="b@conf.example.org" name="B"/>) +
          %(</query></iq>)
      )
      rooms = client.discover_rooms("conf.example.org", timeout: 2)
      responder.join
      expect(rooms).to eq(
        [{ id: "a@conf.example.org", name: "A" }, { id: "b@conf.example.org", name: "B" }]
      )
    end

    it "skips the disco query and returns nothing with no service jid" do
      writes_before = socket.writes.size
      expect(client.discover_rooms(nil)).to eq([])
      expect(client.discover_rooms("")).to eq([])
      expect(socket.writes.size).to eq(writes_before)
    end

    it "degrades to no rooms when the server never replies (timeout)" do
      expect(client.bookmarked_rooms(timeout: 0.05)).to eq([])
    end

    it "degrades to no rooms on an error reply" do
      responder = reply_when_written(/storage:bookmarks/, %(<iq type="error" id="ID"><error type="cancel"/></iq>))
      rooms = client.bookmarked_rooms(timeout: 2)
      responder.join
      expect(rooms).to eq([])
    end

    it "never confuses a reply for one request with a different pending request" do
      # Fire two enumerations concurrently; each must resolve only its own id.
      bookmarks_thread = Thread.new { client.bookmarked_rooms(timeout: 2) }
      disco_thread = Thread.new { client.discover_rooms("conf.example.org", timeout: 2) }

      bookmarks_responder = reply_when_written(
        /storage:bookmarks/,
        %(<iq type="result" id="ID"><query xmlns="jabber:iq:private"><storage xmlns="storage:bookmarks">) +
          %(<conference jid="bm@conf.example.org" name="BM"/></storage></query></iq>)
      )
      disco_responder = reply_when_written(
        /disco#items/,
        %(<iq type="result" id="ID"><query xmlns="http://jabber.org/protocol/disco#items">) +
          %(<item jid="d@conf.example.org" name="D"/></query></iq>)
      )
      [bookmarks_responder, disco_responder].each(&:join)

      expect(bookmarks_thread.value).to eq([{ id: "bm@conf.example.org", name: "BM" }])
      expect(disco_thread.value).to eq([{ id: "d@conf.example.org", name: "D" }])
    end
  end

  # XEP-0363: discovery and the slot request are IQs over the same socket the
  # tests above already drive; only the final PUT leaves it, through the
  # injectable HTTP seam below.
  describe "attachment upload (XEP-0363)" do
    class XmppUploadFakeHttp
      Response = Struct.new(:code, :body)
      Request = Struct.new(:verb, :uri, :headers, :body)

      def initialize
        @requests = []
        @queue = []
      end

      attr_reader :requests

      def on(code, body = "") = (@queue << Response.new(code, body))

      def request(verb, uri, headers: {}, body: nil)
        @requests << Request.new(verb, uri, headers, body)
        @queue.shift || Response.new(201, "")
      end

      def last = @requests.last
    end

    let(:http) { XmppUploadFakeHttp.new }

    subject(:client) do
      described_class.new(jid: "bridge@example.org", password: "s3cr3t", nick: "rubotty",
                          http: http, logger: Rubotty::Log.null)
    end

    before do
      allow(client).to receive(:open_socket).and_return(socket)
      allow(client).to receive(:upgrade_to_tls) { |sock, _domain| sock }
      client.connect
    end
    after { client.close }

    def reply_when_written(pattern, stanza)
      Thread.new do
        write = nil
        write = socket.writes.find { |w| pattern.match?(w) } until write
        id = write[/ id="([^"]+)"/, 1]
        socket.feed(stanza.sub("ID", id))
      end
    end

    def disco_info_reply(supports_upload: true)
      feature = supports_upload ? %(<feature var="urn:xmpp:http:upload:0"/>) : ""
      %(<iq type="result" id="ID"><query xmlns="http://jabber.org/protocol/disco#info">#{feature}</query></iq>)
    end

    def slot_reply(put: "https://upload.example.org/abc/a.png", get: "https://download.example.org/abc/a.png")
      %(<iq type="result" id="ID"><slot xmlns="urn:xmpp:http:upload:0">) +
        %(<put url="#{put}"><header name="Authorization">Bearer secret</header></put>) +
        %(<get url="#{get}"/></slot></iq>)
    end

    describe "#upload_service (private discovery)" do
      it "queries the bot's own server when no upload_service is configured" do
        responder = reply_when_written(/disco#info/, disco_info_reply)
        result = client.send(:upload_service)
        responder.join
        expect(result).to eq("example.org")
      end

      it "queries a configured upload_service instead of the bare domain" do
        hinted_socket = ScriptedSocket.new(handshake_replies)
        hinted = described_class.new(jid: "bridge@example.org", password: "s3cr3t", nick: "rubotty",
                                     upload_service: "upload.example.org", http: http, logger: Rubotty::Log.null)
        allow(hinted).to receive(:open_socket).and_return(hinted_socket)
        allow(hinted).to receive(:upgrade_to_tls) { |sock, _domain| sock }
        hinted.connect

        responder = Thread.new do
          write = nil
          write = hinted_socket.writes.find { |w| w.include?("disco#info") } until write
          id = write[/ id="([^"]+)"/, 1]
          hinted_socket.feed(disco_info_reply.sub("ID", id))
        end
        result = hinted.send(:upload_service)
        responder.join
        expect(result).to eq("upload.example.org")
        expect(hinted_socket.writes.find { |w| w.include?("disco#info") }).to include(%(to="upload.example.org"))
      ensure
        hinted.close
      end

      it "answers nil, and remembers that answer, when the reply names no upload feature" do
        responder = reply_when_written(/disco#info/, disco_info_reply(supports_upload: false))
        expect(client.send(:upload_service)).to be_nil
        responder.join

        writes_before = socket.writes.size
        expect(client.send(:upload_service)).to be_nil
        expect(socket.writes.size).to eq(writes_before)
      end

      it "caches a successful discovery too, asking only once per connection" do
        responder = reply_when_written(/disco#info/, disco_info_reply)
        client.send(:upload_service)
        responder.join

        writes_before = socket.writes.size
        client.send(:upload_service)
        expect(socket.writes.size).to eq(writes_before)
      end
    end

    describe "#upload" do
      it "discovers the component, requests a slot, PUTs the bytes and returns the download url" do
        disco_responder = reply_when_written(/disco#info/, disco_info_reply)
        slot_responder = reply_when_written(/xmlns="urn:xmpp:http:upload:0"/, slot_reply)
        http.on(201)

        url = client.upload("PNGDATA", filename: "a.png", content_type: "image/png")

        disco_responder.join
        slot_responder.join
        expect(url).to eq("https://download.example.org/abc/a.png")
        expect(http.last.verb).to eq(:put)
        expect(http.last.uri.to_s).to eq("https://upload.example.org/abc/a.png")
        expect(http.last.headers["content-type"]).to eq("image/png")
        expect(http.last.headers["Authorization"]).to eq("Bearer secret")
        expect(http.last.body).to eq("PNGDATA")
      end

      it "answers nil, and never requests a slot, when the server advertises no upload support" do
        responder = reply_when_written(/disco#info/, disco_info_reply(supports_upload: false))
        result = client.upload("PNGDATA", filename: "a.png", content_type: "image/png")
        responder.join
        expect(result).to be_nil
        expect(socket.writes.none? { |w| w.include?("urn:xmpp:http:upload:0") }).to be(true)
        expect(http.requests).to be_empty
      end

      it "defaults a blank filename and content type before building the slot request" do
        disco_responder = reply_when_written(/disco#info/, disco_info_reply)
        slot_responder = reply_when_written(/xmlns="urn:xmpp:http:upload:0"/, slot_reply)
        http.on(201)

        client.upload("BYTES", filename: nil, content_type: nil)

        disco_responder.join
        slot_responder.join
        request_write = socket.writes.find { |w| w.include?("urn:xmpp:http:upload:0") }
        expect(request_write).to include(%(filename="attachment"))
        expect(request_write).to include(%(content-type="application/octet-stream"))
        expect(http.last.headers["content-type"]).to eq("application/octet-stream")
      end

      it "raises when the slot request comes back refused" do
        disco_responder = reply_when_written(/disco#info/, disco_info_reply)
        slot_responder = reply_when_written(
          /xmlns="urn:xmpp:http:upload:0"/,
          %(<iq type="error" id="ID"><error type="modify">) +
            %(<not-acceptable xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>)
        )

        expect { client.upload("PNGDATA", filename: "a.png", content_type: "image/png") }
          .to raise_error(Rubotty::AdapterError, /refused/)

        disco_responder.join
        slot_responder.join
      end

      it "raises when the PUT itself is refused" do
        disco_responder = reply_when_written(/disco#info/, disco_info_reply)
        slot_responder = reply_when_written(/xmlns="urn:xmpp:http:upload:0"/, slot_reply)
        http.on(413, "too large")

        expect { client.upload("PNGDATA", filename: "a.png", content_type: "image/png") }
          .to raise_error(Rubotty::AdapterError, /refused \(413\)/)

        disco_responder.join
        slot_responder.join
      end
    end
  end
end
