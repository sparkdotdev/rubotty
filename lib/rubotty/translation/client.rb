# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Rubotty
  module Translation
    # Talks to one LibreTranslate instance, and nothing else.
    #
    # Every way this can go wrong (unreachable, slow, a non 2xx answer, a
    # pair the connection has not allowed, a body that is not the JSON
    # LibreTranslate promises) comes back as {Error}. Nothing here is caught
    # and swallowed: {Relay} lets it propagate into the durable scheduler's
    # own retry-with-backoff, which is the failure posture this integration
    # wants, rather than growing a second one here.
    class Client
      class Error < Rubotty::Error; end

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      # @param settings [Settings]
      # @param logger [#debug, nil]
      # @param http [#call, nil] injected in specs: receives (uri, body) and
      #   returns something answering #code and #body. nil uses Net::HTTP.
      # @param http_get [#call, nil] injected in specs: receives (uri) and
      #   returns something answering #code and #body. nil uses Net::HTTP.
      def initialize(settings:, logger: nil, http: nil, http_get: nil)
        @settings = settings
        @logger = logger
        @http = http
        @http_get = http_get
      end

      # @param text [String]
      # @param source [String] LibreTranslate source language code
      # @param target [String] LibreTranslate target language code
      # @return [String] the translated text
      # @raise [Error]
      def translate(text, source:, target:)
        raise Error, "LibreTranslate is not configured" unless @settings.configured?
        raise Error, "#{source} -> #{target} is not an allowed pair" unless @settings.allowed?(source, target)

        parse(post(endpoint_for("translate"), body_for(text, source, target)))
      end

      # Proves the connection actually works, which is what the Integrations
      # page's Test button needs: no text is translated and nothing is
      # spent, only LibreTranslate's own GET /languages is asked for, and it
      # answers the same way a translate call would to a wrong URL or a
      # wrong key.
      #
      # @return [Array<Hash>] the languages LibreTranslate reports
      # @raise [Error]
      def test_connection
        raise Error, "LibreTranslate is not configured" unless @settings.configured?

        parse_languages(get(languages_endpoint))
      end

      private

      # Raises {Error} rather than a bare URI error for a malformed
      # +@settings.url+: the Integrations page's Test button hands this a
      # URL nobody has saved yet, so a typo has to surface as the same
      # on-page failure a wrong host or a wrong key would, not a 500.
      def endpoint_for(path)
        base = @settings.url.to_s
        base = "#{base}/" unless base.end_with?("/")
        URI.join(base, path)
      rescue URI::Error, ArgumentError => e
        raise Error, "#{@settings.url.inspect} is not a usable URL: #{e.message}"
      end

      def languages_endpoint
        uri = endpoint_for("languages")
        key = @settings.api_key
        uri.query = URI.encode_www_form(api_key: key) if key
        uri
      end

      def body_for(text, source, target)
        payload = { q: text, source: source.to_s, target: target.to_s, format: "text" }
        key = @settings.api_key
        payload[:api_key] = key if key
        JSON.generate(payload)
      end

      def post(uri, body)
        return @http.call(uri, body) if @http

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request["Accept"] = "application/json"
          request.body = body
          http.request(request)
        end
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach LibreTranslate: #{e.class}: #{e.message}"
      end

      def get(uri)
        return @http_get.call(uri) if @http_get

        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          request = Net::HTTP::Get.new(uri)
          request["Accept"] = "application/json"
          http.request(request)
        end
      rescue Error
        raise
      rescue StandardError => e
        raise Error, "could not reach LibreTranslate: #{e.class}: #{e.message}"
      end

      def parse_languages(response)
        code = response.code.to_i
        raise Error, "LibreTranslate answered HTTP #{code}" unless code.between?(200, 299)

        data = JSON.parse(response.body.to_s)
        raise Error, "LibreTranslate's answer was not a list of languages" unless data.is_a?(Array)

        data
      rescue JSON::ParserError => e
        raise Error, "LibreTranslate's answer was not JSON: #{e.message}"
      end

      def parse(response)
        code = response.code.to_i
        raise Error, "LibreTranslate answered HTTP #{code}" unless code.between?(200, 299)

        data = JSON.parse(response.body.to_s)
        text = data["translatedText"]
        raise Error, "LibreTranslate's answer had no translatedText" if text.nil?

        text
      rescue JSON::ParserError => e
        raise Error, "LibreTranslate's answer was not JSON: #{e.message}"
      end
    end
  end
end
