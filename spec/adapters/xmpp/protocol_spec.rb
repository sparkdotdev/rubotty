# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Adapters::Xmpp::Protocol do
  describe "escaping" do
    it "escapes the XML metacharacters in text" do
      expect(described_class.escape_text(%(a & b < c > d))).to eq("a &amp; b &lt; c &gt; d")
    end

    it "also escapes the quote characters in an attribute value" do
      expect(described_class.escape_attr(%(he said "hi" & 'bye'))).to eq("he said &quot;hi&quot; &amp; &apos;bye&apos;")
    end
  end

  describe "outbound stanzas" do
    it "opens the client stream to the domain" do
      header = described_class.stream_header("example.org")
      expect(header).to include(%(to="example.org"))
      expect(header).to include(%(xmlns="jabber:client"))
      expect(header).to include("version=\"1.0\"")
    end

    it "builds a SASL PLAIN auth stanza carrying authzid, local part and password" do
      stanza = described_class.auth_plain("bridge@example.org", "s3cr3t")
      expect(stanza).to include(%(mechanism="PLAIN"))
      payload = stanza[/>([^<]+)</, 1]
      expect(payload.unpack1("m0")).to eq("\x00bridge\x00s3cr3t")
    end

    it "asks for no history when joining a MUC so a rejoin does not replay" do
      stanza = described_class.join_presence("room@conf.example.org", "rubotty")
      expect(stanza).to include(%(to="room@conf.example.org/rubotty"))
      expect(stanza).to include("<history maxstanzas=\"0\"/>")
    end

    it "builds an escaped groupchat message" do
      stanza = described_class.groupchat("room@conf.example.org", "1 < 2 & true", id: "m1")
      expect(stanza).to include(%(type="groupchat"))
      expect(stanza).to include("<body>1 &lt; 2 &amp; true</body>")
    end

    it "kicks by setting an occupant role to none, with a reason" do
      stanza = described_class.admin_role("room@conf.example.org", "troll", "none", "spam", id: "k1")
      expect(stanza).to include(%(<item nick="troll" role="none">))
      expect(stanza).to include("<reason>spam</reason>")
      expect(stanza).to include(%(xmlns="http://jabber.org/protocol/muc#admin"))
    end

    it "bans by setting a bare JID affiliation to outcast" do
      stanza = described_class.admin_affiliation("room@conf.example.org", "bad@example.org", "outcast", nil, id: "b1")
      expect(stanza).to include(%(<item jid="bad@example.org" affiliation="outcast">))
      expect(stanza).not_to include("<reason>")
    end
  end

  describe "feature inspection" do
    let(:features) do
      <<~XML
        <stream:features><starttls xmlns="urn:ietf:params:xml:ns:xmpp-tls"/>
        <mechanisms xmlns="urn:ietf:params:xml:ns:xmpp-sasl"><mechanism>PLAIN</mechanism></mechanisms>
        <session xmlns="urn:ietf:params:xml:ns:xmpp-session"/></stream:features>
      XML
    end

    it "recognises STARTTLS, SASL PLAIN and session offers" do
      expect(described_class.offers_starttls?(features)).to be(true)
      expect(described_class.offers_sasl_plain?(features)).to be(true)
      expect(described_class.offers_session?(features)).to be(true)
    end

    it "reports a missing offer as absent" do
      expect(described_class.offers_starttls?("<stream:features/>")).to be(false)
      expect(described_class.offers_sasl_plain?("<mechanisms><mechanism>SCRAM-SHA-1</mechanism></mechanisms>")).to be(false)
    end
  end

  describe ".stanza_name" do
    it "strips a namespace prefix" do
      expect(described_class.stanza_name("<stream:features/>")).to eq("features")
    end

    it "reads a self closing stanza and an end tag" do
      expect(described_class.stanza_name("<proceed xmlns='x'/>")).to eq("proceed")
      expect(described_class.stanza_name("</stream:stream>")).to eq("stream")
    end
  end

  describe ".parse_message" do
    def groupchat(from:, body: "hi", extra: "")
      %(<message from="#{from}" type="groupchat" id="s1"><body>#{body}</body>#{extra}</message>)
    end

    it "splits the room JID and the occupant nick out of the from address" do
      event = described_class.parse_message(groupchat(from: "room@conf.example.org/grace"))
      expect(event["room_jid"]).to eq("room@conf.example.org")
      expect(event["nick"]).to eq("grace")
      expect(event["body"]).to eq("hi")
      expect(event["time"]).to be_a(Time)
    end

    it "unescapes entities in the body" do
      event = described_class.parse_message(groupchat(from: "room@conf.example.org/ada", body: "1 &lt; 2 &amp; ok"))
      expect(event["body"]).to eq("1 < 2 & ok")
    end

    it "reads a delayed history stamp when present" do
      delay = %(<delay xmlns="urn:xmpp:delay" stamp="2021-03-04T05:06:07Z"/>)
      event = described_class.parse_message(groupchat(from: "room@conf.example.org/ada", extra: delay))
      expect(event["time"]).to eq(Time.utc(2021, 3, 4, 5, 6, 7))
    end

    it "ignores a non groupchat message and a non message stanza" do
      chat = %(<message from="a@b/c" type="chat"><body>psst</body></message>)
      expect(described_class.parse_message(chat)).to be_nil
      expect(described_class.parse_message("<presence from='a@b/c'/>")).to be_nil
    end

    it "returns an empty body for a subject only groupchat, which the inbound path drops" do
      subject = %(<message from="room@conf.example.org/ada" type="groupchat"><subject>topic</subject></message>)
      expect(described_class.parse_message(subject)["body"]).to eq("")
    end

    it "falls back to our own origin-id when the room rewrote the id attribute and stamped no stanza-id" do
      reflected = %(<message from="room@conf.example.org/rubotty" type="groupchat" id="rewritten-by-room">) +
                  %(<body>hi</body><origin-id xmlns="urn:xmpp:sid:0" id="client-1"/></message>)
      expect(described_class.parse_message(reflected)["id"]).to eq("client-1")
    end

    it "still prefers the room's own stanza-id over our origin-id when the room stamped both" do
      reflected = %(<message from="room@conf.example.org/rubotty" type="groupchat" id="client-1">) +
                  %(<body>hi</body>) +
                  %(<stanza-id xmlns="urn:xmpp:sid:0" id="server-9" by="room@conf.example.org"/>) +
                  %(<origin-id xmlns="urn:xmpp:sid:0" id="client-1"/></message>)
      expect(described_class.parse_message(reflected)["id"]).to eq("server-9")
    end
  end

  describe ".bound_jid" do
    it "extracts the full JID the server assigned at bind" do
      iq = %(<iq type="result" id="i1"><bind xmlns="urn:ietf:params:xml:ns:xmpp-bind">) +
           %(<jid>bridge@example.org/abc123</jid></bind></iq>)
      expect(described_class.bound_jid(iq)).to eq("bridge@example.org/abc123")
    end
  end

  # Active room enumeration: disco#items and XEP-0048 bookmarks.
  describe ".disco_items_query" do
    it "asks the MUC service for its items" do
      stanza = described_class.disco_items_query("conference.example.org", id: "d1")
      expect(stanza).to include(%(to="conference.example.org"))
      expect(stanza).to include(%(type="get"))
      expect(stanza).to include(%(xmlns="http://jabber.org/protocol/disco#items"))
    end
  end

  describe ".bookmarks_query" do
    it "asks for the account's own private bookmark storage, addressed to no one" do
      stanza = described_class.bookmarks_query(id: "b1")
      expect(stanza).not_to include("to=")
      expect(stanza).to include(%(xmlns="jabber:iq:private"))
      expect(stanza).to include(%(<storage xmlns="storage:bookmarks"/>))
    end
  end

  # XEP-0363 HTTP File Upload: discovered the same way disco#items already
  # discovers rooms, then a slot is requested and PUT out of band of this file.
  describe ".disco_info_query" do
    it "asks a jid for its advertised features" do
      stanza = described_class.disco_info_query("upload.example.org", id: "u1")
      expect(stanza).to include(%(to="upload.example.org"))
      expect(stanza).to include(%(type="get"))
      expect(stanza).to include(%(xmlns="http://jabber.org/protocol/disco#info"))
    end
  end

  describe ".upload_slot_request" do
    it "names, sizes and types the file being uploaded" do
      stanza = described_class.upload_slot_request(
        "upload.example.org", filename: "a b.png", size: 1234, content_type: "image/png", id: "s1"
      )
      expect(stanza).to include(%(to="upload.example.org"))
      expect(stanza).to include(%(xmlns="urn:xmpp:http:upload:0"))
      expect(stanza).to include(%(filename="a b.png"))
      expect(stanza).to include(%(size="1234"))
      expect(stanza).to include(%(content-type="image/png"))
    end
  end

  describe ".upload_service?" do
    it "recognises the XEP-0363 feature in a disco#info reply" do
      iq = %(<iq type="result" id="u1"><query xmlns="http://jabber.org/protocol/disco#info">) +
           %(<feature var="urn:xmpp:http:upload:0"/></query></iq>)
      expect(described_class.upload_service?(iq)).to be(true)
    end

    it "is false when the reply lists other features but not this one" do
      iq = %(<iq type="result" id="u1"><query xmlns="http://jabber.org/protocol/disco#info">) +
           %(<feature var="http://jabber.org/protocol/muc"/></query></iq>)
      expect(described_class.upload_service?(iq)).to be(false)
    end

    it "is false for an error reply" do
      iq = %(<iq type="error" id="u1"><error type="cancel"/></iq>)
      expect(described_class.upload_service?(iq)).to be(false)
    end
  end

  describe ".parse_upload_slot" do
    it "reads the put url with its headers, and the get url" do
      iq = %(<iq type="result" id="s1"><slot xmlns="urn:xmpp:http:upload:0">) +
           %(<put url="https://upload.example.org/abc/a.png">) +
           %(<header name="Authorization">Basic xyz</header>) +
           %(<header name="Cookie">a=b</header>) +
           %(</put><get url="https://download.example.org/abc/a.png"/></slot></iq>)
      expect(described_class.parse_upload_slot(iq)).to eq(
        put_url: "https://upload.example.org/abc/a.png",
        get_url: "https://download.example.org/abc/a.png",
        headers: { "Authorization" => "Basic xyz", "Cookie" => "a=b" }
      )
    end

    it "accepts a slot with no extra headers" do
      iq = %(<iq type="result" id="s1"><slot xmlns="urn:xmpp:http:upload:0">) +
           %(<put url="https://upload.example.org/abc/a.png"/>) +
           %(<get url="https://download.example.org/abc/a.png"/></slot></iq>)
      expect(described_class.parse_upload_slot(iq)[:headers]).to eq({})
    end

    it "returns nil for an error reply" do
      iq = %(<iq type="error" id="s1"><error type="cancel"/></iq>)
      expect(described_class.parse_upload_slot(iq)).to be_nil
    end

    it "returns nil when the reply carries no slot element" do
      expect(described_class.parse_upload_slot(%(<iq type="result" id="s1"/>))).to be_nil
    end

    it "returns nil for malformed XML" do
      expect(described_class.parse_upload_slot("<iq><slot>")).to be_nil
    end
  end

  describe ".stanza_id" do
    it "reads the root element's id" do
      expect(described_class.stanza_id(%(<iq type="result" id="abc"><bind/></iq>))).to eq("abc")
    end

    it "is not fooled by an id attribute on a nested element" do
      stanza = %(<iq type="result"><item jid="x" id="nested-id"/></iq>)
      expect(described_class.stanza_id(stanza)).to be_nil
    end

    it "returns nil when the stanza is not a tag" do
      expect(described_class.stanza_id("not xml")).to be_nil
    end
  end

  describe ".parse_disco_items" do
    def disco_result(items)
      body = items.map { |i| %(<item jid="#{i[:jid]}"#{i[:name] ? %( name="#{i[:name]}") : ""}/>) }.join
      %(<iq type="result" id="d1"><query xmlns="http://jabber.org/protocol/disco#items">#{body}</query></iq>)
    end

    it "lists each room's jid and name" do
      iq = disco_result([{ jid: "a@conference.example.org", name: "Room A" },
                          { jid: "b@conference.example.org", name: "Room B" }])
      expect(described_class.parse_disco_items(iq)).to eq(
        [{ id: "a@conference.example.org", name: "Room A" },
         { id: "b@conference.example.org", name: "Room B" }]
      )
    end

    it "accepts an item with no name" do
      iq = disco_result([{ jid: "a@conference.example.org", name: nil }])
      expect(described_class.parse_disco_items(iq)).to eq([{ id: "a@conference.example.org", name: nil }])
    end

    it "returns nothing for an error reply" do
      iq = %(<iq type="error" id="d1"><error type="cancel"/></iq>)
      expect(described_class.parse_disco_items(iq)).to eq([])
    end

    it "returns nothing when the server never sent a query element" do
      expect(described_class.parse_disco_items(%(<iq type="result" id="d1"/>))).to eq([])
    end

    it "returns nothing for malformed XML" do
      expect(described_class.parse_disco_items("<iq><query>")).to eq([])
    end
  end

  describe ".parse_bookmarks" do
    it "lists each bookmarked conference's jid and name" do
      iq = %(<iq type="result" id="b1"><query xmlns="jabber:iq:private">) +
           %(<storage xmlns="storage:bookmarks">) +
           %(<conference jid="room@conference.example.org" name="General" autojoin="true"/>) +
           %(</storage></query></iq>)
      expect(described_class.parse_bookmarks(iq)).to eq([{ id: "room@conference.example.org", name: "General" }])
    end

    it "returns nothing for an empty bookmark storage (also what a XEP-0402-only server answers)" do
      iq = %(<iq type="result" id="b1"><query xmlns="jabber:iq:private">) +
           %(<storage xmlns="storage:bookmarks"/></query></iq>)
      expect(described_class.parse_bookmarks(iq)).to eq([])
    end

    it "returns nothing for an error reply" do
      iq = %(<iq type="error" id="b1"><error type="cancel"/></iq>)
      expect(described_class.parse_bookmarks(iq)).to eq([])
    end
  end

  describe ".element_length" do
    it "measures a self closing element" do
      expect(described_class.element_length("<proceed xmlns='x'/>rest")).to eq("<proceed xmlns='x'/>".length)
    end

    it "measures a nested element and stops at its close" do
      xml = "<message><body>hi</body></message><next/>"
      expect(described_class.element_length(xml)).to eq("<message><body>hi</body></message>".length)
    end

    it "does not count a '>' that sits inside a quoted attribute" do
      xml = %(<presence to="a>b"/>tail)
      expect(described_class.element_length(xml)).to eq(%(<presence to="a>b"/>).length)
    end

    it "returns nil for an element that is not yet complete" do
      expect(described_class.element_length("<message><body>hi</bo")).to be_nil
    end
  end

  describe Rubotty::Adapters::Xmpp::Protocol::Framer do
    it "reports the stream header once and returns the stanzas after it" do
      framer = described_class.new
      stream = %(<?xml version="1.0"?><stream:stream xmlns="jabber:client" xmlns:stream="s" id="1">) +
               %(<stream:features/><presence from="r@c/n"/>)
      stanzas = framer.push(stream)
      expect(framer.header?).to be(true)
      expect(stanzas).to eq(["<stream:features/>", %(<presence from="r@c/n"/>)])
    end

    it "reassembles a stanza that arrives across several chunks" do
      framer = described_class.new
      framer.push("<stream:stream>")
      expect(framer.push("<message><bo")).to eq([])
      expect(framer.push("dy>hi</body>")).to eq([])
      expect(framer.push("</message>")).to eq(["<message><body>hi</body></message>"])
    end

    it "skips whitespace keepalives between stanzas" do
      framer = described_class.new
      framer.push("<stream:stream>")
      expect(framer.push("\n  \n<presence/>\n")).to eq(["<presence/>"])
    end

    it "ignores the stream close" do
      framer = described_class.new
      framer.push("<stream:stream>")
      expect(framer.push("<presence/></stream:stream>")).to eq(["<presence/>"])
    end
  end
end
