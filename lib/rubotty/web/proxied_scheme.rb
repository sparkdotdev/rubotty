# frozen_string_literal: true

module Rubotty
  module Web
    # Tells the app it is reached over https when a proxy in front terminated
    # the TLS and forwarded plain http, since Rack 3 silently drops a `secure`
    # session cookie on a request it believes is plain http (an operator logs
    # in correctly and lands back on the login form anyway). Set via
    # `X-Forwarded-Proto: https`, or `RUBOTTY_ASSUME_TLS=1` for a proxy that
    # overwrites that header with its own inbound scheme; only enable this
    # behind a proxy that really terminates TLS.
    class ProxiedScheme
      TRUTHY = %w[1 true yes on].freeze

      def self.assume_tls?(env) = TRUTHY.include?(env["RUBOTTY_ASSUME_TLS"].to_s.strip.downcase)

      # @param app [#call]
      # @param assume_tls [Boolean] treat every request as https, whatever the
      #   forwarded header says
      def initialize(app, assume_tls: ProxiedScheme.assume_tls?(ENV))
        @app = app
        @assume_tls = assume_tls
      end

      def call(env)
        mark_secure(env) if @assume_tls || forwarded_https?(env) || cloudflare_https?(env)
        @app.call(env)
      end

      private

      # A proxy chain appends, so the ORIGINAL client scheme is the first entry.
      def forwarded_https?(env)
        env["HTTP_X_FORWARDED_PROTO"].to_s.split(",").first.to_s.strip.downcase == "https"
      end

      # Cloudflare states the browser's scheme here, and unlike the X-Forwarded-*
      # family a later proxy has no convention that says to rewrite it. Traefik
      # overwrites X-Forwarded-Proto with its own inbound scheme, which is plain
      # http once Cloudflare has terminated the TLS, so on that deployment this is
      # the header that survives to say what really happened.
      def cloudflare_https?(env)
        env["HTTP_CF_VISITOR"].to_s.include?(%("scheme":"https"))
      end

      # Rack reads the scheme from several places depending on which it finds, so
      # setting one and leaving the others makes `request.ssl?` answer differently
      # from `url`. All three move together.
      def mark_secure(env)
        env["HTTPS"] = "on"
        env["rack.url_scheme"] = "https"
        env["SERVER_PORT"] = "443" if env["SERVER_PORT"].to_s == "80"
      end
    end
  end
end
