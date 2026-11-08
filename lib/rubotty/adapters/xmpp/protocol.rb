# frozen_string_literal: true

require "rexml/document"

module Rubotty
  module Adapters
    module Xmpp
      # The pure part of XMPP: framing the byte stream into stanzas, building
      # the handful of stanzas a bridge sends, and turning an inbound MUC
      # message into a plain Hash. No socket and no state except {Framer}'s
      # byte buffer, so it is exhaustively unit testable, which matters since
      # getting the wire format wrong fails silently. Only the slice a bridge
      # needs is modelled: the C2S handshake (stream open, STARTTLS, SASL
      # PLAIN, resource bind), joining a MUC room, a groupchat message, and
      # MUC moderation.
      module Protocol
        STREAM_NS  = "http://etherx.jabber.org/streams"
        CLIENT_NS  = "jabber:client"
        TLS_NS     = "urn:ietf:params:xml:ns:xmpp-tls"
        SASL_NS    = "urn:ietf:params:xml:ns:xmpp-sasl"
        BIND_NS    = "urn:ietf:params:xml:ns:xmpp-bind"
        SESSION_NS = "urn:ietf:params:xml:ns:xmpp-session"
        MUC_NS     = "http://jabber.org/protocol/muc"
        MUC_ADMIN_NS = "http://jabber.org/protocol/muc#admin"
        DELAY_NS   = "urn:xmpp:delay"
        DISCO_ITEMS_NS = "http://jabber.org/protocol/disco#items"
        DISCO_INFO_NS = "http://jabber.org/protocol/disco#info"
        PRIVATE_NS = "jabber:iq:private"
        BOOKMARKS_STORAGE_NS = "storage:bookmarks"
        RETRACT_NS = "urn:xmpp:message-retract:1"
        REACTIONS_NS = "urn:xmpp:reactions:0"
        HTTP_UPLOAD_NS = "urn:xmpp:http:upload:0"
        ORIGIN_ID_NS = "urn:xmpp:sid:0"
        PING_NS = "urn:xmpp:ping"

        # XEP-0045 7.2: the defined-condition element a refused join's <error>
        # carries, mapped to the legacy numeric code for a readable message.
        MUC_JOIN_ERRORS = {
          "not-authorized" => 401,
          "forbidden" => 403,
          "item-not-found" => 404,
          "not-allowed" => 405,
          "not-acceptable" => 406,
          "registration-required" => 407,
          "conflict" => 409,
          "service-unavailable" => 503
        }.freeze

        module_function

        # XMPP is XML, so user text put into a stanza must be escaped, and an
        # attribute value doubly so (the quote characters).
        def escape_text(text)
          text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
        end

        def escape_attr(text)
          escape_text(text).gsub('"', "&quot;").gsub("'", "&apos;")
        end

        # Outbound stanza builders.

        # The opening tag of the client to server stream. It stays open for the
        # life of the connection and is resent after STARTTLS and after SASL,
        # each of which restarts the stream.
        def stream_header(domain)
          %(<?xml version="1.0"?>) +
            %(<stream:stream to="#{escape_attr(domain)}" xmlns="#{CLIENT_NS}" ) +
            %(xmlns:stream="#{STREAM_NS}" version="1.0">)
        end

        def stream_close = "</stream:stream>"

        def starttls = %(<starttls xmlns="#{TLS_NS}"/>)

        # SASL PLAIN (RFC 4616): base64 of "authzid \0 authcid \0 password" with
        # an empty authzid and the JID's local part as the authcid. pack("m0")
        # is base64 without line breaks, so no base64 gem is needed.
        def auth_plain(jid, password)
          node = jid.to_s.split("@", 2).first
          payload = "\x00#{node}\x00#{password}"
          %(<auth xmlns="#{SASL_NS}" mechanism="PLAIN">#{[payload].pack("m0")}</auth>)
        end

        # An empty <bind/> lets the server assign the resource, which is all a
        # bridge needs.
        def bind(id:)
          %(<iq type="set" id="#{escape_attr(id)}"><bind xmlns="#{BIND_NS}"/></iq>)
        end

        def session(domain, id:)
          %(<iq type="set" id="#{escape_attr(id)}" to="#{escape_attr(domain)}">) +
            %(<session xmlns="#{SESSION_NS}"/></iq>)
        end

        def presence = "<presence/>"

        # Join a MUC room as room@service/nick. maxstanzas="0" asks for no
        # history, so a rejoin never replays old messages into the bridge.
        def join_presence(room_jid, nick)
          %(<presence to="#{escape_attr("#{room_jid}/#{nick}")}">) +
            %(<x xmlns="#{MUC_NS}"><history maxstanzas="0"/></x></presence>)
        end

        def leave_presence(room_jid, nick)
          %(<presence to="#{escape_attr("#{room_jid}/#{nick}")}" type="unavailable"/>)
        end

        # XEP-0359: the sender's own id, restated as a dedicated element so a
        # correlation (a later retract or react) still works if the room
        # rewrites the stanza's own `id` attribute rather than preserving it
        # verbatim on reflection, which XEP-0045 never actually requires.
        def origin_id(id) = %(<origin-id xmlns="#{ORIGIN_ID_NS}" id="#{escape_attr(id)}"/>)

        def groupchat(room_jid, body, id:)
          %(<message to="#{escape_attr(room_jid)}" type="groupchat" id="#{escape_attr(id)}">) +
            %(<body>#{escape_text(body)}</body>#{origin_id(id)}</message>)
        end

        # A one to one message, never sent into a room.
        def chat_message(to_jid, body, id:)
          %(<message to="#{escape_attr(to_jid)}" type="chat" id="#{escape_attr(id)}">) +
            %(<body>#{escape_text(body)}</body>#{origin_id(id)}</message>)
        end

        # XEP-0424 message retraction, reflected by the room to every occupant
        # the same way the original post was. +target_id+ is the retracted
        # message's own id, the value {Client#say} returned.
        def retract_message(room_jid, target_id, id:)
          %(<message to="#{escape_attr(room_jid)}" type="groupchat" id="#{escape_attr(id)}">) +
            %(<retract id="#{escape_attr(target_id)}" xmlns="#{RETRACT_NS}"/>) +
            %(<body>(message retracted)</body>#{origin_id(id)}</message>)
        end

        # The same retraction, addressed one to one rather than into a room:
        # the only difference XEP-0424 makes between the two is the message
        # type. +target_id+ is the value {Client#send_dm} returned.
        def retract_chat_message(jid, target_id, id:)
          %(<message to="#{escape_attr(jid)}" type="chat" id="#{escape_attr(id)}">) +
            %(<retract id="#{escape_attr(target_id)}" xmlns="#{RETRACT_NS}"/>) +
            %(<body>(message retracted)</body>#{origin_id(id)}</message>)
        end

        # XEP-0444 reactions: the whole set the bot is putting on +target_id+,
        # replacing whatever it sent there before, no server support required.
        def reaction_message(room_jid, target_id, emojis, id:)
          reacts = Array(emojis).map { |emoji| "<reaction>#{escape_text(emoji)}</reaction>" }.join
          %(<message to="#{escape_attr(room_jid)}" type="groupchat" id="#{escape_attr(id)}">) +
            %(<reactions id="#{escape_attr(target_id)}" xmlns="#{REACTIONS_NS}">#{reacts}</reactions>) +
            %(#{origin_id(id)}</message>)
        end

        # RFC 6120 8.2.3: any stanza this connection cannot otherwise handle
        # (an unsolicited iq get, most often a server's own XEP-0199 ping)
        # still owes a reply; silence there is a protocol violation some
        # servers read as a dead connection. +to+ and +from+ swap since this
        # answers back to whoever sent the original.
        def service_unavailable(id:, to:)
          %(<iq type="error" id="#{escape_attr(id)}"#{to ? %( to="#{escape_attr(to)}") : ""}>) +
            %(<error type="cancel"><service-unavailable xmlns="urn:ietf:params:xml:ns:xmpp-stanzas"/></error></iq>)
        end

        # A single space: the whitespace keepalive RFC 6120 8.4.1 blesses, so an
        # idle connection does not read as dead to a server, load balancer or
        # NAT that closes on silence. No reply is possible or expected.
        def whitespace_ping = " "

        # MUC moderation (XEP-0045): a role is set on an occupant nick (kick sets
        # it to none), an affiliation on a bare JID (ban sets it to outcast).
        def admin_role(room_jid, nick, role, reason, id:)
          admin_item(room_jid, %(nick="#{escape_attr(nick)}" role="#{escape_attr(role)}"), reason, id)
        end

        def admin_affiliation(room_jid, jid, affiliation, reason, id:)
          admin_item(room_jid, %(jid="#{escape_attr(jid)}" affiliation="#{escape_attr(affiliation)}"), reason, id)
        end

        def admin_item(room_jid, item_attrs, reason, id)
          reason_el = reason ? "<reason>#{escape_text(reason)}</reason>" : ""
          %(<iq to="#{escape_attr(room_jid)}" type="set" id="#{escape_attr(id)}">) +
            %(<query xmlns="#{MUC_ADMIN_NS}"><item #{item_attrs}>#{reason_el}</item></query></iq>)
        end

        # Both queries below are read/reply IQs, unlike the fire-and-forget
        # presence and message stanzas above. {Client#request_iq} matches a reply
        # back to its request.

        # XEP-0030 service discovery: what items a MUC service hosts.
        # +service_jid+ takes the conference service's own JID, never a room's.
        def disco_items_query(service_jid, id:)
          %(<iq to="#{escape_attr(service_jid)}" type="get" id="#{escape_attr(id)}">) +
            %(<query xmlns="#{DISCO_ITEMS_NS}"/></iq>)
        end

        # XEP-0048 bookmark storage. No `to` attribute, so the server answers for
        # the requester's own account.
        def bookmarks_query(id:)
          %(<iq type="get" id="#{escape_attr(id)}">) +
            %(<query xmlns="#{PRIVATE_NS}"><storage xmlns="#{BOOKMARKS_STORAGE_NS}"/></query></iq>)
        end

        # XEP-0030 disco#info: what features +jid+ (a server or an upload
        # component) advertises. {Client#upload_service} reads the reply for
        # urn:xmpp:http:upload:0.
        def disco_info_query(jid, id:)
          %(<iq to="#{escape_attr(jid)}" type="get" id="#{escape_attr(id)}">) +
            %(<query xmlns="#{DISCO_INFO_NS}"/></iq>)
        end

        # XEP-0363 slot request: the file this bridge is about to PUT, so the
        # upload component can hand back a url sized and typed to match.
        def upload_slot_request(upload_jid, filename:, size:, content_type:, id:)
          %(<iq to="#{escape_attr(upload_jid)}" type="get" id="#{escape_attr(id)}">) +
            %(<request xmlns="#{HTTP_UPLOAD_NS}" filename="#{escape_attr(filename)}" ) +
            %(size="#{escape_attr(size)}" content-type="#{escape_attr(content_type)}"/></iq>)
        end

        # Stream feature inspection by string test: the feature set is a flat
        # advertisement and the strings are unambiguous.
        def offers_starttls?(features) = features.to_s.include?(TLS_NS)

        def offers_sasl_plain?(features) = /<mechanism>\s*PLAIN\s*<\/mechanism>/i.match?(features.to_s)

        def offers_session?(features) = features.to_s.include?(SESSION_NS)

        # Inbound parsing.

        # The local name of a stanza's root element, prefix stripped, so a
        # <stream:features> reads as "features" and a <proceed/> as "proceed".
        def stanza_name(stanza)
          match = stanza.to_s.match(/\A\s*<\/?([^\s>\/]+)/)
          match && match[1].split(":").last
        end

        def groupchat_message?(stanza)
          stanza_name(stanza) == "message" && /type=(["'])groupchat\1/.match?(stanza.to_s)
        end

        def chat_message?(stanza)
          stanza_name(stanza) == "message" && /type=(["'])chat\1/.match?(stanza.to_s)
        end

        # The `id` attribute of a stanza's root element only, so an id nested
        # inside a query result can never be taken for the correlation id.
        def stanza_id(stanza)
          root_attr(stanza, "id")
        end

        # The `type` attribute of a stanza's root element, quote style
        # irrelevant, or nil when it carries none.
        def stanza_type(stanza)
          root_attr(stanza, "type")
        end

        # The `from` attribute of a stanza's root element, for addressing a
        # reply back to whoever sent it.
        def stanza_from(stanza)
          root_attr(stanza, "from")
        end

        # A named attribute off a stanza's root element only, single or double
        # quoted, so one nested inside a child element can never be mistaken
        # for it.
        def root_attr(stanza, name)
          text = stanza.to_s
          return nil unless text.start_with?("<")

          close = tag_end(text, 0)
          return nil if close.nil?

          match = text[0..close].match(/\s#{Regexp.escape(name)}=(["'])(.*?)\1/)
          match && match[2]
        end

        # The rooms a MUC service hosts, or an empty array for an error or
        # malformed reply. Each item's `jid` is the room and `name` is the human
        # label the service advertises.
        def parse_disco_items(iq)
          disco_style_items(iq, "query")
        end

        # The account's XEP-0048 bookmarked rooms, or an empty array for an error
        # reply, no bookmarks, or a server that only speaks the newer XEP-0402
        # PEP bookmarks (it answers with an empty <storage/>, which reads the
        # same as "no bookmarks").
        def parse_bookmarks(iq)
          disco_style_items(iq, "query/storage", tag: "conference")
        end

        # Shared shape: an <iq> wrapping a container reached by +path+, whose
        # children carry a required `jid` and an optional `name`. An error reply
        # or a missing container degrades to no rooms rather than raising, so a
        # partially compliant server never breaks discovery.
        def disco_style_items(iq, path, tag: "item")
          root = REXML::Document.new(iq).root
          return [] if root.nil? || root.attributes["type"] == "error"

          container = root.elements[path]
          return [] if container.nil?

          container.get_elements(tag).filter_map do |element|
            jid = element.attributes["jid"]
            next nil if jid.to_s.empty?

            { id: jid, name: element.attributes["name"] }
          end
        rescue REXML::ParseException
          []
        end

        # True when a disco#info reply advertises XEP-0363 upload support.
        def upload_service?(iq)
          root = REXML::Document.new(iq).root
          return false if root.nil? || root.attributes["type"] == "error"

          query = root.elements["query"]
          return false if query.nil?

          query.get_elements("feature").any? { |el| el.attributes["var"] == HTTP_UPLOAD_NS }
        rescue REXML::ParseException
          false
        end

        # The slot handed back for an #upload_slot_request: the url to PUT bytes
        # to, the url a downloader later resolves, and whatever headers (a
        # component can ask for Authorization, Cookie or Expires on the PUT) go
        # with it. nil for an error reply or one missing either url.
        def parse_upload_slot(iq)
          root = REXML::Document.new(iq).root
          return nil if root.nil? || root.attributes["type"] == "error"

          slot = root.elements["slot"]
          return nil if slot.nil?

          put = slot.elements["put"]
          get = slot.elements["get"]
          put_url = put&.attributes&.[]("url")
          get_url = get&.attributes&.[]("url")
          return nil if put_url.to_s.empty? || get_url.to_s.empty?

          headers = put.get_elements("header").each_with_object({}) do |el, memo|
            name = el.attributes["name"]
            memo[name] = el.text.to_s unless name.to_s.empty?
          end
          { put_url: put_url, get_url: get_url, headers: headers }
        rescue REXML::ParseException
          nil
        end

        # A groupchat <message> as the plain Hash {Inbound} consumes, or nil for
        # anything else (a subject, a chat state, a private message); the sender is
        # the occupant nick, the resource of the "from" JID, since a semi anonymous
        # MUC hides real JIDs. The id is the room's own XEP-0359 stanza-id where
        # stamped, else our own origin-id (what survives a room rewriting `id` on
        # reflection without stamping a stanza-id), else the stanza's own id
        # attribute, so a reply or dedup has something the server recognizes.
        def parse_message(stanza)
          root = REXML::Document.new(stanza).root
          return nil if root.nil? || root.name != "message"
          return nil unless root.attributes["type"] == "groupchat"

          from = root.attributes["from"].to_s
          room = bare_jid(from)
          body = root.elements["body"]
          {
            "room_jid" => room,
            "nick" => resource_of(from),
            "body" => body ? body.text.to_s : "",
            "time" => delay_time(root),
            "id" => muc_stanza_id(root, room) || origin_id_of(root) || root.attributes["id"]
          }
        rescue REXML::ParseException
          nil
        end

        # The XEP-0359 <stanza-id> the room itself stamped (by="room_jid"), or
        # nil when there is none. A stanza can carry more than one stanza-id
        # from different entities (an archive, a room), and only the room's own
        # is the id a reply or a moderation action can address.
        def muc_stanza_id(root, room_jid)
          root.get_elements("stanza-id")
              .find { |el| el.attributes["by"].to_s == room_jid.to_s }
              &.attributes&.[]("id")
        end

        # The XEP-0359 <origin-id> {#origin_id} stamped on the way out, or nil
        # when there is none. A room reflects this element unchanged even on a
        # server that rewrites the stanza's own `id` attribute, so it is what
        # {#say} and {#react}'s later retract or reaction still has to match
        # against.
        def origin_id_of(root)
          root.get_elements("origin-id").first&.attributes&.[]("id")
        end

        # A one to one type="chat" message from a bare JID, the DM control
        # lane's input. A MUC private message is also type="chat" but carries a
        # resource on its "from"; that is a different gesture and is left nil
        # here for the caller to ignore.
        def parse_chat_message(stanza)
          root = REXML::Document.new(stanza).root
          return nil if root.nil? || root.name != "message"
          return nil unless root.attributes["type"] == "chat"

          from = root.attributes["from"].to_s
          return nil unless resource_of(from).nil?

          body = root.elements["body"]
          return nil if body.nil?

          { "jid" => from, "body" => body.text.to_s, "time" => delay_time(root) }
        rescue REXML::ParseException
          nil
        end

        # A MUC presence (an occupant's, our own join confirmation, or a
        # refused join), or nil for anything with no MUC user extension at all
        # (an ordinary roster presence, unrelated to any room).
        #
        # @return [Hash, nil] room_jid:, nick:, type: ("available",
        #   "unavailable" or "error"), status_codes: (Array<Integer>),
        #   error_condition: (String, nil)
        def parse_muc_presence(stanza)
          root = REXML::Document.new(stanza).root
          return nil if root.nil? || root.name != "presence"

          x = root.elements["x"]
          return nil if x.nil?

          from = root.attributes["from"].to_s
          type = root.attributes["type"]
          {
            room_jid: bare_jid(from),
            nick: resource_of(from),
            type: type || "available",
            status_codes: x.get_elements("status").filter_map { |el| el.attributes["code"]&.to_i },
            error_condition: type == "error" ? muc_error_condition(root) : nil
          }
        rescue REXML::ParseException
          nil
        end

        def muc_error_condition(root)
          root.elements["error"]&.elements&.to_a&.first&.name
        end

        # Extract the full JID assigned by a resource bind result.
        def bound_jid(iq)
          jid = REXML::Document.new(iq).root&.elements&.[]("bind/jid")
          jid&.text
        rescue REXML::ParseException
          nil
        end

        def bare_jid(jid) = jid.to_s.split("/", 2).first
        def resource_of(jid) = jid.to_s.split("/", 2)[1]

        def delay_time(root)
          delay = root.elements.to_a.find { |el| el.name == "delay" && el.attributes["stamp"] }
          return Time.now if delay.nil?

          require "time"
          Time.parse(delay.attributes["stamp"])
        rescue ArgumentError
          Time.now
        end

        # Framing. An XMPP stream is an open <stream:stream> followed by a run of
        # top level stanzas; bytes arrive off the socket in arbitrary chunks, so
        # the scan resumes across pushes and a partial stanza simply waits.

        # Index of the '>' that closes the tag beginning at +start+, skipping any
        # '>' inside a quoted attribute value. nil if the tag is not yet complete.
        def tag_end(string, start)
          index = start + 1
          quote = nil
          while index < string.length
            char = string[index]
            if quote
              quote = nil if char == quote
            elsif char == '"' || char == "'"
              quote = char
            elsif char == ">"
              return index
            end
            index += 1
          end
          nil
        end

        # Byte length of the one complete top level element at the front of
        # +string+, tracking depth so nested children are included. nil if the
        # element is not yet complete.
        def element_length(string)
          return nil if string.empty? || string[0] != "<"

          depth = 0
          index = 0
          while index < string.length
            if string[index] != "<"
              index += 1
              next
            end

            if string[index, 4] == "<!--"
              close = string.index("-->", index)
              return nil if close.nil?

              index = close + 3
              next
            elsif string[index, 9] == "<![CDATA["
              close = string.index("]]>", index)
              return nil if close.nil?

              index = close + 3
              next
            end

            gt = tag_end(string, index)
            return nil if gt.nil?

            tag = string[index..gt]
            if tag.start_with?("</")
              depth -= 1
            elsif tag[-2] != "/"
              depth += 1
            end
            index = gt + 1
            return index if depth <= 0
          end
          nil
        end

        # Splits an incoming XMPP byte stream into stanzas. The stream header is
        # reported once via #header; every balanced top level element after it
        # comes back from #push as it completes.
        class Framer
          def initialize
            @buffer = +""
            @header = nil
          end

          attr_reader :header

          def header? = !@header.nil?

          # Append raw bytes and return the stanzas that became complete.
          def push(bytes)
            @buffer << bytes.to_s
            stanzas = []
            loop do
              result = take_one
              break if result.nil?

              stanzas << result[1] if result[0] == :stanza
            end
            stanzas
          end

          private

          # [:stanza, string] for a top level stanza, [:skip] for the stream
          # header, an XML declaration or a stream close, nil when more bytes are
          # needed.
          def take_one
            @buffer.sub!(/\A\s+/, "")
            return nil if @buffer.empty?

            if @header.nil?
              return take_declaration if @buffer.start_with?("<?")
              return take_header if @buffer.start_with?("<stream:stream", "<stream ")
            end

            return take_close if @buffer.start_with?("</stream:stream", "</stream>")

            length = Protocol.element_length(@buffer)
            return nil if length.nil?

            [:stanza, @buffer.slice!(0, length)]
          end

          def take_declaration
            close = @buffer.index("?>")
            return nil if close.nil?

            @buffer.slice!(0, close + 2)
            [:skip]
          end

          def take_header
            gt = Protocol.tag_end(@buffer, 0)
            return nil if gt.nil?

            @header = @buffer.slice!(0, gt + 1)
            [:skip]
          end

          def take_close
            gt = Protocol.tag_end(@buffer, 0)
            return nil if gt.nil?

            @buffer.slice!(0, gt + 1)
            [:skip]
          end
        end
      end
    end
  end
end
