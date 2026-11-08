# frozen_string_literal: true

require "webrick"
require "yamlcamel"

module Rubotty
  module Core
    # An always-on liveness endpoint: production has no inbound port
    # otherwise, so this gives a platform health check something to probe.
    # The +liveness+ callable is asked on every request and must be cheap.
    # In webhook mode the Telegram transport already binds `$PORT` and
    # serves its own `/healthz`, so this server starts only when no such
    # transport is active. Also serves the internal reload endpoint the
    # dashboard POSTs to, mounted only when +reload+ and +reload_secret+
    # are given, on the Docker-internal `$PORT`, NEVER exposed publicly.
    class HealthServer
      DEFAULT_PORT = 8080
      DEFAULT_BIND = "0.0.0.0"
      PATH = "/healthz"
      RELOAD_PATH = "/internal/reload"
      RELOAD_SECRET_HEADER = "x-rubotty-internal-secret"
      # The admin API's debug/logs endpoint reading THIS process's own recent log lines,
      # gated by the same secret in the same header {RELOAD_PATH} uses.
      LOGS_PATH = "/internal/logs"
      # This process's own build and runtime facts, for the same endpoint's source=bot:
      # which build a misbehaving deployment is ACTUALLY running.
      INFO_PATH = "/internal/info"
      # The admin API's debug/backfill-gaps endpoint running a read-only sweep
      # against THIS process's own adapters, the only ones that hold a live
      # platform connection. Gated by the same secret and header as every
      # other internal route.
      GAPS_PATH = "/internal/backfill-gaps"
      # The dashboard's backfill proposals page, telling this
      # process to relay one APPROVED proposal's stored items through the
      # same paced path a normal sweep uses, since only this process holds
      # the adapters that can actually send them. Gated by the same secret
      # and header as every other internal route.
      RELAY_PROPOSAL_PATH = "/internal/relay-backfill-proposal"

      # Seconds to wait for WEBrick to reach its accept loop. A server told it is
      # listening before it truly is answers a health check with a refusal.
      STARTUP_TIMEOUT = 10

      # @param liveness [#call] returns truthy when the process is healthy. Asked
      #   on every request; must be cheap and must not raise.
      # @param port [Integer, nil] nil binds {DEFAULT_PORT}; 0 lets the OS pick a
      #   free port, which is what the tests do.
      # @param stats [#call, nil] extra facts merged into {INFO_PATH}'s answer;
      #   unlike +liveness+, a raise here is caught and reported in the payload.
      # reload, reload_secret, log_buffer, gap_report, and relay_proposal each
      # gate one internal route; nil for any of them disables that route.
      def initialize(liveness:, logger:, port: nil, bind: DEFAULT_BIND, reload: nil, reload_secret: nil,
                     log_buffer: nil, stats: nil, gap_report: nil, relay_proposal: nil)
        @liveness = liveness
        @logger = logger
        @port = (port || DEFAULT_PORT).to_i
        @bind = bind
        @reload = reload
        @reload_secret = presence(reload_secret)
        @log_buffer = log_buffer
        @stats = stats
        @gap_report = gap_report
        @relay_proposal = relay_proposal
        @running = false
      end

      attr_reader :logger

      def start
        return self if @running

        listening = Thread::Queue.new
        @server = build_server(listening)
        @thread = Thread.new do
          Thread.current.name = "health"
          @server.start
        end
        await(listening)
        @running = true
        logger.info { "health endpoint on #{@bind}:#{bound_port}#{PATH}" }
        self
      end

      # Safe to call when never started, and safe to call twice.
      def stop
        @running = false
        @server&.shutdown
        @thread&.join(STARTUP_TIMEOUT)
        @server = nil
        @thread = nil
        self
      end

      def running? = @running

      # The port actually in use, which with port 0 is the one the OS assigned.
      # Falls back to the requested port before the server is up.
      def bound_port
        listener = @server&.listeners&.first
        listener ? listener.addr[1] : @port
      end

      # The status code a request would receive right now. Separated from the
      # HTTP plumbing so it can be asserted without a socket.
      def status = healthy? ? 200 : 503

      def describe = "health endpoint on #{@bind}:#{@port}#{PATH}"

      private

      def healthy?
        @liveness.call ? true : false
      rescue StandardError => e
        # A liveness probe that itself blows up is not a healthy process.
        logger.warn { "health check raised #{e.class}: #{e.message}, reporting unhealthy" }
        false
      end

      def await(latch)
        latch.pop(timeout: STARTUP_TIMEOUT)
      rescue ArgumentError
        # Thread::Queue#pop gained a timeout in Ruby 3.2; an interpreter without
        # it falls back here rather than failing to boot.
        sleep 0.1
      end

      def build_server(latch)
        server = WEBrick::HTTPServer.new(
          BindAddress: @bind,
          Port: @port,
          Logger: WEBrick::Log.new(File::NULL),
          AccessLog: [],
          StartCallback: -> { latch&.push(:listening) }
        )
        handler = ->(request, response) { respond(request, response) }
        server.mount_proc(PATH, &handler)
        if @reload && @reload_secret
          server.mount_proc(RELOAD_PATH) { |request, response| reload_request(request, response) }
        end
        if @log_buffer && @reload_secret
          server.mount_proc(LOGS_PATH) { |request, response| logs_request(request, response) }
        end
        if @reload_secret
          server.mount_proc(INFO_PATH) { |request, response| info_request(request, response) }
        end
        if @gap_report && @reload_secret
          server.mount_proc(GAPS_PATH) { |request, response| gaps_request(request, response) }
        end
        if @relay_proposal && @reload_secret
          server.mount_proc(RELAY_PROPOSAL_PATH) { |request, response| relay_proposal_request(request, response) }
        end
        # A bare GET / answers too, so a platform default health check works without
        # configuration, and an unmounted reload route falls through to liveness.
        server.mount_proc("/", &handler)
        server
      end

      def respond(request, response)
        healthy = healthy?
        response.status = healthy ? 200 : 503
        response["Content-Type"] = "text/plain"
        # HEAD is what some health checkers send, and WEBrick strips the body.
        response.body = healthy ? "ok\n" : "unhealthy\n"
        response.body = "" if request.request_method == "HEAD"
      end

      # An authenticated POST re-reads the control plane now instead of waiting for the
      # next poll, over Core::Runtime#reload_control_plane.
      def reload_request(request, response)
        unless request.request_method == "POST"
          response.status = 405
          response.body = ""
          return
        end

        unless authentic_reload?(request)
          logger.warn { "rejected an internal reload request with a bad or missing secret" }
          response.status = 403
          response.body = ""
          return
        end

        reason = presence(request.body.to_s.strip) || "push"
        reloaded = @reload.call(reason: reason)
        response.status = reloaded ? 200 : 204
        response["Content-Type"] = "text/plain"
        response.body = reloaded ? "reloaded\n" : "no control plane\n"
      rescue StandardError => e
        logger.warn { "internal reload request failed: #{e.class}: #{e.message}" }
        response.status = 500
        response.body = ""
      end

      def authentic_reload?(request)
        authentic_internal?(request)
      end

      # The admin API's debug/logs endpoint reading this process's own recent lines.
      # GET only; `level` and `limit` pass straight through to {RingBuffer#entries}.
      def logs_request(request, response)
        unless request.request_method == "GET"
          response.status = 405
          response.body = ""
          return
        end

        unless authentic_internal?(request)
          logger.warn { "rejected an internal logs request with a bad or missing secret" }
          response.status = 403
          response.body = ""
          return
        end

        entries = @log_buffer.entries(level: presence(request.query["level"]), limit: presence(request.query["limit"]))
        response.status = 200
        response["Content-Type"] = "application/yaml"
        response.body = YAMLCamel.dump({ "entries" => entries.map { |entry| serialize_entry(entry) } })
      rescue StandardError => e
        logger.warn { "internal logs request failed: #{e.class}: #{e.message}" }
        response.status = 500
        response.body = ""
      end

      def serialize_entry(entry)
        { "time" => entry[:time]&.utc&.iso8601, "level" => entry[:level], "text" => entry[:text] }
      end

      # This process's own build and runtime facts, for the admin API's debug/info
      # source=bot, plus whether its liveness probe is currently satisfied.
      def info_request(request, response)
        unless request.request_method == "GET"
          response.status = 405
          response.body = ""
          return
        end

        unless authentic_internal?(request)
          logger.warn { "rejected an internal info request with a bad or missing secret" }
          response.status = 403
          response.body = ""
          return
        end

        response.status = 200
        response["Content-Type"] = "application/yaml"
        response.body = YAMLCamel.dump(process_info)
      rescue StandardError => e
        logger.warn { "internal info request failed: #{e.class}: #{e.message}" }
        response.status = 500
        response.body = ""
      end

      def process_info
        {
          "version" => Rubotty::VERSION,
          "commit" => BuildInfo.commit,
          "hostname" => BuildInfo.hostname,
          "runtime" => BuildInfo.runtime,
          "platform" => BuildInfo.platform,
          "pid" => Process.pid,
          "healthy" => healthy?
        }.merge(extra_stats)
      end

      # A failing stats callable is reported in the payload rather than raised,
      # so it never costs the caller the build facts it came for.
      def extra_stats
        return {} if @stats.nil?

        stats = @stats.call
        stats.is_a?(Hash) ? stats : {}
      rescue StandardError => e
        { "stats_error" => "#{e.class}: #{e.message}" }
      end

      # The admin API's debug/backfill-gaps endpoint running the read-only
      # sweep against this process's own adapters. GET only, no query params:
      # the sweep always covers every eligible channel.
      def gaps_request(request, response)
        unless request.request_method == "GET"
          response.status = 405
          response.body = ""
          return
        end

        unless authentic_internal?(request)
          logger.warn { "rejected an internal backfill-gaps request with a bad or missing secret" }
          response.status = 403
          response.body = ""
          return
        end

        channels = Array(@gap_report.call)
        response.status = 200
        response["Content-Type"] = "application/yaml"
        response.body = YAMLCamel.dump({ "channels" => channels.map { |row| serialize_gap_channel(row) } })
      rescue StandardError => e
        logger.warn { "internal backfill-gaps request failed: #{e.class}: #{e.message}" }
        response.status = 500
        response.body = ""
      end

      def serialize_gap_channel(row)
        {
          "endpoint_id" => row.endpoint_id,
          "community" => row.community,
          "since" => row.since&.utc&.iso8601,
          "fetched" => row.fetched,
          "gaps" => row.gaps,
          "ours" => row.ours,
          "claimed" => row.claimed,
          "below_floor" => row.below_floor,
          "samples" => Array(row.samples).map { |finding| serialize_gap_finding(finding) },
          "error" => row.error
        }
      end

      def serialize_gap_finding(finding)
        { "endpoint_id" => finding.endpoint_id, "native_id" => finding.native_id, "timestamp" => finding.timestamp }
      end

      # The dashboard's Accept button, telling this process to relay one
      # approved proposal's stored items: POST only, body is the bare
      # proposal id. Answers as soon as +relay_proposal+ has validated the
      # proposal and found a live channel for it, since the actual paced
      # send runs on its own thread rather than blocking this request, which
      # for a large approval could otherwise take minutes.
      def relay_proposal_request(request, response)
        unless request.request_method == "POST"
          response.status = 405
          response.body = ""
          return
        end

        unless authentic_internal?(request)
          logger.warn { "rejected an internal relay-proposal request with a bad or missing secret" }
          response.status = 403
          response.body = ""
          return
        end

        proposal_id = presence(request.body.to_s.strip)
        unless proposal_id&.match?(/\A\d+\z/)
          response.status = 400
          response.body = "a numeric proposal id is required\n"
          return
        end

        outcome = @relay_proposal.call(proposal_id: proposal_id.to_i)
        response["Content-Type"] = "text/plain"
        if outcome.ok?
          response.status = 202
          response.body = "relay started\n"
        else
          response.status = 422
          response.body = "#{outcome.error}\n"
        end
      rescue StandardError => e
        logger.warn { "internal relay-proposal request failed: #{e.class}: #{e.message}" }
        response.status = 500
        response.body = ""
      end

      # Shared by every internal route: same header, secret and comparison.
      def authentic_internal?(request)
        provided = request[RELOAD_SECRET_HEADER]
        return false if provided.nil?

        secure_equal?(provided, @reload_secret)
      end

      # Constant-time, the same comparison the Telegram webhook transport uses:
      # the secret is short and an attacker controls how often they can guess.
      def secure_equal?(a, b)
        return false unless a.bytesize == b.bytesize

        result = 0
        a.each_byte.zip(b.each_byte) { |x, y| result |= x ^ y }
        result.zero?
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
