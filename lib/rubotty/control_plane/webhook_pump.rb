# frozen_string_literal: true

require "net/http"
require "uri"
require "timeout"

module Rubotty
  module ControlPlane
    # The thing that actually posts a webhook: the handler for one
    # {Webhooks::PUMP_KIND} durable job per subscription, which serialises a
    # subscriber's deliveries. {#drain} stops at the first delivery that does
    # not land, so a subscriber never sees event five before event four;
    # {OPEN_TIMEOUT}/{READ_TIMEOUT} bound how long one unresponsive endpoint
    # can hold the drain. Every post goes through the SSRF guard on every
    # attempt and connects to the address the guard validated rather than
    # re-resolving the host, so a rebinding name cannot fool the socket.
    class WebhookPump
      # Short on purpose: a subscriber that cannot answer inside this is treated
      # as down, which is recoverable, where holding the shared drain is not.
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 10
      REQUEST_TIMEOUT = OPEN_TIMEOUT + READ_TIMEOUT

      # Deliveries one drain will send before returning, so a large backlog is
      # worked off across several ticks.
      BATCH = 20

      # What is read back from a subscriber: enough to record a diagnosis and no
      # more.
      MAX_RESPONSE = 2000
      Response = Struct.new(:code, :body, keyword_init: true)

      # @param webhooks [Webhooks] the row store and its rules
      # @param models [ControlPlane::Models]
      # @param logger [#info, #warn, nil]
      # @param http [#call, nil] injected in tests: receives (uri, headers,
      #   body) and returns something answering #code. Nil uses Net::HTTP.
      # @param resolver [#call, nil] hostname to addresses
      def initialize(webhooks:, models:, logger: nil, http: nil, resolver: nil, clock: -> { Time.now })
        @webhooks = webhooks
        @models = models
        @logger = logger
        @http = http
        @resolver = resolver
        @clock = clock
      end

      # The durable scheduler handler, one job, one subscription; never raises
      # for anything a subscriber did, since a refused connection, a 500, a
      # timeout, and a blocked address are all recorded on the delivery row
      # instead. Letting them out would fail the JOB and leave the
      # subscription with no drainer.
      def call(job)
        subscription_id = job.payload["subscription_id"]
        return 0 if subscription_id.nil?

        subscription = @models.webhook_subscription.where(id: subscription_id).first
        return 0 if subscription.nil? || !subscription.active

        drain(subscription)
      end

      # Send what this subscription is owed, in order, until something does not
      # land or the batch is spent.
      #
      # @return [Integer] deliveries that landed
      def drain(subscription, now: @clock.call)
        sent = 0
        BATCH.times do
          row = @webhooks.next_due(subscription_id: subscription.id, now: now)
          break if row.nil?

          break unless attempt(subscription, row, now: now)

          sent += 1
        end
        sent
      end

      # One delivery, one attempt.
      #
      # @return [Boolean] whether the queue may move on. True when it landed, and
      #   true when it dead lettered; false while it still has attempts left,
      #   which is what holds the order.
      def attempt(subscription, row, now: @clock.call)
        response = post(subscription, row, now: now)
        status = response[:status]
        if status && status.between?(200, 299)
          @webhooks.delivered(row, response_status: status, now: now)
          return true
        end

        # A dead lettered delivery returns true so the drain continues past it;
        # one with attempts left returns false so nothing overtakes it.
        !@webhooks.failed(row, error: response[:error], response_status: status, now: now)
      end

      private

      # POST the stored envelope with the Standard Webhooks headers.
      #
      # Returns a hash rather than raising, so every failure shape reaches the
      # caller the same way and gets recorded the same way.
      def post(subscription, row, now:)
        response = Timeout.timeout(REQUEST_TIMEOUT) do
          uri = URI.parse(subscription.url.to_s)
          addresses = guard!(uri)

          headers = WebhookSignature.headers(
            secrets: @webhooks.secrets_for(subscription, now: now),
            id: row.event_id, timestamp: now.to_i, payload: row.payload.to_s
          )
          send_request(uri, headers, row.payload.to_s, addresses)
        end
        status = response.code.to_i
        { status: status, error: status.between?(200, 299) ? nil : "HTTP #{status}: #{summary(response)}" }
      rescue Util::MediaFetcher::Error => e
        { status: nil, error: "refused: #{e.message}" }
      rescue StandardError => e
        { status: nil, error: "#{e.class}: #{e.message}" }
      end

      # Connects to the address the guard already validated rather than handing
      # Net::HTTP the hostname to resolve again, which is what used to reopen the
      # DNS rebinding window between the check and the connection.
      #
      # Tries each validated address in turn, same as {Scripting::Endpoints}: a
      # host that only answers on a family this deployment cannot route still
      # gets a fair attempt on whichever address does.
      def send_request(uri, headers, body, addresses)
        return @http.call(uri, headers, body) if @http

        last = nil
        Array(addresses).each do |address|
          http = Util::MediaFetcher.pinned_http(uri, address, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
          begin
            return read_response(http, build_request(uri, headers, body))
          rescue *Util::MediaFetcher::UNREACHABLE_ERRORS => e
            last = e
            @logger&.debug { "webhook pump could not reach #{address}: #{e.class}: #{e.message}" }
          end
        end

        raise last if last

        raise Util::MediaFetcher::Error, "no address answered for #{uri.hostname}"
      end

      # Stop reading once the diagnostic budget is filled. Leaving the request
      # block early closes the connection rather than draining an arbitrary
      # subscriber response. The wall deadline also covers slow body chunks.
      def read_response(http, request)
        completed = Object.new
        Timeout.timeout(REQUEST_TIMEOUT) do
          catch(completed) do
            http.request(request) do |response|
              body = +"".b
              response.read_body do |chunk|
                body << chunk.byteslice(0, MAX_RESPONSE - body.bytesize)
                throw completed, Response.new(code: response.code, body: body) if body.bytesize >= MAX_RESPONSE
              end
              throw completed, Response.new(code: response.code, body: body)
            end
          end
        end
      end

      def build_request(uri, headers, body)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = Scripting::Endpoints::YAML_TYPE
        request["User-Agent"] = "rubotty-webhooks"
        headers.each { |key, value| request[key] = value }
        request.body = body
        request
      end

      # The media fetcher's own guard, so there is one answer in this codebase
      # to "may the bot open a connection to this host". Returns the addresses
      # it validated, in the order to try them, so the caller connects to one of
      # those rather than resolving the name a second time.
      def guard!(uri)
        Util::MediaFetcher.new(logger: @logger, resolver: @resolver)
                          .send(:guard_public_address!, uri)
      end

      def summary(response)
        response.body.to_s[0, MAX_RESPONSE].to_s.strip.gsub(/\s+/, " ")[0, 200].to_s
      rescue StandardError
        ""
      end
    end
  end
end
