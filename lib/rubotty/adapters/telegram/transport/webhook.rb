# frozen_string_literal: true

require "json"
require "securerandom"
require "webrick"

module Rubotty
  module Adapters
    module Telegram
      module Transport
        # Telegram POSTs updates to a URL we serve, over WEBrick since it is pure
        # Ruby and the workload suits it: a handful of small POSTs a second from a
        # single client, no static assets, no keep alive fan out. Telegram requires
        # HTTPS but this server speaks HTTP and expects to sit behind something that
        # terminates TLS, which is why no certificate options are exposed here. This
        # transport REQUIRES the `X-Telegram-Bot-Api-Secret-Token` secret, generated
        # at boot if none is supplied: without it, anyone who learns the URL can inject arbitrary messages into every bridged room.
        class Webhook < Base
          DEFAULT_PATH = "/telegram/webhook"
          DEFAULT_BIND = "0.0.0.0"
          SECRET_HEADER = "x-telegram-bot-api-secret-token"

          # Time to wait for WEBrick to reach its accept loop before we tell
          # Telegram to start posting.
          STARTUP_TIMEOUT = 10

          def start
            return self if @running

            @secret = settings[:webhook_secret] || SecureRandom.hex(24)
            listening = Thread::Queue.new
            @server = build_server(listening)
            @thread = Thread.new do
              Thread.current.name = "telegram-webhook"
              @server.start
            end

            # Waiting for the accept loop stops us telling Telegram about a URL
            # that is not yet answering, and makes shutdown deterministic:
            # WEBrick#shutdown issued before the server has started is lost.
            await(listening)
            @running = true

            begin
              register
            rescue StandardError
              shutdown_server
              raise
            end
            self
          end

          def stop
            unregister if @running
            @running = false
            shutdown_server
            self
          end

          def describe
            "webhook on #{bind}:#{port}#{path}, public URL #{public_url}"
          end

          # Exposed for tests: feed a request body straight in, exactly as the
          # HTTP handler would.
          def handle_body(body)
            update = JSON.parse(body)
            deliver(update)
            true
          rescue JSON::ParserError => e
            logger.warn { "discarded malformed webhook body: #{e.message}" }
            false
          end

          private

          def path = settings[:webhook_path] || DEFAULT_PATH

          def bind = settings[:webhook_bind] || DEFAULT_BIND

          # PORT is supplied by the platform on both Heroku and Coolify, so it
          # takes precedence over anything in the config file.
          def port
            (ENV["PORT"] || settings[:webhook_port] || 8080).to_i
          end

          def public_url = settings[:webhook_url]

          def await(latch)
            latch.pop(timeout: STARTUP_TIMEOUT)
          rescue ArgumentError
            # Thread::Queue#pop gained a timeout in Ruby 3.2.
            sleep 0.1
          end

          def shutdown_server
            @server&.shutdown
            @thread&.join(STARTUP_TIMEOUT)
            @server = nil
            @thread = nil
          end

          def build_server(latch = nil)
            server = WEBrick::HTTPServer.new(
              BindAddress: bind,
              Port: port,
              Logger: WEBrick::Log.new(File::NULL),
              AccessLog: [],
              StartCallback: -> { latch&.push(:listening) }
            )
            server.mount_proc(path) { |request, response| handle(request, response) }
            # Kept outside the webhook path so a health check can never be
            # mistaken for an update.
            server.mount_proc("/healthz") do |_request, response|
              response.status = 200
              response["Content-Type"] = "text/plain"
              response.body = "ok\n"
            end
            server
          end

          def handle(request, response)
            unless request.request_method == "POST"
              response.status = 405
              response.body = ""
              return
            end

            unless authentic?(request)
              logger.warn { "rejected a webhook request with a bad or missing secret token" }
              response.status = 403
              response.body = ""
              return
            end

            # Telegram retries on a non 2xx and escalates to disabling the
            # webhook, so acknowledge first and process after.
            response.status = 200
            response["Content-Type"] = "text/plain"
            response.body = ""
            handle_body(request.body.to_s)
          end

          def authentic?(request)
            provided = request[SECRET_HEADER] || request["X-Telegram-Bot-Api-Secret-Token"]
            return false if provided.nil?

            # Constant time comparison: an attacker controls how often they guess.
            secure_equal?(provided, @secret)
          end

          def secure_equal?(a, b)
            return false unless a.bytesize == b.bytesize

            result = 0
            a.each_byte.zip(b.each_byte) { |x, y| result |= x ^ y }
            result.zero?
          end

          def register
            url = public_url
            if url.nil? || url.empty?
              raise ConfigError,
                    ["telegram webhook transport needs webhook_url set to the public HTTPS URL " \
                     "Telegram should POST to, for example https://bridge.example.com#{DEFAULT_PATH}"]
            end

            drop_pending = drop_backlog?
            log_backlog(drop_pending)

            client.call(
              "setWebhook",
              url: url,
              secret_token: @secret,
              allowed_updates: allowed_updates,
              drop_pending_updates: drop_pending,
              max_connections: settings[:webhook_max_connections] || 40
            )
            mark_registered
            logger.info { "registered Telegram webhook at #{url}" }
          end

          def unregister
            # Leaving the webhook registered would make Telegram keep POSTing into
            # a void and eventually disable it with an error to clear by hand.
            client.call("deleteWebhook", drop_pending_updates: false)
          rescue AdapterError => e
            logger.warn { "could not remove the Telegram webhook: #{e.message}" }
          end

          # Only the first ever registration drops the backlog; a restart of an
          # already-registered webhook resumes, matching long polling's offset.
          def drop_backlog?
            settings.fetch(:skip_backlog, true) && !registered_before?
          end

          # Count what is about to be dropped, so a discarded backlog leaves a
          # number in the log.
          def log_backlog(dropping)
            return unless dropping

            info = client.call("getWebhookInfo")
            pending = info.is_a?(Hash) ? info["pending_update_count"].to_i : 0
            return unless pending.positive?

            logger.info { "dropping #{pending} queued Telegram update(s) on webhook registration" }
          rescue AdapterError => e
            logger.warn { "could not check the Telegram webhook backlog: #{e.message}" }
          end

          def registered_before?
            return false unless durable_store?

            !storage.get_state(registration_state_key).nil?
          rescue StandardError => e
            logger.warn { "could not read the Telegram webhook registration state: #{e.message}" }
            false
          end

          def mark_registered
            return unless durable_store?

            storage.put_state(registration_state_key, JSON.generate("registered_at" => Time.now.to_i))
          rescue StandardError => e
            logger.warn { "could not persist the Telegram webhook registration state: #{e.message}" }
          end

          # Per-account key, so one shared backend tracks each Telegram bot.
          def registration_state_key
            "telegram:webhook:registered:#{account}"
          end

          # Whether a durable KV store is actually available.
          def durable_store?
            !storage.nil? && storage.respond_to?(:get_state) && storage.respond_to?(:put_state)
          end
        end
      end
    end
  end
end
