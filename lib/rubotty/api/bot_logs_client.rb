# frozen_string_literal: true

require "net/http"
require "uri"
require "yamlcamel"

module Rubotty
  module Api
    # One authenticated GET against the bot process's own {Core::HealthServer},
    # over the docker network: env-driven URL, shared secret header, never the
    # public tunnel. #fetch and #fetch_info are the two callers today; #get is
    # that same hop generalised to any path the health server mounts under the
    # secret, so a third caller has somewhere to plug in rather than a reason
    # to copy this file.
    class BotLogsClient
      DEFAULT_TIMEOUT = 3

      # A log fetch's outcome: +entries+ (an Array of { time:, level:, text: })
      # on success, or +error+ (a short reason) on failure.
      Result = Struct.new(:entries, :error, keyword_init: true) do
        def ok? = error.nil?
      end

      # One internal GET's outcome: +body+ (the parsed YAML document) on
      # success, or +error+ (a short reason) on failure.
      Response = Struct.new(:body, :error, keyword_init: true) do
        def ok? = error.nil?
      end

      # @param bot_url [String, nil] the bot's internal base URL; nil makes every
      #   call answer with an explanatory error instead of attempting a request
      # @param secret [String, nil] the shared secret
      #   {Core::HealthServer::RELOAD_SECRET_HEADER} expects; nil also short-circuits
      # @param logger [#warn, nil]
      # @param timeout [Numeric] open and read timeout, in seconds
      def initialize(bot_url:, secret:, logger: nil, timeout: DEFAULT_TIMEOUT)
        @bot_url = presence(bot_url)
        @secret = presence(secret)
        @logger = logger
        @timeout = timeout
      end

      # Whether both a URL and a secret are configured.
      def configured? = !@bot_url.nil? && !@secret.nil?

      # Fetch the bot process's recent log entries.
      #
      # @param level [String, nil] passed through as the `level` query param
      # @param limit [Integer, String, nil] passed through as the `limit` query param
      # @return [Result]
      def fetch(level: nil, limit: nil)
        result = get(Core::HealthServer::LOGS_PATH, params: { "level" => level, "limit" => limit })
        return Result.new(entries: nil, error: result.error) unless result.ok?

        # With no log buffer wired HealthServer never mounts LOGS_PATH, so the
        # request falls through to the liveness handler and gets a 200 "ok".
        unless result.body.is_a?(Hash) && result.body.key?("entries")
          return Result.new(entries: nil, error: "the bot process has no logs route (its log buffer is not wired)")
        end

        Result.new(entries: Array(result.body["entries"]), error: nil)
      end

      # The bot process's own build and runtime facts, from
      # {Core::HealthServer::INFO_PATH}: which build that container is running.
      #
      # @return [Hash] the parsed facts, or { "reachable" => false, "error" => ... }
      def fetch_info
        result = get(Core::HealthServer::INFO_PATH)
        return { "reachable" => false, "error" => result.error } unless result.ok?
        unless result.body.is_a?(Hash)
          return { "reachable" => false, "error" => "the bot process sent an unreadable body" }
        end

        result.body.merge("reachable" => true)
      end

      # One authenticated GET against the bot process's health server: the
      # hop #fetch and #fetch_info are both built on. Any path
      # {Core::HealthServer} mounts under its shared secret is reachable this
      # way, with +params+ riding the query string.
      #
      # @param path [String] a path {Core::HealthServer} mounts
      # @param params [Hash] query params; a nil value is dropped rather than sent as empty
      # @return [Response]
      def get(path, params: {})
        unless configured?
          return Response.new(body: nil, error: "the bot process's internal URL or shared secret is not configured")
        end

        uri = build_uri(path, params)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: @timeout, read_timeout: @timeout) do |http|
          request = Net::HTTP::Get.new(uri)
          request[Core::HealthServer::RELOAD_SECRET_HEADER] = @secret
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          return Response.new(body: nil, error: "the bot process answered #{response.code}")
        end

        Response.new(body: YAMLCamel.load(response.body.to_s), error: nil)
      rescue StandardError => e
        @logger&.warn { "internal GET #{path} failed: #{e.class}: #{e.message}" }
        Response.new(body: nil, error: "could not reach the bot process (#{e.class}: #{e.message})")
      end

      private

      def build_uri(path, params)
        uri = URI.join(@bot_url, path)
        given = params.compact
        uri.query = URI.encode_www_form(given) unless given.empty?
        uri
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
