# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"

module Rubotty
  module Adapters
    module Stoat
      # Minimal Stoat (formerly Revolt) REST client built on Net::HTTP. The
      # ONLY file that speaks HTTP, so the rest of the adapter is exercised
      # against a double with no network. Auth is a single bot token sent as
      # the `x-bot-token` header; it never goes into a URL or a log line.
      class Client
        # The hosted Stoat instance. Overridable for a self hosted deployment.
        DEFAULT_API_BASE = "https://api.stoat.chat"
        # Where user uploaded files are served from, and where one is uploaded to.
        DEFAULT_CDN_BASE = "https://cdn.stoatusercontent.com"
        # The hosted service's cap on one "attachments" tagged upload.
        DEFAULT_UPLOAD_BYTES = 20 * 1024 * 1024

        def initialize(token:, api_base: DEFAULT_API_BASE, cdn_base: DEFAULT_CDN_BASE,
                       http: nil, logger: nil, timeout: 60)
          @token = token
          @api_base = api_base.to_s.chomp("/")
          @cdn_base = cdn_base.to_s.chomp("/")
          @http = http || HttpTransport.new(timeout: timeout)
          @logger = logger
        end

        attr_reader :logger, :api_base, :cdn_base, :token

        # The account we are signed in as. Loop prevention depends on it: a relayed
        # masquerade message is still AUTHORED by this account, so the loop guard
        # recognises our own echoes by this id.
        def own_id
          me = get("/users/@me")
          id = me && me["_id"]
          id&.to_s
        end

        # Best effort lookup of a user, so an inbound author id can be turned into
        # a name. A user the bot cannot see returns nil rather than raising.
        def fetch_user(id)
          return nil if id.nil?

          get("/users/#{escape(id)}")
        rescue AdapterError
          nil
        end

        # Best effort lookup of one server member, which is where Stoat keeps a
        # per server nickname. Answers the Member object; a member the bot cannot
        # see returns nil rather than raising.
        def fetch_member(server_id, user_id)
          return nil if server_id.nil? || user_id.nil?

          body = get("/servers/#{escape(server_id)}/members/#{escape(user_id)}")
          return nil unless body.is_a?(Hash)

          # Asking for roles answers {"member": ..., "roles": ...}; without it the
          # Member object is the whole body.
          member = body["member"]
          member.is_a?(Hash) ? member : body
        rescue AdapterError
          nil
        end

        # Best effort channel lookup for discovery: a ServerCreate event names its
        # channels only by id, so this fills in the name and type. Returns nil for
        # a channel the bot can no longer see.
        def fetch_channel(id)
          return nil if id.nil?

          get("/channels/#{escape(id)}")
        rescue AdapterError
          nil
        end

        # @param body [Hash] content, replies, masquerade, attachments, nonce
        # @return [Hash] the created Message object
        def send_message(channel_id, body)
          post("/channels/#{escape(channel_id)}/messages", body)
        end

        # Open (or reopen; Revolt's endpoint is idempotent) the DM channel
        # with one user, so #send_message can post to it.
        # @return [Hash] the channel object
        def open_dm(user_id)
          post("/users/#{escape(user_id)}/dm", {})
        end

        def edit_message(channel_id, message_id, body)
          patch("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}", body)
        end

        def delete_message(channel_id, message_id)
          delete("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}")
        end

        # Stoat identifies a reaction by a unicode emoji or a custom emoji id, in
        # the path, and the bot's own reaction is added and removed one at a time.
        def add_reaction(channel_id, message_id, emoji)
          put("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}/reactions/#{escape(emoji)}")
        end

        def remove_own_reaction(channel_id, message_id, emoji)
          delete("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}/reactions/#{escape(emoji)}")
        end

        def ban_member(server_id, user_id, reason: nil)
          put("/servers/#{escape(server_id)}/bans/#{escape(user_id)}", { reason: reason }.compact)
        end

        def unban_member(server_id, user_id)
          delete("/servers/#{escape(server_id)}/bans/#{escape(user_id)}")
        end

        # Stoat has no distinct kick: removing a member lets them rejoin, which is
        # exactly a kick.
        def kick_member(server_id, user_id)
          delete("/servers/#{escape(server_id)}/members/#{escape(user_id)}")
        end

        def pin_message(channel_id, message_id)
          post("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}/pin", nil)
        end

        def unpin_message(channel_id, message_id)
          delete("/channels/#{escape(channel_id)}/messages/#{escape(message_id)}/pin")
        end

        # Time out a member until +until_time+ (an ISO 8601 string).
        def timeout_member(server_id, user_id, until_time)
          patch("/servers/#{escape(server_id)}/members/#{escape(user_id)}", { timeout: until_time })
        end

        # Lift a timeout. Stoat rejects an explicit null, so clearing one goes
        # through `remove` rather than `timeout: nil`.
        def clear_timeout(server_id, user_id)
          patch("/servers/#{escape(server_id)}/members/#{escape(user_id)}", { remove: ["Timeout"] })
        end

        # Upload +io+'s bytes under the "attachments" tag and return the file id
        # +send_message+'s `attachments` field takes, or nil when Stoat refused.
        def upload_file(io, filename:, content_type: "application/octet-stream")
          uri = URI.parse("#{@cdn_base}/attachments")
          boundary = "rubotty-#{SecureRandom.hex(16)}"
          response = @http.request(:post, uri, headers: upload_headers(boundary),
                                              body: multipart_body(boundary, io, filename, content_type))
          body = parse(:post, "/attachments", response)
          body.is_a?(Hash) ? body["id"] : nil
        rescue JSON::ParserError => e
          raise AdapterError.new("Stoat upload returned unparseable JSON: #{e.message}",
                                 adapter: :stoat, retryable: true)
        end

        # Turn an inbound file object into a downloadable CDN URL; these
        # carry no credential, so they are safe to relay to another
        # platform. The filename is whatever the uploader originally called
        # it, unconstrained free text that can hold a space or other
        # character a URL path cannot, so every segment is escaped the same
        # way a REST path parameter is.
        def file_url(file)
          return nil unless file.is_a?(Hash)

          id = file["_id"] || file["id"]
          return nil if id.nil?

          tag = file["tag"] || "attachments"
          filename = file["filename"] || id
          "#{@cdn_base}/#{escape_segment(tag)}/#{escape_segment(id)}/#{escape_segment(filename)}"
        end

        private

        def get(path) = request(:get, path)

        def post(path, body) = request(:post, path, body)

        def patch(path, body) = request(:patch, path, body)

        def put(path, body = nil) = request(:put, path, body)

        def delete(path) = request(:delete, path)

        def request(verb, path, body = nil)
          uri = URI.parse("#{@api_base}#{path}")
          payload = body.nil? ? nil : JSON.generate(compact(body))
          response = @http.request(verb, uri, headers: headers, body: payload)
          parse(verb, path, response)
        rescue JSON::ParserError => e
          raise AdapterError.new("Stoat returned unparseable JSON from #{verb.upcase} #{path}: #{e.message}",
                                 adapter: :stoat, retryable: true)
        rescue URI::Error => e
          raise AdapterError.new("Stoat request URL was invalid: #{e.message}", adapter: :stoat, retryable: false)
        end

        def headers
          {
            "x-bot-token" => @token.to_s,
            "content-type" => "application/json",
            "accept" => "application/json"
          }
        end

        def upload_headers(boundary)
          {
            "x-bot-token" => @token.to_s,
            "content-type" => "multipart/form-data; boundary=#{boundary}",
            "accept" => "application/json"
          }
        end

        # A single-part "file" upload body, built by hand since the transport
        # seam takes a plain body string rather than a live request object.
        def multipart_body(boundary, io, filename, content_type)
          data = io.respond_to?(:read) ? io.read : io.to_s
          body = +"--#{boundary}\r\n"
          body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{multipart_filename(filename)}\"\r\n"
          body << "Content-Type: #{content_type}\r\n\r\n"
          body.force_encoding(Encoding::BINARY)
          body << data.b << "\r\n--#{boundary}--\r\n".b
        end

        # Quoted and CRLF free, so a hostile filename cannot break out of the
        # header line it sits in.
        def multipart_filename(filename)
          filename.to_s.gsub(/["\r\n]/, "")
        end

        # Stoat answers 2xx with either a JSON body or an empty one. A 4xx or 5xx
        # becomes the error vocabulary every other adapter uses, so the router's
        # retry and logging policy is uniform across platforms.
        def parse(verb, path, response)
          code = response.code.to_i
          raw = response.body.to_s

          return nil if raw.strip.empty? && code.between?(200, 299)

          if code.between?(200, 299)
            return JSON.parse(raw)
          end

          detail = describe_error(raw)
          case code
          when 429
            retry_after = retry_after_of(raw)
            raise RateLimitedError.new("Stoat rate limited #{verb.upcase} #{path}: #{detail}",
                                       adapter: :stoat, retry_after: retry_after)
          when 401, 403
            raise PermissionError.new("Stoat refused #{verb.upcase} #{path} (#{code}): #{detail}", adapter: :stoat)
          else
            raise AdapterError.new(
              "Stoat #{verb.upcase} #{path} failed (#{code}): #{detail}",
              adapter: :stoat, retryable: code >= 500
            )
          end
        end

        # Stoat error bodies are a small JSON object, for example
        # {"type":"NotFound"}; a missing permission names it too, for example
        # {"type":"MissingPermission","permission":"SendMessage"}, which the
        # caller needs to tell one missing permission apart from another.
        # Falls back to the raw body when shaped differently.
        def describe_error(raw)
          parsed = JSON.parse(raw)
          return raw unless parsed.is_a?(Hash)

          type = parsed["type"] || parsed.to_s
          parsed["permission"] ? "#{type} (#{parsed["permission"]})" : type
        rescue JSON::ParserError
          raw.empty? ? "no body" : raw
        end

        def retry_after_of(raw)
          parsed = JSON.parse(raw)
          value = parsed.is_a?(Hash) ? (parsed["retry_after"] || parsed["retryAfter"]) : nil
          # Stoat reports the wait in milliseconds; the router thinks in seconds.
          value && (value.to_f / 1000.0).ceil
        rescue JSON::ParserError
          nil
        end

        # Stoat rejects explicit nulls on optional fields, so they are stripped.
        def compact(params)
          params.each_with_object({}) do |(key, value), out|
            next if value.nil?

            out[key] = value
          end
        end

        def escape(value) = URI.encode_www_form_component(value.to_s)

        # A path segment, where a space is %20. escape spells one "+", which a
        # query string reads back as a space and a CDN path does not, so a file
        # called "holiday photo.png" would be fetched under a name nothing has.
        def escape_segment(value) = URI::DEFAULT_PARSER.escape(value.to_s, %r{[^A-Za-z0-9\-_.~]})
      end

      # The default HTTP layer. One method, so a test double or a keep alive pool
      # is a one line swap.
      class HttpTransport
        VERBS = {
          get: Net::HTTP::Get, post: Net::HTTP::Post, patch: Net::HTTP::Patch,
          put: Net::HTTP::Put, delete: Net::HTTP::Delete
        }.freeze

        def initialize(timeout: 60)
          @timeout = timeout
        end

        # @return [#code, #body] anything responding to code and body
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
          raise AdapterError.new("Stoat request timed out: #{e.class}", adapter: :stoat, retryable: true)
        rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
          raise AdapterError.new("Stoat request failed: #{e.class}: #{e.message}",
                                 adapter: :stoat, retryable: true)
        end
      end
    end
  end
end
