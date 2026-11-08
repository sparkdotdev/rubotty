# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module Api
    # Header-only authentication before Sinatra asks Rack to parse params.
    # The route filter revalidates the token afterward without charging twice.
    class RequestGuard
      CLAIM_KEY = "rubotty.api.request_claim"
      LIMIT_KEY = "rubotty.api.body_limit"
      # Match Sinatra's path language, including encoded literal characters.
      ADMIN_PATH = Mustermann.new("/admin/*")
      UPLOAD_PATH = Mustermann.new("/admin/communities/:slug/files")

      def self.response(status, message, authenticated: false, headers: {})
        body = YAMLCamel.dump({ "error" => message })
        values = { "content-type" => "application/yaml;charset=utf-8", "content-length" => body.bytesize.to_s,
                   "connection" => "close" }.merge(headers)
        values["x-rubotty-version"] = Rubotty::VERSION.to_s if authenticated
        [status, values, [body]]
      end

      def initialize(app, deps:, marker:, text_limit:, envelope_bytes:)
        @app, @deps, @marker = app, deps, marker
        @text_limit, @envelope_bytes = text_limit, envelope_bytes
      end

      def call(env)
        env.delete(CLAIM_KEY)
        env[LIMIT_KEY] = @text_limit
        return @app.call(env) if env["PATH_INFO"] == "/healthz"

        match = env["HTTP_AUTHORIZATION"].to_s.match(/\ABearer\s+(.+)\z/i)
        return self.class.response(401, "missing or malformed Authorization header") unless match

        token = match[1]
        key = @deps.api_keys.authenticate(token: token)
        return self.class.response(401, "invalid or revoked API key") if key.nil?
        unless @deps.rate_limiter.allow?(key)
          return self.class.response(429, "rate limit exceeded", headers: { "retry-after" => @deps.rate_limiter.retry_after.to_s })
        end

        @deps.rate_limiter.record!(key)
        @deps.api_keys.touch_last_used(key)
        env[CLAIM_KEY] = { marker: @marker, token: token }
        if ADMIN_PATH.params(env["PATH_INFO"].to_s) && key.scope != ControlPlane::ApiKeys::SCOPE_ADMINISTRATOR
          return self.class.response(403, "administrator scope required", authenticated: true)
        end

        if env["REQUEST_METHOD"] == "POST" && (upload = UPLOAD_PATH.params(env["PATH_INFO"].to_s))
          community = @deps.community(upload["slug"])
          if community.nil? || (key.scope != ControlPlane::ApiKeys::SCOPE_ADMINISTRATOR && key.community_id != community.id)
            return self.class.response(404, "not found", authenticated: true)
          end
          files = @deps.rehosted_files
          return self.class.response(503, "this deployment has no file store configured", authenticated: true) if files.nil?

          # room_key is in the unread body. The largest permitted room policy
          # preserves every valid upload without trusting that body for a cap.
          rooms = @deps.models.room.where(community_id: community.id).select_map(:room_key)
          limits = [nil, *rooms].map { |room| files.policy_for(community_id: community.id, room_key: room)[:max_bytes].to_i }
          env[LIMIT_KEY] = limits.max + @envelope_bytes
        end
        @app.call(env)
      end
    end
  end
end
