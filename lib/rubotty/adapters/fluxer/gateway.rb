# frozen_string_literal: true

require "json"

module Rubotty
  module Adapters
    module Fluxer
      # The Fluxer real time gateway: one persistent WebSocket, framed the
      # way Discord's gateway is (docs.fluxer.app, bots/gateway-connection).
      # Frames are `{op, d, s, t}`: HELLO gives the `heartbeat_interval`,
      # IDENTIFY carries the token, then DISPATCH events stream in with `t`
      # naming the event and `d` the payload; opcode numbers follow Discord's.
      class Gateway
        DISPATCH = 0
        HEARTBEAT = 1
        IDENTIFY = 2
        HELLO = 10
        HEARTBEAT_ACK = 11

        DEFAULT_HEARTBEAT_MS = 41_250

        MIN_BACKOFF = 1
        MAX_BACKOFF = 60

        # How many connections may close before the first dispatch arrives
        # before this stops reporting itself as running. Two, so one unlucky
        # close does not 503 the health endpoint while a refused token does.
        HANDSHAKE_FAILURES_BEFORE_DEAF = 2

        # How long an identified session has to stay up before it counts as
        # real recovery rather than a bounce.
        MIN_SESSION_SECONDS = 5

        # How many identified sessions in a row may end before
        # MIN_SESSION_SECONDS before this starts asking the caller to back
        # off, the same as a genuine failure would. A rolling deploy on the
        # remote end, or a proxy resetting connections right after the
        # handshake, otherwise reconnects hot, bounded only by handshake
        # speed, which is exactly the kind of thing that gets a bot rate
        # limited or banned.
        MAX_RAPID_RECONNECTS = 3

        # @param url [String] the gateway WebSocket URL (from /gateway/bot)
        # @param token [String] bot token, sent in IDENTIFY
        # @param on_event [#call] receives one dispatch frame ({"t","d"}) at a
        #   time, on a thread this gateway owns. It must not raise.
        def initialize(url:, token:, on_event:, logger: nil)
          @url = url.to_s
          @token = token
          @on_event = on_event
          @logger = logger
          @running = false
          @socket = nil
          @seq = nil
          @supervisor = nil
          @heartbeat_thread = nil
          @heartbeat_ms = DEFAULT_HEARTBEAT_MS
          @heartbeat_sent_at = nil
          @identified = false
          @identified_at = nil
          @handshake_failures = 0
          @rapid_reconnects = 0
        end

        attr_reader :logger

        # True while this gateway is both meant to be running and able to
        # receive. A socket that keeps closing before the first dispatch answers
        # false, so the health surface reports a deaf adapter rather than hiding
        # it.
        def running? = @running && @handshake_failures < HANDSHAKE_FAILURES_BEFORE_DEAF

        def describe = "gateway #{@url}"

        def start
          return self if @running

          @identified = false
          @identified_at = nil
          @handshake_failures = 0
          @rapid_reconnects = 0
          @running = true
          @supervisor = Thread.new { supervise }
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
        # loop. A refused token opens the socket fine and raises nothing, so only
        # the missing dispatch tells the two cases apart.
        def supervise
          Thread.current.name = "fluxer-gateway"
          failures = 0
          while @running
            reason = attempt
            if reason.nil?
              failures = 0
              next
            end

            failures += 1
            wait = backoff(failures)
            logger&.warn { "fluxer gateway #{reason}, reconnecting in #{wait}s (failure #{failures})" }
            sleep_interruptibly(wait)
          end
        end

        # One connect and the whole life of the connection it opens. nil when
        # IDENTIFY was answered and either the session stayed up a while or
        # has not yet failed to often enough in a row to worry about,
        # otherwise why it was not.
        def attempt
          @identified = false
          @identified_at = nil
          # Each connection identifies afresh rather than resuming a session.
          @seq = nil
          @heartbeat_sent_at = nil
          connect_once
          wait_while_connected
          return identified_reason if @identified

          @handshake_failures += 1
          "closed before the first dispatch, so the token is being refused"
        rescue StandardError => e
          "error (#{e.class}: #{e.message})"
        end

        # A session that stayed up past MIN_SESSION_SECONDS is real recovery:
        # the streak clears and this reconnects at once, same as ever. One
        # that ended faster than that keeps the streak alive instead, and
        # once it has happened MAX_RAPID_RECONNECTS times running, this stops
        # answering nil so the caller backs off instead of spinning.
        def identified_reason
          if @identified_at && (Time.now - @identified_at) >= MIN_SESSION_SECONDS
            @rapid_reconnects = 0
            return nil
          end

          @rapid_reconnects += 1
          return nil if @rapid_reconnects < MAX_RAPID_RECONNECTS

          "identified but the session keeps ending again almost immediately " \
            "(#{@rapid_reconnects} times running)"
        end

        def connect_once
          require "websocket-client-simple"

          gateway = self
          separator = @url.include?("?") ? "&" : "?"
          @socket = ::WebSocket::Client::Simple.connect("#{@url}#{separator}v=1&encoding=json")
          @socket.on(:message) { |frame| gateway.send(:on_frame, frame) }
          @socket.on(:error) { |err| gateway.logger&.debug { "fluxer gateway socket error: #{err}" } }
          @socket.on(:close) { gateway.send(:mark_closed) }
        rescue LoadError => e
          raise AdapterError.new(
            "the websocket-client-simple gem is not available: #{e.message}. Run `bundle install`.",
            adapter: :fluxer
          )
        end

        def on_frame(frame)
          data = frame.respond_to?(:data) ? frame.data : frame
          return if data.nil? || data.to_s.empty?

          payload = JSON.parse(data)
          @seq = payload["s"] if payload["s"]

          case payload["op"]
          when HELLO then handle_hello(payload)
          when DISPATCH then handle_dispatch(payload)
          when HEARTBEAT then send_heartbeat
          when HEARTBEAT_ACK then @heartbeat_sent_at = nil
          end
        rescue JSON::ParserError => e
          logger&.debug { "fluxer gateway sent unparseable JSON: #{e.message}" }
        end

        def handle_hello(payload)
          interval = payload.dig("d", "heartbeat_interval")
          @heartbeat_ms = interval.is_a?(Integer) && interval.positive? ? interval : DEFAULT_HEARTBEAT_MS
          identify
          start_heartbeat
        end

        # Fluxer's IDENTIFY takes token and properties, plus an optional presence,
        # ignored_events, initial_guild_id, shard and flags; the validator is
        # fluxer_gateway/src/gateway/gateway_handler_identify.erl. It has no intents
        # field, and the server has no intent concept at all: dispatch is opt OUT
        # through ignored_events, so a bot naming nothing there receives everything
        # its permissions allow, reactions included.
        def identify
          send_frame(op: IDENTIFY, d: {
                       token: @token,
                       properties: { os: "linux", browser: "rubotty", device: "rubotty" }
                     })
        end

        # The first dispatch after IDENTIFY is the only proof the token was
        # accepted, so it is what makes this connection count as a real one.
        def handle_dispatch(payload)
          unless @identified
            @identified = true
            @identified_at = Time.now
            @handshake_failures = 0
            logger&.info { "fluxer gateway identified" }
          end
          deliver(payload)
        end

        def deliver(payload)
          @on_event.call("t" => payload["t"], "d" => payload["d"])
        rescue StandardError => e
          logger&.error { "error handling a Fluxer event: #{e.class}: #{e.message}" }
        end

        def start_heartbeat
          @heartbeat_thread&.kill
          connection = @socket
          @heartbeat_thread = Thread.new do
            Thread.current.name = "fluxer-heartbeat"
            while @running && @socket.equal?(connection)
              sleep_interruptibly(@heartbeat_ms / 1000.0)
              break unless @running && @socket.equal?(connection)

              break unless heartbeat_tick
            end
          end
        end

        # A connected socket that no longer acknowledges heartbeats is not a
        # live session. Close it so the existing supervisor reconnects, rather
        # than sending forever into a connection that receives nothing.
        def heartbeat_tick
          if @heartbeat_sent_at && heartbeat_clock - @heartbeat_sent_at >= @heartbeat_ms / 1000.0
            logger&.warn { "fluxer gateway heartbeat was not acknowledged; reconnecting" }
            close_socket
            return false
          end

          send_heartbeat
          true
        end

        def send_heartbeat
          # A server-requested heartbeat must not extend an existing deadline.
          @heartbeat_sent_at ||= heartbeat_clock
          send_frame(op: HEARTBEAT, d: @seq)
        end

        def heartbeat_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def send_frame(op:, d: nil)
          @socket&.send(JSON.generate(op: op, d: d))
        rescue StandardError => e
          logger&.debug { "fluxer gateway send failed: #{e.message}" }
        end

        def mark_closed
          @socket = nil
          state = @identified ? "after the first dispatch" : "before the first dispatch"
          logger&.info { "fluxer gateway socket closed #{state}" }
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

        def sleep_interruptibly(seconds)
          deadline = Time.now + seconds
          sleep(0.05) while @running && Time.now < deadline
        end
      end
    end
  end
end
