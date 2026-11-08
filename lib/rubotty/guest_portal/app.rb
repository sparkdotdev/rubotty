# frozen_string_literal: true

require "sinatra/base"
require "json"
require_relative "request_guard"

module Rubotty
  # The room-scoped guest portal web surface, gated by an invite token in the URL:
  # the link is the whole credential. Expiry, revocation, room scope and the hashed
  # token live in {ControlPlane::GuestInvites}, the cursor in {ControlPlane::GuestFeed}.
  module GuestPortal
    class App < Sinatra::Base
      # The longest guest message accepted, so one huge post cannot flood a room.
      MAX_BODY = 4_000

      # The largest guest upload accepted: 8 MiB sits under every bridged platform's
      # own ceiling, deliberately, not merely never revisited. A guest upload is
      # handed to the bridge as an ordinary URL attachment and has to clear every
      # bridged target as a real upload, unlike {ControlPlane::RehostedFiles}'s much
      # larger cap for a file no platform will carry at all; {ControlPlane::GuestRetention}
      # also ties this bucket to invite expiry rather than a year, so it needs no
      # quota of its own. Enforced by Storage::ObjectStore mid-stream, so no
      # declared length is trusted.
      MAX_UPLOAD_BYTES = 8 * 1024 * 1024

      # Room for the multipart envelope around a file at the cap: boundaries, part
      # headers and the caption field.
      UPLOAD_ENVELOPE_BYTES = 64 * 1024

      # Covers a 4,000-character message even at worst-case UTF-8 URL encoding.
      TEXT_BODY_BYTES = 64 * 1024

      # Compatibility reference for the former default batch ceiling. The live
      # request guard derives its budget from the authenticated ticket's policy.
      MAX_TICKET_BATCH_BODY_BYTES = ControlPlane::RehostedFiles::DEFAULT_MAX_BATCH_FILES *
                                    (ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES + UPLOAD_ENVELOPE_BYTES)

      # Seconds between server-sent-events feed passes, matching the guest adapter's poll.
      SSE_INTERVAL = 1

      # How long one SSE connection lives before it closes and the client opens a
      # fresh one from its Last-Event-ID. Unbounded means a thread and two queries
      # a second per open tab, against a connection pool of four.
      DEFAULT_SSE_MAX_PASSES = 1800

      # Streams one invite may hold at once. A browser needs one, and a second
      # briefly while a tab reloads.
      MAX_STREAMS_PER_INVITE = 3

      # Up to this size an object is read twice, once to check its authentication
      # tag and once to serve it, so the 200 means something. Every guest upload
      # is under this; a large rehosted file is not.
      VERIFY_BEFORE_SERVE_BYTES = MAX_UPLOAD_BYTES

      # Build a configured app over a set of dependencies.
      #
      # @param deps [Deps]
      # @param env [Hash]
      # @return [Class] a ready-to-serve Sinatra app subclass
      def self.assemble(deps:, env: ENV)
        marker = Object.new
        Class.new(self) do
          set :deps, deps
          set :portal_env, env
          set :request_guard_marker, marker
          use RequestGuard, deps: deps, marker: marker, text_limit: TEXT_BODY_BYTES,
                            upload_limit: MAX_UPLOAD_BYTES + UPLOAD_ENVELOPE_BYTES,
                            envelope_bytes: UPLOAD_ENVELOPE_BYTES
          use Util::BodyLimit, max: ->(request_env) { request_env.fetch(RequestGuard::LIMIT_KEY, TEXT_BODY_BYTES) }
        end
      end

      # One per assembled app, counting the SSE streams each invite holds open.
      def self.stream_limiter
        @stream_limiter ||= StreamLimiter.new(max: MAX_STREAMS_PER_INVITE)
      end

      set :views, File.expand_path("guest_portal/views", File.expand_path("..", __dir__))
      # Stdlib ERB does not auto-escape, so every view escapes dynamic values with `h`.
      set :erb, escape_html: false
      disable :show_exceptions
      enable :raise_errors
      disable :dump_errors
      # No cookie at all: the token in the URL is the entire credential and join
      # state lives in the invite row, which removes the CSRF surface.
      disable :sessions
      # The reverse proxy is the trust boundary, so Sinatra's Host whitelist is off.
      # Every route is still gated by the invite token.
      set :host_authorization, permitted_hosts: []

      before do
        denial = request.env[RequestGuard::DENIAL_KEY]
        next unless denial.is_a?(Hash) && denial[:marker].equal?(settings.request_guard_marker)

        halt 404 if denial[:reason] == :not_found
        halt upload_ended_page
      end

      # Sent with every route that returns bytes somebody else supplied. sandbox
      # puts the response in an opaque origin, so even a client that renders it
      # anyway reaches neither the dashboard's cookie nor its DOM.
      SERVED_BYTES_HEADERS = {
        "Content-Security-Policy" => "default-src 'none'; sandbox",
        "X-Content-Type-Options" => "nosniff"
      }.freeze

      get "/healthz" do
        content_type "text/plain"
        "ok\n"
      end

      # A bare landing page that reveals nothing, for someone with no invite link.
      get "/" do
        erb :landing, layout: :layout
      end

      # The chat window. Validates the token, pins the join cursor on first open
      # (so the backlog is never shown), and renders the minimal chat UI.
      get "/g/:token" do
        invite = live_invite
        return ended_page if invite.nil?

        join!(invite)
        @invite = invite
        @room_label = room_label(invite)
        @cursor = invite.join_cursor.to_i
        @expires_at = invite.expires_at
        # Expiry plus the capped grace, the same formula
        # ControlPlane::GuestRetention#reclaim_at schedules the real reclamation on.
        @retained_until = invite.expires_at + deps.retention_grace
        erb :chat, layout: :layout
      end

      # Poll for new messages since a cursor. Only rows above the join cursor, so
      # no history before join is served, and only rows in the invite's own room.
      get "/g/:token/messages.json" do
        content_type :json
        invite = live_invite
        return JSON.generate(ended: true) if invite.nil?

        entries = deps.feed.for_guest(invite: invite, since: params[:since].to_i)
        JSON.generate(
          ended: false,
          expires_at: invite.expires_at.to_s,
          cursor: entries.empty? ? [params[:since].to_i, invite.join_cursor.to_i].max : entries.last.id,
          messages: entries.map { |entry| present(entry, invite) }
        )
      end

      # Send a message as the guest. Rate limited per invite; plain text only;
      # recorded as a pending send the bot's relay fans out to every platform.
      post "/g/:token/messages" do
        content_type :json
        invite = live_invite
        if invite.nil?
          status 410
          return JSON.generate(ended: true, error: "This guest session has ended.")
        end

        body = params[:body].to_s.strip
        if body.empty?
          status 422
          return JSON.generate(error: "A message cannot be empty.")
        end
        if body.length > MAX_BODY
          status 422
          return JSON.generate(error: "That message is too long.")
        end

        unless deps.rate_limiter.allow?(invite)
          status 429
          headers "Retry-After" => deps.rate_limiter.retry_after.to_s
          return JSON.generate(error: "You are sending messages too quickly. Please slow down.")
        end

        row = deps.feed.record_out(invite: invite, body: body)
        status 201
        JSON.generate(ok: true, id: row.id)
      end

      # Server-sent events over the same feed the poll reads. The client falls back
      # to messages.json if this will not open or the stream drops.
      get "/g/:token/stream" do
        content_type "text/event-stream"
        headers "Cache-Control" => "no-cache", "X-Accel-Buffering" => "no"

        invite = live_invite
        return sse_event(ended: true) if invite.nil?

        since = params[:since] || request.env["HTTP_LAST_EVENT_ID"]
        cursor = [since.to_i, invite.join_cursor.to_i].max
        max_passes = sse_max_passes
        expires_at = invite.expires_at
        invite_id = invite.id
        stream(:keep_open) do |out|
          # A guest holding their share of this process's threads is told to poll
          # instead, which the client already knows how to do.
          held = stream_limiter.hold(invite_id) do
            out << sse_event(id: cursor, ended: false, expires_at: expires_at.to_s, cursor: cursor, messages: [])
            cursor = pump_stream(out, cursor: cursor, max_passes: max_passes)
          end
          out << sse_event(ended: false, cursor: cursor, messages: [], poll: true) if held.nil?
          out.close
        end
      end

      # Upload a file as the guest: rate limited like a text send, size capped, and
      # stored so the portal can serve it back at an unguessable URL.
      post "/g/:token/upload" do
        content_type :json
        invite = live_invite
        if invite.nil?
          status 410
          return JSON.generate(ended: true, error: "This guest session has ended.")
        end

        # No object store means nowhere to put the file; the chat is unaffected.
        if deps.uploads.nil?
          status 503
          return JSON.generate(error: "Uploads are unavailable right now. Your messages still work.")
        end

        # The relayed URL is fetched by every adapter and carries the object's
        # decryption key, so an unset GUEST_PORTAL_URL refuses the upload rather
        # than minting a link off whatever Host this request arrived with.
        if public_base.empty?
          deps.logger&.warn { "refused a guest upload: GUEST_PORTAL_URL is not set to an http(s) base" }
          status 503
          return JSON.generate(error: "Uploads are unavailable right now. Your messages still work.")
        end

        file = params[:file]
        unless file.is_a?(Hash) && file[:tempfile]
          status 422
          return JSON.generate(error: "No file was uploaded.")
        end

        source = file[:tempfile]
        # Only the empty case is decided on this length. The size cap is the store's.
        if source.size.to_i.zero?
          status 422
          return JSON.generate(error: "That file is empty.")
        end

        caption = params[:body].to_s.strip
        if caption.length > MAX_BODY
          status 422
          return JSON.generate(error: "That caption is too long.")
        end

        unless deps.rate_limiter.allow?(invite)
          status 429
          headers "Retry-After" => deps.rate_limiter.retry_after.to_s
          return JSON.generate(error: "You are sending messages too quickly. Please slow down.")
        end

        begin
          stored = deps.uploads.store_file(
            invite: invite, source: source, filename: file[:filename],
            content_type: file[:type], limit: MAX_UPLOAD_BYTES
          )
        rescue Rubotty::Storage::ObjectStore::TooLarge
          status 413
          return JSON.generate(error: "That file is too large.")
        rescue Rubotty::Storage::ObjectStore::Error => e
          deps.logger&.warn { "a guest upload could not be stored: #{e.message}" }
          status 503
          return JSON.generate(error: "That file could not be stored. Please try again.")
        end

        descriptor = {
          "kind" => attachment_kind_for(stored.content_type),
          "url" => upload_url(stored.secret),
          "filename" => stored.filename,
          "mime_type" => stored.content_type
        }
        row = deps.feed.record_out(invite: invite, body: caption, attachments: [descriptor])
        status 201
        JSON.generate(ok: true, id: row.id)
      end

      # Serve a guest-uploaded file's bytes. No invite token: the secret in the path
      # is the whole capability, because the target adapters fetch this URL and
      # cannot present one. Streamed and unsealed as it goes.
      get "/uploads/:token" do
        halt 404 if deps.uploads.nil?

        row = deps.uploads.fetch(secret: params[:token])
        halt 404 if row.nil?
        halt 500, unreadable_body unless verified?(row) { deps.uploads.intact?(row, secret: params[:token]) }

        content_type Security::ServedTypes.allowed(row.content_type)
        disposition = Security::ServedTypes.disposition(row.content_type)
        headers "Content-Disposition" => %(#{disposition}; filename="#{header_filename(row.filename)}"),
                "Content-Length" => row.byte_size.to_s,
                "Cache-Control" => "private, max-age=300",
                **SERVED_BYTES_HEADERS
        secret = params[:token]
        stream do |out|
          deps.uploads.stream(row, secret: secret) { |chunk| out << chunk }
        rescue Rubotty::Storage::ObjectStore::Unreadable => e
          # Status and headers are already sent, so ending short is the only signal left.
          deps.logger&.warn { "a guest upload could not be served: #{e.message}" }
        end
      end

      # The upload form a /upload ticket names. Shows nothing about the community
      # or room, so a leaked link reveals no topology.
      get "/u/:token" do
        halt 404 if deps.upload_tickets.nil?

        ticket = deps.upload_tickets.authenticate(token: params[:token])
        return upload_ended_page if ticket.nil?

        @token = params[:token]
        @expires_at = ticket.expires_at
        policy = upload_policy(ticket)
        @max_bytes = policy[:max_bytes]
        @max_batch_files = policy[:max_batch_files]
        @max_batch_bytes = policy[:max_batch_bytes]
        erb :upload, layout: :layout
      end

      # Accept the whole selection as one batch. The ticket is claimed before a
      # byte is read, so a replayed link loses the race, and the room comes
      # from the ticket. One ticket covers one batch: it is spent here, by this
      # request, whether the selection was one file or several.
      post "/u/:token" do
        halt 404 if deps.upload_tickets.nil? || deps.rehosted_files.nil?

        ticket = deps.upload_tickets.claim(token: params[:token])
        return upload_ended_page if ticket.nil?

        files = uploaded_files(params[:file])
        if files.empty?
          status 422
          return upload_problem("No file was chosen.")
        end

        # The community's own cap and retention, read now so a change made since the
        # ticket was issued still applies.
        policy = upload_policy(ticket)
        unless policy[:enabled]
          status 410
          return upload_problem("This community is no longer accepting uploads.")
        end

        if files.size > policy[:max_batch_files]
          status 422
          return upload_problem("That is too many files: this upload accepts at most " \
                                "#{policy[:max_batch_files]} at once.")
        end

        total_bytes = files.sum { |file| file[:tempfile].size.to_i }
        if total_bytes > policy[:max_batch_bytes]
          status 413
          return upload_problem("That selection is #{total_bytes / (1024 * 1024)} MB together, over the " \
                                "#{policy[:max_batch_bytes] / (1024 * 1024)} MB this upload accepts for one batch.")
        end

        stored, failed = store_batch(files, ticket, policy)
        if stored.empty?
          invalid = failed.find { |f| f[:reason] == :invalid }
          if invalid
            status 503
            return upload_problem(invalid[:message])
          end

          status 413
          return upload_problem("None of those files could be stored: they were all larger than " \
                                "this community accepts. Run /upload again for a fresh link.")
        end

        # Ask the bot to post the batch into the room the command was typed in.
        # The web process has no adapters, so this only records the hand-off.
        failed_names = failed.map { |f| f[:filename] }
        deps.upload_announcer&.announce(ticket: ticket, files: stored, failed: failed_names)
        @links = stored.map do |result|
          { filename: result.file.filename, url: rehosted_url(result.file, result.secret) }
        end
        @failed = failed_names
        erb :upload_done, layout: :layout
      end

      helpers do
        def deps = settings.deps

        def h(text) = Rack::Utils.escape_html(text.to_s)

        # A guest-facing timestamp, always naming its zone: "26 Jul 2026, 21:40 UTC".
        def format_time(time)
          time.getutc.strftime("%-d %b %Y, %H:%M UTC")
        end

        # The live invite the path token names, or nil when it is unknown,
        # expired or revoked. Every route funnels through this one gate.
        def live_invite
          deps.invites.authenticate(token: params[:token])
        end

        # Pin the join cursor to the head of the room's feed the first time the link
        # is opened. Idempotent, so a reload never re-reveals the backlog.
        def join!(invite)
          return unless invite.joined_at.nil?

          cursor = deps.feed.latest_id(room_id: invite.room_id)
          deps.invites.record_join(invite: invite, cursor: cursor)
        end

        def room_label(invite)
          room = deps.models.room[invite.room_id]
          return "this room" if room.nil?

          room.label.to_s.empty? ? room.room_key.to_s : room.label.to_s
        end

        # A feed entry as the JSON the browser renders. "mine" is scoped to the
        # reader's own invite, so one guest never sees another's sends as their own.
        def present(entry, invite)
          {
            id: entry.id,
            mine: entry.out? && entry.invite_id == invite.id,
            author: entry.author_label.to_s,
            # The feed stores the label flat; the browser bolds the identity part.
            author_parts: Core::SenderLabel.split(entry.author_label.to_s),
            body: entry.body.to_s,
            kind: entry.kind,
            # The earlier bubble a rich-inbound event acts on. Null on ordinary rows.
            ref: entry.ref_id,
            attachments: entry.attachments,
            at: entry.created_at.to_s
          }
        end

        # One "data:" frame carrying the same JSON shape messages.json returns,
        # so the client has one render path. The blank line ends the event.
        def sse_event(id: nil, **payload)
          "#{"id: #{id}\n" if id}data: #{JSON.generate(payload)}\n\n"
        end

        def sse_heartbeat = ": heartbeat\n\n"

        def sse_heartbeat_interval
          raw = settings.portal_env["GUEST_SSE_HEARTBEAT_INTERVAL"]
          raw.nil? || raw.to_s.empty? ? 20 : raw.to_f
        end

        # Whether a row's bytes can be handed over as a 200. The tag is checked at
        # the end of the stream, so a row small enough to read twice is read once
        # to verify and once to serve; past that the second pass costs more than
        # the wrong status does, and the stream's short body remains the signal.
        def verified?(row)
          return true if row.byte_size.to_i > VERIFY_BEFORE_SERVE_BYTES
          return true if yield

          deps.logger&.warn { "refused to serve an object that no longer authenticates: #{row.object_key}" }
          false
        end

        def unreadable_body
          content_type "text/plain"
          "That file could not be read.\n"
        end

        # The per-invite open-stream count, one per app class rather than per
        # request, since what it bounds is this process's own threads.
        def stream_limiter = self.class.stream_limiter

        # Feed passes until the invite ends, the client goes away or the pass
        # budget runs out. Returns the cursor it reached.
        def pump_stream(out, cursor:, max_passes:)
          last_sent_at = Time.now
          passes = 0
          loop do
            break if out.respond_to?(:closed?) && out.closed?

            begin
              current = live_invite
              if current.nil?
                out << sse_event(ended: true)
                break
              end
              entries = deps.feed.for_guest(invite: current, since: cursor)
              unless entries.empty?
                out << sse_event(id: entries.last.id, ended: false, cursor: entries.last.id,
                                 messages: entries.map { |entry| present(entry, current) })
                cursor = entries.last.id
                last_sent_at = Time.now
              end
              if Time.now - last_sent_at >= sse_heartbeat_interval
                out << sse_heartbeat
                last_sent_at = Time.now
              end
            rescue StandardError
              # End cleanly on a transient read failure and let the client poll.
              break
            end

            passes += 1
            break if passes >= max_passes

            sleep(SSE_INTERVAL)
          end
          cursor
        end

        # How many feed passes a stream makes before closing. A stream holds a
        # thread and two queries a second against a pool of four, so this is
        # bounded by default and the client reconnects from its Last-Event-ID.
        def sse_max_passes
          raw = settings.portal_env["GUEST_SSE_MAX_PASSES"].to_s
          return DEFAULT_SSE_MAX_PASSES if raw.empty?

          passes = raw.to_i
          passes.positive? ? passes : DEFAULT_SSE_MAX_PASSES
        end

        # The public base a capability URL is built on, or "" when GUEST_PORTAL_URL
        # names none. Never the request's own host: a guest sets that header, and
        # the path segment of the URL built from it is the object's decryption key.
        def public_base
          configured = settings.portal_env["GUEST_PORTAL_URL"].to_s.sub(%r{/+\z}, "")
          configured.match?(%r{\Ahttps?://\S+\z}) ? configured : ""
        end

        def upload_url(token) = "#{public_base}/uploads/#{token}"

        # The public base a rehosted file's own download url is built on, kept
        # apart from {#public_base}: file storage has no relationship to the
        # guest portal, so it reads its own env name rather than borrowing
        # GUEST_PORTAL_URL for a link that will not even resolve under this
        # mount.
        def file_storage_base
          configured = settings.portal_env["RUBOTTY_FILE_STORAGE_URL"].to_s.sub(%r{/+\z}, "")
          configured.match?(%r{\Ahttps?://\S+\z}) ? configured : ""
        end

        # A freshly stored rehosted file's own download url, in the same
        # extensioned shape {Core::AttachmentRehoster#download_url} builds.
        def rehosted_url(file, secret)
          ext = Util::FileExtension.for(filename: file.filename, content_type: file.content_type)
          "#{file_storage_base}/#{Core::AttachmentRehoster::PATH}/#{secret}.#{ext}"
        end

        # The broad attachment category for a MIME type.
        def attachment_kind_for(mime)
          case mime.to_s.split("/").first
          when "image" then "photo"
          when "video" then "video"
          when "audio" then "audio"
          else "document"
          end
        end

        # Strips characters that could break or inject a Content-Disposition header.
        def header_filename(name)
          name.to_s.gsub(/[^\w.\- ]/, "_")[0, 255]
        end

        def ended_page
          status 410
          erb :ended, layout: :layout
        end

        # A dead or spent upload ticket. 410 rather than 404: the link was real.
        def upload_ended_page
          status 410
          erb :upload_ended, layout: :layout
        end

        # The community's own rehosting policy for a ticket's room, so an upload
        # honours the same enablement, retention and cap a relay file does.
        def upload_policy(ticket)
          deps.rehosted_files.policy_for(community_id: ticket.community_id, room_key: ticket.room_key)
        end

        # Normalises the "file" field into an ordered array of upload hashes,
        # whether the browser sent one file (a bare Hash) or several under
        # "file[]" (an Array of them): a multi select with only one file
        # chosen still has to work. Selection order survives, since Rack keeps
        # a repeated multipart field in the order it arrived on the wire and
        # nothing here re-sorts it.
        def uploaded_files(raw)
          list = raw.is_a?(Array) ? raw : [raw]
          list.select { |file| file.is_a?(Hash) && file[:tempfile] }
        end

        # Store every file in selection order, one ticket's whole batch. A
        # file that fails does not fail the others: eight good files and a
        # note naming the two that did not store beats refusing all ten.
        # +reason+ separates "too large" from "invalid", the store itself
        # being unusable, which the caller reports as the outage it is.
        #
        # @return [Array(Array<ControlPlane::RehostedFiles::Stored>, Array<Hash>)]
        def store_batch(files, ticket, policy)
          stored = []
          failed = []
          files.each do |file|
            stored << deps.rehosted_files.store_file(
              community_id: ticket.community_id, room_key: ticket.room_key,
              source: file[:tempfile], filename: file[:filename], content_type: file[:type],
              ttl_days: policy[:retention_days], limit: policy[:max_bytes],
              origin: "upload", created_by: ticket.requested_by_label
            )
          rescue Rubotty::Storage::ObjectStore::TooLarge
            failed << { filename: file[:filename].to_s, reason: :too_large,
                        message: "That file is larger than this community accepts." }
          rescue ControlPlane::RehostedFiles::Invalid => e
            deps.logger&.warn { "a /upload file could not be stored: #{e.message}" }
            failed << { filename: file[:filename].to_s, reason: :invalid, message: e.message }
          end
          [stored, failed]
        end

        def upload_problem(text)
          @problem = text
          erb :upload_ended, layout: :layout
        end
      end
    end
  end
end
