# frozen_string_literal: true

require "rubotty/core/delivery_groups"

require "monitor"
require "set"
require "uri"

module Rubotty
  module Adapters
    module Matrix
      # The Matrix platform adapter: federated ("@name:homeserver"), rooms map
      # cleanly to channels, events arrive by long polling `/sync`
      # ({Client} is the one seam that touches the network). A single bot
      # posts, and the sender label names the sender with the origin
      # homeserver as its platform token, so a message reads as
      # "Ada [ada@matrix.org]".
      class Adapter < Adapters::Base
        # Cap on remembered display names; oldest inserted goes first. A
        # homeserver puts no bound on the distinct users a federated room can
        # carry, so without one this grows for the life of the process.
        MAX_CACHED_DISPLAYNAMES = 2048

        # Cap on remembered reaction event ids. An entry normally goes when the
        # reaction it names is removed, so this only bounds the ones nobody ever
        # takes back.
        MAX_TRACKED_REACTIONS = 4096

        # No way to ask a homeserver its real m.upload.size ahead of a
        # request, so this just borrows the fetcher's own generic ceiling.
        MAX_ATTACHMENT_BYTES = Util::MediaFetcher::DEFAULT_LIMIT

        class << self
          def supports_backfill? = true
          def supports_reaction_backfill? = true
          def supports_gap_ownership? = true
          def supports_leave? = true
          def supports_space_notice? = true

          def adapter_name = :matrix

          # One account is one access token, so a missing token means "not yet
          # connected".
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :homeserver, :string, required: true,
                                          desc: "homeserver base URL, for example https://matrix.org"
              field :token_env, :string, required: true, env: true,
                                         desc: "name of the environment variable holding the access token"
              field :sync_timeout, :integer, default: 30_000,
                                             desc: "milliseconds to hold each /sync open"
              field :skip_backlog, :boolean, default: true,
                                             desc: "resume from now rather than replaying missed history"
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :room_id, :string, required: true, desc: "Matrix room id, for example !abc:example.org"
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages"
              field :sender_separator, :string, default: ":", desc: "printed after the sender name"
            end
          end

          def validate_endpoint(settings, path)
            id = settings[:room_id].to_s
            return [] if id.start_with?("!") && id.include?(":")

            ["#{path}.room_id: expected a Matrix room id like !abc:example.org, got #{id.inspect}"]
          end

          def discovers_channels? = true

          def route_key_for(endpoint) = endpoint.settings[:room_id].to_s

          def addressing(route_key, external_id: nil)
            { "room_id" => route_key.to_s }
          end

          # A DM is an ordinary two member room: #send_admin_dm finds or opens
          # one and posts into it, #delete_admin_dm redacts the event the same
          # way an ordinary delete does.
          def supports_admin_dm? = true
          def supports_admin_dm_delete? = true
        end

        CAPABILITIES = Capabilities.new(
          edits: true,
          deletes: true,
          replies: true,
          threads: false,
          max_attachment_bytes: MAX_ATTACHMENT_BYTES,
          reactions: true,
          max_reactions: nil,
          # A foreign custom emoji has no Matrix equivalent, so only unicode
          # reactions are placed.
          custom_reactions: false,
          moderation: %i[delete ban unban kick]
        ).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil,
                       pending_spaces: nil)
          super
          @client = Client.new(
            access_token: settings[:token],
            homeserver: settings[:homeserver],
            logger: logger
          )
          @outbound = Outbound.new(logger: logger)
          @fetcher = Util::MediaFetcher.new(limit: MAX_ATTACHMENT_BYTES, logger: logger)
          @index = build_index(endpoints)
          @displayname_cache = {}
          @reaction_events = {}
          # room_id => true once #build_inbound's on_encrypted seam has seen an
          # m.room.encrypted event there. Consulted before every send, so a
          # room this bridge has already learned is encrypted never gets a
          # plaintext event posted into it after that point.
          @known_encrypted_rooms = Set.new
          @monitor = Monitor.new
          @sync = nil
          @own_account_id = nil
          @server_name = nil
          build_inbound
        end

        attr_reader :client

        def replace_client(client)
          @client = client
          build_inbound
          self
        end

        def replace_sync(sync)
          @sync = sync
          self
        end

        def capabilities = CAPABILITIES

        def own_account_id = @own_account_id

        # The origin platform token for the sender label: the homeserver the
        # sender belongs to, so a relayed user reads as "@matrix.org".
        def origin_label(_endpoint = nil)
          @server_name || homeserver_host || self.class.adapter_name.to_s
        end

        # Core::SenderLabel prefixes the handle with this protocol token:
        # "matrix::ada@example.org".
        def origin_protocol(_endpoint = nil) = "matrix"

        def running? = !@sync.nil? && @sync.running?

        # The /sync loop, held open across requests with a resume token.
        def persistent_connection? = true

        # #persistent_connection? is exactly why this matters: Core::GatewayCycle
        # drops and re-establishes /sync nightly, and skip_backlog then resumes
        # from now, so whatever was said during the drop is otherwise gone with
        # nothing left to go and find it.
        def supports_backfill? = self.class.supports_backfill?

        def supports_reaction_backfill? = self.class.supports_reaction_backfill?

        # Matrix posts every relayed copy under the bot's own account with no
        # per sender impersonation, so #own_account_id already answers the
        # ownership question directly, with no webhook lookup needed.
        def supports_gap_ownership? = self.class.supports_gap_ownership?

        # Canonical chat messages posted in +endpoint+'s room since +since+,
        # oldest first, reconstructed by walking Client#messages backward from
        # the live end of the room until the walk passes +since+ or +limit+
        # kept items are collected. A copy this bridge posted itself is
        # dropped, silently.
        def backfill_messages(endpoint, since:, limit: 500)
          room = endpoint.settings[:room_id]
          history_items(room, since: since, limit: limit) { |event| @inbound.backfill_message(room, event) }
        end

        # Same walk {#backfill_messages} does, but nothing is dropped for being
        # our own copy: each candidate is paired with the ownership answer
        # {#backfill_messages} acts on instead of exposing, for
        # {Core::GapReport}.
        def backfill_candidates(endpoint, since:, limit: 500)
          room = endpoint.settings[:room_id]
          history_items(room, since: since, limit: limit) do |event|
            @inbound.backfill_message_with_ownership(room, event)
          end
        end

        # The reactions on one history message, shaped through the same
        # builder a live m.reaction takes, so the react claim dedups a replay
        # the same way it dedups a live one. A message already gone (redacted,
        # or the room lost visibility into it) answers empty rather than
        # raising, since that is routine on a message from before the bot's
        # own events start and does not belong in the sweep's failure log.
        def backfill_reactions(endpoint, native_id, limit: 200)
          room = endpoint.settings[:room_id]
          return [] if room.nil? || native_id.nil?

          @client.relations(room, native_id, limit: limit)
                 .filter_map { |event| @inbound.backfill_reaction(room, event) }
        rescue AdapterError => e
          return [] if gone?(e)

          raise
        end

        def start
          @own_account_id = @client.whoami
          if @own_account_id.nil?
            raise AdapterError.new(
              "connected to Matrix but never learned the bot's own user id, so loop prevention " \
              "would be unsafe. Check the access token in #{settings[:token_env]}.",
              adapter: :matrix
            )
          end
          @server_name = @own_account_id.to_s.split(":", 2)[1]
          # A one-time sweep of every room already joined. Best effort.
          discover_joined_rooms
          @sync ||= build_sync
          @sync.start
          logger.info { "signed in to Matrix as #{@own_account_id} via #{@sync.describe}" }
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Matrix adapter failed to start: #{e.class}: #{e.message}", adapter: :matrix)
        end

        def stop
          @sync&.stop
          @sync = nil
          self
        end

        # A message with attachments sends more than one event: the text (if
        # any survives once an uploaded attachment's link line is dropped from
        # it) first, then one event per uploaded attachment. The tracked
        # native id is whichever went out first. Multipart membership is kept
        # durably for deletion; edits and replies still use that first anchor.
        def deliver(message, endpoint)
          room = endpoint.settings[:room_id]
          raise_if_encrypted!(room)
          uploads, remainder = upload_attachments(message.attachments)
          degraded = message.with(attachments: remainder)
          content = @outbound.send_content(degraded, endpoint)

          text_id =
            if content["body"].to_s.strip.empty?
              nil
            else
              @client.send_event(room, "m.room.message", content, txn_id: delivery_txn_id(message))
            end
          posted, unposted = post_media_events(room, uploads)

          native_id = text_id || posted.first
          if native_id.nil?
            # Nothing to send by design, so Bridge must not record a loss.
            return Core::DeliveryReceipt::NOT_APPLICABLE if uploads.empty?

            # Content already sits in the content repository but no event
            # points at it, so this is real loss, not "nothing to send".
            raise AdapterError.new(
              "Matrix send failed: uploaded #{uploads.size} attachment(s) but could not post any of them",
              adapter: :matrix, retryable: true
            )
          end

          delivery_groups.remember(delivery_group_key(endpoint, native_id), [text_id, *posted])
          Core::DeliveryReceipt.new(
            endpoint_id: endpoint.id, native_id: native_id, extra: notes_extra(degraded, unposted)
          )
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Matrix send failed: #{e.class}: #{e.message}", adapter: :matrix, retryable: true)
        end

        # An edit is a new m.replace event pointing at the original, but the
        # original event id stays the anchor the message map tracks.
        def edit(message, endpoint, native_id)
          raise_if_encrypted!(endpoint.settings[:room_id])
          content = @outbound.edit_content(message, endpoint, native_id)
          @client.send_event(endpoint.settings[:room_id], "m.room.message", content)
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
        rescue AdapterError => e
          return nil if gone?(e)

          raise
        end

        def delete(endpoint, native_id)
          key = delivery_group_key(endpoint, native_id)
          delivery_groups.members(key, fallback: native_id).each do |id|
            begin
              @client.redact(endpoint.settings[:room_id], id)
            rescue AdapterError => e
              raise unless gone?(e)
            end
          end
          delivery_groups.forget(key)
          nil
        rescue StorageError => e
          raise AdapterError.new("Matrix multipart deletion state failed: #{e.message}", adapter: :matrix, retryable: true)
        rescue AdapterError => e
          return nil if gone?(e)

          raise
        end

        # DM +text+ to +native_id+: reuse the direct room m.direct already
        # names for them, or open one, then post to it the same way #say does.
        # #whoami rather than the cached @own_account_id, so a DM sent before
        # #start (the contract's own walk does exactly this) still resolves.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          my_id = @own_account_id || @client.whoami
          return dm_refused(native_id, "this homeserver did not say who the bot is") if my_id.nil?

          room_id = @client.direct_room_for(my_id, native_id) || open_direct_room(my_id, native_id)
          return dm_refused(native_id, "no direct room opened") if room_id.nil?

          event_id = @client.send_event(room_id, "m.room.message", { msgtype: "m.text", body: text.to_s })
          return dm_refused(native_id, "the direct room took no event") if event_id.nil?

          Core::DmReceipt.new(native_id: event_id, channel_ref: room_id)
        rescue AdapterError => e
          dm_refused(native_id, e.message)
        end

        # Remove a DM #send_admin_dm sent: the ordinary redact, over the
        # direct room the receipt names.
        def delete_admin_dm(receipt)
          return false if receipt.nil? || receipt.channel_ref.nil?

          @client.redact(receipt.channel_ref, receipt.native_id)
          true
        rescue AdapterError => e
          return true if gone?(e)

          logger.info { "matrix: could not delete a DM: #{e.message}" }
          false
        end

        # Matrix reactions are annotation events, removed by redacting the
        # event that added them. A refusal (a 403, a 429) has to raise
        # rather than being swallowed: the bridge records the aggregate as
        # placed on any non-raising return, so storage would end up believing
        # in an emoji that is not on the message; only an already-gone event
        # is tolerated.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          room = endpoint.settings[:room_id]
          (desired - previous).each { |reaction| add_reaction(room, native_id, reaction) }
          (previous - desired).each { |reaction| remove_reaction(room, native_id, reaction) }
          nil
        rescue AdapterError => e
          return nil if gone?(e)

          raise
        end

        def moderate(command, endpoint, native_id)
          case command.action
          when :delete then moderate_delete(endpoint, native_id)
          when :ban then moderate_ban(command, endpoint)
          when :unban then moderate_unban(command, endpoint)
          when :kick then moderate_kick(command, endpoint)
          else
            Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end
        rescue PermissionError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :forbidden, detail: e.message)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        # matrix.to is the federated permalink shape, and the specification
        # writes both ids into it with their sigils intact. The via hint names
        # the room id's own server, so a client not already in the room has
        # somewhere to ask about it.
        def message_permalink(endpoint, native_id)
          room_id = endpoint.settings[:room_id].to_s
          event_id = native_id.to_s
          return nil if room_id.empty? || event_id.empty?

          via = room_id.split(":", 2)[1].to_s
          link = "https://matrix.to/#/#{room_id}/#{event_id}"
          via.empty? ? link : "#{link}?via=#{via}"
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (matrix room #{endpoint.settings[:room_id]})"
        end

        def supports_leave? = self.class.supports_leave?

        # Post +notice+ (nil skips the post) then leave the room. Also how an
        # invite still pending is declined, since Matrix answers /leave the
        # same way whether we were joined or only invited.
        def leave_space(external_id, notice: nil)
          begin
            post_space_notice(external_id, notice) if notice
          rescue StandardError => e
            logger.info { "matrix: could not post the leave notice in #{external_id}: #{e.message}" }
          end
          @client.leave_room(external_id)
          logger.info { "matrix: left room #{external_id}" }
          true
        rescue AdapterError => e
          logger.warn { "matrix: could not leave room #{external_id}: #{e.message}" }
          false
        end

        def supports_space_notice? = self.class.supports_space_notice?

        # Post +text+ into +external_id+ as a bot notice, with no accompanying
        # leave.
        def post_space_notice(external_id, text)
          return false if text.to_s.strip.empty?

          content = { "msgtype" => "m.notice", "body" => text }
          !@client.send_event(external_id, "m.room.message", content).nil?
        rescue AdapterError => e
          logger.info { "matrix: could not post a space notice in #{external_id}: #{e.message}" }
          false
        end

        # Entry point the sync loop drives, one (room_id, event) pair at a time.
        def handle_event(room_id, event)
          learn_room(room_id) if discovery && event["type"] == "m.room.message"
          emit_if(@inbound.call(room_id, event))
        end

        def emit_if(message)
          return nil if message.nil?

          emit(message)
          message
        rescue StandardError => e
          logger.error { "error handling a Matrix event: #{e.class}: #{e.message}" }
          nil
        end

        # Entry point the sync loop drives for a pending m.room.invite. Accepts
        # the invite outright, since that is the only way a Matrix room becomes
        # usable at all, then runs the same stay/review/leave decision Telegram
        # and Discord run on their own join events.
        def handle_invite(room_id, state_events)
          member_event = invite_member_event(state_events)
          return if member_event.nil?

          joined = @client.join_room(room_id)
          if joined.nil?
            logger.warn { "matrix: joining #{room_id} returned no room id, treating the invite as declined" }
            return
          end

          logger.info { "matrix: accepted an invite to #{room_id}" }
          title = room_name_from_state(state_events)
          learn_invited_room(room_id, title)
          decide_membership(room_id, title, invite_author(member_event))
        rescue StandardError => e
          logger.warn { "matrix: could not accept the invite to #{room_id}: #{e.message}" }
        end

        private

        # A fresh direct room with +native_id+, recorded into m.direct so the
        # next #send_admin_dm to them finds it instead of opening another.
        def open_direct_room(my_id, native_id)
          room_id = @client.create_room(invite: native_id)
          return nil if room_id.nil?

          @client.remember_direct_room(my_id, native_id, room_id)
          room_id
        end

        # A stable transaction id for a message's text event, so a Bridge retry
        # after a client side timeout (RetryPolicy wraps #deliver; see
        # Features::Bridge#deliver_one) reuses the same id on the next attempt.
        # Matrix's own txn_id dedup then recognises the retry as the request it
        # already handled instead of posting the message a second time, which is
        # exactly what PUT .../send/{eventType}/{txnId} exists for; Client#new_txn
        # mints a fresh random id per call and stays the right default everywhere
        # else that sends once and does not get retried.
        def delivery_txn_id(message) = "rubotty-#{message.correlation_id}"

        def delivery_group_key(endpoint, native_id) = [:matrix, account, endpoint.settings[:room_id].to_s, native_id.to_s]

        def delivery_groups
          @monitor.synchronize do
            @delivery_groups ||= Core::DeliveryGroups.new(storage: -> { storage }, ttl: -> { delivery_state_ttl },
                                                          logger: logger)
          end
        end

        # Told to the sender through Features::Bridge#report_notes, the same
        # signal Discord's note_failed_upload gives when a file never crosses.
        # Empty, not a key holding an empty array, when nothing failed.
        def notes_extra(message, unposted = [])
          notes = @outbound.unrelayed_attachments(message).map do |attachment|
            "could not relay #{attachment.label} to Matrix: the source URL could not be shown"
          end
          notes += unposted.map do |attachment|
            "could not relay #{attachment.label} to Matrix: it uploaded but the message posting it failed"
          end
          notes.empty? ? {} : { notes: notes }
        end

        def build_inbound
          @inbound = Inbound.new(
            endpoint_for: method(:endpoint_for),
            displayname: method(:resolve_displayname),
            media_url: @client.method(:media_http_url),
            own_account_id: method(:own_account_id),
            on_encrypted: method(:mark_encrypted),
            logger: logger
          )
        end

        def mark_encrypted(room_id)
          @monitor.synchronize { @known_encrypted_rooms << room_id.to_s }
        end

        def encrypted?(room_id) = @monitor.synchronize { @known_encrypted_rooms.include?(room_id.to_s) }

        # This bridge has no way to encrypt: sending a plaintext event into a
        # room this bridge has already learned is end to end encrypted would
        # be a silent, serious breach of what every other participant in it
        # believes, so a known-encrypted room refuses the send outright
        # rather than posting into it in the clear. Only known-encrypted, not
        # every room this bridge has simply never confirmed either way: there
        # is no cheap way to ask a room's encryption state ahead of the first
        # event that reveals it.
        def raise_if_encrypted!(room)
          return unless encrypted?(room)

          raise AdapterError.new(
            "matrix room #{room} is end to end encrypted; this bridge cannot send into it",
            adapter: :matrix
          )
        end

        # Fetch and upload every resolvable attachment into the room's
        # homeserver, in send order. Returns [[attachment, message_content],
        # attachments_left_for_the_text_body]: an attachment that uploaded
        # cleanly is dropped from the second list, since Outbound would
        # otherwise also print it as a link and the same file would appear
        # twice. The attachment travels alongside its content so a later
        # failure to post it can still be reported by label.
        def upload_attachments(attachments)
          uploads = []
          remainder = []
          attachments.each do |attachment|
            content = upload_attachment(attachment)
            content ? uploads << [attachment, content] : remainder << attachment
          end
          [uploads, remainder]
        end

        def upload_attachment(attachment)
          return nil unless attachment.resolvable?

          mxc = fetch_and_upload(attachment)
          return nil if mxc.nil?

          @outbound.media_content(attachment, mxc)
        rescue StandardError => e
          logger.warn { "matrix: could not upload an attachment: #{e.class}: #{e.message}" }
          nil
        end

        # Download through the hardened fetcher (SSRF guarded, size capped),
        # then push the bytes to the content repository. nil on either half
        # failing, which #upload_attachment reads as "fall back to a link".
        def fetch_and_upload(attachment)
          @fetcher.with(attachment.url, filename: attachment.filename) do |file|
            @client.upload(file.read, filename: attachment.filename, content_type: attachment.mime_type)
          end
        end

        # Posts every already-uploaded attachment, in order. Returns
        # [posted_event_ids, attachments_whose_post_failed] so #deliver can
        # tell a real posting failure apart from nothing having uploaded at
        # all, and can still name the attachment in a sender-facing note.
        def post_media_events(room, uploads)
          posted = []
          unposted = []
          uploads.each do |attachment, content|
            event_id = send_media_event(room, content)
            event_id ? posted << event_id : unposted << attachment
          end
          [posted, unposted]
        end

        # Posting an uploaded attachment must not cost the whole delivery: a
        # hiccup here, after the text event may already be out, must not raise
        # and risk Bridge retrying the send and duplicating that text.
        def send_media_event(room, content)
          @client.send_event(room, "m.room.message", content)
        rescue StandardError => e
          logger.warn { "matrix: could not post an uploaded attachment: #{e.class}: #{e.message}" }
          nil
        end

        # The one page walk both {#backfill_messages} and {#backfill_candidates}
        # need: pages backward from the live room end in batches of 100 until
        # +limit+ items are kept, history runs out, or a page reaches an event
        # older than +since+ (Matrix pages by opaque token, so there is no way to
        # precompute a starting boundary up front). Results collect newest first
        # and are reversed and capped afterward, so the oldest +limit+ candidates
        # survive, the order {#backfill_messages} promises.
        def history_items(room, since:, limit: 500)
          return [] if room.nil?

          collected = []
          token = nil
          loop do
            page, next_token = @client.messages(room, from: token, dir: "b", limit: 100)
            break if page.empty?

            hit_horizon = false
            page.each do |event|
              if past_horizon?(event, since)
                hit_horizon = true
                break
              end

              item = yield event
              collected << item unless item.nil?
            end
            break if hit_horizon || collected.size >= limit || next_token.nil?

            token = next_token
          end
          collected.reverse.first(limit)
        end

        def past_horizon?(event, since)
          ms = event["origin_server_ts"]
          return false if ms.nil?

          Time.at(ms / 1000.0) < since
        end

        def build_sync
          Sync.new(
            client: @client,
            on_event: method(:handle_event),
            on_invite: method(:handle_invite),
            logger: logger,
            timeout_ms: settings[:sync_timeout] || Sync::DEFAULT_TIMEOUT_MS,
            skip_backlog: settings.fetch(:skip_backlog, true)
          )
        end

        # Matrix has no guild or supergroup to scope a platform_connection to, so
        # the account is the space a discovered room belongs to and the room_id
        # is the route_key.

        # Bulk enumeration of every room already joined, run once from #start.
        # A failure is logged and swallowed: it must never prevent #start from
        # finishing or the sync loop from starting.
        def discover_joined_rooms
          return if discovery.nil?

          channels = @client.joined_rooms.map { |room_id| { id: room_id, name: room_label(room_id) } }
          discovery.inventory(adapter: :matrix, account: account, external_id: account, channels: channels)
        rescue StandardError => e
          logger.warn { "matrix: room enumeration failed: #{e.class}: #{e.message}" }
        end

        # A room's published name, falling back to its canonical alias, guarded
        # per room so one failed lookup does not lose the rest of the sweep. Both
        # are nil for an unnamed room with no alias, which is normal.
        def room_label(room_id)
          @client.room_name(room_id) || @client.room_canonical_alias(room_id)
        rescue StandardError
          nil
        end

        # One sighting from live traffic. Matrix carries no room name on an
        # ordinary message, and looking one up here would cost two requests per
        # message, so the next #discover_joined_rooms sweep supplies the label.
        def learn_room(room_id)
          discovery.saw(
            adapter: :matrix, account: account, external_id: account,
            route_key: room_id.to_s, name: nil
          )
        rescue StandardError => e
          logger.warn { "matrix: room discovery failed: #{e.class}: #{e.message}" }
        end

        # Like #learn_room, but for a room just joined via an accepted invite,
        # where the stripped invite state already carries a name for free.
        def learn_invited_room(room_id, title)
          return if discovery.nil?

          discovery.saw(
            adapter: :matrix, account: account, external_id: account,
            route_key: room_id.to_s, name: title
          )
        rescue StandardError => e
          logger.warn { "matrix: room discovery failed: #{e.class}: #{e.message}" }
        end

        # The stripped m.room.member state naming OUR OWN pending invite, which
        # carries who invited us as its sender.
        def invite_member_event(state_events)
          Array(state_events).find do |event|
            event.is_a?(Hash) && event["type"] == "m.room.member" &&
              event["state_key"] == @own_account_id && event.dig("content", "membership") == "invite"
          end
        end

        def room_name_from_state(state_events)
          name_event = Array(state_events).find { |event| event.is_a?(Hash) && event["type"] == "m.room.name" }
          name_event&.dig("content", "name")
        end

        def invite_author(member_event)
          sender = member_event["sender"]
          return nil if sender.to_s.empty?

          Core::Author.new(native_id: sender, username: sender, display_name: resolve_displayname(sender), kind: :user)
        end

        # Run the auto-leave decision, the way Telegram's my_chat_member handler
        # and Discord's guild_add handler do, now that the room is joined.
        def decide_membership(room_id, title, inviter)
          return if join_guard.nil?

          decision = join_guard.on_join(adapter: :matrix, account: account, external_id: room_id.to_s,
                                        title: title, inviter: inviter, channel_sample: [])
          return unless decision.leave? || decision.review?

          if pending_spaces
            pend_room(room_id, title, inviter)
          elsif decision.leave?
            post_inert_fallback(room_id) unless leave_space(room_id, notice: decision.notice)
          end
        end

        # Hand the room to the pending-review service and carry out what it
        # decided. A no-op when no service is wired, since there is no board.
        def pend_room(room_id, title, inviter)
          return if pending_spaces.nil?

          outcome = pending_spaces.on_join!(
            adapter: :matrix, account: account, external_id: room_id.to_s, name: title,
            inviter_native_id: inviter&.native_id, inviter_username: inviter&.username,
            inviter_display: inviter&.display_name, member_count: nil, sample_channels: []
          )
          if outcome.pending? && outcome.post_notice
            posted = post_space_notice(room_id, ControlPlane::PendingSpaces::PENDING_NOTICE)
            pending_spaces.mark_notice_posted!(outcome.row) if posted
          elsif outcome.leave?
            pending_spaces.reconfirm_denied!(outcome.row)
          end
        end

        # A room whose bookkeeping stays stuck: the auto-leave notice is posted
        # at most once per room, matching Telegram and Discord.
        def post_inert_fallback(room_id)
          return if join_guard.nil?
          return unless join_guard.record_leave_failure(adapter: :matrix, account: account,
                                                         external_id: room_id.to_s)

          post_space_notice(room_id, ControlPlane::JoinGuard::INERT_NOTICE)
          logger.warn { "matrix: could not leave room #{room_id}; posted the inert notice instead" }
        end

        def add_reaction(room, target, reaction)
          if reaction.custom?
            logger.debug { "matrix: dropped custom reaction #{reaction.label} on #{room}:#{target}" }
            return
          end
          raise_if_encrypted!(room)

          content = { "m.relates_to" => { "rel_type" => "m.annotation",
                                          "event_id" => target, "key" => reaction.emoji } }
          event_id = @client.send_event(room, "m.reaction", content)
          remember_reaction(room, target, reaction, event_id) if event_id
        end

        def remove_reaction(room, target, reaction)
          if reaction.custom?
            logger.debug { "matrix: dropped custom reaction #{reaction.label} on #{room}:#{target}" }
            return
          end

          event_id = forget_reaction(room, target, reaction)
          if event_id.nil?
            logger.warn { "matrix: no tracked event id for a reaction removal on #{room}:#{target}, nothing to redact" }
            return
          end

          @client.redact(room, event_id)
        end

        def reaction_key(room, target, reaction) = [room, target.to_s, reaction.key]

        # Remembered twice: the in process Hash is the fast path within one
        # run, and reaction_store carries the same mapping through a restart,
        # which is the case #forget_reaction otherwise cannot answer.
        def remember_reaction(room, target, reaction, event_id)
          key = reaction_key(room, target, reaction)
          @monitor.synchronize do
            @reaction_events.shift while @reaction_events.size >= MAX_TRACKED_REACTIONS
            @reaction_events[key] = event_id
          end
          reaction_store&.remember(room, target, reaction, event_id)
        end

        def forget_reaction(room, target, reaction)
          key = reaction_key(room, target, reaction)
          cached = @monitor.synchronize { @reaction_events.delete(key) }
          cached || reaction_store&.forget(room, target, reaction)
        end

        def reaction_store
          return nil unless storage

          @reaction_store ||= ReactionEvents.new(store: storage, logger: logger)
        end

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        def moderate_delete(endpoint, native_id)
          delete(endpoint, native_id)
          ok(endpoint)
        end

        def moderate_ban(command, endpoint)
          @client.ban(endpoint.settings[:room_id], command.target_user_id, reason: "bridged /ban by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_unban(command, endpoint)
          @client.unban(endpoint.settings[:room_id], command.target_user_id)
          ok(endpoint)
        end

        def moderate_kick(command, endpoint)
          @client.kick(endpoint.settings[:room_id], command.target_user_id, reason: "bridged /kick by #{command.issuer}")
          ok(endpoint)
        end

        def resolve_displayname(user_id)
          return nil if user_id.nil?

          key = user_id.to_s
          @monitor.synchronize do
            return @displayname_cache[key] if @displayname_cache.key?(key)
          end
          name = @client.displayname(key)
          @monitor.synchronize do
            @displayname_cache.shift while @displayname_cache.size >= MAX_CACHED_DISPLAYNAMES
            @displayname_cache[key] = name
          end
          name
        rescue RateLimitedError
          # Leave the cache unset rather than latch a transient 429 in as this
          # user's permanent name; the next message from them tries again.
          nil
        end

        def homeserver_host
          URI.parse(settings[:homeserver].to_s).host
        rescue StandardError
          nil
        end

        def build_index(endpoints)
          endpoints.each_with_object({}) do |endpoint, index|
            index[endpoint.settings[:room_id].to_s] = endpoint
          end
        end

        def endpoint_for(room_id)
          if @endpoint_resolver
            return nil if room_id.nil?

            return @endpoint_resolver.endpoint_for(:matrix, account, room_id.to_s)
          end

          return nil if room_id.nil?

          @index[room_id.to_s]
        end

        # The shared answer, so this adapter cannot drift a little wider than
        # the others and start swallowing refusals with it.
        def gone?(error) = AlreadyGone.call(error)
      end
    end
  end
end
