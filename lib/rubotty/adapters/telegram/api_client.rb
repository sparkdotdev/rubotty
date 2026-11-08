# frozen_string_literal: true

require "json"
# Faraday runs on Net::HTTP and wraps most of what it raises, but the wrapping is
# not exhaustive, so the classes underneath are named in #call's rescue list and
# have to be loaded.
require "net/http"
require "telegram/bot"
require "uri"

module Rubotty
  module Adapters
    module Telegram
      # Telegram Bot API client over telegram-bot-ruby's generic dispatch. The
      # gem owns the HTTP round trip; the error taxonomy, the token redaction
      # and the stripping of nil parameters stay here, because the gem does none
      # of the three. The transport is injectable, which is how the test suite
      # exercises the adapter end to end with zero network access and no HTTP
      # stubbing library.
      class ApiClient
        DEFAULT_BASE = "https://api.telegram.org"

        # Telegram error codes worth distinguishing. Everything else becomes a
        # generic AdapterError.
        RATE_LIMITED = 429
        FORBIDDEN = 403
        BAD_REQUEST = 400
        CONFLICT = 409

        def initialize(token:, base_url: DEFAULT_BASE, http: nil, logger: nil, timeout: 60)
          @token = token
          @base_url = base_url.to_s.chomp("/")
          @http = http || BotApi.new(token: token, base_url: @base_url, timeout: timeout)
          @logger = logger
        end

        attr_reader :logger

        # @param method [String] Bot API method, for example "sendMessage"
        # @param params [Hash]
        # @return [Object] the `result` member of the response
        # @raise [Rubotty::AdapterError]
        def call(method, params = {})
          # Built and thrown away: this is the token check. A malformed token
          # makes the URL parser raise with the whole URL in its message, and
          # Faraday parses the URL too, so the failure has to happen here where
          # the token can still be scrubbed out.
          url_for(method)
          parse(method, @http.call(method, compact(params)))
        rescue JSON::ParserError => e
          raise AdapterError.new("Telegram returned unparseable JSON from #{method}: #{e.message}",
                                 adapter: :telegram, retryable: true)
        rescue Faraday::Error => e
          raise transport_error(e)
        rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
          # Anything Faraday let through unwrapped. The poll loop only knows how
          # to retry an AdapterError, so a bare socket error escaping here would
          # kill the receive thread and take the bridge off the air quietly.
          raise transport_error(e)
        end

        # Same as {#call} but returns nil instead of raising when the target
        # message no longer exists.
        def call_tolerating_gone(method, params = {})
          call(method, params)
        rescue AdapterError => e
          raise unless gone?(e)

          logger&.debug { "#{method}: target message already gone, ignoring" }
          nil
        end

        def get_me = call("getMe")

        # Resolve a Telegram file_id into a downloadable URL, raising on failure;
        # {Inbound#resolve_file} is where that gets logged. These URLs embed the
        # bot token, so they must never be logged or relayed as a link.
        def file_url(file_id)
          file = call("getFile", file_id: file_id)
          path = file && file["file_path"]
          return nil if path.nil?

          "#{@base_url}/file/bot#{@token}/#{path}"
        end

        # The shared answer, so this client cannot drift a little wider than the
        # adapters and start swallowing refusals with it.
        def gone?(error) = AlreadyGone.call(error)

        private

        # A Telegram URL embeds the bot token. A malformed token makes URI.parse
        # raise with the URL in its message, so the token would ride into the
        # logs unless it is scrubbed first.
        def url_for(method)
          URI.parse("#{@base_url}/bot#{@token}/#{method}")
        rescue URI::Error => e
          raise AdapterError.new("Telegram request URL was invalid: #{redact_token(e.message)}",
                                 adapter: :telegram, retryable: false)
        end

        def redact_token(text)
          scrubbed = text.to_s
          scrubbed = scrubbed.gsub(@token.to_s, Util::SafeUrl::REDACTED) unless @token.to_s.empty?
          Util::SafeUrl.redact(scrubbed)
        end

        # Faraday's own failures, mapped onto the retryable AdapterError the poll
        # loop and the retry policy already understand. Redacted, because a
        # connection error can quote the request URL and a Telegram URL carries
        # the bot token in its path.
        def transport_error(error)
          if error.is_a?(Faraday::TimeoutError)
            return AdapterError.new("Telegram request timed out: #{error.class}",
                                    adapter: :telegram, retryable: true)
          end

          AdapterError.new("Telegram request failed: #{error.class}: #{redact_token(error.message)}",
                           adapter: :telegram, retryable: true)
        end

        def parse(method, payload)
          unless payload.is_a?(Hash)
            raise AdapterError.new("Telegram answered #{method} with something other than a response object",
                                   adapter: :telegram, retryable: true)
          end
          return payload["result"] if payload["ok"]

          code = payload["error_code"]
          description = payload["description"].to_s
          retry_after = payload.dig("parameters", "retry_after")

          case code
          when RATE_LIMITED
            raise RateLimitedError.new(
              "Telegram rate limited #{method}: #{description}",
              adapter: :telegram, retry_after: retry_after
            )
          when FORBIDDEN
            raise PermissionError.new("Telegram refused #{method}: #{description}", adapter: :telegram)
          when CONFLICT
            raise conflict_error(method, description)
          when BAD_REQUEST
            migrated_to = payload.dig("parameters", "migrate_to_chat_id")
            if migrated_to
              raise ChatMigratedError.new("Telegram #{method} failed (#{code}): #{description}", migrated_to)
            end
            raise gone_error(method, description) if MESSAGE_GONE.match?(description)

            raise AdapterError.new("Telegram #{method} failed (#{code}): #{description}",
                                   adapter: :telegram, retryable: false)
          else
            raise AdapterError.new(
              "Telegram #{method} failed (#{code}): #{description}",
              adapter: :telegram, retryable: code.nil? || code >= 500
            )
          end
        end

        # Telegram has no error code for "that message is gone": every shape of
        # it is a 400 whose description says so, one phrasing per method
        # ("message to react not found", "message to delete not found", and the
        # bare "message not found"). Matched here rather than at a call site so
        # one adapter owns the wording.
        MESSAGE_GONE = /message(?: to \w+)? not found/i

        def gone_error(method, description)
          MessageGoneError.new("Telegram #{method} found no such message: #{description}", adapter: :telegram)
        end

        # A 409 from getUpdates has exactly one real cause: two long-polling
        # processes asked Telegram for updates at once, and Telegram only ever
        # serves one. Logged here, once, in plain words.
        def conflict_error(method, description)
          unless method == "getUpdates"
            return AdapterError.new(
              "Telegram #{method} conflicted (#{CONFLICT}): #{description}",
              adapter: :telegram, retryable: true
            )
          end

          logger&.warn { "another getUpdates instance is polling for this bot; standing by" }
          AdapterError.new(
            "another getUpdates instance is polling for this bot",
            adapter: :telegram, retryable: true
          )
        end

        # Telegram rejects explicit nulls for optional parameters, and the gem
        # forwards a nil as an empty form field rather than dropping it, so they
        # are stripped rather than sent.
        def compact(params)
          params.each_with_object({}) do |(key, value), out|
            next if value.nil?

            out[key] = value
          end
        end
      end

      # A call to a basic group Telegram has since upgraded to a supergroup,
      # carrying the id it moved to. Never retryable against the old id.
      class ChatMigratedError < AdapterError
        attr_reader :migrate_to_chat_id

        def initialize(message, migrate_to_chat_id)
          @migrate_to_chat_id = migrate_to_chat_id
          super(message, adapter: :telegram, retryable: false)
        end
      end

      # The Bot API seam, one method wide, over telegram-bot-ruby. Answers with
      # the response envelope Telegram sent, error envelopes included, so
      # {ApiClient} stays the only place that decides what an error means.
      class BotApi
        # How long to wait for the connection itself, as opposed to the reply.
        OPEN_TIMEOUT = 10

        def initialize(token:, base_url: ApiClient::DEFAULT_BASE, timeout: 60)
          @api = ::Telegram::Bot::Api.new(token, url: base_url)
          # The gem reads its timeouts from process-wide configuration and
          # defaults to 20s, which is under the 30s a long poll holds getUpdates
          # open, so this connection carries its own pair instead.
          @api.connection.options.timeout = timeout
          @api.connection.options.open_timeout = OPEN_TIMEOUT
        end

        # @param method [String] Bot API method, for example "sendMessage"
        # @param params [Hash]
        # @return [Hash] the parsed response envelope
        def call(method, params)
          @api.call(method, params)
        rescue ::Telegram::Bot::Exceptions::ResponseError => e
          # Telegram answers a rejected call with a 4xx AND an ordinary error
          # envelope. The gem raises on the status alone, so the envelope has to
          # be recovered from the response.
          envelope(e)
        end

        private

        # The gem's own client, so a spec can drive the real dispatch over a
        # stubbed connection instead of the network.
        attr_reader :api

        def envelope(error)
          body = JSON.parse(error.response.body.to_s)
          body.is_a?(Hash) && body.key?("ok") ? body : bodyless(error)
        rescue JSON::ParserError
          bodyless(error)
        end

        # A non-JSON error body, which Telegram itself never sends but a proxy in
        # front of a self hosted Bot API server might. Built by hand rather than
        # read off the exception, whose own message quotes the request URL in
        # exactly this case and with it the bot token.
        def bodyless(error)
          status = error.response.status
          { "ok" => false, "error_code" => status,
            "description" => "Telegram returned #{status} with no error body" }
        end
      end
    end
  end
end
