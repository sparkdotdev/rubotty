# frozen_string_literal: true

require "net/http"
require "uri"
require "securerandom"
require "json"
require "yamlcamel"

module Rubotty
  module Adapters
    module ApiWrapper
      # Signs and sends one account's outbound events to its webhook_url,
      # one call one attempt since retrying a transient failure is
      # {Core::RetryPolicy}'s job. Reuses {ControlPlane::WebhookSignature}
      # for signing but not {ControlPlane::WebhookPump}'s durable queue,
      # since that needs the control-plane database and scheduler an
      # adapter's constructor never gets. The connection is SSRF-guarded:
      # the socket connects to the address the guard already resolved and
      # validated, not a fresh hostname lookup.
      class Client
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 10

        # What is read back from the remote end: enough for a diagnosis and
        # no more.
        MAX_RESPONSE = 2000

        # @param webhook_url [String] this account's configured https URL
        # @param secret [String] the whsec_ secret outbound POSTs are signed with
        # @param logger [#warn, #debug, nil]
        # @param http [#call, nil] injected in tests: receives (uri, headers, body)
        #   and returns something answering #code and #body. Nil uses Net::HTTP.
        # @param resolver [#call, nil] hostname to addresses, injected in tests
        def initialize(webhook_url:, secret:, logger: nil, http: nil, resolver: nil)
          @webhook_url = webhook_url
          @secret = secret
          @logger = logger
          @http = http
          @resolver = resolver
        end

        # One outbound POST's outcome, once the remote end has actually
        # answered (a transport level failure never reaches this, it raises
        # instead; see {#post}).
        Response = Struct.new(:status, :body, keyword_init: true) do
          def ok? = status.between?(200, 299)

          # 410 Gone is this wire protocol's own convention for "already gone",
          # the same way each platform spells the answer differently: the
          # remote end choosing to say so is what lets an edit or a reaction
          # racing a delete stay ordinary instead of raising.
          def gone? = status == 410
        end

        # Sign and POST one event, +type+ being the wire event name and +data+ its
        # own body; raises only for a failure that never reached the remote end
        # (SSRF guard, unreachable, timed out), always retryable. Anything the
        # remote end actually answered comes back as a {Response} instead, 2xx
        # or otherwise.
        #
        # @return [Response]
        # @raise [Rubotty::AdapterError] transport level failure, always retryable
        def post(type:, data:)
          event_id = "evt_#{SecureRandom.urlsafe_base64(18)}"
          now = Time.now
          payload = envelope(event_id, type, data, now)
          uri = URI.parse(@webhook_url.to_s)
          addresses = guard!(uri)
          headers = ControlPlane::WebhookSignature.headers(
            secrets: [@secret], id: event_id, timestamp: now.to_i, payload: payload
          )
          response = send_request(uri, headers, payload, addresses)
          Response.new(status: response.code.to_i, body: summary(response))
        rescue Util::MediaFetcher::Error => e
          raise AdapterError.new("api_wrapper webhook refused: #{e.message}", adapter: :api_wrapper, retryable: true)
        rescue *Util::MediaFetcher::TRANSIENT_ERRORS => e
          raise AdapterError.new("api_wrapper webhook unreachable: #{e.class}: #{e.message}",
                                 adapter: :api_wrapper, retryable: true)
        end

        private

        def envelope(event_id, type, data, now)
          YAMLCamel.dump({
            "id" => event_id, "type" => type.to_s, "timestamp" => now.utc.iso8601,
            "data" => stringify(data)
          })
        end

        def stringify(data)
          return {} unless data.is_a?(Hash)

          data.each_with_object({}) do |(key, value), out|
            out[key.to_s] = value.is_a?(Hash) ? stringify(value) : value
          end
        end

        def guard!(uri)
          Util::MediaFetcher.new(logger: @logger, resolver: @resolver).send(:guard_public_address!, uri)
        end

        def send_request(uri, headers, body, addresses)
          return @http.call(uri, headers, body) if @http

          last = nil
          Array(addresses).each do |address|
            http = Util::MediaFetcher.pinned_http(uri, address, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
            begin
              return http.request(build_request(uri, headers, body))
            rescue *Util::MediaFetcher::UNREACHABLE_ERRORS => e
              last = e
              @logger&.debug { "api_wrapper webhook could not reach #{address}: #{e.class}: #{e.message}" }
            end
          end
          raise last if last

          raise Util::MediaFetcher::Error, "no address answered for #{uri.hostname}"
        end

        def build_request(uri, headers, body)
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/yaml"
          request["User-Agent"] = "rubotty-api-wrapper"
          headers.each { |key, value| request[key] = value }
          request.body = body
          request
        end

        def summary(response)
          response.body.to_s[0, MAX_RESPONSE].to_s.strip.gsub(/\s+/, " ")[0, 200].to_s
        rescue StandardError
          ""
        end
      end
    end
  end
end
