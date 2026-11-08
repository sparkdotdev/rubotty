# frozen_string_literal: true

require "ipaddr"
require "net/http"
require "resolv"
require "tempfile"
require "timeout"
require "uri"

module Rubotty
  module Util
    # Downloads a remote file so it can be re uploaded to a platform that will not
    # fetch a URL itself, enforcing a streaming byte cap, a redirect limit, https
    # with no downgrade, and an SSRF guard on every hop.
    #
    # Returns a Tempfile the caller must close and unlink; {.with} does that.
    class MediaFetcher
      DEFAULT_LIMIT = 25 * 1024 * 1024
      MAX_REDIRECTS = 3

      # Per attempt, and short because a host is tried once per resolved address:
      # an address family this deployment cannot route has to cost a moment
      # rather than stalling the room's worker.
      OPEN_TIMEOUT = 3

      # Once the connection is up this is about a real file arriving, so it stays
      # generous.
      READ_TIMEOUT = 60

      # How many times the whole fetch is attempted when the network faults.
      ATTEMPTS = 3
      RETRY_DELAY = 0.25

      # The whole fetch, including resolution, retries, redirects and a body
      # that keeps arriving a little at a time, shares this wall deadline.
      MAX_TOTAL_SECONDS = 45

      # Faults that mean the connection was never made, so the next address is
      # worth trying. A fault raised after the connection is up is deliberately
      # absent: moving that to another address would replay a request the server
      # already has.
      UNREACHABLE_ERRORS = [
        Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH,
        Errno::ENETUNREACH, Errno::ETIMEDOUT, SocketError
      ].freeze

      # Network faults worth attempting the whole fetch again, for a link whose
      # families come and go. A refusal is a decision and never appears here.
      TRANSIENT_ERRORS = (UNREACHABLE_ERRORS + [Net::ReadTimeout, Errno::ECONNRESET, EOFError]).freeze

      # The blocks a fetch must never target live in {Util::PublicAddress}. Kept as a
      # constant here because callers still ask for it.
      RESERVED_RANGES = PublicAddress::RESERVED_RANGES

      # Raised when a download is refused or fails. Never fatal: the caller falls
      # back to relaying a link.
      class Error < Rubotty::Error; end
      class DeadlineExceeded < Error; end

      # @param resolver [#call] maps a hostname to address strings. Injectable so
      #   the SSRF guard can be tested without real DNS.
      def initialize(limit: DEFAULT_LIMIT, logger: nil, allow_insecure: false, http: nil, resolver: nil,
                     sleeper: nil, clock: nil, timeout: MAX_TOTAL_SECONDS)
        @limit = limit
        @logger = logger
        @allow_insecure = allow_insecure
        @http = http
        @resolver = resolver || PublicAddress.system_resolver
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @timeout = timeout
      end

      attr_reader :limit

      # Download +url+, yield the open Tempfile, and clean up afterwards.
      #
      # @yieldparam [Tempfile]
      # @return [Object] whatever the block returns, or nil when the download
      #   was refused
      def with(url, filename: nil)
        file = fetch(url, filename: filename)
        return nil if file.nil?

        begin
          yield file
        ensure
          file.close
          file.unlink
        end
      end

      # @return [Tempfile, nil] nil when the file is too large, unreachable, or
      #   the URL is unacceptable
      def fetch(url, filename: nil)
        uri = parse(url)
        return nil if uri.nil?

        return @http.call(uri, filename) if @http

        deadline = @clock.call + @timeout
        # Socket read_timeout restarts whenever bytes arrive, so it cannot
        # enforce the overall budget against a slowly streaming peer. The
        # independent timer also interrupts resolution and partial reads.
        Timeout.timeout(@timeout, DeadlineExceeded, "media download exceeded its time limit") do
          with_retries(url, deadline) { download(uri, filename, MAX_REDIRECTS, deadline: deadline) }
        end
      rescue Error => e
        @logger&.warn { "media download refused: #{e.message}" }
        nil
      rescue StandardError => e
        @logger&.warn { "media download failed for #{safe_url(url)}: #{e.class}: #{e.message}" }
        nil
      end

      # A Net::HTTP pinned to +address+, keeping +uri+'s hostname for the Host
      # header and for TLS SNI and certificate verification.
      #
      # Public and on the class because Scripting::Endpoints borrows the guard
      # and so has to borrow the connection too: the two halves are only safe
      # together, and splitting them is exactly how the rebinding window opened.
      def self.pinned_http(uri, address, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
        http = Net::HTTP.new(uri.hostname, uri.port)
        http.ipaddr = address
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        http
      end

      private

      def parse(url)
        return nil if url.nil? || url.to_s.empty?

        uri = URI.parse(url.to_s)
        unless uri.is_a?(URI::HTTPS) || (@allow_insecure && uri.is_a?(URI::HTTP))
          raise Error, "refusing to download from #{uri.scheme.inspect}"
        end

        uri
      rescue URI::InvalidURIError
        raise Error, "not a usable URL"
      end

      def download(uri, filename, redirects_left, deadline: nil)
        raise Error, "too many redirects" if redirects_left.negative?

        connect(uri, guard_public_address!(uri), deadline: deadline) do |http|
          request = Net::HTTP::Get.new(uri)
          http.request(request) do |response|
            case response
            when Net::HTTPRedirection
              return follow(response, uri, filename, redirects_left, deadline: deadline)
            when Net::HTTPSuccess
              return stream(response, filename || basename(uri), deadline: deadline)
            else
              raise Error, "server returned #{response.code}"
            end
          end
        end
      end

      # Open a connection to the first of +addresses+ that answers and yield it.
      #
      # Every candidate has already been validated, so falling through to the
      # next one costs the guard nothing: the choice is only ever between
      # addresses the host was allowed to be reached at.
      def connect(uri, addresses, deadline: nil)
        last = nil
        addresses.each do |address|
          remaining = remaining_seconds(deadline)
          http = self.class.pinned_http(uri, address, open_timeout: [OPEN_TIMEOUT, remaining].min,
                                                      read_timeout: [READ_TIMEOUT, remaining].min)
          begin
            http.start
          rescue *UNREACHABLE_ERRORS => e
            last = e
            @logger&.debug { "media download could not reach #{address}: #{e.class}: #{e.message}" }
            next
          end

          begin
            return yield http
          ensure
            http.finish if http.started?
          end
        end

        raise last if last

        raise Error, "no address answered for #{uri.hostname}"
      end

      # Attempt the whole fetch again when the network faults, since one
      # family of an unstable link dropping out should not cost the
      # message. Only a transient fault is retried: a refusal, an HTTP
      # status and an over-size file are all decisions, and repeating one
      # would mean hammering something already refused.
      def with_retries(url, deadline)
        attempt = 0
        begin
          attempt += 1
          remaining_seconds(deadline)
          yield
        rescue *TRANSIENT_ERRORS => e
          raise e if attempt >= ATTEMPTS
          remaining_seconds(deadline)

          @logger&.debug do
            "media download of #{safe_url(url)} hit #{e.class}, attempt #{attempt} of #{ATTEMPTS}"
          end
          @sleeper.call(RETRY_DELAY * attempt)
          retry
        end
      end

      def follow(response, uri, filename, redirects_left, deadline: nil)
        location = response["location"]
        raise Error, "redirect without a location" if location.nil?

        target = URI.join(uri, location)
        # A redirect must not be allowed to downgrade the transport.
        unless target.is_a?(URI::HTTPS) || @allow_insecure
          raise Error, "redirect downgraded to #{target.scheme}"
        end

        download(target, filename, redirects_left - 1, deadline: deadline)
      end

      # Refuses anything that is not a normal public address, on every
      # redirect hop, and hands back the addresses the caller may then
      # connect to: returning them closes the DNS rebinding window, since
      # letting Net::HTTP re-resolve the name at connect time would
      # validate a different answer than the one used (see {.pinned_http}).
      # Every answer must pass, so a mixed public/private name is refused.
      #
      # @return [Array<String>] validated addresses, in the order to try them
      def guard_public_address!(uri)
        addresses = resolve_addresses(uri.hostname)
        raise Error, "could not resolve host" if addresses.empty?

        addresses.each do |address|
          next if public_address?(address)

          raise Error, "refusing to connect to a non public address"
        end
        ordered(addresses).map(&:to_s)
      end

      # IPv4 ahead of IPv6 when a host answers in both families, because IPv4 is
      # the family this deployment can route; the order inside a family is left
      # as the resolver gave it. IPv6 is still tried, so a v4 only failure falls
      # through to it rather than being ruled out.
      def ordered(addresses) = addresses.partition { |address| address.native.ipv4? }.flatten

      # @return [Array<IPAddr>] every address the host resolves to; a literal IP
      #   resolves to itself. Fails closed to an empty list, which is a refusal.
      def resolve_addresses(host) = PublicAddress.addresses_for(host, resolver: @resolver)

      def public_address?(address) = PublicAddress.public?(address)

      # The cap is enforced as bytes arrive, since Content-Length is a header the
      # remote server controls.
      def stream(response, filename, deadline: nil)
        file = Tempfile.new(["rubotty-media", File.extname(filename.to_s)], binmode: true)
        written = 0
        response.read_body do |chunk|
          remaining_seconds(deadline)
          written += chunk.bytesize
          if written > @limit
            file.close
            file.unlink
            raise Error, "file exceeds the #{@limit} byte limit"
          end
          file.write(chunk)
        end
        file.rewind
        file.define_singleton_method(:original_filename) { filename }
        file
      rescue StandardError
        file&.close!
        raise
      end

      def remaining_seconds(deadline)
        return READ_TIMEOUT if deadline.nil?

        remaining = deadline - @clock.call
        raise DeadlineExceeded, "media download exceeded its time limit" unless remaining.positive?

        remaining
      end

      def basename(uri)
        name = File.basename(uri.path.to_s)
        name.empty? ? "attachment" : name
      end

      # Telegram file URLs embed the bot token, so a URL must never reach a log
      # line intact.
      def safe_url(url) = SafeUrl.redact(url)
    end
  end
end
