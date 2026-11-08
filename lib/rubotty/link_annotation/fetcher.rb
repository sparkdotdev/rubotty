# frozen_string_literal: true

require "net/http"
require "uri"

module Rubotty
  module LinkAnnotation
    # Reads the beginning of a web page so its language can be told. The URL
    # comes from whoever typed it into a room, so every bound is tight:
    # https only, an SSRF guard on every resolved address and redirect hop,
    # a connection pinned to the address the guard validated rather than a
    # fresh hostname lookup, {MAX_BYTES} enforced while streaming,
    # {MAX_REDIRECTS}, and two timeouts. Nothing here raises at its caller;
    # a refusal and a failure both come back as nil.
    class Fetcher
      MAX_BYTES = 512 * 1024
      MAX_REDIRECTS = 3
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 5

      # Content types worth reading. A PDF, image or video has no <html lang>
      # and no prose to count, so it is dropped without being downloaded.
      HTML_TYPES = %w[text/html application/xhtml+xml text/plain].freeze

      # Identified plainly, so a site operator reading their logs can tell who is
      # fetching and block it.
      USER_AGENT = "rubotty/link-annotation"

      # @param logger [#debug, #warn, nil]
      # @param resolver [#call, nil] hostname to addresses, injected in specs
      # @param http [#call, nil] a stand-in for the whole request, taking the URI
      #   and returning a {Page} or nil. Specs pass one instead of a socket.
      def initialize(logger: nil, resolver: nil, http: nil, limit: MAX_BYTES)
        @logger = logger
        @resolver = resolver || Util::PublicAddress.system_resolver
        @http = http
        @limit = limit
      end

      # @param uri [URI::HTTPS] a URL already through {Link.clean}
      # @return [Page, nil]
      def call(uri)
        return nil if uri.nil?
        return @http.call(uri) if @http

        get(uri, uri, MAX_REDIRECTS)
      rescue StandardError => e
        @logger&.debug { "link_annotation: could not read #{Util::SafeUrl.redact(uri.to_s)}: #{e.class}: #{e.message}" }
        nil
      end

      private

      def get(uri, requested, redirects_left)
        return nil if redirects_left.negative?
        return nil unless uri.is_a?(URI::HTTPS)

        addresses = guard(uri)
        return nil if addresses.nil?

        connect(uri, addresses) do |http|
          http.request(request_for(uri)) do |response|
            case response
            when Net::HTTPRedirection then return follow(response, uri, requested, redirects_left)
            when Net::HTTPSuccess then return read(response, uri, requested)
            else
              @logger&.debug { "link_annotation: #{uri.host} answered #{response.code}" }
              return nil
            end
          end
        end
      end

      # Open a connection to the first of +addresses+ that answers and yield it,
      # pinned there rather than to a fresh lookup of +uri+'s hostname, since
      # that second lookup is the DNS rebinding window. Every candidate already
      # passed {#guard}, so falling through to the next one costs nothing.
      def connect(uri, addresses)
        last = nil
        addresses.each do |address|
          http = Util::MediaFetcher.pinned_http(uri, address, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
          begin
            http.start
          rescue *Util::MediaFetcher::UNREACHABLE_ERRORS => e
            last = e
            @logger&.debug { "link_annotation: could not reach #{address}: #{e.class}: #{e.message}" }
            next
          end

          begin
            return yield http
          ensure
            http.finish if http.started?
          end
        end

        raise last if last

        nil
      end

      def request_for(uri)
        Net::HTTP::Get.new(uri).tap do |request|
          request["User-Agent"] = USER_AGENT
          request["Accept"] = "text/html,application/xhtml+xml"
          # Read in the site's own default. Naming a preferred language would
          # make a multilingual publisher serve that edition instead.
          request["Accept-Language"] = "*"
        end
      end

      def follow(response, uri, requested, redirects_left)
        location = response["location"]
        return nil if location.nil?

        target = URI.join(uri, location)
        # A redirect must not leave https; the guard runs again on the new host.
        return nil unless target.is_a?(URI::HTTPS)

        get(target, requested, redirects_left - 1)
      end

      def read(response, uri, requested)
        type = response["content-type"].to_s.split(";").first.to_s.strip.downcase
        return nil unless type.empty? || HTML_TYPES.include?(type)

        body = +""
        response.read_body do |chunk|
          body << chunk
          break if body.bytesize >= @limit
        end
        Page.new(url: uri, requested: requested, html: decode(body, response))
      end

      # The body as UTF-8, from whichever charset the response or the markup
      # declares. A Latin-1 page read as UTF-8 loses its accented characters.
      def decode(body, response)
        charset = response["content-type"].to_s[/charset=["']?([\w-]+)/i, 1] ||
                  body[/<meta[^>]+charset=["']?([\w-]+)/i, 1]
        body.force_encoding(charset || "UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      rescue ArgumentError, Encoding::ConverterNotFoundError
        body.force_encoding("UTF-8").scrub("")
      end

      # Resolve and validate every address +uri+'s host answers to, refusing
      # the whole request if one of them is not public. Returns the addresses
      # to connect to, in the order {#connect} should try them, or nil when
      # the guard refused.
      def guard(uri)
        Util::MediaFetcher.new(logger: @logger, resolver: @resolver).send(:guard_public_address!, uri)
      rescue Util::MediaFetcher::Error => e
        @logger&.debug { "link_annotation: refusing to fetch #{Util::SafeUrl.redact(uri.to_s)}: #{e.message}" }
        nil
      end
    end
  end
end
