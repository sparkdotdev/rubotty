# frozen_string_literal: true

require "json"

module Rubotty
  module Adapters
    module Stoat
      # The Stoat real time gateway: one persistent WebSocket the server pushes
      # events over (developers.stoat.chat, Bonfire protocol), the ONE place that
      # touches a WebSocket library, required lazily inside {#connect_once}.
      #
      #   connect  ->  send {type: "Authenticate", token}  ->  {type: "Authenticated"}
      #            ->  {type: "Ready", ...}                 ->  a stream of events
      # A {type: "Ping", data: n} is sent on a timer, the server answers Pong; a
      # dropped connection is retried with capped backoff, so a server deploy or a flaky link reconnects rather than silently going deaf.
      class Gateway
        DEFAULT_WS_BASE = "wss://events.stoat.chat"
        DEFAULT_HEARTBEAT = 30

        MIN_BACKOFF = 1
        MAX_BACKOFF = 60

        # How many connections may close before the handshake finishes before
        # this stops reporting itself as running. Two, so one unlucky close does
        # not 503 the health endpoint while a refused token does.
        HANDSHAKE_FAILURES_BEFORE_DEAF = 2

        # How long an authenticated session has to stay up before it counts as
        # real recovery rather than a bounce.
        MIN_SESSION_SECONDS = 5

        # How many authenticated sessions in a row may end before
        # MIN_SESSION_SECONDS before this starts asking the caller to back
        # off, the same as a genuine failure would. A rolling deploy on the
        # remote end, or a proxy resetting connections right after the
        # handshake, otherwise reconnects hot, bounded only by handshake
        # speed, which is exactly the kind of thing that gets a bot rate
        # limited or banned.
        MAX_RAPID_RECONNECTS = 3

        # @param token [String] the bot token, sent in the Authenticate frame
        # @param on_event [#call] receives one parsed event Hash at a time, on a
        #   thread this gateway owns. It must not raise; the adapter wraps it.
        def initialize(token:, on_event:, ws_base: DEFAULT_WS_BASE, logger: nil,
                       heartbeat: DEFAULT_HEARTBEAT)
          @token = token
          @on_event = on_event
          @ws_base = ws_base.to_s.chomp("/")
          @logger = logger
          @heartbeat = heartbeat
          @running = false
          @socket = nil
          @supervisor = nil
          @heartbeat_thread = nil
          @authenticated = false
          @authenticated_at = nil
          @handshake_failures = 0
          @refused = false
          @rapid_reconnects = 0
        end

        attr_reader :logger

        # True while this gateway is both meant to be running and able to
        # receive. A socket that keeps closing before it authenticates, or a
        # session the server has ended, answers false, so the health surface
        # reports a deaf adapter rather than hiding it.
        def running? = @running && !deaf?

        def describe = "gateway #{@ws_base}"

        def start
          return self if @running

          @authenticated = false
          @authenticated_at = nil
          @handshake_failures = 0
          @refused = false
          @rapid_reconnects = 0
          @running = true
          @supervisor = Thread.new { supervise }
          self
        end

        # The server has ended this session for good: a token it will not accept
        # (Error) or one that has been reset (Logout). Reconnecting on the same
        # credential cannot help, so drop the socket and let the supervisor back
        # off while #running? tells the truth about it.
        def note_refused(reason)
          @refused = true
          @authenticated = false
          logger&.debug { "stoat gateway session ended by the server: #{reason}" }
          close_socket
          self
        end

        def stop
          @running = false
          close_socket
          @heartbeat_thread&.kill
          @supervisor&.kill
          @heartbeat_thread = @supervisor = nil
          self
        end

        private

        # Back off between attempts so a persistent failure does not become a hot
        # loop. A refused token opens the socket fine and raises nothing, so
        # only the missing handshake tells the two cases apart.
        def supervise
          Thread.current.name = "stoat-gateway"
          failures = 0
          while @running
            reason = attempt
            if reason.nil?
              failures = 0
              next
            end

            failures += 1
            wait = backoff(failures)
            logger&.warn { "stoat gateway #{reason}, reconnecting in #{wait}s (failure #{failures})" }
            sleep_interruptibly(wait)
          end
        end

        # One connect and the whole life of the connection it opens. nil when
        # the session authenticated and either stayed up a while or has not
        # yet done so often enough in a row to worry about, otherwise why it
        # did not.
        def attempt
          @authenticated = false
          @authenticated_at = nil
          connect_once
          wait_while_connected
          return authenticated_reason if @authenticated
          return "session ended by the server" if @refused

          @handshake_failures += 1
          "closed before authenticating, so the token is being refused"
        rescue StandardError => e
          "error (#{e.class}: #{e.message})"
        end

        # A session that stayed up past MIN_SESSION_SECONDS is real recovery:
        # the streak clears and this reconnects at once, same as ever. One
        # that ended faster than that keeps the streak alive instead, and
        # once it has happened MAX_RAPID_RECONNECTS times running, this stops
        # answering nil so the caller backs off instead of spinning.
        def authenticated_reason
          if @authenticated_at && (Time.now - @authenticated_at) >= MIN_SESSION_SECONDS
            @rapid_reconnects = 0
            return nil
          end

          @rapid_reconnects += 1
          return nil if @rapid_reconnects < MAX_RAPID_RECONNECTS

          "authenticated but the session keeps ending again almost immediately " \
            "(#{@rapid_reconnects} times running)"
        end

        # Nothing more will arrive on this token until an operator changes
        # something.
        def deaf? = @refused || @handshake_failures >= HANDSHAKE_FAILURES_BEFORE_DEAF

        def connect_once
          require "websocket-client-simple"

          gateway = self
          @socket = ::WebSocket::Client::Simple.connect("#{@ws_base}/?version=1&format=json")
          @socket.on(:open) { gateway.send(:authenticate) }
          @socket.on(:message) { |frame| gateway.send(:on_frame, frame) }
          @socket.on(:error) { |err| gateway.logger&.debug { "stoat gateway socket error: #{err}" } }
          @socket.on(:close) { gateway.send(:mark_closed) }
          start_heartbeat
        rescue LoadError => e
          raise AdapterError.new(
            "the websocket-client-simple gem is not available: #{e.message}. Run `bundle install`.",
            adapter: :stoat
          )
        end

        def authenticate
          send_json(type: "Authenticate", token: @token)
        end

        def on_frame(frame)
          data = frame.respond_to?(:data) ? frame.data : frame
          return if data.nil? || data.to_s.empty?

          event = JSON.parse(data)
          # Pong is transport bookkeeping; swallow it.
          return if event["type"] == "Pong"

          note_authenticated if event["type"] == "Authenticated"
          deliver(event)
        rescue JSON::ParserError => e
          logger&.debug { "stoat gateway sent unparseable JSON: #{e.message}" }
        end

        def deliver(event)
          @on_event.call(event)
        rescue StandardError => e
          logger&.error { "error handling a Stoat event: #{e.class}: #{e.message}" }
        end

        def start_heartbeat
          @heartbeat_thread&.kill
          @heartbeat_thread = Thread.new do
            Thread.current.name = "stoat-heartbeat"
            while @running && @socket
              sleep_interruptibly(@heartbeat)
              break unless @running && @socket

              send_json(type: "Ping", data: Time.now.to_i)
            end
          end
        end

        def send_json(hash)
          @socket&.send(JSON.generate(hash))
        rescue StandardError => e
          logger&.debug { "stoat gateway send failed: #{e.message}" }
        end

        # The handshake landed, so this connection counts as a real one and any
        # earlier refusal is history.
        def note_authenticated
          @authenticated = true
          @authenticated_at = Time.now
          @handshake_failures = 0
          @refused = false
          logger&.info { "stoat gateway authenticated" }
        end

        def mark_closed
          @socket = nil
          state = @authenticated ? "after authenticating" : "before authenticating"
          logger&.info { "stoat gateway socket closed #{state}" }
        end

        def close_socket
          @socket&.close
        rescue StandardError
          nil
        ensure
          @socket = nil
        end

        def wait_while_connected
          sleep(0.1) while @running && @socket
        end

        def backoff(failures)
          [MIN_BACKOFF * (2**[failures - 1, 6].min), MAX_BACKOFF].min
        end

        # Sleep in short slices so stop takes effect promptly.
        def sleep_interruptibly(seconds)
          deadline = Time.now + seconds
          sleep(0.05) while @running && Time.now < deadline
        end
      end
    end
  end
end
