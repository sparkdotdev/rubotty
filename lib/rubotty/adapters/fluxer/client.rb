# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

module Rubotty
  module Adapters
    module Fluxer
      # Minimal Fluxer REST client built on Net::HTTP. Fluxer (docs.fluxer.app)
      # is Discord shaped: `Authorization: Bot <token>`, snowflake ids, a
      # webhook execute path. The ONLY file that speaks HTTP, so the rest of
      # the adapter runs against a double with no network.
      class Client
        # The API is its own host. fluxer.app serves the marketing site and
        # answers every API path with a 404 page, so this cannot be derived
        # from the web address the way Discord's can.
        DEFAULT_API_BASE = "https://api.fluxer.app"

        def initialize(token:, api_base: DEFAULT_API_BASE, http: nil, logger: nil, timeout: 60)
          @token = token
          @api_base = api_base.to_s.chomp("/")
          @http = http || HttpTransport.new(timeout: timeout)
          @logger = logger
        end

        attr_reader :logger, :api_base, :token

        # The account we are signed in as: an inbound message authored by this id
        # is one we sent as the bot.
        def own_id
          me = get("/users/@me")
          id = me && me["id"]
          id&.to_s
        end

        # Best effort user lookup: a user the bot cannot see returns nil rather
        # than raising, and the parser falls back.
        def fetch_user(id)
          return nil if id.nil?

          get("/users/#{escape(id)}")
        rescue AdapterError
          nil
        end

        # Best effort lookup of one guild member, which is where Fluxer keeps a
        # per guild nickname. A member the bot cannot see returns nil rather than
        # raising.
        def fetch_member(guild_id, user_id)
          return nil if guild_id.nil? || user_id.nil?

          get("/guilds/#{escape(guild_id)}/members/#{escape(user_id)}")
        rescue AdapterError
          nil
        end

        # Fetched rather than hardcoded, so a self hosted Fluxer points the bot at
        # its own gateway.
        def gateway_url
          info = get("/gateway/bot")
          info && (info["url"] || info.dig("url"))
        rescue AdapterError
          nil
        end

        # Every guild the bot is a member of, as the API returned them.
        def list_guilds
          Array(get("/users/@me/guilds"))
        end

        # One guild's channels, each carrying an id, a name and a numeric type.
        def list_guild_channels(guild_id)
          Array(get("/guilds/#{escape(guild_id)}/channels"))
        end

        # @param body [Hash] content, message_reference, allowed_mentions, nonce
        def send_message(channel_id, body)
          post("/channels/#{escape(channel_id)}/messages", body)
        end

        # Same send, carrying real files. +files+ is an array of
        # {filename:, mime_type:, io:} in the order they should attach.
        def send_message_with_files(channel_id, body, files)
          post_multipart("/channels/#{escape(channel_id)}/messages", body, files)
        end

        # Open (or reopen, a Discord shaped endpoint is idempotent here) the
        # DM channel with one user, so #send_message can post to it. Returns
        # the channel object.
        def create_dm(user_id)
          post("/users/@me/channels", recipient_id: user_id)
        end

        def edit_message(channel_id, message_id, body)
          patch("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}", body)
        end

        def delete_message(channel_id, message_id)
          delete("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}")
        end

        # The bot's own reaction is added and removed one emoji at a time, keyed
        # by the emoji token in the path.
        def add_reaction(channel_id, message_id, emoji)
          put("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}/reactions/#{escape(emoji)}/@me")
        end

        def remove_own_reaction(channel_id, message_id, emoji)
          delete("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}/reactions/#{escape(emoji)}/@me")
        end

        def list_webhooks(channel_id)
          get("/channels/#{escape(channel_id)}/webhooks")
        end

        def create_webhook(channel_id, name)
          post("/channels/#{escape(channel_id)}/webhooks", name: name)
        end

        # ?wait=true so the created message id comes back; without it there is
        # nothing to record and no edit or delete propagation.
        def execute_webhook(webhook_id, webhook_token, body)
          post("/webhooks/#{escape(webhook_id)}/#{escape(webhook_token)}?wait=true", body)
        end

        def execute_webhook_with_files(webhook_id, webhook_token, body, files)
          post_multipart("/webhooks/#{escape(webhook_id)}/#{escape(webhook_token)}?wait=true", body, files)
        end

        def edit_webhook_message(webhook_id, webhook_token, message_id, body)
          patch("/webhooks/#{escape(webhook_id)}/#{escape(webhook_token)}/messages/#{escape(message_id)}", body)
        end

        def delete_webhook_message(webhook_id, webhook_token, message_id)
          delete("/webhooks/#{escape(webhook_id)}/#{escape(webhook_token)}/messages/#{escape(message_id)}")
        end

        def ban_member(guild_id, user_id, reason: nil)
          put("/guilds/#{escape(guild_id)}/bans/#{escape(user_id)}", { reason: reason }.compact)
        end

        def unban_member(guild_id, user_id)
          delete("/guilds/#{escape(guild_id)}/bans/#{escape(user_id)}")
        end

        def kick_member(guild_id, user_id)
          delete("/guilds/#{escape(guild_id)}/members/#{escape(user_id)}")
        end

        def leave_guild(guild_id)
          delete("/users/@me/guilds/#{escape(guild_id)}")
        end

        def pin_message(channel_id, message_id)
          put("/channels/#{escape(channel_id)}/pins/#{escape(message_id)}")
        end

        def unpin_message(channel_id, message_id)
          delete("/channels/#{escape(channel_id)}/pins/#{escape(message_id)}")
        end

        # +until+ is an ISO8601 timestamp, or nil to lift a timeout early. nil has
        # to reach the wire as a real JSON null, not go missing: the API reads a
        # missing key as "leave the timeout alone" and only a literal null clears
        # it, so this skips the generic compacting #patch does for every other call.
        def timeout_member(guild_id, user_id, until_time, reason: nil)
          patch_literal("/guilds/#{escape(guild_id)}/members/#{escape(user_id)}",
                        communication_disabled_until: until_time, timeout_reason: reason)
        end

        private

        def get(path) = request(:get, path)

        def post(path, body = nil) = request(:post, path, body)

        def patch(path, body) = request(:patch, path, body)

        def put(path, body = nil) = request(:put, path, body)

        def delete(path) = request(:delete, path)

        def request(verb, path, body = nil)
          uri = URI.parse("#{@api_base}#{path}")
          payload = body.nil? ? nil : JSON.generate(compact(body))
          response = @http.request(verb, uri, headers: headers, body: payload)
          parse(verb, path, response)
        rescue JSON::ParserError => e
          raise AdapterError.new("Fluxer returned unparseable JSON from #{verb.upcase} #{path}: #{e.message}",
                                 adapter: :fluxer, retryable: true)
        rescue URI::Error => e
          raise AdapterError.new("Fluxer request URL was invalid: #{e.message}", adapter: :fluxer, retryable: false)
        end

        # Like #request, but +body+ goes to the wire exactly as given: no key
        # dropped for being nil.
        def patch_literal(path, body)
          uri = URI.parse("#{@api_base}#{path}")
          response = @http.request(:patch, uri, headers: headers, body: JSON.generate(body))
          parse(:patch, path, response)
        rescue URI::Error => e
          raise AdapterError.new("Fluxer request URL was invalid: #{e.message}", adapter: :fluxer, retryable: false)
        end

        # A multipart POST: +files+ is {filename:, mime_type:, io:} in send
        # order, riding alongside +body+ the same way Discord's webhook upload
        # does, as a payload_json part plus one files[N] part per file.
        def post_multipart(path, body, files)
          uri = URI.parse("#{@api_base}#{path}")
          boundary = SecureRandom.hex(16)
          payload = multipart_body(boundary, compact(body), files)
          response = @http.request(:post, uri, headers: multipart_headers(boundary), body: payload)
          parse(:post, path, response)
        rescue URI::Error => e
          raise AdapterError.new("Fluxer request URL was invalid: #{e.message}", adapter: :fluxer, retryable: false)
        end

        def multipart_headers(boundary)
          headers.merge("content-type" => "multipart/form-data; boundary=#{boundary}")
        end

        def multipart_body(boundary, json_body, files)
          body = "".b
          body << multipart_field(boundary, "payload_json", JSON.generate(json_body))
          files.each_with_index { |file, index| body << multipart_file(boundary, "files[#{index}]", file) }
          body << "--#{boundary}--\r\n"
          body
        end

        def multipart_field(boundary, name, value)
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n".b
        end

        def multipart_file(boundary, field, file)
          name = file[:filename].to_s.gsub('"', "'")
          type = file[:mime_type] || "application/octet-stream"
          header = "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{field}\"; filename=\"#{name}\"\r\n" \
                   "Content-Type: #{type}\r\n\r\n".b
          header << file[:io].read.to_s.b << "\r\n".b
        end

        def headers
          {
            "authorization" => "Bot #{@token}",
            "content-type" => "application/json",
            "accept" => "application/json"
          }
        end

        def parse(verb, path, response)
          code = response.code.to_i
          raw = response.body.to_s

          return nil if raw.strip.empty? && code.between?(200, 299)
          return JSON.parse(raw) if code.between?(200, 299)

          detail = describe_error(raw)
          case code
          when 429
            raise RateLimitedError.new("Fluxer rate limited #{verb.upcase} #{path}: #{detail}",
                                       adapter: :fluxer, retry_after: retry_after_of(raw))
          when 401, 403
            raise PermissionError.new("Fluxer refused #{verb.upcase} #{path} (#{code}): #{detail}", adapter: :fluxer)
          else
            raise AdapterError.new("Fluxer #{verb.upcase} #{path} failed (#{code}): #{detail}",
                                   adapter: :fluxer, retryable: code >= 500)
          end
        end

        # Discord shaped error bodies carry a `message` and a numeric `code`.
        def describe_error(raw)
          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? (parsed["message"] || parsed["code"] || parsed.to_s) : raw
        rescue JSON::ParserError
          raw.empty? ? "no body" : raw
        end

        def retry_after_of(raw)
          parsed = JSON.parse(raw)
          # Discord reports retry_after in seconds (a float); round up.
          value = parsed.is_a?(Hash) ? parsed["retry_after"] : nil
          value&.to_f&.ceil
        rescue JSON::ParserError
          nil
        end

        def compact(params)
          params.each_with_object({}) do |(key, value), out|
            next if value.nil?

            out[key] = value
          end
        end

        def escape(value) = URI.encode_www_form_component(value.to_s)
      end

      # The default HTTP layer, one method wide so a fake or a pool is a one line
      # swap.
      class HttpTransport
        VERBS = {
          get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch,
          put: Net::HTTP::Put, delete: Net::HTTP::Delete
        }.freeze

        def initialize(timeout: 60)
          @timeout = timeout
        end

        def request(verb, uri, headers: {}, body: nil)
          klass = VERBS.fetch(verb)
          req = klass.new(uri)
          headers.each { |name, value| req[name] = value }
          req.body = body if body

          Net::HTTP.start(uri.hostname, uri.port,
                          use_ssl: uri.scheme == "https",
                          open_timeout: 10, read_timeout: @timeout) do |http|
            http.request(req)
          end
        rescue Net::OpenTimeout, Net::ReadTimeout => e
          raise AdapterError.new("Fluxer request timed out: #{e.class}", adapter: :fluxer, retryable: true)
        rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
          raise AdapterError.new("Fluxer request failed: #{e.class}: #{e.message}",
                                 adapter: :fluxer, retryable: true)
        end
      end
    end
  end
end
