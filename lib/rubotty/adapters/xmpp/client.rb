# frozen_string_literal: true

require "socket"
require "securerandom"
require "net/http"
require "uri"

module Rubotty
  module Adapters
    module Xmpp
      # The one seam that speaks XMPP: owns the socket, runs the C2S
      # handshake, and reads and writes stanzas; parsing and stanza building
      # live in the pure {Protocol} module. xmpp4r is unusable here since it
      # monkeypatches REXML::IOSource#position, which breaks the stream
      # parser on the REXML shipping with Ruby 4.0.
      class Client
        READ_CHUNK = 4096

        # How long #join waits for the server's own join presence (a
        # confirmation or a refusal) before giving up.
        JOIN_TIMEOUT = 10

        # How many times a MUC join refused over a nick collision (409
        # conflict) retries under a fallback nick before giving up.
        MAX_NICK_RETRIES = 3

        # How often the whitespace keepalive (RFC 6120 8.4.1) writes a single
        # space to the stream, so a server, load balancer or NAT that closes
        # an idle connection never mistakes this one for dead.
        KEEPALIVE_INTERVAL = 60

        def initialize(jid:, password:, nick:, host: nil, port: 5222, upload_service: nil, http: nil, logger: nil)
          @jid = jid
          @password = password
          @nick = nick
          @host = host
          @port = port
          # A configured XEP-0363 upload component JID; blank means "ask the
          # account's own server instead", the same fallback #discover_rooms
          # already leaves to bookmarks-only when muc_service is unset.
          @upload_hint = upload_service
          @http = http || HttpTransport.new
          @logger = logger
          @socket = nil
          @framer = nil
          @pending = []
          @rooms = {}
          @on_message = nil
          @on_presence = nil
          @on_dm = nil
          @write_mutex = Mutex.new
          @reader = nil
          @keepalive = nil
          @running = false
          # Stanza id => the Queue the #request_iq caller is blocked on.
          @pending_iqs = {}
          # "room_jid/nick" => the Queue #join is blocked on, waiting for the
          # server's own confirming or refusing presence.
          @pending_presence = {}
          @pending_mutex = Mutex.new
          # :unknown until #upload's first call resolves it; then the upload
          # component's JID, or nil once a query came back with no support.
          # Reset on #close, since a fresh connection may land on a different
          # server.
          @upload_service = :unknown
          # Whether the read loop is up and reading, set true alongside it in #connect
          # and false the moment it ends, for any reason; #alive? answers from this,
          # the same signal the IRC client tracks. @running only clears in #close, so a
          # dropped connection nothing has noticed yet would otherwise read as healthy.
          @alive = false
        end

        attr_reader :logger, :nick

        # Is the read loop still up? False before the first #connect, and false
        # again once it has ended, whether from #close, an exception, or the
        # server just going away with no warning.
        def alive? = @alive

        def on_message(&block)
          @on_message = block
        end

        # Fires for an occupant's presence (join/leave), never our own.
        def on_presence(&block)
          @on_presence = block
        end

        # Fires for a one to one type="chat" message from a bare JID.
        def on_dm(&block)
          @on_dm = block
        end

        # Open the socket and run the handshake: stream open, STARTTLS, SASL PLAIN,
        # resource bind, then initial presence. Returns once the reader thread is
        # delivering stanzas.
        def connect
          domain = jid_domain(@jid)
          @socket = open_socket
          @running = true
          @alive = true

          features = open_stream(domain)
          features = negotiate_tls(domain, features)
          authenticate(features)
          features = open_stream(domain)
          bind_resource
          establish_session(domain) if Protocol.offers_session?(features)
          write(Protocol.presence)
          start_reader
          start_keepalive
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("could not connect to XMPP: #{e.class}: #{e.message}", adapter: :xmpp)
        end

        # Room JIDs presently believed joined. What {Adapters::Base#joined_route_keys}
        # reads for {Adapters::Base#reconcile_channels}.
        def joined_rooms = @rooms.keys

        # Every nick actually registered on the server across every joined
        # room, +@nick+ included even before anything has joined under it.
        # Usually one value; more than one only once a 409 nick collision (see
        # #join) has forced a fallback in some rooms and not others, so a
        # message echoing back under either nick still has to read as ours.
        def nicks = ([@nick] + @rooms.values).uniq

        # Join one MUC room under our nick and block for the server's own confirming
        # or refusing presence (XEP-0045 7.2), so a room is never marked joined until
        # it actually is. A refusal over a nick collision (409) retries under a
        # fallback nick, up to {MAX_NICK_RETRIES} times, since a stale ghost session
        # from an earlier crash is common and otherwise blocks this room for good;
        # any other refusal or a timeout raises straight away. Its messages then
        # arrive on the reader thread through {#deliver}.
        def join(room_jid, nick = @nick, timeout: JOIN_TIMEOUT, attempt: 0)
          key = presence_key(room_jid, nick)
          queue = Queue.new
          @pending_mutex.synchronize { @pending_presence[key] = queue }
          write(Protocol.join_presence(room_jid, nick))
          presence = queue.pop(timeout: timeout)
          return retry_join(room_jid, nick, timeout, attempt) if nick_conflict?(presence, attempt)

          confirm_join(room_jid, presence)
          @nick = nick if attempt.positive?
          @rooms[room_jid.to_s] = nick
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("could not join XMPP room #{room_jid}: #{e.message}", adapter: :xmpp)
        ensure
          @pending_mutex.synchronize { @pending_presence.delete(key) }
        end

        # Send a groupchat message to a joined room, returning a client side id.
        def say(room_jid, body)
          raise AdapterError.new("not joined to XMPP room #{room_jid}", adapter: :xmpp) unless @rooms.key?(room_jid.to_s)

          id = new_id
          write(Protocol.groupchat(room_jid, body, id: id))
          id
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP send failed: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # Retract a message this bot posted (XEP-0424), by the id {#say} or the
        # room's own stanza-id returned for it.
        def retract(room_jid, target_id)
          ensure_joined(room_jid)
          id = new_id
          write(Protocol.retract_message(room_jid, target_id, id: id))
          id
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP retract failed: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # Set the bot's whole reaction set on a message (XEP-0444), replacing
        # whatever it sent there before.
        def react(room_jid, target_id, emojis)
          ensure_joined(room_jid)
          id = new_id
          write(Protocol.reaction_message(room_jid, target_id, emojis, id: id))
          id
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP react failed: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # Retract a one to one message this bot posted (XEP-0424), by the id
        # {#send_dm} returned. No #ensure_joined: a bare JID needs no room.
        def retract_dm(jid, target_id)
          id = new_id
          write(Protocol.retract_chat_message(jid, target_id, id: id))
          id
        rescue StandardError => e
          raise AdapterError.new("XMPP DM retract failed: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # Send a one to one message to a bare JID, the DM control lane's reply.
        def send_dm(jid, body)
          id = new_id
          write(Protocol.chat_message(jid, body, id: id))
          id
        rescue StandardError => e
          raise AdapterError.new("XMPP DM send failed: #{e.message}", adapter: :xmpp, retryable: true)
        end

        # A kick sets the occupant's role to none; a ban sets a bare JID's
        # affiliation to outcast; an unban clears it back to none. The IQ is sent
        # without waiting, so a server side refusal is not surfaced here.
        def kick(room_jid, nick, reason: nil)
          ensure_joined(room_jid)
          write(Protocol.admin_role(room_jid, nick, "none", reason, id: new_iq_id))
        end

        def ban(room_jid, bare_jid, reason: nil)
          ensure_joined(room_jid)
          write(Protocol.admin_affiliation(room_jid, bare_jid, "outcast", reason, id: new_iq_id))
        end

        def unban(room_jid, bare_jid)
          ensure_joined(room_jid)
          write(Protocol.admin_affiliation(room_jid, bare_jid, "none", nil, id: new_iq_id))
        end

        def close
          @running = false
          @rooms.each { |room, nick| write(Protocol.leave_presence(room, nick)) }
          write(Protocol.stream_close)
        rescue StandardError => e
          logger&.warn { "error while closing the XMPP stream: #{e.message}" }
          nil
        ensure
          @reader&.kill
          @reader = nil
          @keepalive&.kill
          @keepalive = nil
          @socket&.close
          @socket = nil
          @rooms = {}
          @upload_service = :unknown
        end

        # Both queries below are read/reply IQs, so a reply goes through
        # {#request_iq}, which blocks on a Queue that {#handle_stanza} feeds.

        # XEP-0048 bookmarks: the rooms this account has bookmarked, autojoin or not;
        # never raises. A server that only implements the newer XEP-0402 answers with
        # an empty <storage/>, which reads here as "no bookmarks".
        #
        # @return [Array<Hash>] { id:, name: } per bookmarked room
        def bookmarked_rooms(timeout: 5)
          id = new_iq_id
          reply = request_iq(Protocol.bookmarks_query(id: id), id: id, timeout: timeout)
          return [] if reply.nil?

          Protocol.parse_bookmarks(reply)
        rescue StandardError => e
          logger&.warn { "XMPP bookmark discovery failed: #{e.class}: #{e.message}" }
          []
        end

        # XEP-0030 service discovery: the rooms a MUC service lists publicly,
        # degrading to empty like {#bookmarked_rooms}. The caller supplies
        # +service_jid+, since a server can host several MUC services.
        #
        # @return [Array<Hash>] { id:, name: } per listed room
        def discover_rooms(service_jid, timeout: 5)
          return [] if service_jid.to_s.empty?

          id = new_iq_id
          reply = request_iq(Protocol.disco_items_query(service_jid, id: id), id: id, timeout: timeout)
          return [] if reply.nil?

          Protocol.parse_disco_items(reply)
        rescue StandardError => e
          logger&.warn { "XMPP room disco failed for #{service_jid}: #{e.class}: #{e.message}" }
          []
        end

        # XEP-0363: discover the upload component (cached for the life of this
        # connection, see #close), request a slot for +bytes+, and PUT them to
        # the url the slot names. Returns the url a room's occupants resolve to
        # fetch the file back.
        #
        # @return [String, nil] nil when no server (or configured upload_service)
        #   ever advertises the feature; anything else wrong with the request raises.
        def upload(bytes, filename:, content_type:)
          service = upload_service
          return nil if service.nil?

          name = filename.to_s.strip.empty? ? "attachment" : filename.to_s
          type = content_type.to_s.strip.empty? ? "application/octet-stream" : content_type
          slot = request_slot(service, filename: name, size: bytes.bytesize, content_type: type)
          put_bytes(slot, bytes, type)
          slot[:get_url]
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("XMPP upload failed: #{e.message}", adapter: :xmpp, retryable: true)
        end

        private

        # The XEP-0363 upload component's JID, resolved once per connection via
        # disco#info on the configured hint or, absent one, this account's own
        # server. A homeserver's advertised feature set does not change
        # mid-connection, so the answer is kept rather than re-asked before
        # every upload.
        def upload_service
          return @upload_service unless @upload_service == :unknown

          @upload_service = discover_upload_service
        end

        def discover_upload_service
          jid = @upload_hint.to_s.strip.empty? ? jid_domain(@jid) : @upload_hint.to_s
          id = new_iq_id
          reply = request_iq(Protocol.disco_info_query(jid, id: id), id: id, timeout: 5)
          return nil if reply.nil? || !Protocol.upload_service?(reply)

          jid
        rescue StandardError => e
          logger&.warn { "XMPP upload discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        def request_slot(service_jid, filename:, size:, content_type:)
          id = new_iq_id
          xml = Protocol.upload_slot_request(service_jid, filename: filename, size: size,
                                             content_type: content_type, id: id)
          reply = request_iq(xml, id: id, timeout: 20)
          if reply.nil?
            raise AdapterError.new("XMPP upload slot request to #{service_jid} timed out",
                                   adapter: :xmpp, retryable: true)
          end

          slot = Protocol.parse_upload_slot(reply)
          raise AdapterError.new("XMPP upload slot request to #{service_jid} was refused", adapter: :xmpp) if slot.nil?

          slot
        end

        def put_bytes(slot, bytes, content_type)
          uri = URI.parse(slot[:put_url])
          headers = slot[:headers].merge("content-type" => content_type)
          response = @http.request(:put, uri, headers: headers, body: bytes)
          code = response.code.to_i
          return if code.between?(200, 299)

          raise AdapterError.new("XMPP upload PUT was refused (#{code})", adapter: :xmpp, retryable: code >= 500)
        rescue URI::Error => e
          raise AdapterError.new("XMPP upload PUT url was invalid: #{e.message}", adapter: :xmpp)
        end

        # Send an IQ and block the calling thread for its correlated reply, matched
        # by id, returning nil on timeout. Always unregistering after keeps a timed
        # out reply from reaching a later request that reused the id.
        def request_iq(xml, id:, timeout:)
          queue = Queue.new
          @pending_mutex.synchronize { @pending_iqs[id] = queue }
          write(xml)
          queue.pop(timeout: timeout)
        ensure
          @pending_mutex.synchronize { @pending_iqs.delete(id) }
        end

        def open_socket
          TCPSocket.new(@host || jid_domain(@jid), @port)
        end

        # (Re)start the stream and return the server's <stream:features>. A fresh
        # framer each time, because STARTTLS and SASL each restart the stream.
        def open_stream(domain)
          @framer = Protocol::Framer.new
          @pending = []
          write(Protocol.stream_header(domain))
          read_named("features")
        end

        def negotiate_tls(domain, features)
          unless Protocol.offers_starttls?(features)
            raise AdapterError.new("XMPP server did not offer STARTTLS", adapter: :xmpp)
          end

          write(Protocol.starttls)
          reply = read_stanza
          unless Protocol.stanza_name(reply) == "proceed"
            raise AdapterError.new("XMPP server refused STARTTLS", adapter: :xmpp)
          end

          @socket = upgrade_to_tls(@socket, domain)
          open_stream(domain)
        end

        def upgrade_to_tls(socket, domain)
          require "openssl"
          context = OpenSSL::SSL::SSLContext.new
          context.set_params
          ssl = OpenSSL::SSL::SSLSocket.new(socket, context)
          ssl.sync_close = true
          ssl.hostname = domain
          ssl.connect
          ssl.post_connection_check(domain)
          ssl
        end

        def authenticate(features)
          unless Protocol.offers_sasl_plain?(features)
            raise AdapterError.new("XMPP server does not offer SASL PLAIN", adapter: :xmpp)
          end

          write(Protocol.auth_plain(@jid, @password))
          reply = read_stanza
          case Protocol.stanza_name(reply)
          when "success" then nil
          when "failure" then raise AdapterError.new("XMPP authentication was rejected", adapter: :xmpp)
          else raise AdapterError.new("unexpected reply to XMPP auth: #{reply.inspect}", adapter: :xmpp)
          end
        end

        def bind_resource
          write(Protocol.bind(id: new_iq_id))
          reply = read_named("iq")
          raise AdapterError.new("XMPP resource bind failed", adapter: :xmpp) if Protocol.stanza_type(reply) == "error"
        end

        def establish_session(domain)
          write(Protocol.session(domain, id: new_iq_id))
          read_named("iq")
        end

        def start_reader
          @reader = Thread.new { read_loop }
        end

        # RFC 6120 8.4.1's whitespace keepalive: nothing to read back, just a
        # single space written on an interval so an idle connection never
        # reads as dead to a server, a load balancer, or a NAT in between.
        def start_keepalive
          @keepalive = Thread.new do
            Thread.current.name = "xmpp-keepalive"
            while @running
              sleep(KEEPALIVE_INTERVAL)
              write(Protocol.whitespace_ping) if @running
            end
          rescue StandardError => e
            logger&.warn { "XMPP keepalive stopped: #{e.class}: #{e.message}" } if @running
          end
        end

        def read_loop
          Thread.current.name = "xmpp-read"
          while @running
            stanza = read_stanza
            break if stanza.nil?

            handle_stanza(stanza)
          end
          logger&.warn { "XMPP read loop ended: connection closed by the server" } if @running
        rescue StandardError => e
          logger&.warn { "XMPP read loop ended: #{e.class}: #{e.message}" } if @running
        ensure
          @alive = false
        end

        def handle_stanza(stanza)
          return if handle_pending_iq(stanza)
          return if handle_presence(stanza)
          return if handle_chat_message(stanza)
          return if handle_unsolicited_iq(stanza)
          return unless Protocol.groupchat_message?(stanza)

          event = Protocol.parse_message(stanza)
          deliver(event) unless event.nil?
        end

        # RFC 6120 8.2.3: any get or set this connection did not itself ask
        # for, most often a server's own XEP-0199 ping, still owes a reply;
        # silently dropping it is a protocol violation some servers read as a
        # dead connection worth closing. A stray result or error with no
        # matching #request_iq is not a request and gets no reply of its own.
        def handle_unsolicited_iq(stanza)
          return false unless Protocol.stanza_name(stanza) == "iq"

          type = Protocol.stanza_type(stanza)
          return false unless %w[get set].include?(type)

          id = Protocol.stanza_id(stanza)
          write(Protocol.service_unavailable(id: id, to: Protocol.stanza_from(stanza))) if id
          true
        end

        # Claims a presence about our own pending #join first (a confirmation
        # or a refusal); anything else is an occupant's join or leave. True
        # whenever the stanza was a presence at all, whether or not it named a
        # room, so #handle_stanza never falls through to message parsing.
        def handle_presence(stanza)
          return false unless Protocol.stanza_name(stanza) == "presence"

          presence = Protocol.parse_muc_presence(stanza)
          deliver_presence(presence) unless presence.nil? || claim_join_presence(presence)
          true
        end

        def claim_join_presence(presence)
          key = presence_key(presence[:room_jid], presence[:nick])
          queue = @pending_mutex.synchronize { @pending_presence[key] }
          return false if queue.nil?

          queue << presence
          true
        end

        # An occupant other than us joining or leaving. Our own presence
        # changing after the join settled (a kick, a ban, the room going
        # away) is not an occupant event and never reaches {#on_presence};
        # {#handle_own_presence} untracks the room instead, so a moderate
        # caller stops believing a #say or #react into it is still landing.
        def deliver_presence(presence)
          return handle_own_presence(presence) if presence[:nick] == @nick
          return if @on_presence.nil?
          # XEP-0045 7.6: an occupant's own nick change announces as the old nick
          # going unavailable with status 303, then the new nick becoming available.
          # The old-nick half is not a real departure and would read as a spurious
          # leave; with no rename event to relay it as, only the join half is kept.
          return if presence[:type] == "unavailable" && presence[:status_codes].include?(303)

          kind = presence[:type] == "unavailable" ? "leave" : "join"
          @on_presence.call("room_jid" => presence[:room_jid], "nick" => presence[:nick], "kind" => kind)
        rescue StandardError => e
          logger&.error { "error handling an XMPP presence: #{e.class}: #{e.message}" }
        end

        # XEP-0045 statuses 301 (banned) and 307 (kicked) both read as this
        # nick going unavailable; a room simply being destroyed does too, with
        # neither code set. Every case means the same thing to this client: it
        # is no longer in the room, whatever the reason, so #ensure_joined
        # must start refusing rather than let a caller believe a message it
        # sends is still landing.
        def handle_own_presence(presence)
          return unless presence[:type] == "unavailable"
          return if @rooms.delete(presence[:room_jid]).nil?

          reason = (presence[:status_codes] & [301, 307]).first
          logger&.warn { "XMPP: removed from #{presence[:room_jid]}#{reason ? " (status #{reason})" : ""}" }
        rescue StandardError => e
          logger&.error { "error handling our own XMPP presence: #{e.class}: #{e.message}" }
        end

        # Raises when +presence+ is nil (no reply arrived in time) or carries
        # type="error" (the join was refused). A nil presence never reaches
        # here as a success: the caller already treats "no confirmation" as a
        # failure.
        def confirm_join(room_jid, presence)
          if presence.nil?
            raise AdapterError.new("XMPP room #{room_jid} did not confirm the join in time", adapter: :xmpp)
          end
          return unless presence[:type] == "error"

          condition = presence[:error_condition]
          code = Protocol::MUC_JOIN_ERRORS[condition]
          reason = code ? "#{condition} (#{code})" : (condition || "unknown reason")
          raise AdapterError.new("XMPP room #{room_jid} refused the join: #{reason}", adapter: :xmpp)
        end

        def presence_key(room_jid, nick) = "#{room_jid}/#{nick}"

        # Whether +presence+ is a 409 nick-collision refusal with a retry
        # still available: the one join failure worth retrying automatically,
        # since the taken nick is very often a ghost session's, left behind by
        # an earlier crash, that will not free itself any time soon.
        def nick_conflict?(presence, attempt)
          presence.is_a?(Hash) && presence[:type] == "error" &&
            presence[:error_condition] == "conflict" && attempt < MAX_NICK_RETRIES
        end

        # Drop the collided key's own wait, then join again under an
        # underscore-suffixed nick. A separate call, not a loop, so each
        # attempt gets its own #ensure cleanup for the key it registered.
        def retry_join(room_jid, nick, timeout, attempt)
          @pending_mutex.synchronize { @pending_presence.delete(presence_key(room_jid, nick)) }
          fallback = "#{nick}_"
          logger&.warn { "XMPP room #{room_jid} nick #{nick} is taken, retrying as #{fallback}" }
          join(room_jid, fallback, timeout: timeout, attempt: attempt + 1)
        end

        def handle_chat_message(stanza)
          return false unless Protocol.chat_message?(stanza)

          event = Protocol.parse_chat_message(stanza)
          deliver_dm(event) unless event.nil?
          true
        end

        def deliver_dm(event)
          return if @on_dm.nil?

          @on_dm.call(event)
        rescue StandardError => e
          logger&.error { "error handling an XMPP direct message: #{e.class}: #{e.message}" }
        end

        # Hand an IQ reply to the {#request_iq} caller waiting on its id, if any.
        # True when the stanza was claimed, so #handle_stanza stops there.
        def handle_pending_iq(stanza)
          return false unless Protocol.stanza_name(stanza) == "iq"

          id = Protocol.stanza_id(stanza)
          return false if id.nil?

          queue = @pending_mutex.synchronize { @pending_iqs[id] }
          return false if queue.nil?

          queue << stanza
          true
        end

        # Read stanzas until one with the given local name arrives. Handshake only.
        def read_named(name)
          loop do
            stanza = read_stanza
            raise AdapterError.new("XMPP stream closed while awaiting <#{name}>", adapter: :xmpp) if stanza.nil?
            return stanza if Protocol.stanza_name(stanza) == name
          end
        end

        # The next complete stanza, or nil when the stream closes. Blocks on the
        # socket, feeding the framer until a stanza is available.
        def read_stanza
          loop do
            return @pending.shift unless @pending.empty?

            chunk = @socket.readpartial(READ_CHUNK)
            @pending.concat(@framer.push(chunk))
          end
        rescue EOFError, IOError
          nil
        end

        def write(data)
          @write_mutex.synchronize { @socket&.write(data) }
        end

        # Delivers +event+ as parsed, id and all: {Protocol.parse_message}
        # already picked the room's own XEP-0359 stanza-id, our own origin-id,
        # or the stanza's own id attribute, in that order. A synthetic id is
        # minted only when none of those existed at all, never as an overwrite
        # of a real one.
        def deliver(event)
          return if @on_message.nil?

          id = event["id"]
          event = event.merge("id" => new_id) if id.nil? || id.to_s.empty?
          @on_message.call(event)
        rescue StandardError => e
          logger&.error { "error handling an XMPP message: #{e.class}: #{e.message}" }
        end

        def ensure_joined(room_jid)
          return if @rooms.key?(room_jid.to_s)

          raise AdapterError.new("not joined to XMPP room #{room_jid}", adapter: :xmpp)
        end

        def jid_domain(jid) = jid.to_s.split("@", 2)[1].to_s.split("/", 2).first

        def new_id = "xmpp-#{SecureRandom.hex(6)}"

        def new_iq_id = "iq-#{SecureRandom.hex(4)}"
      end

      # The default HTTP layer for the one real HTTP request this adapter makes:
      # the XEP-0363 upload PUT itself. Everything else XMPP does is the socket
      # stream {Client} already owns. Injectable so #upload is testable with no
      # network.
      class HttpTransport
        VERBS = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.freeze

        def initialize(timeout: 60)
          @timeout = timeout
        end

        def request(verb, uri, headers: {}, body: nil)
          klass = VERBS.fetch(verb)
          req = klass.new(uri)
          headers.each { |name, value| req[name] = value }
          req.body = body if body

          Net::HTTP.start(uri.hostname, uri.port,
                          use_ssl: uri.scheme == "https",
                          open_timeout: 10, read_timeout: @timeout) do |http|
            http.request(req)
          end
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          raise AdapterError.new("XMPP upload PUT timed out: #{e.class}", adapter: :xmpp, retryable: true)
        rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
          raise AdapterError.new("XMPP upload PUT failed: #{e.class}: #{e.message}", adapter: :xmpp, retryable: true)
        end
      end
    end
  end
end
