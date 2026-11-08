# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "securerandom"

module Rubotty
  module Adapters
    module Matrix
      # Minimal Matrix client-server API client built on Net::HTTP, the only
      # file here that speaks HTTP (the layer is injectable so the sync loop
      # runs against a double). Auth is an access token sent as
      # `Authorization: Bearer <token>` on every request, never placed in a
      # URL or a log line.
      class Client
        # A safe, widely supported client-server API version prefix.
        API = "/_matrix/client/v3"
        MEDIA = "/_matrix/media/v3"
        # The relations family (backfilling reactions) never shipped under v3;
        # it is v1 only.
        RELATIONS_API = "/_matrix/client/v1"

        def initialize(access_token:, homeserver:, http: nil, logger: nil, timeout: 60)
          @access_token = access_token
          @homeserver = homeserver.to_s.chomp("/")
          @http = http || HttpTransport.new(timeout: timeout)
          @logger = logger
        end

        attr_reader :logger, :homeserver

        # The user id this access token belongs to, "@bot:example.org". Loop
        # prevention depends on it: an event sent by this id is one we sent.
        def whoami
          me = get("#{API}/account/whoami")
          me && me["user_id"]
        end

        # Long poll for new events. Returns the raw sync response, whose
        # `next_batch` is the cursor for the following call.
        def sync(since: nil, timeout_ms: 30_000, full_state: false)
          query = { timeout: timeout_ms, full_state: full_state }
          query[:since] = since if since
          get("#{API}/sync", query: query)
        end

        # Send a room event, returning its event id. The transaction id makes the
        # send idempotent: the server de duplicates a retry with the same id.
        def send_event(room_id, type, content, txn_id: new_txn)
          result = put("#{API}/rooms/#{escape(room_id)}/send/#{escape(type)}/#{escape(txn_id)}", content)
          result && result["event_id"]
        end

        # Redact (remove) an event. This is how a delete and a reaction removal
        # are both expressed on Matrix.
        def redact(room_id, event_id, reason: nil, txn_id: new_txn)
          body = reason ? { reason: reason } : {}
          result = put("#{API}/rooms/#{escape(room_id)}/redact/#{escape(event_id)}/#{escape(txn_id)}", body)
          result && result["event_id"]
        end

        # Accept an invite (or join a public room), returning the room id
        # actually joined, which can differ from an alias passed in.
        def join_room(room_id_or_alias)
          result = post("#{API}/join/#{escape(room_id_or_alias)}", {})
          result && result["room_id"]
        end

        # A fresh two member room, flagged as direct: Matrix's own shape for a DM.
        def create_room(invite:)
          result = post("#{API}/createRoom", { invite: [invite], is_direct: true, preset: "trusted_private_chat" })
          result && result["room_id"]
        end

        # The room already shared with +user_id+ for a direct chat, read off this
        # account's own m.direct bookkeeping, the same account_data every Matrix
        # client checks before opening a second DM with the same person. nil on a
        # first contact, or when the read fails for any reason: the worst case is
        # a spare room, not a broken send.
        def direct_room_for(my_id, user_id)
          data = get("#{API}/user/#{escape(my_id)}/account_data/m.direct")
          Array(data[user_id]).first
        rescue AdapterError
          nil
        end

        # Fold +room_id+ into m.direct as the direct chat with +user_id+, so a
        # later #direct_room_for finds it instead of a new room being created.
        def remember_direct_room(my_id, user_id, room_id)
          data = begin
            get("#{API}/user/#{escape(my_id)}/account_data/m.direct")
          rescue AdapterError
            {}
          end
          data[user_id] = (Array(data[user_id]) + [room_id]).uniq
          put("#{API}/user/#{escape(my_id)}/account_data/m.direct", data)
        end

        # Leave a room. Also how a pending invite is declined: Matrix answers
        # this the same way whether we were joined or only invited.
        def leave_room(room_id)
          post("#{API}/rooms/#{escape(room_id)}/leave", {})
        end

        # A rate limit is let through rather than swallowed here: the caller
        # (Adapter#resolve_displayname) caches this answer, and caching a rate
        # limit as "no display name" would turn one transient 429 into a wrong
        # name for the life of the process.
        def displayname(user_id)
          result = get("#{API}/profile/#{escape(user_id)}/displayname")
          result && result["displayname"]
        rescue RateLimitedError
          raise
        rescue AdapterError
          nil
        end

        # Every room this account is currently JOINED to, the bulk enumeration
        # source for discovery. Always an array, never nil.
        def joined_rooms
          result = get("#{API}/joined_rooms")
          Array(result && result["joined_rooms"])
        end

        # The room's published name (m.room.name), or nil when it has none: an
        # unnamed room answers 404 for this state key, which reads as "no name"
        # rather than an error.
        def room_name(room_id)
          result = get("#{API}/rooms/#{escape(room_id)}/state/m.room.name")
          result && result["name"]
        rescue AdapterError
          nil
        end

        # The room's published canonical alias, or nil when none is set. Same
        # 404-as-absent handling as #room_name, and the fallback label for a room
        # carrying no m.room.name.
        def room_canonical_alias(room_id)
          result = get("#{API}/rooms/#{escape(room_id)}/state/m.room.canonical_alias")
          result && result["alias"]
        rescue AdapterError
          nil
        end

        def kick(room_id, user_id, reason: nil)
          post("#{API}/rooms/#{escape(room_id)}/kick", { user_id: user_id, reason: reason }.compact)
        end

        def ban(room_id, user_id, reason: nil)
          post("#{API}/rooms/#{escape(room_id)}/ban", { user_id: user_id, reason: reason }.compact)
        end

        def unban(room_id, user_id)
          post("#{API}/rooms/#{escape(room_id)}/unban", { user_id: user_id })
        end

        # Turn an mxc:// URI into an HTTP download URL on this homeserver. The
        # download route carries no credential, so it is safe to relay to another
        # platform.
        def media_http_url(mxc)
          return nil unless mxc.is_a?(String) && mxc.start_with?("mxc://")

          server, media_id = mxc.delete_prefix("mxc://").split("/", 2)
          return nil if server.nil? || media_id.nil? || media_id.empty?

          "#{@homeserver}#{MEDIA}/download/#{escape(server)}/#{escape(media_id)}"
        end

        # Push bytes into the homeserver's own content repository, the write
        # half #media_http_url has no counterpart for. Returns the mxc:// URI
        # to reference from a message's content, or nil on a refusal.
        def upload(bytes, filename: nil, content_type: nil)
          query = {}
          query[:filename] = filename unless filename.to_s.strip.empty?
          uri = URI.parse("#{@homeserver}#{MEDIA}/upload")
          uri.query = URI.encode_www_form(query) unless query.empty?
          response = @http.request(:post, uri, headers: upload_headers(content_type), body: bytes)
          result = parse(:post, "#{MEDIA}/upload", response)
          result && result["content_uri"]
        rescue URI::Error => e
          raise AdapterError.new("Matrix request URL was invalid: #{e.message}", adapter: :matrix, retryable: false)
        end

        # One page of a room's history, walking backward (or forward) from a
        # pagination token. Passing no +from+ IS the cursor-acquisition step: a
        # homeserver with none resolves that to the live end of the room, which
        # is exactly where a backfill sweep's backward walk needs to start.
        #
        # @return [Array(Array<Hash>, String)] the raw events in +dir+ order,
        #   and the token to pass as +from+ for the next page (nil once the
        #   room has nothing older left).
        def messages(room_id, from: nil, dir: "b", limit: 100)
          query = { dir: dir, limit: limit }
          query[:from] = from if from
          result = get("#{API}/rooms/#{escape(room_id)}/messages", query: query)
          return [[], nil] if result.nil?

          [Array(result["chunk"]), result["end"]]
        end

        # The reactions on one event: one page of the m.annotation relations to
        # +event_id+, newest first. A single message's reaction count never
        # approaches the page size a backfill sweep asks for, so unlike
        # #messages this reads only one page.
        def relations(room_id, event_id, rel_type: "m.annotation", limit: 100)
          path = "#{RELATIONS_API}/rooms/#{escape(room_id)}/relations/#{escape(event_id)}/#{escape(rel_type)}"
          result = get(path, query: { limit: limit })
          result ? Array(result["chunk"]) : []
        end

        def new_txn = "rubotty-#{SecureRandom.hex(8)}"

        private

        def upload_headers(content_type)
          {
            "authorization" => "Bearer #{@access_token}",
            "content-type" => content_type.to_s.strip.empty? ? "application/octet-stream" : content_type,
            "accept" => "application/json"
          }
        end

        def get(path, query: {}) = request(:get, path, query: query)

        def post(path, body) = request(:post, path, body: body)

        def put(path, body) = request(:put, path, body: body)

        def request(verb, path, query: {}, body: nil)
          uri = URI.parse("#{@homeserver}#{path}")
          uri.query = URI.encode_www_form(query) unless query.nil? || query.empty?
          payload = body.nil? ? nil : JSON.generate(compact(body))
          response = @http.request(verb, uri, headers: headers, body: payload)
          parse(verb, path, response)
        rescue JSON::ParserError => e
          raise AdapterError.new("Matrix returned unparseable JSON from #{verb.upcase} #{path}: #{e.message}",
                                 adapter: :matrix, retryable: true)
        rescue URI::Error => e
          raise AdapterError.new("Matrix request URL was invalid: #{e.message}", adapter: :matrix, retryable: false)
        end

        def headers
          {
            "authorization" => "Bearer #{@access_token}",
            "content-type" => "application/json",
            "accept" => "application/json"
          }
        end

        def parse(verb, path, response)
          code = response.code.to_i
          raw = response.body.to_s

          return {} if raw.strip.empty? && code.between?(200, 299)
          return JSON.parse(raw) if code.between?(200, 299)

          errcode, detail = error_of(raw)
          case code
          when 429
            raise RateLimitedError.new("Matrix rate limited #{verb.upcase} #{path}: #{detail}",
                                       adapter: :matrix, retry_after: retry_after_of(raw))
          when 401, 403
            raise PermissionError.new("Matrix refused #{verb.upcase} #{path} (#{errcode}): #{detail}", adapter: :matrix)
          else
            raise AdapterError.new("Matrix #{verb.upcase} #{path} failed (#{code} #{errcode}): #{detail}",
                                   adapter: :matrix, retryable: code >= 500)
          end
        end

        # Matrix errors are {"errcode":"M_...","error":"..."}.
        def error_of(raw)
          parsed = JSON.parse(raw)
          return [parsed["errcode"], parsed["error"] || parsed["errcode"]] if parsed.is_a?(Hash)

          [nil, raw]
        rescue JSON::ParserError
          [nil, raw.empty? ? "no body" : raw]
        end

        def retry_after_of(raw)
          parsed = JSON.parse(raw)
          ms = parsed.is_a?(Hash) ? parsed["retry_after_ms"] : nil
          ms && (ms.to_f / 1000.0).ceil
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
        VERBS = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.freeze

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
          raise AdapterError.new("Matrix request timed out: #{e.class}", adapter: :matrix, retryable: true)
        rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError => e
          raise AdapterError.new("Matrix request failed: #{e.class}: #{e.message}",
                                 adapter: :matrix, retryable: true)
        end
      end
    end
  end
end
