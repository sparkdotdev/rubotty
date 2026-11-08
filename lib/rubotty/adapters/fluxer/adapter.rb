# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Fluxer
      # The Fluxer platform adapter. Fluxer is shaped like Discord: guilds
      # hold channels, one bot token, a WebSocket gateway, and per sender
      # identity by webhook, so it reuses the Discord Markdown parser and
      # renderer. Channel discovery has both halves: the bot enumerates a
      # guild's channels over REST when it connects and when it is added to
      # one, and every message shaped dispatch sights the channel it arrived
      # in.
      class Adapter < Adapters::Base
        class << self
          def supports_leave? = true
          def supports_space_notice? = true

          def adapter_name = :fluxer

          # A missing token leaves this account dormant rather than refusing the
          # whole configuration, the same as every other credentialed adapter.
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :token_env, :string, required: true, env: true,
                                         desc: "name of the environment variable holding the bot token"
              field :api_base, :string, default: Client::DEFAULT_API_BASE,
                                        desc: "override for a self hosted Fluxer API server"
              field :gateway_url, :string,
                    desc: "override the gateway URL rather than fetching it from /gateway/bot"
              field :webhook_name, :string, default: "rubotty",
                                            desc: "name given to webhooks this bridge creates"
              # Accepted and ignored. Fluxer has no intent concept, so nothing is
              # sent for this, but refusing the key would fail a deployment whose
              # stored account still carries it.
              field :intents, :integer,
                    desc: "ignored: Fluxer subscribes to everything and opts out per event instead"
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :channel_id, :string, required: true, desc: "Fluxer channel id (a snowflake)"
              field :guild_id, :string,
                    desc: "guild the channel belongs to, required only for ban/kick moderation"
              field :webhook, :symbol, default: :auto, one_of: %i[auto off],
                                       desc: "post relayed messages under each sender's own name via " \
                                             "a channel webhook. Falls back to bot posting when not permitted."
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages when " \
                                                    "posting as the bot"
              field :sender_separator, :string, default: ":", desc: "printed after the sender name"
              field :allow_mass_mentions, :boolean, default: false,
                                                    desc: "permit relayed text to ping everyone. Leave " \
                                                          "false unless you are certain."
            end
          end

          def validate_endpoint(settings, path)
            id = settings[:channel_id].to_s
            return [] if id.match?(/\A\d{5,}\z/)

            ["#{path}.channel_id: expected a Fluxer snowflake (a long number), got #{id.inspect}"]
          end

          def discovers_channels? = true

          def route_key_for(endpoint) = endpoint.settings[:channel_id].to_s

          # Mirrors Discord's addressing: guild_id is left for an operator to
          # fill in, since it is needed only for ban/kick.
          def addressing(route_key, external_id: nil)
            { "channel_id" => route_key.to_s }
          end

          def supports_space_enumeration? = true
          def supports_admin_dm? = true

          # A DM channel is a channel like any other here too.
          def supports_admin_dm_delete? = true

          def accepts_pending_spaces? = true
        end

        # Fluxer's own singlepart upload ceiling (fluxer_api's
        # ATTACHMENT_UPLOAD_CHUNK_THRESHOLD): a file at or under this rides one
        # multipart POST alongside the message. A bot may go up to 50 MB, but
        # that needs the presigned chunked-upload dance this adapter does not
        # implement, so the ceiling declared here stops short of it.
        MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024

        # Fluxer's cap on attachments carried by one message.
        MAX_UPLOAD_FILES = 10

        CAPABILITIES = Capabilities.new(
          edits: true,
          deletes: true,
          replies: true,
          threads: false,
          max_attachment_bytes: MAX_ATTACHMENT_BYTES,
          reactions: true,
          max_reactions: nil,
          custom_reactions: true,
          # Webhook execute and edit, the same shape as Discord's.
          puppets_send: true,
          puppets_edit: true,
          moderation: %i[delete ban unban kick pin unpin mute unmute],
          # No application-command resource exists: /applications/{id}/commands
          # answers 404, so there is nothing to publish CommandRegistry into.
          command_list: false,
          # The "/" menu is a fixed list compiled into the Fluxer client, and
          # /ban, /kick and /nick in it are command names of ours, so "/" never
          # reaches the bot and help text prints "!" here.
          reserved_command_prefixes: ["/"]
        ).freeze

        # Fluxer's channel type numbers, from its own ChannelConstants rather than
        # Discord's. Only a guild text channel carries relayable text, so a
        # category (4), a voice channel (2) and a link (998) are never bridgeable.
        GUILD_TEXT_CHANNEL = 0

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil,
                       pending_spaces: nil)
          super
          @client = Client.new(
            token: settings[:token],
            api_base: settings[:api_base] || Client::DEFAULT_API_BASE,
            logger: logger
          )
          @outbound = Outbound.new(logger: logger)
          @index = build_index(endpoints)
          @user_cache = {}
          @member_cache = {}
          @channel_names = {}
          @enumerated_guilds = {}
          @guild_names = {}
          @guild_member_counts = {}
          @cache_monitor = Monitor.new
          @gateway = nil
          @own_account_id = nil
          @webhooks = Webhook.new(client: @client, logger: logger,
                                  bridge_name: settings[:webhook_name] || "rubotty")
          @fetcher = Util::MediaFetcher.new(limit: MAX_ATTACHMENT_BYTES, logger: logger)
          @pending_notes = []
          build_inbound
        end

        attr_reader :client

        # See Adapters::Discord::Adapter#puppet_snapshot, the same contract.
        def puppet_snapshot = @webhooks.puppet_snapshot

        def replace_client(client)
          @client = client
          @webhooks = Webhook.new(client: client, logger: logger,
                                  bridge_name: settings[:webhook_name] || "rubotty")
          build_inbound
          self
        end

        def replace_gateway(gateway)
          @gateway = gateway
          self
        end

        def capabilities = CAPABILITIES

        def own_account_id = @own_account_id

        def running? = !@gateway.nil? && @gateway.running?

        # The gateway websocket.
        def persistent_connection? = true

        # List one guild's channels again, for a space whose first listing was
        # dropped because it had no platform connection yet.
        def enumerate_space(external_id)
          guild_id = presence(external_id)
          return false if guild_id.nil? || discovery.nil?

          discover_guild_channels(guild_id, force: true)
          true
        end

        def supports_leave? = self.class.supports_leave?

        # Post +notice+ (nil skips the post) then leave the guild. True once the
        # leave call itself succeeds; a failed post never blocks it.
        def leave_space(external_id, notice: nil)
          post_space_notice(external_id, notice) if notice
          @client.leave_guild(external_id)
          logger.info { "fluxer: left guild #{external_id}" }
          true
        rescue StandardError => e
          logger.warn { "fluxer: could not leave guild #{external_id}: #{e.message}" }
          false
        end

        def supports_space_notice? = self.class.supports_space_notice?

        # Post +text+ into +external_id+'s first text channel; Fluxer has no
        # guild wide announcement, so this is the same "pick a channel" fallback
        # Discord's own post_guild_notice uses.
        def post_space_notice(external_id, text)
          return false if text.to_s.strip.empty?

          channel_id = first_text_channel(external_id)
          return false if channel_id.nil?

          !@client.send_message(channel_id, content: text.to_s).nil?
        rescue StandardError => e
          logger.info { "fluxer: could not post a space notice in guild #{external_id}: #{e.message}" }
          false
        end

        def start
          @own_account_id = @client.own_id
          if @own_account_id.nil?
            raise AdapterError.new(
              "connected to Fluxer but never learned the bot's own user id, so loop prevention " \
              "would be unsafe. Check the token in #{settings[:token_env]}.",
              adapter: :fluxer
            )
          end
          @gateway ||= build_gateway
          @gateway.start
          logger.info { "signed in to Fluxer as #{@own_account_id} via #{@gateway.describe}" }
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Fluxer adapter failed to start: #{e.class}: #{e.message}", adapter: :fluxer)
        end

        def stop
          @gateway&.stop
          @gateway = nil
          self
        end

        def deliver(message, endpoint)
          # A notice the bridge itself is saying always posts as the bot, never
          # through a webhook, so loop prevention by author id recognises it.
          return deliver_as_bot(message, endpoint) if message.system_notice?

          hook = @webhooks.for(endpoint)
          return deliver_via_webhook(message, endpoint, hook) if hook

          deliver_as_bot(message, endpoint)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Fluxer send failed: #{e.class}: #{e.message}", adapter: :fluxer, retryable: true)
        end

        def edit(message, endpoint, native_id)
          return edit_as_bot(message, endpoint, native_id) if message.system_notice?

          hook = @webhooks.for(endpoint)
          if hook
            @webhooks.edit(hook, native_id,
                           content: @outbound.compose(message, endpoint, webhook: true, editing: true),
                           allowed_mentions: @outbound.allowed_mentions(message, endpoint))
            return Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
          end

          edit_as_bot(message, endpoint, native_id)
        rescue AdapterError => e
          return nil if gone?(e)

          raise
        end

        def delete(endpoint, native_id)
          @client.delete_message(endpoint.settings[:channel_id], native_id)
          nil
        rescue AdapterError => e
          return nil if gone?(e)

          # A webhook message the bot cannot delete can be deleted by the webhook
          # that created it.
          hook = @webhooks.for(endpoint)
          if hook
            begin
              @webhooks.delete(hook, native_id)
              return nil
            rescue AdapterError => inner
              return nil if gone?(inner)

              raise
            end
          end
          raise
        end

        # DM +text+ to +native_id+: open the DM channel, Discord shaped like
        # every other Fluxer channel, then post to it the same way
        # #deliver_as_bot does.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          channel = @client.create_dm(native_id)
          channel_id = channel && channel["id"]
          return dm_refused(native_id, "no DM channel opened") if channel_id.nil?

          sent = @client.send_message(channel_id, content: text.to_s)
          return dm_refused(native_id, "the DM channel took no message") if sent.nil? || sent["id"].nil?

          Core::DmReceipt.new(native_id: sent["id"], channel_ref: channel_id)
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

          logger.info { "fluxer: could not delete a DM: #{e.message}" }
          false
        end

        # Fluxer's reaction model is incremental, so the declarative request
        # becomes a diff. A refusal (a 403, a 429) has to raise rather than
        # being swallowed: the bridge records the aggregate as placed on any
        # non-raising return, so storage would end up believing in an emoji
        # that is not on the message; only an already-gone message is tolerated.
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
          when :pin then moderate_pin(endpoint, native_id, pinned: true)
          when :unpin then moderate_pin(endpoint, native_id, pinned: false)
          when :mute then moderate_timeout(command, endpoint, minutes: mute_minutes(command))
          when :unmute then moderate_timeout(command, endpoint, minutes: nil)
          else
            Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end
        rescue PermissionError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :forbidden, detail: e.message)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (fluxer channel #{endpoint.settings[:channel_id]})"
        end

        # Entry point the gateway drives, one dispatch event ({"t","d"}) at a time.
        def handle_event(event)
          return nil unless event.is_a?(Hash)

          payload = event["d"]
          return nil unless payload.is_a?(Hash)

          # Fed from every dispatch event carrying a channel_id. Never consumes or
          # alters the event.
          discover_channel_sighting(payload) if discovery

          name = event["t"].to_s.downcase
          # One frame naming many ids, so it cannot become a single message.
          return handle_bulk_delete(payload) if name == "message_delete_bulk"

          produced =
            case name
            when "ready" then sweep_guilds
            when "guild_create" then handle_guild_created(payload)
            when "message_create" then handle_message_create(payload)
            when "message_update" then handle_message_update(payload)
            when "message_delete" then @inbound.delete(payload)
            when "message_reaction_add" then @inbound.reaction(payload, :reaction_add)
            when "message_reaction_remove" then @inbound.reaction(payload, :reaction_remove)
            when "message_reaction_remove_all", "message_reaction_remove_emoji"
              @inbound.reaction_clear(payload)
            when "message_reaction_add_many" then handle_reaction_add_many(payload)
            when "guild_member_add" then handle_member_change(payload, :join)
            when "guild_member_remove" then handle_member_change(payload, :leave)
            else
              logger.debug { "unhandled Fluxer event type #{event["t"].inspect}" }
              nil
            end
          emit_if(produced)
        end

        def emit_if(message)
          return nil if message.nil?

          emit(message)
          message
        rescue StandardError => e
          logger.error { "error handling a Fluxer event: #{e.class}: #{e.message}" }
          nil
        end

        # The guild's member count, for RehostedFiles' download-serve ceiling;
        # see ControlPlane::CommunityMembers. Fluxer's REST API carries no
        # per-guild count, so this only ever answers what a GUILD_CREATE
        # already delivered, nil until one has.
        def community_member_count(guild_id) = cached_member_count(guild_id)

        private

        # MESSAGE_DELETE_BULK is how a moderator clearing a raid reaches us, so
        # each id becomes an ordinary delete and the copies mirrored elsewhere
        # come down with the originals. discordrb already does this expansion for
        # us on the Discord side.
        def handle_bulk_delete(payload)
          ids = Array(payload["ids"])
          unless ids.empty?
            logger.info { "fluxer bulk delete of #{ids.size} messages in #{payload["channel_id"]}" }
          end
          ids.filter_map { |id| emit_if(@inbound.delete(payload.merge("id" => id))) }
        end

        def build_inbound
          @inbound = Inbound.new(
            endpoint_for: method(:endpoint_for),
            resolver: method(:resolve_mention),
            user_for: method(:resolve_user),
            own_webhook: ->(id, channel) { @webhooks.own_message?(id, channel: channel) },
            logger: logger
          )
        end

        def build_gateway
          url = @client.gateway_url || settings[:gateway_url]
          if url.nil?
            raise AdapterError.new("Fluxer did not return a gateway URL and none is configured", adapter: :fluxer)
          end

          Gateway.new(url: url, token: settings[:token], on_event: method(:handle_event),
                      logger: logger)
        end

        # Record one channel sighting; a discovery hiccup must never break
        # relay. Skipped entirely when the payload carries no guild_id: a DM
        # is a channel like any other dispatch shaped event, but it belongs
        # to no guild, and inventing one only pends a review row for
        # somebody's inbox.
        def discover_channel_sighting(payload)
          channel_id = payload["channel_id"]
          return nil if channel_id.nil?

          guild_id = presence(payload["guild_id"])
          return nil if guild_id.nil?

          discovery.saw(
            adapter: :fluxer, account: account, external_id: guild_id,
            route_key: channel_id.to_s, name: channel_name_for(channel_id.to_s)
          )
          nil
        rescue StandardError => e
          logger.warn { "fluxer: channel discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        # The channel's name, if a guild enumeration has already listed it, or nil
        # otherwise. Never asks the API itself: backfill_name fills the name in
        # from a later sighting once an enumeration has caught up.
        def channel_name_for(channel_id)
          @cache_monitor.synchronize { @channel_names[channel_id] }
        end

        # Enumerate every guild the bot is in, once per connect. Fluxer hands a bot
        # an empty guild list in READY and a GUILD_CREATE per guild afterwards, so
        # the guilds are asked for over REST instead of read off the frame.
        def sweep_guilds
          return nil if discovery.nil?

          @cache_monitor.synchronize { @enumerated_guilds.clear }
          remember_guild_names(@client.list_guilds).each_key do |guild_id|
            discover_guild_channels(guild_id)
          end
          nil
        rescue StandardError => e
          logger.warn { "fluxer: guild enumeration at connect failed: #{e.class}: #{e.message}" }
          nil
        end

        # The bot was added to a guild, or one it is already in synced at connect.
        # The guild reaches the onboarding board straight away, and its channels
        # are recorded so the mapping wizard lists real ones.
        def handle_guild_created(payload)
          guild_id = presence(payload["id"])
          return nil if guild_id.nil?

          count = member_count_of(payload)
          remember_member_count(guild_id, count)
          pend_guild(guild_id, guild_name_for(guild_id, payload), count)
          discover_guild_channels(guild_id)
          nil
        rescue StandardError => e
          logger.warn { "fluxer: guild-add handling failed: #{e.class}: #{e.message}" }
          nil
        end

        # The guild's title. GUILD_CREATE arrives with a nil name on a lazy guild
        # object, so the REST listing is asked first and the frame is the fallback.
        def guild_name_for(guild_id, payload)
          cached = @cache_monitor.synchronize { @guild_names[guild_id] }
          return cached unless cached.nil?

          remember_guild_names(@client.list_guilds)[guild_id] || presence(payload["name"])
        rescue StandardError => e
          logger.info { "fluxer: could not read the name of guild #{guild_id} over REST: #{e.message}" }
          presence(payload["name"])
        end

        # Index the REST guild listing by id, keeping the names it carries, and
        # answer that index so a caller can walk the guilds it just listed.
        def remember_guild_names(guilds)
          named = Array(guilds).each_with_object({}) do |guild, index|
            next unless guild.is_a?(Hash)

            guild_id = presence(guild["id"])
            index[guild_id] = presence(guild["name"]) unless guild_id.nil?
          end
          @cache_monitor.synchronize { @guild_names.merge!(named.compact) }
          named
        end

        # Hand a guild to the pending-review service, a no-op with none wired since
        # there is no board for it to reach.
        def pend_guild(guild_id, name, member_count)
          return if pending_spaces.nil?

          outcome = pending_spaces.on_join!(
            adapter: :fluxer, account: account, external_id: guild_id, name: name,
            member_count: member_count, sample_channels: []
          )
          if outcome.pending? && outcome.post_notice
            post_pending_notice(guild_id, outcome.row)
          elsif outcome.leave?
            pending_spaces.reconfirm_denied!(outcome.row)
          end
        end

        def post_pending_notice(guild_id, row)
          posted = post_space_notice(guild_id, ControlPlane::PendingSpaces::PENDING_NOTICE)
          pending_spaces.mark_notice_posted!(row) if posted
        end

        # Record a guild's text channels through the discovery seam. A recorded
        # channel is in no room, so nothing bridges until an operator maps it.
        # +force+ skips the once-per-connect claim, for the sweep an approval asks
        # for after the connect-time listing was dropped.
        def discover_guild_channels(guild_id, force: false)
          return if discovery.nil?
          return unless force || claim_enumeration(guild_id)

          channels = text_channels_of(guild_id)
          return if channels.empty?

          discovery.inventory(adapter: :fluxer, account: account, external_id: guild_id, channels: channels)
        rescue StandardError => e
          logger.warn { "fluxer: channel discovery for guild #{guild_id} failed: #{e.class}: #{e.message}" }
        end

        # One guild's text channels as {id:, name:} hashes. A guild the bot may not
        # read, or one the API refuses, yields nothing and leaves the rest of the
        # sweep running.
        def text_channels_of(guild_id)
          channels = @client.list_guild_channels(guild_id)
          cache_channel_names(channels)
          channels.filter_map do |channel|
            next nil unless channel.is_a?(Hash) && channel["type"].to_i == GUILD_TEXT_CHANNEL

            id = presence(channel["id"])
            id.nil? ? nil : { id: id, name: channel["name"].to_s }
          end
        rescue AdapterError => e
          logger.warn { "fluxer: could not list the channels of guild #{guild_id}: #{e.message}" }
          []
        end

        # The first text channel of a guild, for posting a notice into a space
        # that has no guild wide announcement point.
        def first_text_channel(guild_id)
          text_channels_of(guild_id).first&.fetch(:id, nil)
        end

        # Remember every channel name a listing turns up, of any type, so a
        # passive sighting can carry the real name instead of an empty one. A
        # blank name never overwrites a name already in hand.
        def cache_channel_names(channels)
          return unless channels.is_a?(Array)

          @cache_monitor.synchronize do
            channels.each do |channel|
              next unless channel.is_a?(Hash)

              id = presence(channel["id"])
              next if id.nil?

              name = presence(channel["name"])
              @channel_names[id] = name unless name.nil?
            end
          end
        end

        # True the first time a guild is claimed on this connect, so the
        # GUILD_CREATE burst that follows a reconnect costs one listing per guild
        # rather than two.
        def claim_enumeration(guild_id)
          @cache_monitor.synchronize do
            next false if @enumerated_guilds.key?(guild_id)

            @enumerated_guilds[guild_id] = true
          end
        end

        # The guild's member count for the pending card, nil when the frame omits
        # it, which the dashboard shows as unknown.
        def member_count_of(payload)
          count = payload["member_count"]
          count.is_a?(Integer) ? count : nil
        end

        # Fluxer's REST guild listing carries no member count, so GUILD_CREATE
        # is the only frame this is ever read from; cached here so a count
        # asked for later, e.g. by RehostedFiles' serve ceiling, does not have
        # to wait for another connect.
        def remember_member_count(guild_id, count)
          @cache_monitor.synchronize { @guild_member_counts[guild_id] = count }
        end

        # Kept in step by the join/leave events the gateway already delivers,
        # so a long-lived connection's cached count does not go stale between
        # reconnects. A guild never snapshotted stays nil either way.
        def nudge_member_count(guild_id, delta)
          @cache_monitor.synchronize do
            current = @guild_member_counts[guild_id]
            @guild_member_counts[guild_id] = current + delta unless current.nil?
          end
        end

        def cached_member_count(guild_id)
          @cache_monitor.synchronize { @guild_member_counts[guild_id] }
        end

        def presence(value)
          return nil if value.nil?

          string = value.to_s.strip
          string.empty? ? nil : string
        end

        # A MESSAGE_CREATE dispatch: routed to the operator console first when it
        # is a DM the console owns, otherwise built into a canonical message the
        # normal way.
        def handle_message_create(payload)
          return nil if own_author?(payload["author"])
          return nil if handle_control_gesture(payload)

          @inbound.message(payload)
        end

        # An edit of the bridge's own copy comes back the same way a fresh one
        # does, so it needs the same authorship check ahead of it.
        def handle_message_update(payload)
          return nil if own_author?(payload["author"])

          @inbound.edit(payload)
        end

        # If +payload+ is a directed DM the control lane should own, hand it
        # over and answer true so the caller skips the normal routing. Never
        # raises out: a control gesture must not take down the receive loop.
        def handle_control_gesture(payload)
          return false unless control_gesture?(payload)

          reply = control_lane.handle_dm(
            adapter: :fluxer, account: account, author: author_for_dm(payload["author"]),
            text: payload["content"].to_s
          )
          send_dm_reply(payload["channel_id"], reply) if reply
          true
        rescue StandardError => e
          logger.warn { "fluxer: control gesture handling failed: #{e.class}: #{e.message}" }
          true
        end

        # Only when a lane is wired and the event is a non empty DM that is not
        # the bot's own reply coming back around.
        def control_gesture?(payload)
          return false if control_lane.nil?
          return false unless dm_payload?(payload)
          return false if own_author?(payload["author"])

          !payload["content"].to_s.strip.empty?
        end

        # A DM carries no guild_id, the same signal #discover_channel_sighting
        # uses to keep a DM out of channel discovery's guild bucket.
        def dm_payload?(payload)
          presence(payload["guild_id"]).nil?
        end

        def own_author?(author)
          !@own_account_id.nil? && author.is_a?(Hash) && author["id"].to_s == @own_account_id.to_s
        end

        def author_for_dm(user)
          return nil if user.nil?

          Core::Author.new(
            native_id: user["id"], username: user["username"] || user["name"],
            display_name: user["global_name"] || user["display_name"], kind: :user
          )
        end

        # Send the lane's reply back into the DM channel as the bot. A failed
        # reply must not take down the gateway thread.
        def send_dm_reply(channel_id, text)
          return if channel_id.nil?

          @client.send_message(channel_id, content: text.to_s)
        rescue StandardError => e
          logger.warn { "fluxer: could not reply to a DM control gesture: #{e.message}" }
        end

        # MESSAGE_REACTION_ADD_MANY: the gateway's debounced batch of reactions
        # placed close together, one reaction_add per entry through the same
        # Inbound#reaction a live add uses. Emits each directly rather than
        # returning one message, since a batch is not one event.
        def handle_reaction_add_many(payload)
          channel_id = payload["channel_id"]
          message_id = payload["message_id"]
          guild_id = payload["guild_id"]
          Array(payload["reactions"]).each do |entry|
            next unless entry.is_a?(Hash)

            single = { "channel_id" => channel_id, "message_id" => message_id, "guild_id" => guild_id,
                       "user_id" => entry["user_id"], "emoji" => entry["emoji"] }
            emit_if(@inbound.reaction(single, :reaction_add))
          end
          nil
        rescue StandardError => e
          logger.warn { "fluxer: could not handle a batched reaction add: #{e.class}: #{e.message}" }
          nil
        end

        # GUILD_MEMBER_ADD or GUILD_MEMBER_REMOVE: a guild wide event with no
        # channel_id of its own, so every endpoint bridged in that guild is
        # given its own join or leave message. Emits directly for the same
        # reason #handle_reaction_add_many does.
        def handle_member_change(payload, kind)
          guild_id = presence(payload["guild_id"])
          return nil if guild_id.nil?

          nudge_member_count(guild_id, kind == :join ? 1 : -1)
          endpoints_in_guild(guild_id, kind).each { |endpoint| emit_if(@inbound.member(payload, kind, endpoint)) }
          nil
        rescue StandardError => e
          logger.warn { "fluxer: member #{kind} handling failed: #{e.class}: #{e.message}" }
          nil
        end

        # Every endpoint bridged into +guild_id+, so a guild scoped event
        # (which carries no channel_id of its own) can still be routed. An
        # endpoint that set guild_id itself (what ban and kick need) matches
        # directly, no request required. guild_id is documented as optional,
        # needed only for moderation, so a plain relay endpoint configured
        # with channel_id alone is resolved the other way: by checking
        # whether its channel is one of this guild's, the same live listing
        # #first_text_channel already reaches for.
        def endpoints_for_guild(guild_id)
          by_setting = every_endpoint.select { |endpoint| endpoint.settings[:guild_id].to_s == guild_id }
          channel_only = every_endpoint.reject { |endpoint| presence(endpoint.settings[:guild_id]) }
          return by_setting if channel_only.empty?

          member_channel_ids = text_channels_of(guild_id).map { |channel| channel[:id] }
          by_channel = channel_only.select do |endpoint|
            member_channel_ids.include?(endpoint.settings[:channel_id].to_s)
          end
          (by_setting + by_channel).uniq(&:id)
        end

        # The same set, narrowed to the ONE community that bridges the guild,
        # since a guild-wide event carries no channel and so names no tenant.
        # Two of them and the fan-out is refused and logged rather than
        # announcing one community's arrivals in the other's channels.
        def endpoints_in_guild(guild_id, kind)
          endpoints = endpoints_for_guild(guild_id)
          communities = endpoints.map(&:community_id).uniq
          return endpoints if communities.size <= 1

          logger.error do
            "fluxer: REFUSED to fan a member #{kind} out from guild #{guild_id}, which serves rooms " \
              "of communities #{communities.map(&:inspect).join(", ")} and names none of them"
          end
          []
        end

        def every_endpoint
          return @index.values if @endpoint_resolver.nil?

          @endpoint_resolver.endpoints_for(:fluxer, account).map { |(_route_key, endpoint)| endpoint }
        end

        def deliver_as_bot(message, endpoint)
          body = @outbound.send_body(message, endpoint)
          uploadable = message.attachments.select(&:resolvable?)
          channel_id = endpoint.settings[:channel_id]
          # Nothing to send by design, so Bridge must not record a loss. An
          # attachment with no caption still has something real to send.
          return Core::DeliveryReceipt::NOT_APPLICABLE if body[:content].to_s.strip.empty? && uploadable.empty?

          sent = uploadable.empty? ? send_text(channel_id, body) : send_with_files(channel_id, body, uploadable)
          return nil if sent.nil? || sent["id"].nil?

          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: sent["id"], extra: { notes: drain_notes })
        end

        def send_text(channel_id, body)
          return nil if body[:content].to_s.strip.empty?

          @client.send_message(channel_id, body)
        end

        def deliver_via_webhook(message, endpoint, hook)
          username = webhook_username(message)
          avatar = Util::SafeUrl.public(message.author&.avatar_url)
          body = @outbound.webhook_body(message, endpoint, username: username, avatar_url: avatar)
          uploadable = message.attachments.select(&:resolvable?)
          # Nothing to send by design, so Bridge must not record a loss. An
          # attachment with no caption still has something real to send.
          return Core::DeliveryReceipt::NOT_APPLICABLE if body[:content].to_s.strip.empty? && uploadable.empty?

          sent = uploadable.empty? ? send_webhook_text(hook, body) : send_webhook_with_files(hook, body, uploadable)
          return nil if sent.nil? || sent["id"].nil?

          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: sent["id"], extra: { notes: drain_notes })
        rescue AdapterError => e
          # A webhook removed in the channel settings must not cost the message.
          logger.warn { "webhook delivery to #{endpoint.id} failed (#{e.message}), posting as the bot" }
          @webhooks.forget(endpoint)
          deliver_as_bot(message, endpoint)
        end

        def send_webhook_text(hook, body)
          return nil if body[:content].to_s.strip.empty?

          @webhooks.execute(hook, body)
        end

        # Uploads the resolvable attachments as real files, alongside the
        # caption, in one multipart send. An attachment the fetcher could not
        # produce a file for falls back to a text reference instead, so the room
        # still learns something was meant to be there.
        def send_with_files(channel_id, body, attachments)
          files, prepared, fetched = prepare_upload(body, attachments)
          return @client.send_message(channel_id, prepared) if files.empty?

          @client.send_message_with_files(channel_id, prepared, files)
        ensure
          release_all(fetched)
        end

        def send_webhook_with_files(hook, body, attachments)
          files, prepared, fetched = prepare_upload(body, attachments)
          return @webhooks.execute(hook, prepared) if files.empty?

          @webhooks.execute_files(hook, prepared, files)
        ensure
          release_all(fetched)
        end

        # Downloads every attachment, builds the file parts the wire format
        # wants, and folds a fallback reference line into the caption for any
        # that could not be fetched. +body+'s content is replaced, never
        # appended blind, so a caption that was already empty stays readable.
        def prepare_upload(body, attachments)
          fetched, missed = fetch_uploadable(attachments)
          files = fetched.map { |entry| file_part(entry) }
          content = clamp_with_fallbacks(body[:content].to_s, missed)
          missed.each { |attachment| note_failed_upload(attachment) }
          [files, body.merge(content: content), fetched]
        end

        def release_all(fetched)
          Array(fetched).each { |entry| release_fetched(entry[:file]) }
        end

        # Only the first MAX_UPLOAD_FILES are even attempted; the rest are
        # reported the same way a failed download is.
        def fetch_uploadable(attachments)
          list = Array(attachments)
          fetched = []
          missed = list.drop(MAX_UPLOAD_FILES)
          list.first(MAX_UPLOAD_FILES).each do |attachment|
            file = @fetcher.fetch(attachment.url, filename: attachment.filename)
            file.nil? ? missed << attachment : fetched << { attachment: attachment, file: file }
          end
          [fetched, missed]
        end

        def file_part(entry)
          { filename: entry[:attachment].filename || entry[:attachment].label,
            mime_type: entry[:attachment].mime_type, io: entry[:file] }
        end

        def release_fetched(file)
          file.close
          file.unlink
        rescue StandardError
          nil
        end

        def clamp_with_fallbacks(content, missed)
          return content if missed.empty?

          lines = missed.map { |attachment| attachment_reference(attachment) }
          @outbound.clamp([content, *lines].reject(&:empty?).join("\n"))
        end

        # A link when the source URL carries no secret, otherwise a bare marker.
        # A Telegram file URL embeds the bot token, so relaying it would put a
        # working credential into channel history for good.
        def attachment_reference(attachment)
          Util::SafeUrl.public(attachment.url) || "[#{attachment.label}, could not be relayed]"
        end

        # Remember that a file could not be relayed, so the router can tell the
        # sender. Without this the sender believes the file crossed.
        def note_failed_upload(attachment)
          size = attachment.size
          reason = if size && size > MAX_ATTACHMENT_BYTES
                     "it is over this bridge's #{MAX_ATTACHMENT_BYTES / (1024 * 1024)}MB limit"
                   else
                     "the upload failed"
                   end
          @pending_notes << "could not relay #{attachment.label} to Fluxer: #{reason}"
        end

        def drain_notes
          notes = @pending_notes
          @pending_notes = []
          notes
        end

        def edit_as_bot(message, endpoint, native_id)
          @client.edit_message(endpoint.settings[:channel_id], native_id, @outbound.edit_body(message, endpoint))
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
        end

        def webhook_username(message)
          label = message.sender_label
          name = label.nil? ? "" : label.to_s
          name = message.author&.any_name.to_s if name.strip.empty?
          @webhooks.sanitise_username(name, fallback: "bridge")
        end

        def react(channel, message_id, reaction)
          @client.add_reaction(channel, message_id, reaction_token(reaction))
        end

        def unreact(channel, message_id, reaction)
          @client.remove_own_reaction(channel, message_id, reaction_token(reaction))
        end

        # Fluxer identifies a custom emoji as "name:id" and a unicode one by the
        # character.
        def reaction_token(reaction)
          reaction.custom? ? "#{reaction.custom_name}:#{reaction.custom_id}" : reaction.emoji
        end

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        def moderate_delete(endpoint, native_id)
          delete(endpoint, native_id)
          ok(endpoint)
        end

        def moderate_ban(command, endpoint)
          @client.ban_member(guild_for(endpoint), command.target_user_id, reason: "bridged /ban by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_unban(command, endpoint)
          @client.unban_member(guild_for(endpoint), command.target_user_id)
          ok(endpoint)
        end

        def moderate_kick(command, endpoint)
          @client.kick_member(guild_for(endpoint), command.target_user_id)
          ok(endpoint)
        end

        def moderate_pin(endpoint, native_id, pinned:)
          channel_id = endpoint.settings[:channel_id]
          pinned ? @client.pin_message(channel_id, native_id) : @client.unpin_message(channel_id, native_id)
          ok(endpoint)
        end

        # Fluxer has a timeout rather than a mute: the member cannot speak
        # until a moment in the future, and lifting it sets that moment to nil.
        def moderate_timeout(command, endpoint, minutes:)
          until_time = minutes.nil? ? nil : (Time.now + (minutes * 60)).utc.iso8601
          @client.timeout_member(guild_for(endpoint), command.target_user_id, until_time,
                                 reason: "bridged by #{command.issuer}")
          ok(endpoint)
        end

        MAX_TIMEOUT_MINUTES = 28 * 24 * 60
        DEFAULT_MUTE_MINUTES = 60

        def mute_minutes(command)
          value = command.arguments.first.to_i
          return DEFAULT_MUTE_MINUTES if value <= 0

          [value, MAX_TIMEOUT_MINUTES].min
        end

        def guild_for(endpoint)
          guild = endpoint.settings[:guild_id]
          if guild.nil?
            raise AdapterError.new("no guild_id configured for #{endpoint.id}, which ban/kick/mute needs",
                                   adapter: :fluxer)
          end

          guild
        end

        # Turn a mention id into a name for the parser; only users are resolved
        # today. Cached, a user the bot has never seen resolves to nil; +guild_id+,
        # when known, is what lets this read the per-guild member's nickname
        # instead of the bot-wide user's global name.
        def resolve_mention(type, id, guild_id: nil)
          return nil unless type == :user

          handle = member_handle(guild_id, id) || user_handle(id)
          handle && "@#{handle}"
        rescue StandardError
          nil
        end

        # The guild MEMBER's nickname wins over the bot-wide User's global name:
        # that is what Fluxer's own client shows for someone typed as a mention,
        # and a bot-wide User carries no per-guild nickname at all. nil when
        # guild_id is unknown (a DM) or the member has never been seen there.
        def member_handle(guild_id, id)
          member = resolve_member(guild_id, id)
          return nil unless member.is_a?(Hash)

          presence(member["nick"]) || user_handle_from(member["user"])
        end

        def user_handle(id) = user_handle_from(resolve_user(id))

        def user_handle_from(user)
          return nil unless user.is_a?(Hash)

          user["username"] || user["global_name"] || user["name"]
        end

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

        # The guild member behind +id+ in +guild_id+, cached the same way
        # #resolve_user already is: a nickname chosen inside one guild lives on
        # the member, not the account. nil when guild_id is unknown (a DM) or
        # the member has never been seen there.
        def resolve_member(guild_id, id)
          return nil if guild_id.nil? || id.nil?

          key = "#{guild_id}/#{id}"
          @cache_monitor.synchronize do
            return @member_cache[key] if @member_cache.key?(key)
          end
          fetched = @client.fetch_member(guild_id, id)
          @cache_monitor.synchronize { @member_cache[key] = fetched }
          fetched
        end

        def build_index(endpoints)
          endpoints.each_with_object({}) do |endpoint, index|
            index[endpoint.settings[:channel_id].to_s] = endpoint
          end
        end

        def endpoint_for(channel_id)
          if @endpoint_resolver
            return nil if channel_id.nil?

            return @endpoint_resolver.endpoint_for(:fluxer, account, channel_id.to_s)
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
