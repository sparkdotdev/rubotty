# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Stoat
      # The Stoat platform adapter. Stoat (developers.stoat.chat, the
      # platform formerly called Revolt) is Discord shaped: servers hold
      # channels, one bot token, a WebSocket gateway, and REST for
      # everything else. Per sender identity uses Stoat's "masquerade", a
      # per message override of the shown name and avatar; a masquerade
      # message is still authored by the bot account, so the loop guard
      # recognises our own echoes by author id.
      class Adapter < Adapters::Base
        class << self
          def supports_space_notice? = true

          def adapter_name = :stoat

          # One account is one bot token, one connection, so a missing token
          # cleanly means "not yet connected".
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :token_env, :string, required: true, env: true,
                                         desc: "name of the environment variable holding the bot token"
              field :api_base, :string, default: Client::DEFAULT_API_BASE,
                                        desc: "override for a self hosted Stoat API server"
              field :cdn_base, :string, default: Client::DEFAULT_CDN_BASE,
                                        desc: "override for a self hosted file/CDN host"
              field :ws_base, :string, default: Gateway::DEFAULT_WS_BASE,
                                       desc: "override for a self hosted gateway"
              field :heartbeat, :integer, default: Gateway::DEFAULT_HEARTBEAT,
                                          desc: "seconds between gateway Ping frames"
              field :max_upload_bytes, :integer, default: Client::DEFAULT_UPLOAD_BYTES,
                                                 desc: "largest file to download and upload to Stoat, " \
                                                       "in bytes. 20 MB is the hosted service's " \
                                                       "attachments limit."
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :channel_id, :string, required: true, desc: "Stoat channel id (a ULID)"
              field :server_id, :string,
                    desc: "server the channel belongs to, required only for ban/kick moderation"
              field :masquerade, :symbol, default: :auto, one_of: %i[auto off],
                                          desc: "post relayed messages under each sender's own name " \
                                                "and avatar via Stoat masquerade. off falls back to a " \
                                                "text sender prefix."
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages when " \
                                                    "masquerade is off"
              field :sender_separator, :string, default: ":",
                                                desc: "printed after the sender name"
            end
          end

          def validate_endpoint(settings, path)
            id = settings[:channel_id].to_s
            return [] if id.match?(/\A\S{3,}\z/)

            ["#{path}.channel_id: expected a Stoat channel id, got #{id.inspect}"]
          end

          def discovers_channels? = true

          def route_key_for(endpoint) = endpoint.settings[:channel_id].to_s

          # Mirrors Discord's addressing: server_id is left for an operator to
          # fill in, since it is needed only for ban/kick.
          def addressing(route_key, external_id: nil)
            { "channel_id" => route_key.to_s }
          end

          def supports_admin_dm? = true
          def supports_space_enumeration? = true

          # A DM channel is a channel like any other here too.
          def supports_admin_dm_delete? = true
        end

        CAPABILITIES = Capabilities.new(
          edits: true,
          deletes: true,
          replies: true,
          threads: false,
          # This account's own ceiling, once max_upload_bytes is known, is what
          # #capabilities reports; the constant carries the hosted default.
          max_attachment_bytes: Client::DEFAULT_UPLOAD_BYTES,
          reactions: true,
          # A masquerade overrides the shown name and avatar per message. It is
          # fixed at creation and cannot be changed on edit, but it is also not
          # cleared by one, so an edited message still wears the sender's name.
          puppets_send: true,
          puppets_edit: true,
          # Stoat places no meaningful limit on the bot's distinct reactions.
          max_reactions: nil,
          # A foreign custom emoji has no equivalent on a Stoat server.
          custom_reactions: false,
          moderation: %i[delete ban unban kick mute unmute pin unpin]
        ).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil,
                       pending_spaces: nil)
          super
          @client = Client.new(
            token: settings[:token],
            api_base: settings[:api_base] || Client::DEFAULT_API_BASE,
            cdn_base: settings[:cdn_base] || Client::DEFAULT_CDN_BASE,
            logger: logger
          )
          @outbound = Outbound.new(logger: logger)
          @index = build_index(endpoints)
          @user_cache = {}
          @member_cache = {}
          # endpoint id -> true once Stoat has refused a masquerade there.
          @masquerade_refused = {}
          # Whether a channel id is a DM with the bot, learned from a fetch the
          # first time an unmapped message is seen in it.
          @dm_channel_cache = {}
          @cache_monitor = Monitor.new
          @gateway = nil
          @own_account_id = nil
          # channel id -> server id, learned from Ready/ServerCreate/ChannelCreate;
          # written from the gateway thread and read from that plus the durable
          # scheduler, so every access goes through @cache_monitor. A Message event
          # carries no server id, so this is what names a passively-seen channel's space.
          @channel_servers = {}
          @fetcher = Util::MediaFetcher.new(limit: upload_limit, logger: logger)
          @pending_notes = []
          build_inbound
        end

        attr_reader :client

        # Test seam: a fake REST client, so the adapter runs without a network.
        def replace_client(client)
          @client = client
          build_inbound
          self
        end

        # Test seam: swap in a fake gateway so start does not open a socket.
        def replace_gateway(gateway)
          @gateway = gateway
          self
        end

        # This account's own ceiling, once max_upload_bytes is known, so a self
        # hosted instance that raised its attachments limit gets the bridge
        # relaying up to what it really takes.
        def capabilities = @capabilities ||=
          Capabilities.new(**CAPABILITIES.to_h.merge(max_attachment_bytes: upload_limit))

        # Has Stoat already answered 403 to a masquerade in this channel? Held
        # per endpoint so the channel costs one refused send rather than one per
        # message, the way Fluxer's Webhook#for caches its negative answer.
        def masquerade_refused?(endpoint)
          @cache_monitor.synchronize { @masquerade_refused.key?(endpoint.id) }
        end

        # The configured ceiling, or the hosted service's default.
        def upload_limit
          limit = settings[:max_upload_bytes].to_i
          limit.positive? ? limit : Client::DEFAULT_UPLOAD_BYTES
        end


        def own_account_id = @own_account_id

        def running? = !@gateway.nil? && @gateway.running?

        # The gateway websocket.
        def persistent_connection? = true

        def start
          @own_account_id = @client.own_id
          if @own_account_id.nil?
            raise AdapterError.new(
              "connected to Stoat but never learned the bot's own user id, so loop prevention " \
              "would be unsafe. Check the token in #{settings[:token_env]}.",
              adapter: :stoat
            )
          end
          @gateway ||= build_gateway
          @gateway.start
          logger.info { "signed in to Stoat as #{@own_account_id} via #{@gateway.describe}" }
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          # Converting here lets the runtime isolate this adapter instead of crash
          # looping the process.
          raise AdapterError.new("Stoat adapter failed to start: #{e.class}: #{e.message}", adapter: :stoat)
        end

        def stop
          @gateway&.stop
          @gateway = nil
          self
        end

        def deliver(message, endpoint)
          uploaded, file_ids, missed = upload_attachments(message.attachments.select(&:resolvable?))
          body = @outbound.send_body(message, endpoint, masquerade: !masquerade_refused?(endpoint), uploaded: uploaded)
          body[:attachments] = file_ids unless file_ids.empty?
          missed.each { |attachment| note_failed_upload(attachment) }
          # Nothing to send by design, so Bridge must not record a loss.
          return Core::DeliveryReceipt::NOT_APPLICABLE if body[:content].to_s.strip.empty? && file_ids.empty?

          post(endpoint, body)
        rescue PermissionError => e
          # Stoat refuses the whole send when the bot lacks Masquerade, so without
          # this the channel relays nothing at all, forever. Stoat's client turns
          # every 401/403 into the same PermissionError, so a channel merely missing
          # SendMessage would otherwise get misdiagnosed as a Masquerade problem too.
          raise unless body.is_a?(Hash) && body[:masquerade] && masquerade_permission_refused?(e)

          note_masquerade_refused(endpoint, e)
          # The attachments already made the trip up in the first attempt, so the
          # retry reuses them rather than uploading again. It needs its own
          # begin/rescue: Ruby never routes an exception raised inside one rescue
          # clause into a sibling rescue of the same begin.
          retry_body = @outbound.send_body(message, endpoint, masquerade: false, uploaded: uploaded)
          retry_body[:attachments] = file_ids unless file_ids.empty?
          begin
            post(endpoint, retry_body)
          rescue AdapterError
            raise
          rescue StandardError => retry_error
            raise AdapterError.new("Stoat send failed: #{retry_error.class}: #{retry_error.message}",
                                   adapter: :stoat, retryable: true)
          end
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Stoat send failed: #{e.class}: #{e.message}",
                                 adapter: :stoat, retryable: true)
        end

        def edit(message, endpoint, native_id)
          @client.edit_message(endpoint.settings[:channel_id], native_id, @outbound.edit_body(message, endpoint))
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
        rescue AdapterError => e
          # Editing a message that is already gone is an ordinary race.
          return nil if gone?(e)

          raise
        end

        def delete(endpoint, native_id)
          @client.delete_message(endpoint.settings[:channel_id], native_id)
          nil
        rescue AdapterError => e
          return nil if gone?(e)

          raise
        end

        # DM +text+ to +native_id+: open the DM channel, then post to it
        # the same way #deliver does.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          channel = @client.open_dm(native_id)
          channel_id = channel && (channel["_id"] || channel["id"])
          return dm_refused(native_id, "no DM channel opened") if channel_id.nil?

          sent = @client.send_message(channel_id, content: text.to_s)
          message_id = sent && (sent["_id"] || sent["id"])
          return dm_refused(native_id, "the DM channel took no message") if message_id.nil?

          Core::DmReceipt.new(native_id: message_id, channel_ref: channel_id)
        rescue AdapterError => e
          dm_refused(native_id, e.message)
        end

        # Remove a DM #send_admin_dm sent: the ordinary channel-message
        # delete, over the DM channel the receipt names.
        def delete_admin_dm(receipt)
          return false if receipt.nil? || receipt.channel_ref.nil?

          @client.delete_message(receipt.channel_ref, receipt.native_id)
          true
        rescue AdapterError => e
          return true if gone?(e)

          logger.info { "stoat: could not delete a DM: #{e.message}" }
          false
        end

        # Stoat's reaction model is incremental (one PUT or DELETE per
        # emoji), so the declarative request becomes a diff. A refusal (a
        # 403, a 429) has to raise rather than being swallowed: the bridge
        # records the aggregate as placed on any non-raising return, so
        # storage would end up believing in an emoji that is not on the
        # message; only an already-gone message is tolerated.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          channel = endpoint.settings[:channel_id]
          (desired - previous).each { |reaction| react(channel, native_id, reaction) }
          (previous - desired).each { |reaction| unreact(channel, native_id, reaction) }
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
          when :mute then moderate_mute(command, endpoint)
          when :unmute then moderate_unmute(command, endpoint)
          when :pin then moderate_pin(endpoint, native_id, pinned: true)
          when :unpin then moderate_pin(endpoint, native_id, pinned: false)
          else
            Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end
        rescue PermissionError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :forbidden, detail: e.message)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (stoat channel #{endpoint.settings[:channel_id]})"
        end

        # List one server's channels again, for a space whose first listing was
        # dropped because it had no platform connection yet. Stoat has no
        # server-channels endpoint, so the ids come from what Ready and
        # ServerCreate already told this adapter, and each is re-fetched by id.
        def enumerate_space(external_id)
          server_id = external_id.to_s
          return false if server_id.empty? || discovery.nil?

          ids = channel_ids_for_server(server_id)
          return false if ids.empty?

          discover_server_channels(server_id, ids.filter_map { |id| fetch_channel_for(id, server_id) })
          true
        rescue StandardError => e
          logger.warn { "stoat: could not re-enumerate server #{server_id}: #{e.message}" }
          false
        end

        # The connection resolver's hook (see ControlPlane::GuildResolver): the
        # server a channel belongs to, from the cache Ready/ServerCreate/
        # ChannelCreate already populated, falling back to a fetch.
        def guild_id_for_channel(channel_id)
          return nil if channel_id.nil?

          key = channel_id.to_s
          cached = channel_server(key)
          return cached if cached

          channel = @client.fetch_channel(key)
          server_id = presence(channel.is_a?(Hash) ? channel["server"] : nil)
          remember_channel_server(key, server_id) if server_id
          server_id
        rescue StandardError
          nil
        end

        def supports_space_notice? = self.class.supports_space_notice?

        # Post +text+ into one of the server's known text channels, best effort.
        def post_space_notice(external_id, text)
          channel_id = channel_ids_for_server(external_id.to_s).first
          return false if channel_id.nil?

          sent = @client.send_message(channel_id, content: text.to_s)
          !(sent.nil? || sent["_id"].nil?)
        rescue AdapterError => e
          logger.info { "stoat: could not post a space notice in #{external_id}: #{e.message}" }
          false
        end

        # Entry point the gateway drives, one parsed event Hash at a time. The
        # first case covers everything that does not become exactly one canonical
        # message: the channel-discovery seam, a Bulk envelope unpacked into its
        # own events, the two frames that say the session is over, and a bulk
        # delete that fans out into one delete per id.
        def handle_event(event)
          return nil unless event.is_a?(Hash)

          case event["type"]
          when "Ready" then return handle_ready(event)
          when "ServerCreate" then return handle_server_created(event)
          when "ChannelCreate" then return handle_channel_created(event)
          when "Bulk" then return handle_bulk(event)
          when "Error" then return handle_session_error(event)
          when "Logout" then return handle_logout(event)
          when "BulkMessageDelete" then return handle_bulk_delete(event)
          end

          produced =
            case event["type"]
            when "Message" then handle_message(event)
            when "MessageUpdate" then @inbound.edit(event)
            when "MessageDelete" then @inbound.delete(event)
            when "MessageReact" then @inbound.reaction(event, :reaction_add)
            when "MessageUnreact" then @inbound.reaction(event, :reaction_remove)
            when "MessageRemoveReaction" then @inbound.reaction_clear(event)
            when "ServerMemberJoin" then member_messages(event, :join)
            when "ServerMemberLeave" then member_messages(event, :leave)
            else
              logger.debug { "unhandled Stoat event type #{event["type"].inspect}" }
              nil
            end
          emit_if(produced)
        end

        # Exposed so specs can push an event through the whole inbound path.
        # +message+ is one Core::Message, nil, or an Array of either (a
        # membership event fans out to every bridged channel of its server).
        def emit_if(message)
          return nil if message.nil?
          return message.each { |item| emit_if(item) } if message.is_a?(Array)

          emit(message)
          message
        rescue StandardError => e
          logger.error { "error handling a Stoat event: #{e.class}: #{e.message}" }
          nil
        end

        private

        def post(endpoint, body)
          sent = @client.send_message(endpoint.settings[:channel_id], body)
          return nil if sent.nil? || sent["_id"].nil?

          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: sent["_id"], extra: { notes: drain_notes })
        end

        # Whether a 403 actually names the Masquerade permission, the only
        # signal available to tell it apart from an unrelated refusal:
        # Client#parse turns every 401/403 into the same PermissionError, and
        # #describe_error only carries the permission name when Stoat's body
        # included one.
        def masquerade_permission_refused?(error)
          error.message.include?("Masquerade")
        end

        # Remember the refusal and say so once, since the channel is about to
        # start showing every sender under the bot's name instead of their own.
        def note_masquerade_refused(endpoint, error)
          fresh = @cache_monitor.synchronize do
            next false if @masquerade_refused.key?(endpoint.id)

            @masquerade_refused[endpoint.id] = true
          end
          return unless fresh

          logger.warn do
            "stoat refused a masquerade in #{endpoint.id} (#{error.message}), so this channel now " \
              "relays under a sender name prefix. Grant the bot the Masquerade permission to show " \
              "each sender under their own name and avatar."
          end
        end

        # The envelope Bonfire wraps several events in, most often a
        # ChannelCreate/ChannelDelete pair from a permission change. Processed
        # exactly like a standalone frame, recursively, so nothing inside it is
        # dropped.
        def handle_bulk(event)
          Array(event["v"]).filter_map { |item| handle_event(item) }
        end

        def build_inbound
          @inbound = Inbound.new(
            endpoint_for: method(:endpoint_for),
            user_resolver: method(:resolve_user),
            member_resolver: method(:resolve_member),
            mention_resolver: method(:resolve_mention),
            file_url: @client.method(:file_url),
            logger: logger
          )
        end

        def build_gateway
          Gateway.new(
            token: settings[:token],
            on_event: method(:handle_event),
            ws_base: settings[:ws_base] || Gateway::DEFAULT_WS_BASE,
            logger: logger,
            heartbeat: settings[:heartbeat] || Gateway::DEFAULT_HEARTBEAT
          )
        end

        # bulk_delete and bulk_delete_by_author_since both publish this, so
        # clearing a spammer's recent history arrives as one frame naming many
        # ids. Each becomes an ordinary delete, which is what discordrb does for
        # us on the Discord side.
        def handle_bulk_delete(event)
          channel = event["channel"]
          ids = Array(event["ids"])
          logger.info { "stoat bulk delete of #{ids.size} messages in #{channel}" } unless ids.empty?
          ids.filter_map { |id| emit_if(@inbound.delete("channel" => channel, "id" => id)) }
        end

        # Bonfire sends "Error" when the connection could not authenticate. Until
        # this branch existed the frame fell out of the case, so the only sign
        # was a socket that kept reopening.
        def handle_session_error(event)
          detail = event["error"] || event["data"] || "no reason given"
          logger.error do
            "stoat refused this gateway session (#{detail}). " \
              "Check the bot token in #{settings[:token_env]}."
          end
          @gateway&.note_refused(detail.to_s)
          nil
        end

        # "Logout" means the session was invalidated or the bot token was reset,
        # so every reconnect on this credential will be refused as well.
        def handle_logout(_event)
          logger.error do
            "stoat invalidated this gateway session, so the bot token in " \
              "#{settings[:token_env]} has been reset or revoked. This adapter is now receiving nothing."
          end
          @gateway&.note_refused("Logout")
          nil
        end

        # Download and upload each attachment, so it arrives on Stoat as a real
        # file rather than a link a Telegram source's credentialed URL cannot
        # even carry. Returns the attachments that made it across, the file ids
        # to send, and the ones that did not.
        def upload_attachments(attachments)
          uploaded = []
          file_ids = []
          missed = []
          attachments.each do |attachment|
            id = upload_one(attachment)
            if id
              uploaded << attachment
              file_ids << id
            else
              missed << attachment
            end
          end
          [uploaded, file_ids, missed]
        end

        def upload_one(attachment)
          @fetcher.with(attachment.url, filename: attachment.filename) do |file|
            @client.upload_file(file, filename: attachment.filename || file.original_filename,
                                     content_type: attachment.mime_type || "application/octet-stream")
          end
        rescue AdapterError => e
          logger.info { "stoat: could not upload #{attachment.label}: #{e.message}" }
          nil
        end

        # Remember that a file could not be relayed, so the router can tell the
        # person who sent it.
        def note_failed_upload(attachment)
          size = attachment.size
          limit = upload_limit
          reason =
            if size && size > limit
              "it is #{format_bytes(size)}, over this bridge's #{format_bytes(limit)} limit"
            else
              "the upload failed"
            end
          @pending_notes << "could not relay #{attachment.label} to Stoat: #{reason}"
        end

        def drain_notes
          notes = @pending_notes
          @pending_notes = []
          notes
        end

        def format_bytes(bytes)
          units = %w[B KB MB GB]
          value = bytes.to_f
          unit = 0
          while value >= 1024 && unit < units.size - 1
            value /= 1024
            unit += 1
          end
          "#{value.round(value < 10 && unit.positive? ? 1 : 0)}#{units[unit]}"
        end

        # A live message is a passive channel sighting, resolved through
        # @channel_servers ("Ready" bulk syncs at connect, "ServerCreate" and
        # "ChannelCreate" cover later additions). A DM to the bot owns no
        # channel, so it misses the resolver and would be dropped; with a
        # control lane wired it is handled there instead.
        def handle_message(event)
          return handle_control_gesture(event) if control_gesture?(event)

          learn_channel_from_message(event) if discovery
          @inbound.message(event)
        end

        # Only when a lane is wired, the author is not this bot's own account,
        # the channel is a DM, and there is text worth handing over.
        def control_gesture?(event)
          return false if control_lane.nil?
          return false if own_author?(event["author"])
          return false unless dm_channel?(event["channel"])

          !event["content"].to_s.strip.empty?
        end

        def own_author?(user_id)
          !user_id.nil? && user_id.to_s == @own_account_id.to_s
        end

        # The lane is I/O free and returns text; sending is the adapter's job.
        # Never raises out: a control gesture must not take down the gateway.
        def handle_control_gesture(event)
          reply = control_lane.handle_dm(
            adapter: :stoat, account: account, author: control_gesture_author(event["author"]),
            text: event["content"].to_s
          )
          send_dm_reply(event["channel"], reply) if reply
          nil
        rescue StandardError => e
          logger.warn { "stoat: control gesture handling failed: #{e.class}: #{e.message}" }
          nil
        end

        def control_gesture_author(user_id)
          user = resolve_user(user_id)
          Core::Author.new(
            native_id: user_id,
            username: user && (user["username"] || user["name"]),
            display_name: user && presence(user["display_name"]),
            kind: :user
          )
        end

        def send_dm_reply(channel_id, text)
          return if channel_id.nil?

          @client.send_message(channel_id, content: text.to_s)
        rescue AdapterError => e
          logger.info { "stoat: could not reply to a DM control gesture: #{e.message}" }
        end

        # Whether +channel_id+ is a DM with the bot, cached so a busy unmapped
        # channel costs one fetch rather than one per message.
        def dm_channel?(channel_id)
          return false if channel_id.nil?

          key = channel_id.to_s
          cached = @cache_monitor.synchronize { @dm_channel_cache[key] }
          return cached unless cached.nil?

          channel = @client.fetch_channel(key)
          is_dm = channel.is_a?(Hash) && channel["channel_type"] == "DirectMessage"
          @cache_monitor.synchronize { @dm_channel_cache[key] = is_dm }
          is_dm
        end

        # Record every text channel of every server the bot can already see.
        def handle_ready(event)
          return nil if discovery.nil?

          index = index_channels(event["channels"])
          remember_channel_servers(index)
          Array(event["servers"]).each do |server|
            server_id = presence(server["_id"])
            next if server_id.nil?

            discover_server_channels(server_id, channels_of(server, index))
          end
          nil
        rescue StandardError => e
          logger.warn { "stoat: Ready discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        # The event carries only channel ids, so each is fetched over REST for its
        # name and type.
        def handle_server_created(event)
          return nil if discovery.nil? && pending_spaces.nil?

          server_id = presence(event["_id"])
          return nil if server_id.nil?

          channels = Array(event["channels"]).filter_map { |id| fetch_channel_for(id, server_id) }
          discover_server_channels(server_id, channels) if discovery
          pend_server(server_id, presence(event["name"]))
          nil
        rescue StandardError => e
          logger.warn { "stoat: ServerCreate discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        # Hand a newly joined server to the pending-review service and carry out
        # what it decided. A no-op with none wired, since there is no board.
        def pend_server(server_id, name)
          return if pending_spaces.nil?

          outcome = pending_spaces.on_join!(adapter: :stoat, account: account, external_id: server_id, name: name)
          if outcome.pending? && outcome.post_notice
            posted = post_space_notice(server_id, ControlPlane::PendingSpaces::PENDING_NOTICE)
            pending_spaces.mark_notice_posted!(outcome.row) if posted
          elsif outcome.leave?
            pending_spaces.reconfirm_denied!(outcome.row)
          end
        rescue StandardError => e
          logger.warn { "stoat: pending-space handling failed: #{e.class}: #{e.message}" }
        end

        # "ServerMemberJoin"/"ServerMemberLeave" name a server, never a channel,
        # so the membership message is fanned out to every bridged channel of
        # that server, one Core::Message each, the same set enumerate_space and
        # a space notice already resolve a server id to. Narrowed to the one
        # community that bridges the server first, since the event names none.
        def member_messages(event, kind)
          server_id = presence(event["id"])
          user_id = presence(event["user"])
          return [] if server_id.nil? || user_id.nil?

          author = member_author(user_id, event["member"])
          endpoints_in_server(server_id, kind).map do |endpoint|
            Core::Message.new(
              kind: kind, ref: Core::MessageRef.new(endpoint.id, "member-#{user_id}-#{Time.now.to_i}"),
              origin: endpoint, author: author, timestamp: Time.now, raw: event
            )
          end
        end

        # Every endpoint bridged to server_id, resolved the same way
        # #channel_ids_for_server and #post_space_notice already do.
        def endpoints_for_server(server_id)
          channel_ids_for_server(server_id).filter_map { |channel_id| endpoint_for(channel_id) }
        end

        # The same set, narrowed to the ONE community that bridges the server. A
        # server two tenants both map names neither of them, so the fan-out is
        # refused and logged rather than announcing one community's arrivals
        # and departures in the other's channels.
        def endpoints_in_server(server_id, kind)
          endpoints = endpoints_for_server(server_id)
          communities = endpoints.map(&:community_id).uniq
          return endpoints if communities.size <= 1

          logger.error do
            "stoat: REFUSED to fan a member #{kind} out from server #{server_id}, which serves rooms " \
              "of communities #{communities.map(&:inspect).join(", ")} and names none of them"
          end
          []
        end

        def member_author(user_id, member)
          user = resolve_user(user_id)
          nickname = member.is_a?(Hash) ? presence(member["nickname"]) : nil
          Core::Author.new(
            native_id: user_id,
            username: user && (user["username"] || user["name"]),
            nickname: nickname,
            display_name: nickname || (user && presence(user["display_name"])),
            kind: :user
          )
        end

        # A new channel in a known server: one sighting for the watch. Recorded
        # even without a discovery seam, since the DM-detection cache and
        # #guild_id_for_channel both read @channel_servers too.
        def handle_channel_created(event)
          return nil unless text_channel?(event)

          channel_id = presence(event["_id"])
          server_id = presence(event["server"])
          return nil if channel_id.nil? || server_id.nil?

          remember_channel_server(channel_id, server_id)
          return nil if discovery.nil?

          discovery.saw(adapter: :stoat, account: account, external_id: server_id,
                        route_key: channel_id, name: event["name"].to_s)
          nil
        rescue StandardError => e
          logger.warn { "stoat: ChannelCreate discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        # A message reveals the channel it lives in even when no ChannelCreate
        # was seen for it. Side effect only: it never consumes the event.
        def learn_channel_from_message(event)
          channel_id = presence(event["channel"])
          return if channel_id.nil?

          server_id = channel_server(channel_id)
          return if server_id.nil?

          discovery.saw(adapter: :stoat, account: account, external_id: server_id,
                        route_key: channel_id, name: nil)
        rescue StandardError => e
          logger.warn { "stoat: passive channel discovery failed: #{e.class}: #{e.message}" }
        end

        # Record a server's text channels through the discovery seam.
        def discover_server_channels(server_id, channels)
          return if discovery.nil? || channels.empty?

          discovery.inventory(adapter: :stoat, account: account, external_id: server_id, channels: channels)
        rescue StandardError => e
          logger.warn { "stoat: channel discovery for server #{server_id} failed: #{e.message}" }
        end

        # Fetch one channel by id, remember its server for the passive path, and
        # shape it for #discover_server_channels. nil for anything that is not a
        # text channel, or that the bot can no longer see.
        def fetch_channel_for(channel_id, server_id)
          channel = @client.fetch_channel(channel_id)
          return nil unless text_channel?(channel)

          remember_channel_server(channel_id.to_s, server_id)
          { id: channel_id.to_s, name: channel["name"].to_s }
        end

        # Ready's channels indexed by id, so a server's bare channel-id list can be
        # resolved to full channel objects.
        def index_channels(list)
          Array(list).each_with_object({}) do |channel, index|
            id = presence(channel["_id"])
            index[id] = channel unless id.nil?
          end
        end

        # Remember every text channel's server, so a passive Message sighting can
        # resolve a server id later. One lock acquisition for the whole batch.
        def remember_channel_servers(index)
          pairs = {}
          index.each_value do |channel|
            next unless text_channel?(channel)

            server_id = presence(channel["server"])
            pairs[channel["_id"].to_s] = server_id if server_id
          end
          @cache_monitor.synchronize { @channel_servers.merge!(pairs) }
        end

        # A server's channels shaped for .inventory. A category, a voice channel or
        # an id Ready carried no channel object for is skipped rather than guessed.
        def channels_of(server, index)
          Array(server["channels"]).filter_map do |channel_id|
            channel = index[channel_id.to_s]
            next nil if channel.nil? || !text_channel?(channel)

            { id: channel_id.to_s, name: channel["name"].to_s }
          end
        end

        # The only Stoat channel kind that maps to a room: a voice channel carries
        # no relayable text, and a group/DM/saved-messages channel has no server.
        def text_channel?(channel)
          channel.is_a?(Hash) && channel["channel_type"] == "TextChannel"
        end

        def presence(value)
          return nil if value.nil?

          string = value.to_s
          string.empty? ? nil : string
        end

        # Look up a user once and remember it. A stale display name is a cosmetic
        # miss the next restart corrects.
        def resolve_user(id)
          return nil if id.nil?

          key = id.to_s
          @cache_monitor.synchronize do
            return @user_cache[key] if @user_cache.key?(key)
          end
          fetched = @client.fetch_user(key)
          @cache_monitor.synchronize { @user_cache[key] = fetched }
          fetched
        end

        # The server member behind an author, cached the same way, since that is
        # where a nickname chosen inside this server lives. Nil where the
        # channel's server was never learned.
        def resolve_member(channel_id, user_id)
          server_id = server_of_channel(channel_id)
          return nil if server_id.nil? || user_id.nil?

          key = "#{server_id}/#{user_id}"
          @cache_monitor.synchronize do
            return @member_cache[key] if @member_cache.key?(key)
          end
          fetched = @client.fetch_member(server_id, user_id)
          @cache_monitor.synchronize { @member_cache[key] = fetched }
          fetched
        end

        # Turn a Stoat mention id into something readable, injected into
        # Inbound#parse_markdown as its resolver (see #build_inbound). Only
        # ever sees :user: Stoat carries no role or channel mention token of
        # its own, so the shared parser's other mention kinds never fire here.
        # #resolve_member and #resolve_user are live REST lookups, unlike
        # Discord's gateway cache reads, so a network hiccup here must not take
        # the whole message down with it.
        def resolve_mention(type, id, channel_id: nil)
          return nil unless type == :user

          stoat_mention_name(id, channel_id: channel_id)
        rescue StandardError => e
          logger.warn { "stoat: mention resolution failed for #{id} in channel #{channel_id.inspect}: #{e.message}" }
          "@#{id}"
        end

        # The server MEMBER's nickname wins over the bot wide user's account name,
        # the same #member_author already prefers for the author line: that is what
        # a Stoat client actually shows for a mention. Falls back to the account
        # name when no member is cached, and to the raw id rather than a silent
        # generic marker when neither resolves: a never-seen member still deserves
        # an honest, loggable trace instead of the shared parser's "@unknown-user".
        def stoat_mention_name(id, channel_id: nil)
          nickname = mention_member_nickname(channel_id, id)
          return "@#{nickname}" if nickname

          name = mention_user_name(id)
          return "@#{name}" if name

          logger.warn do
            "stoat: could not resolve a mention of #{id} in channel #{channel_id.inspect}; " \
              "the bot has not seen this member or user"
          end
          "@#{id}"
        end

        def mention_member_nickname(channel_id, id)
          return nil if channel_id.nil?

          member = resolve_member(channel_id, id)
          member.is_a?(Hash) ? presence(member["nickname"]) : nil
        end

        def mention_user_name(id)
          user = resolve_user(id)
          return nil unless user.is_a?(Hash)

          presence(user["display_name"]) || presence(user["username"]) || presence(user["name"])
        end

        # A Message event names no server, so the server comes from what discovery
        # learned, falling back to whatever the endpoint was configured with.
        def server_of_channel(channel_id)
          return nil if channel_id.nil?

          key = channel_id.to_s
          channel_server(key) || presence(endpoint_for(key)&.settings&.[](:server_id))
        end

        # @channel_servers is written from the gateway thread and read from
        # that thread and from the durable scheduler (enumerate_space), so
        # every access goes through @cache_monitor.
        def channel_server(channel_id) = @cache_monitor.synchronize { @channel_servers[channel_id] }

        def remember_channel_server(channel_id, server_id)
          @cache_monitor.synchronize { @channel_servers[channel_id] = server_id }
        end

        def channel_ids_for_server(server_id)
          @cache_monitor.synchronize { @channel_servers.select { |_channel_id, server| server == server_id }.keys }
        end

        # Unicode only: a foreign custom emoji is skipped rather than failing.
        def react(channel, message_id, reaction)
          token = reaction_token(reaction)
          return if token.nil?

          @client.add_reaction(channel, message_id, token)
        end

        def unreact(channel, message_id, reaction)
          token = reaction_token(reaction)
          return if token.nil?

          @client.remove_own_reaction(channel, message_id, token)
        end

        def reaction_token(reaction)
          return nil if reaction.custom?

          reaction.emoji
        end

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        def moderate_delete(endpoint, native_id)
          delete(endpoint, native_id)
          ok(endpoint)
        end

        def moderate_ban(command, endpoint)
          server = server_for(endpoint)
          @client.ban_member(server, command.target_user_id, reason: "bridged /ban by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_unban(command, endpoint)
          server = server_for(endpoint)
          @client.unban_member(server, command.target_user_id)
          ok(endpoint)
        end

        def moderate_kick(command, endpoint)
          server = server_for(endpoint)
          @client.kick_member(server, command.target_user_id)
          ok(endpoint)
        end

        DEFAULT_MUTE_MINUTES = 60

        def moderate_mute(command, endpoint)
          server = server_for(endpoint)
          until_time = (Time.now.utc + (mute_minutes(command) * 60)).iso8601(3)
          @client.timeout_member(server, command.target_user_id, until_time)
          ok(endpoint)
        end

        def moderate_unmute(command, endpoint)
          server = server_for(endpoint)
          @client.clear_timeout(server, command.target_user_id)
          ok(endpoint)
        end

        def mute_minutes(command)
          value = command.arguments.first.to_i
          value.positive? ? value : DEFAULT_MUTE_MINUTES
        end

        def moderate_pin(endpoint, native_id, pinned:)
          channel = endpoint.settings[:channel_id]
          pinned ? @client.pin_message(channel, native_id) : @client.unpin_message(channel, native_id)
          ok(endpoint)
        end

        def server_for(endpoint)
          server = endpoint.settings[:server_id]
          if server.nil?
            raise AdapterError.new("no server_id configured for #{endpoint.id}, which ban/kick/mute needs",
                                   adapter: :stoat)
          end

          server
        end

        def build_index(endpoints)
          endpoints.each_with_object({}) do |endpoint, index|
            index[endpoint.settings[:channel_id].to_s] = endpoint
          end
        end

        # With a live resolver injected this reads the current Snapshot (the Stoat
        # route_key is the channel id); without one it reads the boot time index.
        def endpoint_for(channel_id)
          if @endpoint_resolver
            return nil if channel_id.nil?

            return @endpoint_resolver.endpoint_for(:stoat, account, channel_id.to_s)
          end

          return nil if channel_id.nil?

          @index[channel_id.to_s]
        end

        # The shared answer, so this adapter cannot drift a little wider than
        # the others and start swallowing refusals with it.
        def gone?(error) = AlreadyGone.call(error)
      end
    end
  end
end
