# frozen_string_literal: true

require "socket"
require "thread"
require "base64"
require "set"
require "time"

module Rubotty
  module Adapters
    module Irc
      # The one seam that owns the IRC socket: speaks the line protocol
      # directly over a stdlib TCP (optionally TLS) socket with no gem, with
      # all parsing and message splitting in the pure {Protocol} module. A
      # channel message reaches the adapter as a plain Hash, so the inbound
      # path stays free of any socket type.
      class Client
        # Every IRCv3 capability this client can make use of, most important
        # first. "sasl" is added only when SASL credentials are configured, see
        # #understood_caps. message-tags, server-time, msgid, echo-message and
        # draft/message-redaction are fully wired; the rest are requested and
        # tracked in {#negotiated_capabilities} but nothing reads them yet,
        # since this adapter has no inbound handling for AWAY, MODE or
        # WHO/NAMES lines (JOIN, PART, QUIT and KICK are handled).
        UNDERSTOOD_CAPS = %w[
          message-tags server-time msgid echo-message account-tag extended-join
          multi-prefix away-notify chghost labeled-response batch draft/message-redaction
        ].freeze

        # How long #privmsg waits for the server to echo our own message back
        # before falling back to a synthetic id. A timeout only loses the
        # ability to edit, delete or react to that send later.
        ECHO_TIMEOUT = 5

        # How long #kick, #ban and #unban wait for the server to answer with a
        # moderation error before treating silence as success. IRC gives no
        # request id, so a reply is matched to the oldest still-waiting
        # command against the same channel and, where the numeral names one,
        # nick.
        MODERATION_TIMEOUT = 3

        # Numerics a server sends instead of 001 when it refuses this
        # connection outright, mapped to a human reason. Fed into #connect's
        # AdapterError so a rejected PASS or a K-line says why, rather than
        # just timing out.
        REGISTRATION_ERRORS = {
          "431" => "no nickname given",
          "432" => "erroneous nickname",
          "433" => "nickname already in use",
          "436" => "nickname collision",
          "437" => "nickname temporarily unavailable",
          "464" => "password incorrect",
          "465" => "banned from this server"
        }.freeze

        # How many times a nickname-in-use (433) during registration retries
        # under a fallback nick before giving up and failing the connection.
        # A ghost session left by a crash or restart often frees its nick
        # within minutes, so a bounded retry beats an unconditional failure.
        MAX_NICK_RETRIES = 3

        # Bound on how many wrapped-send groups {#ids_for} remembers at once,
        # oldest evicted first.
        MAX_TRACKED_GROUPS = 4096

        # Bound on how many nicks {#ban_mask} remembers a hostmask for,
        # oldest evicted first.
        MAX_TRACKED_HOSTMASKS = 4096

        # Minimum gap between two wire PRIVMSG lines. See #pace_send.
        SEND_INTERVAL = 0.5

        def initialize(server:, nick:, port: 6697, tls: true, realname: "rubotty",
                       password: nil, sasl_user: nil, sasl_password: nil, logger: nil)
          @server = server
          @port = port
          @tls = tls
          @nick = nick
          @realname = realname
          @password = password
          # SASL PLAIN: many networks require this before they admit a +r
          # channel. The exchange is folded into CAP negotiation.
          @sasl_user = sasl_user
          @sasl_password = sasl_password
          @logger = logger
          @socket = nil
          @thread = nil
          @on_message = nil
          @on_dm = nil
          @write_mutex = Mutex.new
          @ready = Thread::Queue.new
          @running = false
          # CAP negotiation state. @cap_ls_buffer accumulates a possibly multiline
          # "CAP LS" response; @negotiated_caps is what the server actually ACKed.
          # @cap_requests_outstanding counts REQ lines not yet answered; CAP END is
          # sent once that is zero and the AUTHENTICATE round trip has finished.
          @cap_ls_buffer = {}
          @advertised_caps = {}
          @negotiated_caps = Set.new
          @cap_requests_outstanding = 0
          @sasl_authenticating = false
          @cap_ended = false
          # Set true once 001 arrives. A 433 before that point is a
          # registration collision #retry_nick may recover from; one after is
          # some other request entirely and always fatal.
          @registered = false
          @nick_retries = 0
          # channel (as sent) => FIFO of Thread::Queue, one per in-flight
          # #privmsg awaiting its echo-message reply. See #register_echo_wait.
          @pending_echoes = {}
          @echo_mutex = Mutex.new
          # In-flight kick/ban/unban commands awaiting a moderation error
          # numeral, or silence within MODERATION_TIMEOUT read as success.
          @pending_moderations = []
          @moderation_mutex = Mutex.new
          # Channels a JOIN was refused for (471/473/474/475), downcased.
          # There is deliberately no retry, so this only ever grows.
          @unusable_channels = Set.new
          # First wire-line id => the ids of the lines after it, for a
          # #privmsg split into more than one PRIVMSG. See #ids_for.
          @sent_groups = {}
          @group_mutex = Mutex.new
          # nick => "user@host" last seen on the wire from them. See
          # #ban_mask.
          @hostmasks = {}
          @hostmask_mutex = Mutex.new
          # Monotonic clock reading of the last PRIVMSG line written, or nil
          # before the first. See #pace_send.
          @last_privmsg_at = nil
          # nick => Set of channels we have seen them JOIN and not yet PART, get
          # KICKed from, or QUIT; a QUIT names no channel, so this is what lets it
          # relay as a leave on every channel actually shared with that nick. Only
          # as complete as what this connection watched; a NICK re-keys the entry.
          @channels_by_nick = {}
          # Whether the read loop is up and reading, set true alongside it in #connect
          # and false the moment it ends, for any reason; #alive? answers from this.
          # @running only clears in #close, so a clean close from the server leaves
          # it true while the loop itself is already gone.
          @alive = false
        end

        attr_reader :logger, :nick

        # Is the read loop still up? False before the first #connect, and
        # false again once it has ended, whether from #close, an exception, or
        # the server just going away with no warning.
        def alive? = @alive

        def on_message(&block) = (@on_message = block)

        # Fires for a PRIVMSG addressed to our own nick: a DM to the bot.
        def on_dm(&block) = (@on_dm = block)

        # The capability names the server actually granted, once negotiation has
        # settled: empty before {#connect}, and permanently empty for a server
        # with no CAP support at all.
        def negotiated_capabilities = @negotiated_caps.to_a.freeze

        def negotiated?(name) = @negotiated_caps.include?(name.to_s)

        # Open the socket, register, and wait until the server welcomes us
        # (the 001 numeral), so a JOIN or PRIVMSG is never sent into a half open
        # session: "CAP LS 302" is sent first and always, since a server that
        # understands CAP holds registration and withholds 001 until CAP END, so
        # the whole exchange (every ACK or NAK, plus SASL's AUTHENTICATE round
        # trip) settles before this returns. A server with no CAP support just
        # ignores it as an unknown command and registers as it always has, with
        # no numeral to say so, which is why #wait_for_ready waits on 001 rather than on CAP.
        def connect(ready_timeout: 30)
          reset_connection_state
          @socket = open_socket
          @running = true
          @alive = true
          @thread = Thread.new { read_loop }
          send_line("CAP LS 302")
          send_line("PASS #{@password}") if @password
          send_line("NICK #{@nick}")
          send_line("USER #{@nick} 0 * :#{@realname}")
          ready = wait_for_ready(ready_timeout)
          raise registration_error(ready, ready_timeout) unless ready == :ready

          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("could not connect to IRC: #{e.class}: #{e.message}", adapter: :irc)
        end

        # @param key [String, nil] the channel's +k key, if it has one
        def join(channel, key: nil)
          send_line("JOIN #{channel}#{key ? " #{key}" : ""}")
        end

        # Send a channel message, wrapping it to the protocol's line limits and
        # splitting into several wire lines; the extra ids are remembered against
        # the first (see {#ids_for}), so a later #redact removes every line. +tags+
        # is dropped silently unless message-tags was negotiated.
        #
        # @return [String, nil] the first wire line's msgid, or nil if msgid/echo
        #   wasn't negotiated or timed out (not an error; caller uses a synthetic id)
        # @raise [AdapterError] when +channel+'s JOIN was refused earlier
        def privmsg(channel, text, tags: {})
          unless channel_usable?(channel)
            raise AdapterError.new("IRC channel #{channel} was never joined (its JOIN was refused)", adapter: :irc)
          end

          ids = Protocol.split_message(text).each_with_index.map do |line, index|
            send_privmsg_line(channel, line, tags: index.zero? ? tags : {})
          end
          remember_group(ids)
          ids.compact.first
        end

        # Bring the bot's reaction on +msgid+ into the given emoji, via the
        # client-only +draft/reply (which message) and +draft/react (which
        # emoji) tags on a TAGMSG. draft/react has no separate add/remove wire
        # form: sending the same reaction again is how it toggles off. A no-op
        # when message-tags was never negotiated, since there is no other way to
        # carry either tag.
        def react(channel, msgid, emoji)
          return unless negotiated?("message-tags")

          tags = Protocol.render_tags("+draft/reply" => msgid, "+draft/react" => emoji)
          send_line("#{tags}TAGMSG #{channel}")
        end

        # Remove a previously sent message via draft/message-redaction. Only
        # called when {Capabilities#deletes?} is true, so a server that never
        # advertised the capability never gets asked and needs no fallback.
        # +msgid+'s whole group (see {#ids_for}) is removed, so a wrapped
        # message does not leave its tail sitting behind.
        def redact(channel, msgid, reason: nil)
          [msgid, *ids_for(msgid)].each do |id|
            send_line("REDACT #{channel} #{id}#{reason ? " :#{reason}" : ""}")
          end
        end

        # The ids of the wire lines after the first, for a #privmsg that
        # returned +first_id+ and was split into more than one line. Empty
        # when it was not, or the group has aged out of {MAX_TRACKED_GROUPS}.
        def ids_for(first_id) = @group_mutex.synchronize { @sent_groups[first_id] } || []

        # @raise [PermissionError] on 482 (not a channel operator)
        # @raise [AdapterError] on 442, 441 or 401
        def kick(channel, nick, reason: nil)
          moderation_command(channel, nick) { send_line("KICK #{channel} #{nick}#{reason ? " :#{reason}" : ""}") }
        end

        # See {#ban_mask} for what the ban actually covers.
        # @raise (see #kick)
        def ban(channel, nick)
          moderation_command(channel, nick) { send_line("MODE #{channel} +b #{ban_mask(nick)}") }
        end

        # Lifts a ban this connection wrote with #ban and nothing else: it
        # sends the same mask #ban would compute for +nick+ right now, which
        # only matches an operator's own hand-placed ban by coincidence.
        # @raise (see #kick)
        def unban(channel, nick)
          moderation_command(channel, nick) { send_line("MODE #{channel} -b #{ban_mask(nick)}") }
        end

        def close
          @registered = false
          @running = false
          send_line("QUIT :bridge shutting down")
        rescue StandardError
          nil
        ensure
          @socket&.close
          @socket = nil
          @thread&.kill
          @thread = nil
        end

        private

        def reset_connection_state
          @ready = Thread::Queue.new
          @cap_ls_buffer = {}
          @advertised_caps = {}
          @negotiated_caps = Set.new
          @cap_requests_outstanding = 0
          @sasl_authenticating = false
          @cap_ended = false
          @registered = false
          @nick_retries = 0
          @unusable_channels = Set.new
          @channels_by_nick = {}
          @echo_mutex.synchronize { @pending_echoes.clear }
          @moderation_mutex.synchronize { @pending_moderations.clear }
          @hostmask_mutex.synchronize { @hostmasks.clear }
          @last_privmsg_at = nil
        end

        def open_socket
          raw = TCPSocket.new(@server, @port)
          return raw unless @tls

          require "openssl"
          # An SSLSocket built with no context defaults to VERIFY_NONE, accepting any
          # certificate at all. set_params turns on the usual verification and cipher
          # defaults; hostname plus post_connection_check is what actually checks the
          # certificate names this server, the same pair the XMPP client uses.
          context = OpenSSL::SSL::SSLContext.new
          context.set_params
          ssl = OpenSSL::SSL::SSLSocket.new(raw, context)
          ssl.sync_close = true
          ssl.hostname = @server
          ssl.connect
          ssl.post_connection_check(@server)
          ssl
        end

        def send_line(line)
          @write_mutex.synchronize { @socket&.write("#{line}\r\n") }
        rescue StandardError => e
          raise AdapterError.new("IRC write failed: #{e.message}", adapter: :irc, retryable: true)
        end

        # Register a pending echo wait and write the PRIVMSG line as one
        # critical section. The registration has to be atomic with the
        # write: in hub mode several bridged rooms can share one physical
        # channel, so two threads may reach this for the same channel at
        # once, and #resolve_pending_echo's oldest-waiter matching only
        # holds if queueing the wait and writing the line cannot be
        # reordered.
        def send_privmsg_line(channel, line, tags:)
          prefix = Protocol.render_tags(negotiated?("message-tags") ? tags : {})
          queue = nil
          @write_mutex.synchronize do
            raise IOError, "IRC socket is disconnected" if @socket.nil?
            raise IOError, "IRC registration is not complete" unless @registered

            pace_send
            queue = register_echo_wait(channel) if capture_echo?
            @socket.write("#{prefix}PRIVMSG #{channel} :#{line}\r\n")
          end
          queue && wait_for_echo(channel, queue)
        rescue StandardError => e
          raise AdapterError.new("IRC write failed: #{e.message}", adapter: :irc, retryable: true)
        end

        # Sleeps just long enough to keep two consecutive wire PRIVMSG lines
        # at least SEND_INTERVAL apart, so a message Protocol.split_message
        # turned into many lines drains at a fixed rate instead of bursting,
        # which is what most networks' flood protection kills a connection
        # for. Called with @write_mutex already held, and costs nothing on
        # the first line of a send.
        def pace_send
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          wait = @last_privmsg_at ? SEND_INTERVAL - (now - @last_privmsg_at) : 0
          sleep(wait) if wait.positive?
          @last_privmsg_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        # Both echo-message (the echo itself) and msgid (an id worth capturing)
        # have to be negotiated, or there is nothing useful to wait for.
        def capture_echo? = negotiated?("echo-message") && negotiated?("msgid")

        def register_echo_wait(channel)
          queue = Thread::Queue.new
          @echo_mutex.synchronize { (@pending_echoes[channel] ||= []) << queue }
          queue
        end

        # A timeout removes this exact queue from @pending_echoes itself. Left
        # behind, it would sit ahead of every later send for this channel, and
        # each of those would settle a queue nobody is reading: one timeout
        # would offset the FIFO for the rest of the connection's life.
        def wait_for_echo(channel, queue)
          msgid = queue.pop(timeout: ECHO_TIMEOUT)
          @echo_mutex.synchronize { @pending_echoes[channel]&.delete(queue) } if msgid.nil?
          msgid
        end

        # The server echoed one of our own messages back. Feed its msgid to the
        # oldest still-waiting #privmsg for this channel; a no-op when nothing
        # is waiting.
        def resolve_pending_echo(line)
          queue = @echo_mutex.synchronize { @pending_echoes[line.target]&.shift }
          queue&.push(line.tag("msgid"))
        end

        # Remember +ids+' captured group under its first present id, so
        # #ids_for and #redact can find the rest of a wrapped send later. A
        # no-op when there is nothing to remember: none captured, or only one.
        def remember_group(ids)
          first, *rest = ids.compact
          return if first.nil? || rest.empty?

          @group_mutex.synchronize do
            @sent_groups.shift while @sent_groups.size >= MAX_TRACKED_GROUPS
            @sent_groups[first] = rest
          end
        end

        # Every line names its sender as "nick!user@host": worth keeping since
        # #ban_mask needs the user@host part and IRC gives no other cheap way
        # to learn it. Refreshed on every line so a stale host cannot outlive
        # a reconnect under the same nick.
        def remember_hostmask(line)
          return if line.nick.nil?

          match = line.prefix.to_s.match(/\A[^!]+!(.+)\z/)
          return if match.nil?

          @hostmask_mutex.synchronize do
            @hostmasks.shift while @hostmasks.size >= MAX_TRACKED_HOSTMASKS
            @hostmasks[line.nick] = match[1]
          end
        end

        # "*!user@host" when this connection has seen +nick+ JOIN or speak, so
        # a plain /nick does not lift the ban; "nick!*@*" otherwise, which one
        # does.
        def ban_mask(nick)
          host = @hostmask_mutex.synchronize { @hostmasks[nick] }
          host ? "*!#{host}" : "#{nick}!*@*"
        end

        # Run +block+, then wait up to MODERATION_TIMEOUT for the server to
        # answer with a moderation error naming this channel or nick.
        def moderation_command(channel, nick)
          entry = { channel: channel, nick: nick, queue: Thread::Queue.new }
          @moderation_mutex.synchronize { @pending_moderations << entry }
          yield
          code = entry[:queue].pop(timeout: MODERATION_TIMEOUT)
          @moderation_mutex.synchronize { @pending_moderations.delete(entry) }
          raise moderation_error(code, channel) if code
        end

        # Match a moderation error numeral to the oldest pending command
        # against the same channel and, where the numeral names one, nick.
        # A no-op when nothing is waiting.
        def handle_moderation_numeric(code, channel, nick)
          entry = @moderation_mutex.synchronize do
            index = @pending_moderations.find_index do |candidate|
              (channel.nil? || candidate[:channel] == channel) &&
                (nick.nil? || candidate[:nick]&.casecmp?(nick))
            end
            index && @pending_moderations.delete_at(index)
          end
          entry&.dig(:queue)&.push(code)
        end

        def moderation_error(code, channel)
          reason = case code
                   when "482" then "not a channel operator in #{channel}"
                   when "442" then "not on channel #{channel}"
                   when "441" then "target is not on channel #{channel}"
                   when "401" then "no such nick"
                   end
          code == "482" ? PermissionError.new(reason, adapter: :irc) : AdapterError.new(reason, adapter: :irc)
        end

        def read_loop
          Thread.current.name = "irc-read"
          while @running && (raw = @socket.gets)
            handle_line(Protocol.parse(raw))
          end
          logger&.warn { "IRC read loop ended: connection closed by the server" } if @running
        rescue StandardError => e
          logger&.warn { "IRC read loop ended: #{e.class}: #{e.message}" } if @running
        ensure
          @alive = false
          @registered = false
        end

        def handle_line(line)
          remember_hostmask(line)
          case line.command
          when "PING" then send_line("PONG :#{line.trailing || line.params.first}")
          when "001" then handle_ready
          when "PRIVMSG" then handle_privmsg(line)
          when "NOTICE" then handle_notice(line)
          when "TAGMSG" then handle_tagmsg(line)
          when "JOIN" then handle_join(line)
          when "PART" then handle_part(line)
          when "QUIT" then handle_quit(line)
          when "KICK" then handle_kick(line)
          when "NICK" then handle_nick(line)
          when "CAP" then handle_cap(line)
          when "AUTHENTICATE" then handle_authenticate(line)
          when "903" then handle_sasl_result(true)
          when "904", "905", "906", "907" then handle_sasl_result(false)
          when "482" then handle_moderation_numeric("482", line.params[1], nil)
          when "442" then handle_moderation_numeric("442", line.params[1], nil)
          when "441" then handle_moderation_numeric("441", line.params[2], line.params[1])
          when "401" then handle_moderation_numeric("401", nil, line.params[1])
          when "431", "432", "433", "436", "437", "464", "465" then handle_registration_error(line)
          else
            failure = Protocol.join_failure(line)
            handle_join_failure(line, failure) if failure
          end
        end

        def handle_ready
          @registered = true
          @ready.push(:ready)
        end

        # A registration numeral in place of 001: the whole connection was
        # refused. Fed to #connect via the same queue 001 uses, so it raises
        # with the reason instead of sitting there until ready_timeout. 433
        # before we are registered gets {MAX_NICK_RETRIES} fallback attempts
        # first, rather than failing the connection over a nick a ghost
        # session is likely to give up on its own within minutes.
        def handle_registration_error(line)
          return retry_nick if line.command == "433" && !@registered && @nick_retries < MAX_NICK_RETRIES

          reason = REGISTRATION_ERRORS.fetch(line.command, "registration refused (#{line.command})")
          detail = line.trailing
          @ready.push(detail.to_s.empty? ? reason : "#{reason}: #{detail}")
        end

        # Append an underscore and register again under it. Exhausting
        # {MAX_NICK_RETRIES} falls through to the ordinary fatal 433 handling
        # on the next collision.
        def retry_nick
          @nick_retries += 1
          @nick = "#{@nick}_"
          logger&.warn { "IRC nickname in use during registration, retrying as #{@nick}" }
          send_line("NICK #{@nick}")
        end

        def registration_error(ready, timeout)
          message = ready.nil? ? "IRC server never sent 001 within #{timeout}s" : "IRC registration failed: #{ready}"
          AdapterError.new(message, adapter: :irc)
        end

        # A refused JOIN leaves the channel unusable for the rest of this
        # connection: a later send into it raises instead of vanishing into a
        # channel the bot was never admitted to. There is deliberately no
        # retry, so this state never clears itself.
        def handle_join_failure(line, failure)
          channel = line.params[1]
          @unusable_channels << channel.to_s.downcase if channel
          logger&.error { failure }
        end

        def channel_usable?(channel) = !@unusable_channels.include?(channel.to_s.downcase)

        def sasl? = !@sasl_user.to_s.empty? && !@sasl_password.to_s.empty?

        # Whether CAP LS's "sasl=PLAIN,EXTERNAL,..." value, when the server
        # sent one at all, lists PLAIN, the only mechanism {#handle_authenticate}
        # speaks. A server that advertises bare "sasl" with no mechanism list
        # names none, the older convention that means "ask and find out," so
        # that case is trusted rather than blocked here.
        def sasl_plain_offered?
          raw = @advertised_caps["sasl"]
          raw.to_s.empty? || raw.split(",").include?("PLAIN")
        end

        # The fixed list, plus "sasl" only when credentials were configured.
        # Asking for sasl with nothing to authenticate earns a useless ACK.
        def understood_caps
          sasl? ? UNDERSTOOD_CAPS + ["sasl"] : UNDERSTOOD_CAPS
        end

        def handle_cap(line)
          case line.params[1]
          when "LS" then handle_cap_ls(line)
          when "ACK" then handle_cap_ack(line)
          when "NAK" then handle_cap_nak(line)
          end
        end

        # Accumulate one page of a possibly multiline "CAP LS 302"
        # advertisement. The full set is known, and negotiation can proceed,
        # only once a page arrives with no trailing "*" continuation marker.
        def handle_cap_ls(line)
          @cap_ls_buffer.merge!(Protocol.parse_cap_list(line.trailing))
          return if Protocol.cap_continuation?(line)

          @advertised_caps = @cap_ls_buffer
          negotiate_caps
        end

        # Request exactly the intersection of what the server advertised and what
        # this client understands; anything else would just be NAKed, and a server
        # with no CAP support never sends a "CAP LS" reply, so this never runs for
        # one, which is the whole of the no-CAP fallback. SASL gets its own REQ
        # because one CAP REQ line is all-or-nothing, so a single unwelcome
        # capability would take the rest down with it.
        def negotiate_caps
          wanted = understood_caps & @advertised_caps.keys
          if sasl? && !wanted.include?("sasl")
            logger&.warn { "IRC server does not advertise sasl; joining unauthenticated" }
          elsif sasl? && wanted.include?("sasl") && !sasl_plain_offered?
            logger&.warn do
              "IRC server's sasl mechanism list (#{@advertised_caps["sasl"]}) does not include " \
                "PLAIN, the only one this client speaks; joining unauthenticated"
            end
            wanted -= ["sasl"]
          end

          requested = false
          if wanted.include?("sasl")
            @cap_requests_outstanding += 1
            requested = true
            send_line("CAP REQ :sasl")
          end

          other = wanted - ["sasl"]
          unless other.empty?
            @cap_requests_outstanding += 1
            requested = true
            send_line("CAP REQ :#{other.join(" ")}")
          end

          maybe_end_cap unless requested
        end

        # "CAP * ACK :sasl message-tags server-time" grants everything named on
        # the line. sasl among them starts the AUTHENTICATE exchange.
        def handle_cap_ack(line)
          granted = line.trailing.to_s.split(" ")
          @negotiated_caps.merge(granted)
          @cap_requests_outstanding -= 1
          if granted.include?("sasl")
            @sasl_authenticating = true
            send_line("AUTHENTICATE PLAIN")
          end
          maybe_end_cap
        end

        # "CAP * NAK :..." refuses everything on that one REQ line, all-or-
        # nothing like the REQ that earned it. Nothing was assumed usable, so
        # nothing here needs to unwind.
        def handle_cap_nak(line)
          refused = line.trailing.to_s.split(" ")
          logger&.warn { "IRC server declined capabilities (CAP NAK): #{refused.join(", ")}" }
          @cap_requests_outstanding -= 1
          maybe_end_cap
        end

        # Send CAP END exactly once, after every requested capability is ACKed
        # or NAKed and the AUTHENTICATE round trip has finished. Earlier
        # abandons SASL mid-exchange; later holds registration, and every JOIN
        # behind it, open for no reason.
        def maybe_end_cap
          return if @cap_ended
          return if @cap_requests_outstanding.positive? || @sasl_authenticating

          @cap_ended = true
          send_line("CAP END")
        end

        # "AUTHENTICATE +" asks for the credential blob: authzid, authcid and
        # password, NUL separated and base64 encoded (SASL PLAIN, RFC 4616).
        def handle_authenticate(line)
          return unless line.params.first == "+"

          payload = Base64.strict_encode64("#{@sasl_user}\0#{@sasl_user}\0#{@sasl_password}")
          send_line("AUTHENTICATE #{payload}")
        end

        def handle_sasl_result(success)
          if success
            logger&.info { "authenticated to services via SASL as #{@sasl_user}" }
          else
            logger&.error { "IRC SASL authentication failed for #{@sasl_user}; joining unauthenticated" }
          end
          @sasl_authenticating = false
          maybe_end_cap
        end

        def handle_privmsg(line)
          return handle_dm(line) unless line.channel?

          if line.nick.to_s.casecmp?(@nick.to_s)
            # A bouncer may echo our own PRIVMSG back regardless of
            # negotiation, and echo-message turns it on deliberately. Either
            # way it must never be relayed back, only settle a pending
            # #privmsg wait.
            resolve_pending_echo(line)
            return
          end

          remember_membership(line.nick, line.target)

          body, action = Protocol.strip_ctcp(line.trailing.to_s)
          # Tags are read only when message-tags was negotiated, even though
          # {Protocol.parse} will parse an "@..." prefix off any line: a server
          # or proxy sending tags we never asked for must not be trusted to hand
          # out ids, or it could forge native reply and redaction targets.
          tagged = negotiated?("message-tags")
          deliver(
            "channel" => line.target, "nick" => line.nick, "body" => body, "action" => action,
            "msgid" => tagged ? line.tag("msgid") : nil,
            "reply_to" => tagged ? line.tag("+draft/reply") : nil,
            "timestamp" => server_time(line)
          )
        end

        # A PRIVMSG whose target is our own nick rather than a channel: a DM,
        # the operator control lane's input.
        def handle_dm(line)
          return if @on_dm.nil?
          return if line.nick.to_s.casecmp?(@nick.to_s)

          body, = Protocol.strip_ctcp(line.trailing.to_s)
          @on_dm.call("nick" => line.nick, "body" => body, "timestamp" => server_time(line))
        rescue StandardError => e
          logger&.error { "error handling an IRC direct message: #{e.class}: #{e.message}" }
        end

        # NOTICE is PRIVMSG's twin without its "an auto-reply is fine" implication
        # (RFC 2812 3.3.2): a channel one is relayed exactly like a channel
        # PRIVMSG, so ChanServ, NickServ or another bridge bot posting into a
        # shared room stays visible; one addressed to us alone is only logged,
        # never handed to the DM control lane, so replying to a NOTICE can never
        # start the very reply loop the convention exists to avoid.
        def handle_notice(line)
          return handle_private_notice(line) unless line.channel?
          return if line.nick.to_s.casecmp?(@nick.to_s)

          remember_membership(line.nick, line.target)
          body, action = Protocol.strip_ctcp(line.trailing.to_s)
          tagged = negotiated?("message-tags")
          deliver(
            "channel" => line.target, "nick" => line.nick, "body" => body, "action" => action,
            "msgid" => tagged ? line.tag("msgid") : nil,
            "reply_to" => tagged ? line.tag("+draft/reply") : nil,
            "timestamp" => server_time(line)
          )
        end

        def handle_private_notice(line)
          return if line.nick.nil? || line.nick.to_s.casecmp?(@nick.to_s)

          logger&.info { "IRC NOTICE from #{line.nick}: #{line.trailing}" }
        end

        # TAGMSG carries no body, only tags: the wire form of a client-only
        # gesture, here the +draft/react reaction. It needs message-tags, the
        # only way either tag reaches us, so one that arrives without it came
        # from a misbehaving or spoofing peer and is not trusted.
        def handle_tagmsg(line)
          return unless line.channel?
          return if line.nick.to_s.casecmp?(@nick.to_s)
          return unless negotiated?("message-tags")

          react = line.tag("+draft/react")
          target = line.tag("+draft/reply")
          return if react.nil? || target.nil?

          deliver("channel" => line.target, "nick" => line.nick, "kind" => "reaction",
                   "reaction" => react, "target_msgid" => target, "timestamp" => server_time(line))
        end

        # Plain JOIN sends the channel as a param; some servers send it as
        # trailing instead ("JOIN :#room"), so both are read.
        def handle_join(line)
          channel = line.params.first || line.trailing
          nick = line.nick
          return if nick.nil? || channel.nil? || !Protocol.channel?(channel)

          remember_membership(nick, channel)
          return if nick.casecmp?(@nick.to_s) # our own JOIN confirming, nothing to relay

          deliver("channel" => channel, "nick" => nick, "kind" => "join", "timestamp" => server_time(line))
        end

        def handle_part(line)
          channel = line.params.first
          nick = line.nick
          return if nick.nil? || channel.nil?

          forget_membership(nick, channel)
          return if nick.casecmp?(@nick.to_s)

          deliver("channel" => channel, "nick" => nick, "kind" => "leave", "timestamp" => server_time(line))
        end

        # QUIT names no channel, so it is relayed as a leave on every channel
        # {#forget_membership} has this nick in.
        def handle_quit(line)
          nick = line.nick
          return if nick.nil?

          channels = forget_all_membership(nick)
          return if nick.casecmp?(@nick.to_s)

          channels.each do |channel|
            deliver("channel" => channel, "nick" => nick, "kind" => "leave", "timestamp" => server_time(line))
          end
        end

        def handle_kick(line)
          channel = line.params[0]
          target = line.params[1]
          return if channel.nil? || target.nil?

          forget_membership(target, channel)
          if target.casecmp?(@nick.to_s)
            logger&.warn { "IRC: kicked from #{channel}#{line.trailing ? " (#{line.trailing})" : ""}" }
            return
          end

          deliver("channel" => channel, "nick" => target, "kind" => "leave", "timestamp" => server_time(line))
        end

        # A live nick change. This bridge has no message kind for "somebody's
        # name changed" (see Core::Message::KINDS), so nothing is relayed; what
        # matters is re-keying #forget_all_membership's own tracking, so a QUIT
        # under the new nick still resolves to every channel this connection
        # watched it join under the old one, and #ban_mask still finds its host.
        def handle_nick(line)
          old_nick = line.nick
          new_nick = line.trailing || line.params.first
          return if old_nick.nil? || new_nick.nil?

          rename_membership(old_nick, new_nick)
          rename_hostmask(old_nick, new_nick)
          @nick = new_nick if old_nick.casecmp?(@nick.to_s)
        end

        def rename_membership(old_nick, new_nick)
          channels = @channels_by_nick.delete(old_nick)
          @channels_by_nick[new_nick] = channels if channels
        end

        def rename_hostmask(old_nick, new_nick)
          @hostmask_mutex.synchronize do
            host = @hostmasks.delete(old_nick)
            @hostmasks[new_nick] = host if host
          end
        end

        def remember_membership(nick, channel)
          (@channels_by_nick[nick] ||= Set.new) << channel
        end

        def forget_membership(nick, channel)
          set = @channels_by_nick[nick]
          return if set.nil?

          set.delete(channel)
          @channels_by_nick.delete(nick) if set.empty?
        end

        def forget_all_membership(nick) = (@channels_by_nick.delete(nick) || Set.new).to_a

        # The "time" tag (server-time) parsed to a Time, or nil when the
        # capability was not negotiated or the tag is absent; {Inbound} falls
        # back to Time.now.
        def server_time(line)
          return nil unless negotiated?("server-time")

          raw = line.tag("time")
          raw && Time.iso8601(raw)
        rescue ArgumentError
          nil
        end

        def deliver(event)
          return if @on_message.nil?

          @on_message.call(event)
        rescue StandardError => e
          logger&.error { "error handling an IRC message: #{e.class}: #{e.message}" }
        end

        def wait_for_ready(timeout) = @ready.pop(timeout: timeout)
      end
    end
  end
end
