# frozen_string_literal: true

module Rubotty
  module LinkAnnotation
    # One fetched page, and whether it is worth believing.
    #
    # A consent wall, a bot check and a subscription interstitial all answer 200
    # with a full HTML body, so a 200 alone would have the bot announce the
    # language of a Cloudflare challenge.
    class Page
      # Text a challenge screen carries and an article does not, matched case
      # insensitively against the title and the opening of the visible text.
      # Kept narrow: matching "we use cookies" would refuse half the web.
      INTERSTITIAL_MARKERS = [
        "just a moment",
        "enable javascript and cookies",
        "checking your browser",
        "attention required",
        "verify you are human",
        "are you a robot",
        "please enable cookies to continue",
        "access denied",
        "one more step",
        "unusual traffic"
      ].freeze

      # Below this much visible text a page is a holding screen, a redirect stub
      # or an error.
      MIN_TEXT = 400

      # @param url [URI] the URL finally landed on, after any redirects
      # @param requested [URI] the URL originally asked for
      # @param html [String]
      def initialize(url:, requested:, html:)
        @url = url
        @requested = requested
        @html = html.to_s
        @text = nil
      end

      attr_reader :url, :requested, :html

      # The page's visible text: markup, scripts, styles and comments removed and
      # whitespace collapsed.
      def text
        @text ||= begin
          stripped = @html.dup
          stripped.gsub!(%r{<(script|style|noscript|template)\b.*?</\1>}mi, " ")
          stripped.gsub!(/<!--.*?-->/m, " ")
          stripped.gsub!(/<[^>]*>/m, " ")
          unescape(stripped).gsub(/\s+/, " ").strip
        end
      end

      def title = @html[%r{<title[^>]*>(.*?)</title>}mi, 1].to_s.strip

      # Whether this is the page that was asked for rather than something served
      # in front of it.
      def article?
        same_site? && text.length >= MIN_TEXT && !interstitial?
      end

      # The reason {#article?} said no, for the log line. nil when it said yes.
      def refusal
        return nil if article?
        return "landed on #{@url.host} instead of #{@requested.host}" unless same_site?
        return "only #{text.length} characters of text" if text.length < MIN_TEXT

        "looks like an interstitial"
      end

      # Whether the fetch ended up somewhere related to where it started; a
      # redirect to a consent domain or a login provider does not pass.
      def same_site?
        landed = @url.host.to_s.downcase
        asked = @requested.host.to_s.downcase
        return true if landed == asked

        landed.end_with?(".#{registrable(asked)}") || landed == registrable(asked)
      end

      def interstitial?
        haystack = "#{title} #{text[0, 500]}".downcase
        INTERSTITIAL_MARKERS.any? { |marker| haystack.include?(marker) }
      end

      private

      # The host minus one leading label, as close to a registrable domain as
      # this gets without a public suffix list.
      def registrable(host)
        labels = host.split(".")
        labels.length > 2 ? labels[1..].join(".") : host
      end

      def unescape(text)
        text.gsub("&nbsp;", " ").gsub("&amp;", "&").gsub("&lt;", "<")
            .gsub("&gt;", ">").gsub("&quot;", '"').gsub("&#39;", "'")
            .gsub(/&#(\d+);/) { [Regexp.last_match(1).to_i].pack("U") }
      rescue RangeError
        text
      end
    end
  end
end
