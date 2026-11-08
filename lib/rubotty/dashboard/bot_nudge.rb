# frozen_string_literal: true

require "net/http"
require "uri"

module Rubotty
  module Dashboard
    # After a control-plane write, POST a lightweight "reload" to the bot's
    # internal endpoint so it re-reads the database without waiting for its next
    # poll. +bot_url+ must be internal, never the public tunnel address.
    class BotNudge
      # Short on purpose: the poll is about to catch the change anyway.
      DEFAULT_TIMEOUT = 2

      # @param bot_url [String, nil] the bot's internal base URL; nil makes every call a no-op
      # @param secret [String, nil] the shared secret Core::HealthServer's reload route
      #   expects; nil also makes every call a no-op
      # @param logger [#warn, nil]
      # @param timeout [Numeric] open and read timeout, in seconds
      def initialize(bot_url:, secret:, logger: nil, timeout: DEFAULT_TIMEOUT)
        @bot_url = presence(bot_url)
        @secret = presence(secret)
        @logger = logger
        @timeout = timeout
      end

      def configured? = !@bot_url.nil? && !@secret.nil?

      # POST the nudge. Never raises: a lost nudge must not fail a write that
      # already succeeded.
      #
      # @param reason [String] carried as the request body, for the bot's log
      # @return [Boolean] whether the nudge was sent
      def nudge(reason: "dashboard write")
        return false unless configured?

        uri = URI.join(@bot_url, Core::HealthServer::RELOAD_PATH)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: @timeout, read_timeout: @timeout) do |http|
          request = Net::HTTP::Post.new(uri)
          request[Core::HealthServer::RELOAD_SECRET_HEADER] = @secret
          request.body = reason.to_s
          http.request(request)
        end
        response.is_a?(Net::HTTPSuccess)
      rescue StandardError => e
        @logger&.debug { "bot nudge failed (the poll will still catch it): #{e.class}: #{e.message}" }
        false
      end

      # #relay_proposal's outcome: ok, or a short reason a reader can act on.
      RelayResult = Struct.new(:ok, :error, keyword_init: true) do
        def ok? = ok
      end

      # POST the accept, telling the bot to relay one approved proposal's
      # stored items. Unlike #nudge, a failure here is NOT harmless: only
      # the bot process holds the adapters that can send it, so the
      # operator has to be told plainly rather than shown a bare "accepted".
      #
      # @param proposal_id [Integer]
      # @return [RelayResult]
      def relay_proposal(proposal_id)
        unless configured?
          return RelayResult.new(ok: false,
                                 error: "the bot process's internal URL or shared secret is not configured")
        end

        uri = URI.join(@bot_url, Core::HealthServer::RELAY_PROPOSAL_PATH)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: @timeout, read_timeout: @timeout) do |http|
          request = Net::HTTP::Post.new(uri)
          request[Core::HealthServer::RELOAD_SECRET_HEADER] = @secret
          request.body = proposal_id.to_s
          http.request(request)
        end

        if response.is_a?(Net::HTTPSuccess)
          RelayResult.new(ok: true, error: nil)
        else
          body = presence(response.body)
          RelayResult.new(ok: false, error: body || "the bot process answered #{response.code}")
        end
      rescue StandardError => e
        @logger&.warn { "relay-proposal push failed: #{e.class}: #{e.message}" }
        RelayResult.new(ok: false, error: "could not reach the bot process (#{e.class}: #{e.message})")
      end

      private

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
