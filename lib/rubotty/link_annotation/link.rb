# frozen_string_literal: true

require "uri"

module Rubotty
  module LinkAnnotation
    # Turns what somebody typed into a room into the URL this feature works with.
    # Tracking parameters come off, since leaving them on splits the cache and
    # rides along into whatever link is posted back. The fragment comes off too.
    module Link
      # Parameters naming a campaign, referrer or click rather than a document.
      # Not on this list: "s", "ref", "source" and "id", each load bearing on
      # some publisher's site, where stripping one resolves to the wrong page.
      TRACKING_PREFIXES = %w[utm_ pk_ mtm_ piwik_ at_ ns_ stm_].freeze

      TRACKING_PARAMS = %w[
        fbclid gclid dclid gclsrc gbraid wbraid msclkid yclid twclid ttclid igshid igsh
        mc_cid mc_eid _hsenc _hsmi mkt_tok vero_id vero_conv oly_anon_id oly_enc_id
        ref_src ref_url s_cid cmpid CMP campaign_id ito xtor scm spm
        __twitter_impression guccounter guce_referrer guce_referrer_sig
        WT.mc_id icid ncid smid srnd cvid
      ].map(&:downcase).freeze

      module_function

      # The cleaned URL, or nil for anything this feature will not work with.
      # https only: http is refused rather than upgraded.
      #
      # @param raw [String]
      # @return [URI::HTTPS, nil]
      def clean(raw)
        uri = parse(raw)
        return nil if uri.nil?

        uri.host = uri.host.to_s.downcase.sub(/\.\z/, "")
        return nil if uri.host.empty?

        uri.fragment = nil
        uri.query = strip_tracking(uri.query)
        uri.path = "/" if uri.path.to_s.empty?
        uri
      rescue URI::Error
        nil
      end

      # Whether +name+ is a parameter that describes how somebody arrived rather
      # than which document they arrived at.
      def tracking?(name)
        key = name.to_s.downcase
        TRACKING_PARAMS.include?(key) || TRACKING_PREFIXES.any? { |prefix| key.start_with?(prefix) }
      end

      # The host with the leading "www." removed, for showing back to a room.
      def display_host(uri) = uri.host.to_s.sub(/\Awww\./, "")

      # Whether +host+ equals or sits under any entry in +domains+, the same
      # subdomain-inclusive rule Features::LinkFilter matches its lists by.
      def under?(host, domains)
        name = host.to_s.downcase
        Array(domains).any? do |domain|
          entry = domain.to_s.strip.downcase.sub(/\Awww\./, "")
          next false if entry.empty?

          name == entry || name.end_with?(".#{entry}")
        end
      end

      def parse(raw)
        text = raw.to_s.strip
        return nil if text.empty?

        # A bare "www.example.com/x" is how half the links in a room are typed.
        # Anything else scheme-less is left alone, so a sentence is not fetched.
        text = "https://#{text}" if text.match?(/\Awww\./i)

        uri = URI.parse(text)
        uri.is_a?(URI::HTTPS) ? uri : nil
      rescue URI::InvalidURIError
        nil
      end
      private_class_method :parse

      # The query with every tracking parameter removed, or nil when nothing is
      # left. A query with nothing to strip comes back byte for byte, since round
      # tripping is lossy ("?token" becomes "?token=") and can break a link.
      def strip_tracking(query)
        return nil if query.nil? || query.empty?

        pairs = URI.decode_www_form(query)
        kept = pairs.reject { |name, _| tracking?(name) }
        return query if kept.length == pairs.length
        return nil if kept.empty?

        URI.encode_www_form(kept)
      rescue ArgumentError
        # A query that is not form encoded at all is left as it arrived.
        query
      end
      private_class_method :strip_tracking
    end
  end
end
