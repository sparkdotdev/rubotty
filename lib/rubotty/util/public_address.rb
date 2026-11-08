# frozen_string_literal: true

require "ipaddr"
require "resolv"

module Rubotty
  module Util
    # Whether a host is somewhere this process is willing to open a connection to:
    # the SSRF guard, shared by everything that fetches a URL it did not choose
    # itself, so the callers cannot drift apart.
    module PublicAddress
      # Address blocks that must never be the target of a fetch, link local included
      # because 169.254.169.254 is the cloud metadata endpoint that turns an SSRF
      # into credential theft. An IPv4 mapped IPv6 address is unwrapped first.
      RESERVED_RANGES = %w[
        0.0.0.0/8
        10.0.0.0/8
        100.64.0.0/10
        127.0.0.0/8
        169.254.0.0/16
        172.16.0.0/12
        192.0.0.0/24
        192.0.2.0/24
        192.88.99.0/24
        192.168.0.0/16
        198.18.0.0/15
        198.51.100.0/24
        203.0.113.0/24
        224.0.0.0/4
        240.0.0.0/4
        255.255.255.255/32
        ::/128
        ::1/128
        64:ff9b::/96
        100::/64
        2001:db8::/32
        fc00::/7
        fe80::/10
        ff00::/8
      ].map { |cidr| IPAddr.new(cidr) }.freeze

      module_function

      # The system resolver, injectable so the guard can be tested without real DNS.
      def system_resolver = ->(host) { Resolv.getaddresses(host) }

      # @return [Array<IPAddr>] every address +host+ resolves to. Fails closed to an
      #   empty list, which every caller treats as a refusal.
      def addresses_for(host, resolver: system_resolver)
        return [] if host.nil? || host.to_s.empty?

        begin
          return [IPAddr.new(host)]
        rescue IPAddr::InvalidAddressError
          # Not a literal address, so fall through to a name lookup.
        end

        begin
          resolver.call(host).filter_map { |address| coerce(address) }
        rescue Resolv::ResolvError, SocketError
          []
        end
      end

      # Whether every address +host+ resolves to is a normal public one. EVERY answer
      # is checked, so a name returning one public and one private address is refused,
      # as is a host that resolves to nothing.
      def reachable?(host, resolver: system_resolver)
        addresses = addresses_for(host, resolver: resolver)
        return false if addresses.empty?

        addresses.all? { |address| public?(address) }
      end

      def public?(address)
        native = address.native
        RESERVED_RANGES.none? { |range| range.include?(native) }
      rescue IPAddr::Error
        false
      end

      def coerce(address)
        return address if address.is_a?(IPAddr)

        IPAddr.new(address.to_s)
      rescue IPAddr::InvalidAddressError
        nil
      end
    end
  end
end
