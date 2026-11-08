# frozen_string_literal: true

module Rubotty
  module Adapters
    module Discord
      # The Discord platform adapter, built on discordrb. The operational traps:
      # the MESSAGE_CONTENT and GUILD_SCHEDULED_EVENTS intents, discordrb 3.8.0
      # not knowing either exists, and server_members needing its own Developer
      # Portal toggle.
      class Adapter < Adapters::Base
        # What a member of an unboosted server may upload. Discord dropped this
        # from 25 MB back to 10 MB in late 2024; boost level 2 lifts it to 50 MB
        # and level 3 to 100 MB, which is what max_upload_bytes is raised for.
        DEFAULT_UPLOAD_BYTES = 10 * 1024 * 1024

        # How long #stop waits for the killed slash-registration thread.
        SHUTDOWN_JOIN_SECONDS = 5

        # Bounded wait, at boot, for #every_known_guild_id to populate from gateway
        # guild sync before #register_slash_commands falls back to Discord's
        # slow global path. The per-guild path Discord reflects within about a
        # minute; the global one it caches for roughly an hour, so ten seconds
        # of patience here is far cheaper than landing on that path only
        # because the cache had not warmed up yet.
        SLASH_GUILDS_WAIT_SECONDS = 10
        SLASH_GUILDS_WAIT_POLL_INTERVAL = 0.1

        # What a text bridge actually needs, materialised here because
        # Config::Schema resolves a field's default into every account's
        # settings, so this is the array Client#intents_bitfield actually
        # sees. direct_messages and direct_message_reactions cover the
        # DM-based operator console and are not privileged. server_members
        # is privileged and required for join/leave events to arrive at
        # all, since an application that has not flipped that Developer
        # Portal toggle gets its gateway connection refused.
        DEFAULT_INTENTS = %i[servers server_messages server_message_reactions
                             direct_messages direct_message_reactions server_members].freeze

        class << self
          def adapter_name = :discord

          # Discord allows five messages per five seconds to one channel, and
          # fifty requests a second across the connection.
          def outbound_limits = { destination: { rate: 1.0, burst: 5 }, account: { rate: 50.0, burst: 50 } }

          # One account is one bot token, one connection, so a missing token
          # means "not yet connected".
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :token_env, :string, required: true, env: true,
                                         desc: "name of the environment variable holding the bot token"
              field :intents, :array, of: :symbol, default: DEFAULT_INTENTS,
                              desc: "gateway intents. message_content and server_scheduled_events " \
                                    "are always added, because without them Discord delivers empty " \
                                    "message bodies and never reports a native Discord event."
              field :log_mode, :symbol, default: :quiet,
                                        one_of: %i[debug verbose normal quiet silent],
                                        desc: "how noisy the underlying library should be"
              field :ready_timeout, :integer, default: 30,
                                              desc: "seconds to wait for the gateway handshake"
              field :webhook_name, :string, default: "rubotty",
                                            desc: "name given to webhooks this bridge creates, " \
                                                  "so they are identifiable in the channel's " \
                                                  "integration settings"
              field :max_upload_bytes, :integer, default: DEFAULT_UPLOAD_BYTES,
                                                 desc: "largest file to download and re upload, " \
                                                       "in bytes. 10 MB is what an unboosted " \
                                                       "server takes; raise it to 52428800 at " \
                                                       "boost level 2 or 104857600 at level 3. " \
                                                       "The bridge aims at this number, so a " \
                                                       "wrong one costs a file that would have " \
                                                       "crossed or sends one that bounces."
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :channel_id, :string, required: true, desc: "Discord channel id (a snowflake)"
              field :guild_id, :string, desc: "guild the channel belongs to, used for mention resolution"
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages"
              field :sender_separator, :string, default: ":",
                                                desc: "printed after the sender name"
              field :webhook, :symbol, default: :auto, one_of: %i[auto off],
                                      desc: "post relayed messages under each sender's own " \
                                            "name by reusing or creating a channel webhook. " \
                                            "Falls back to bot posting when not permitted."
              field :webhook_url_env, :string, env: true,
                                               desc: "use exactly this webhook rather than " \
                                                     "finding or creating one"
              field :use_embeds, :symbol, default: :auto, one_of: %i[auto always never],
                                         desc: "auto puts a message too long for Discord's 2000 " \
                                               "character limit into an embed, which holds 4096 and " \
                                               "so covers Telegram's whole range. never truncates " \
                                               "instead, losing content."
              field :allow_mass_mentions, :boolean, default: false,
                                                    desc: "permit relayed text to ping " \
                                                          "@everyone and @here. Leave this " \
                                                          "false unless you are certain."
            end
          end

          def validate_endpoint(settings, path)
            id = settings[:channel_id].to_s
            return [] if id.match?(/\A\d{5,}\z/)

            ["#{path}.channel_id: expected a Discord snowflake (a long number), got #{id.inspect}"]
          end

          def discovers_channels? = true

          def route_key_for(endpoint) = endpoint.settings[:channel_id].to_s

          # guild_id is left for an operator to fill in, since it is needed
          # only for ban/kick.
          def addressing(route_key, external_id: nil)
            { "channel_id" => route_key.to_s }
          end

          def supports_leave? = true
          def supports_space_notice? = true
          def supports_space_enumeration? = true
          def supports_admin_dm? = true

          # A DM lives in its own channel like any other, so deleting one is
          # the ordinary channel-message delete.
          def supports_admin_dm_delete? = true
          def supports_backfill? = true
          def supports_gap_ownership? = true
          def supports_reaction_backfill? = true
          def supports_native_events? = true
          def supports_channel_management? = true

          # Discord's sibling change wires the pending-review flow through.
          def accepts_pending_spaces? = true
        end

        CAPABILITIES = Capabilities.new(
          edits: true,
          deletes: true,
          replies: true,
          threads: true,
          # The unboosted figure. An account that raised max_upload_bytes gets
          # its own number through #capabilities, since this constant is shared.
          max_attachment_bytes: DEFAULT_UPLOAD_BYTES,
          reactions: true,
          # A webhook execute carries a username and an avatar_url, and a webhook
          # message can only be edited through the webhook that made it, so the
          # name it was sent under survives the edit. Both need a webhook on the
          # channel; without one the bot posts under its own name with a prefix.
          puppets_send: true,
          puppets_edit: true,
          # Discord sets no meaningful limit on distinct bot reactions per message.
          max_reactions: nil,
          custom_reactions: true,
          moderation: %i[delete ban unban kick mute unmute pin unpin unpinall],
          # Discord has application commands, which Interactions#register_commands
          # publishes Core::CommandRegistry as, so "/" opens a picker of them.
          command_list: true
        ).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil,
                       pending_spaces: nil)
          super
          @client = Client.new(
            token: settings[:token],
            logger: logger,
            intents: settings[:intents],
            log_mode: settings[:log_mode] || :quiet
          )
          @outbound = Outbound.new(logger: logger)
          @index = build_index(endpoints)
          @inbound = Inbound.new(
            endpoint_for: method(:endpoint_for),
            logger: logger,
            resolver: method(:resolve_mention),
            own_webhook: ->(id, channel) { @webhooks.own_message?(id, channel: channel) },
            user_handle: method(:user_handle)
          )
          @fetcher = Util::MediaFetcher.new(
            limit: upload_limit,
            logger: logger
          )
          @webhooks = Webhook.new(
            client: @client, logger: logger,
            bridge_name: settings[:webhook_name] || "rubotty"
          )
          # Native slash commands, routed into the same dispatch a "!" text
          # command uses. Rebuilt whenever the client is swapped.
          @interactions = build_interactions
          @scheduled_events = ScheduledEvents.new(client: @client, logger: logger)
          @own_account_id = nil
        end

        attr_reader :client, :interactions

        # This process's own webhook puppeting state, one entry per endpoint
        # it has actually tried to deliver to since boot. See
        # {Webhook#puppet_snapshot}, and {Core::PuppetStatusSweep}, the
        # periodic job that reads this into the dashboard.
        def puppet_snapshot = @webhooks.puppet_snapshot

        def replace_client(client)
          @client = client
          @webhooks = Webhook.new(
            client: client, logger: logger,
            bridge_name: settings[:webhook_name] || "rubotty"
          )
          @interactions = build_interactions
          @scheduled_events = ScheduledEvents.new(client: client, logger: logger)
          self
        end

        # This ACCOUNT's ceiling, so a boosted server that raised
        # max_upload_bytes has the bridge relay up to the number it really takes
        # instead of rehosting everything over the unboosted one.
        def capabilities = @capabilities ||=
          Capabilities.new(**CAPABILITIES.to_h.merge(max_attachment_bytes: upload_limit))

        # The configured ceiling, or Discord's unboosted one.
        def upload_limit
          limit = settings[:max_upload_bytes].to_i
          limit.positive? ? limit : DEFAULT_UPLOAD_BYTES
        end

        def own_account_id = @own_account_id

        # Discord's canonical link is stable when the endpoint knows both the
        # guild and channel snowflakes. A DM or an incompletely mapped channel
        # deliberately returns nil rather than publishing a made-up URL.
        def message_permalink(endpoint, native_id)
          guild_id = endpoint.settings[:guild_id].to_s
          channel_id = endpoint.settings[:channel_id].to_s
          return nil if guild_id.empty? || channel_id.empty? || native_id.to_s.empty?

          "https://discord.com/channels/#{guild_id}/#{channel_id}/#{native_id}"
        end

        # The channel itself, which is that link with no message on the end. A
        # DM or an incompletely mapped channel answers nil for the same reason.
        def room_permalink(endpoint)
          guild_id = endpoint.settings[:guild_id].to_s
          channel_id = endpoint.settings[:channel_id].to_s
          return nil if guild_id.empty? || channel_id.empty?

          "https://discord.com/channels/#{guild_id}/#{channel_id}"
        end

        def running? = @client.connected?

        # The gateway websocket is a persistent connection.
        def persistent_connection? = true

        # Post +notice+ (nil skips the post) then leave the guild. True on a
        # confirmed departure even when the notice could not be posted; false
        # when the leave call failed, and equally when the client could not find
        # the guild to leave it, since the caller records a true here as a
        # departure that really happened.
        def leave_space(external_id, notice: nil)
          post_space_notice(external_id, notice) if notice
          unless @client.leave_server(external_id)
            logger.warn { "discord: could not leave guild #{external_id}: it is not visible to this bot" }
            return false
          end

          logger.info { "discord: left guild #{external_id}" }
          true
        rescue StandardError => e
          logger.warn { "discord: could not leave guild #{external_id}: #{e.message}" }
          false
        end

        # Post +text+ into +external_id+ with no accompanying leave. The client
        # picks the system channel, else the first text channel it can reach,
        # since Discord has no guild-wide post.
        def post_space_notice(external_id, text)
          return false if text.to_s.strip.empty?

          !@client.post_guild_notice(external_id, text).nil?
        rescue StandardError => e
          logger.info { "discord: could not post a space notice in guild #{external_id}: #{e.message}" }
          false
        end

        # List one guild's channels again, for a space whose first listing was
        # dropped because it had no platform connection yet. False when the
        # listing could not be read, so the caller knows nothing was recorded.
        def enumerate_space(external_id)
          guild_id = external_id.to_s
          return false if guild_id.empty? || @discovery.nil?

          listing = @client.guild_text_channels(guild_id)
          return false if listing.unavailable?

          discover_guild_channels(guild_id, listing.channels)
          true
        rescue StandardError => e
          logger.warn { "discord: could not re-enumerate guild #{guild_id}: #{e.message}" }
          false
        end

        # DM +text+ to +native_id+. Discord refuses when the recipient shares no
        # guild with the bot, or has DMs from server members turned off, so this
        # answers nil rather than raising.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          sent = @client.send_direct_message(native_id, text)
          return nil if sent.nil?

          Core::DmReceipt.new(native_id: sent[:message_id], channel_ref: sent[:channel_id])
        end

        # Remove a DM #send_admin_dm sent: the same channel fetch and
        # message delete #delete uses, over the DM channel
        # #send_admin_dm's receipt named.
        def delete_admin_dm(receipt)
          return false if receipt.nil? || receipt.channel_ref.nil?

          require "discordrb"
          channel = @client.channel(receipt.channel_ref)
          message = fetch_message(channel, receipt.native_id)
          message&.delete
          true
        rescue Discordrb::Errors::UnknownMessage
          # Already gone counts as success, same as #delete.
          true
        rescue StandardError => e
          logger.info { "could not delete Discord DM #{receipt.native_id}: #{e.message}" }
          false
        end

        # Canonical messages posted in +endpoint+ since +since+, oldest first,
        # shaped through the same inbound path a live event takes. A copy this
        # bridge wrote itself is dropped, silently: a real sweep must never
        # re relay one.
        def backfill_messages(endpoint, since:, limit: 500)
          history_items(endpoint, since: since, limit: limit) do |native|
            @inbound.message(HistoricalEvent.new(native), replaying: true)
          end
        end

        # Same history {#backfill_messages} pages through, but nothing is
        # dropped for being our own copy: each candidate is paired with the
        # ownership answer {#backfill_messages} silently acts on instead of
        # exposing. {Core::GapReport} calls this rather than reaching into
        # webhook internals of its own.
        def backfill_candidates(endpoint, since:, limit: 500)
          history_items(endpoint, since: since, limit: limit) do |native|
            @inbound.message_with_ownership(HistoricalEvent.new(native))
          end
        end

        # Reactions on a history message, shaped through the same inbound builder
        # a live MESSAGE_REACTION_ADD takes, so the react claim dedups them and a
        # re-run never double-posts.
        def backfill_reactions(endpoint, native_id, limit: 200)
          channel_id = endpoint.settings[:channel_id]
          return [] if channel_id.nil? || native_id.nil?

          channel = ReactionChannel.new(channel_id.to_s)
          @client.reactions(channel_id, native_id, limit: limit).filter_map do |emoji, user|
            @inbound.reaction(HistoricalReaction.new(channel, native_id.to_s, emoji, user), :reaction_add)
          end
        end

        def start
          @client.connect
          register_handlers
          @client.run_async(timeout: settings[:ready_timeout] || 30)
          # Checked before #own_id: the bot's profile resolves over plain REST
          # even when the gateway IDENTIFY itself was refused, so own_id alone
          # would still answer a real user id and let the adapter start deaf.
          raise AdapterError.new(privileged_intent_rejection_message, adapter: :discord) if @client.privileged_intent_rejected?

          @own_account_id = @client.own_id
          if @own_account_id.nil?
            raise AdapterError.new(
              "connected to Discord but never learned the bot's own user id, so loop prevention " \
              "would be unsafe. Check the token and the gateway handshake.",
              adapter: :discord
            )
          end
          logger.info { "signed in to Discord as #{@client.own_name} (#{@own_account_id})" }
          # Best effort and non-fatal (the bridge still runs with only the "!"
          # prefix), but kept OFF this method's thread: Runtime#start joins every
          # adapter's start before resolving guilds, starting the control watcher
          # and announcing the boot, and this can take minutes under Discord's rate limit.
          @slash_registration = Thread.new { register_slash_commands }
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          # discordrb, RestClient and the socket layer raise plain StandardError
          # on a bad token or a gateway hiccup. The runtime's per adapter rescue
          # only catches AdapterError, so converting here is what keeps one bad
          # adapter from taking the whole process down.
          raise AdapterError.new(
            "Discord adapter failed to start: #{e.class}: #{e.message}", adapter: :discord
          )
        end

        def stop
          # Registration holds no state worth finishing for, and under the
          # rate limiter it can still be waiting minutes later. Joined after
          # the kill so a stopped adapter has genuinely stopped.
          @slash_registration&.kill&.join(SHUTDOWN_JOIN_SECONDS)
          @slash_registration = nil
          @client.stop
          self
        end

        # ------------------------------------------------------------------
        # outbound
        # ------------------------------------------------------------------

        def deliver(message, endpoint)
          # A notice the bridge itself says always posts as the bot. Loop
          # prevention recognises our own messages by author id, and a webhook
          # message is not authored by the bot account; the startup banner also
          # skips the delivery ledger, being posted outside the router.
          return deliver_as_bot(message, endpoint) if message.system_notice?

          hook = @webhooks.for(endpoint)
          # A reply goes out as the bot even when a webhook is available: a webhook
          # execute carries no message_reference, so a relayed reply would only
          # show as a quoted text block, never Discord's native reply. The bot
          # account costs the sender's impersonated name and avatar for that message.
          return deliver_via_webhook(message, endpoint, hook) if hook && !@outbound.reply_id(message, endpoint)

          deliver_as_bot(message, endpoint)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord send failed: #{e.class}: #{e.message}",
                                 adapter: :discord, retryable: true)
        end

        def edit(message, endpoint, native_id)
          # A system notice went out as the bot, so it must be edited as the bot:
          # editing through the channel's webhook would target a message the
          # webhook does not own and fail.
          return edit_as_bot(message, endpoint, native_id) if message.system_notice?

          hook = @webhooks.for(endpoint)
          if hook
            channel_id = channel_id_for(endpoint, native_id)
            # A webhook message can only be edited through the webhook that
            # created it, not by the bot account, even with Manage Messages.
            @webhooks.edit(hook, native_id,
                           content: @outbound.compose(message, endpoint, webhook: true),
                           allowed_mentions: @outbound.allowed_mentions(message, endpoint),
                           thread_id: thread_id_for(channel_id, endpoint))
            return Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
          end

          edit_as_bot(message, endpoint, native_id)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord edit failed: #{e.message}", adapter: :discord)
        end

        def edit_as_bot(message, endpoint, native_id)
          channel_id = channel_id_for(endpoint, native_id)
          channel = @client.channel(channel_id)
          target = fetch_message(channel, native_id)
          return nil if target.nil?

          # discordrb's Message#edit sends no allowed_mentions, so the edit would
          # re parse every mention token and reopen the hole the resolved
          # whitelist closes on the send path. API.edit_message takes it directly.
          @client.edit_message(
            channel_id, native_id,
            @outbound.compose(message, endpoint),
            allowed_mentions: @outbound.allowed_mentions(message, endpoint)
          )
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
        end

        def delete(endpoint, native_id)
          require "discordrb"
          # Try the bot first: with Manage Messages it can delete anything in the
          # channel, including webhook messages and messages the bridge did not
          # send, which a moderation command needs.
          channel_id = channel_id_for(endpoint, native_id)
          channel = @client.channel(channel_id)
          target = fetch_message(channel, native_id)
          if target
            target.delete
            return nil
          end

          hook = @webhooks.for(endpoint)
          @webhooks.delete(hook, native_id, thread_id: thread_id_for(channel_id, endpoint)) if hook
          # Already gone counts as success rather than failure: two moderators racing is normal.
          nil
        rescue Discordrb::Errors::UnknownMessage
          # Vanished between #fetch_message and target.delete.
          nil
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord delete failed: #{e.message}", adapter: :discord)
        end

        # Discord's reaction model is incremental, so the declarative request
        # becomes the difference against what was last requested.
        #
        # A refusal (a 403, a 429) leaves here rather than being logged and
        # swallowed: the bridge records the aggregate as placed on whatever this
        # returns without raising, and storage then believes in an emoji that is
        # not on the message; only a message that is already gone is tolerated.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          require "discordrb"
          channel = @client.channel(channel_id_for(endpoint, native_id))
          target = fetch_message(channel, native_id)
          return nil if target.nil?

          (desired - previous).each { |reaction| react(target, reaction) }
          (previous - desired).each { |reaction| unreact(target, reaction) }
          nil
        rescue Discordrb::Errors::UnknownMessage
          # Removed between the fetch and the reaction call, which is ordinary.
          nil
        rescue AdapterError => e
          raise unless AlreadyGone.call(e)

          nil
        rescue StandardError => e
          raise AdapterError.new("Discord reaction sync failed: #{e.message}", adapter: :discord)
        end

        def moderate(command, endpoint, native_id)
          case command.action
          when :delete then moderate_delete(endpoint, native_id)
          when :ban then moderate_ban(command, endpoint)
          when :unban then moderate_unban(command, endpoint)
          when :kick then moderate_kick(command, endpoint)
          when :mute then moderate_timeout(command, endpoint, minutes: mute_minutes(command))
          when :unmute then moderate_timeout(command, endpoint, minutes: nil)
          when :pin then moderate_pin(endpoint, native_id, pinned: true)
          when :unpin then moderate_pin(endpoint, native_id, pinned: false)
          when :unpinall then moderate_unpin_all(endpoint)
          else
            Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end
        rescue PermissionError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :forbidden, detail: e.message)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (discord channel #{endpoint.settings[:channel_id]})"
        end

        # The guild id for one of this account's channels, learned from the
        # gateway. A channel the bot cannot see, or a gateway not yet connected,
        # returns nil and the resolution is retried next boot.
        def guild_id_for_channel(channel_id)
          return nil if channel_id.nil?

          channel = @client.channel(channel_id)
          server = channel.respond_to?(:server) ? channel.server : nil
          id = server.respond_to?(:id) ? server.id : nil
          id&.to_s
        rescue StandardError
          nil
        end

        # The guild's live member count, for RehostedFiles' download-serve
        # ceiling; see ControlPlane::CommunityMembers. Same nil safety as the
        # pending-card read this wraps: no client, no server, no answer.
        def community_member_count(guild_id) = guild_member_count(guild_id)

        # ------------------------------------------------------------------
        # native scheduled events
        # ------------------------------------------------------------------

        # Mirror +event+ into a Discord Guild Scheduled Event (always EXTERNAL,
        # see {ScheduledEvents}). +endpoint+ is the room's own endpoint on this
        # account and is required, because it is the only thing that says which
        # community's guild this event belongs in. A nil raises.
        def create_scheduled_event(event, endpoint)
          guild_id = guild_id_for_native_call(endpoint)
          native_id = @scheduled_events.create(event, guild_id: guild_id)
          logger.info { "discord: created scheduled event #{native_id} in guild #{guild_id}" } if native_id
          native_id
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord scheduled-event create failed: #{e.message}", adapter: :discord)
        end

        def update_scheduled_event(native_id, event, endpoint)
          guild_id = guild_id_for_native_call(endpoint)
          @scheduled_events.update(native_id, event, guild_id: guild_id)
          logger.info { "discord: updated scheduled event #{native_id} in guild #{guild_id}" } if guild_id
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord scheduled-event update failed: #{e.message}", adapter: :discord)
        end

        def delete_scheduled_event(native_id, endpoint)
          guild_id = guild_id_for_native_call(endpoint)
          @scheduled_events.delete(native_id, guild_id: guild_id)
          logger.info { "discord: deleted scheduled event #{native_id} in guild #{guild_id}" } if guild_id
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord scheduled-event delete failed: #{e.message}", adapter: :discord)
        end

        # Discord's interested/going list, not the event_rsvps table.
        def read_native_rsvps(native_id, endpoint)
          guild_id = guild_id_for_native_call(endpoint)
          rsvps = @scheduled_events.rsvps(native_id, guild_id: guild_id)
          logger.info { "discord: read #{rsvps.size} native rsvp(s) for #{native_id} in guild #{guild_id}" } if guild_id
          rsvps
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord scheduled-event RSVP read failed: #{e.message}", adapter: :discord)
        end

        # ------------------------------------------------------------------
        # channel management
        # ------------------------------------------------------------------

        # A new channel has no room of its own yet to resolve a guild from, so
        # the guild comes from +template+, an existing channel in the target
        # guild, and failing that from the community being provisioned for. It
        # used to fall back to the first guild the account knew of, which on a
        # multi-tenant token is another community's server.
        def create_channel(name:, community_id:, template: nil)
          doing = "create the channel #{name.to_s.inspect}"
          scoped_channel_call!(community_id, doing)
          guild_id = guild_for_new_channel(community_id, template, doing)
          return nil if guild_id.nil?

          @client.create_guild_channel(guild_id, name, template_id: template)
        end

        def delete_channel(native_id, community_id:)
          doing = "delete the channel #{native_id.to_s.inspect}"
          scoped_channel_call!(community_id, doing)
          return false unless guild_in_community?(guild_id_for_channel(native_id), community_id, doing)

          @client.delete_guild_channel(native_id)
        end

        def copy_channel_permissions(from:, to:)
          @client.copy_permission_overwrites(from, to)
        end

        # Discord's <t:UNIX:...> markup, which the Discord client localizes to
        # each reader's own timezone and locale, so +tz+ is unused here. The
        # client counts down from its own clock, so +now+ is unused too.
        # +style+ is :full "<t:UNIX:F>", :relative "<t:UNIX:R>", or :both.
        def render_timestamp(time, style: :full, tz: nil, now: nil)
          unix = time.to_i
          case style.to_sym
          when :relative then "<t:#{unix}:R>"
          when :both then "<t:#{unix}:F> <t:#{unix}:R>"
          else "<t:#{unix}:F>"
          end
        end

        # ------------------------------------------------------------------
        # inbound wiring
        # ------------------------------------------------------------------

        def register_handlers
          bot = @client.bot
          return self if bot.nil?

          # A DM to the bot owns no configured channel, so it misses the resolver
          # and would be dropped. With a control lane wired, a private-channel
          # message goes there instead, and a guild message routes normally.
          bot.message do |event|
            next if handle_control_gesture(event)

            message = @inbound.message(event)
            notify_unmapped_command(event) if message.nil?
            emit_if(message)
          end
          bot.message_edit { |event| emit_if(@inbound.edit(event)) }
          bot.message_delete { |event| emit_if(@inbound.delete(event)) }
          bot.reaction_add { |event| emit_if(@inbound.reaction(event, :reaction_add)) }
          bot.reaction_remove { |event| emit_if(@inbound.reaction(event, :reaction_remove)) }
          bot.reaction_remove_all { |event| emit_if(@inbound.reaction_clear(event)) }
          bot.reaction_remove_emoji { |event| emit_if(@inbound.reaction_clear(event)) }
          # Needs the server_members intent, which is privileged.
          bot.member_join { |event| handle_member_change(event, :join) }
          bot.member_leave { |event| handle_member_change(event, :leave) }
          # server_create fires only for a guild joined while the bot is already
          # connected: discordrb's gateway swallows GUILD_CREATE when the payload's
          # `unavailable` is explicitly false, which is how an already-joined guild
          # streams in after READY. #sweep_known_guilds covers guilds added while down.
          if join_guard || discovery
            bot.server_create { |event| handle_guild_added(event) }
            bot.ready { sweep_known_guilds }
          end
          bot.channel_create { |event| handle_channel_created(event) } if discovery
          # discordrb 3.8.0 raises THREAD_CREATE / THREAD_UPDATE but exposes no
          # handler DSL for them, so the always-present path for a thread name is
          # learning it from the thread's own messages (see #decorate_thread).
          register_thread_handlers(bot)
          # discordrb 3.8.0 has no event class for Guild Scheduled Events or for
          # THREAD_CREATE/THREAD_UPDATE, so all of them arrive through its
          # catch-all `unknown`.
          bot.unknown { |event| handle_unknown_dispatch(event) }
          @interactions.register_handlers
          self
        end

        def emit_if(message)
          return nil if message.nil?

          message = decorate_thread(message)
          learn_thread_message(message)
          emit(message)
          message
        rescue StandardError => e
          logger.error { "error handling a Discord event: #{e.class}: #{e.message}" }
          nil
        end

        # ------------------------------------------------------------------
        # DM control gestures
        # ------------------------------------------------------------------

        # If +event+ is a directed DM the control lane should own, hand it over
        # and return true so the caller skips the normal routing. Never raises
        # out: a control gesture must not take down the receive loop.
        def handle_control_gesture(event)
          return false unless control_gesture?(event)

          reply = control_lane.handle_dm(
            adapter: :discord, account: account, author: dm_author(event), text: dm_text(event),
            # An operator answering one of the bot's alerts replies to it, and
            # the quoted text is what names the action they mean.
            quoted: quoted_text(event)
          )
          send_dm_reply(dm_channel(event), reply) if reply
          true
        rescue StandardError => e
          logger.warn { "discord: control gesture handling failed: #{e.class}: #{e.message}" }
          # Still swallow the event: a DM that misses the resolver has nowhere
          # else to go.
          true
        end

        # Tell a member that a real command word (`!delete`, `/pin`) typed in a
        # channel this account has no endpoint for did not land, instead of
        # dropping it silently; only ever fires once #inbound's own parse came up
        # nil, which inside a mapped thread also happens for our own webhook
        # copies, dropped there by the loop guard. Resolving through
        # #inbound.endpoint_for_channel rather than the bare #endpoint_for is what
        # tells that case apart from a genuinely unmapped channel: a thread's own
        # id is never itself a mapped endpoint, only its parent's is.
        def notify_unmapped_command(event)
          return unless event.respond_to?(:channel) && event.channel
          # A DM owns no endpoint by design and the console answers it. Without
          # this guard the direct_messages intent turns every `/help` DM on a
          # deployment with no control plane into an unsolicited reply.
          return if dm_channel?(event.channel)
          return unless @inbound.endpoint_for_channel(event.channel).nil?

          content = event.respond_to?(:message) ? event.message&.content : nil
          return if content.nil?

          word = command_prefix.strip(content).to_s.split.first
          return if word.nil? || !Core::CommandRegistry.known?(word)

          event.channel.send_message("Commands are not available in this channel.")
        rescue StandardError => e
          logger.debug { "discord: could not notify an unmapped-channel command: #{e.class}: #{e.message}" }
        end

        # The default set ("/" and "!"). A community's configured prefixes live
        # in commands: config that is out of reach at this raw gateway layer.
        def command_prefix
          @command_prefix ||= Core::CommandPrefix.new
        end

        # ------------------------------------------------------------------
        # guild membership: auto-leave and discovery
        # ------------------------------------------------------------------

        # The bot has been added to a guild, or one it is already in synced at
        # connect: decide whether to stay, then discover its channels; never
        # raises out. The seed sentinel is resolved first, from the guild's own
        # channels, so a core community whose Discord connection still reads
        # "unresolved: <slug>" is kept rather than left, since its GUILD_CREATE
        # can arrive before the boot-time resolve pass.
        def handle_guild_added(event)
          guild_id = guild_id_of(server_of(event))
          return nil if guild_id.nil?

          listing = @client.guild_text_channels(guild_id)
          title = server_name(event)
          return keep_unreadable_guild(guild_id, title, listing) if listing.unavailable?

          channels = listing.channels
          inviter = capture_inviter(guild_id)
          channel_names = listing.channel_names
          # Resolve the sentinel first, so a seeded guild is recognised.
          known = @discovery&.recognize_guild(
            account: account, guild_id: guild_id, channel_ids: listing.channel_ids
          )
          decision = stay_or_leave(known, guild_id, title, inviter: inviter, channel_sample: channel_names)
          if decision.leave?
            handle_unauthorized_guild(guild_id, title, inviter, decision)
            return decision
          end

          # A guild the bot keeps but no community owns still belongs on the board.
          pend_guild(guild_id, title, inviter) if decision.review?

          # Record the guild's channels so the mapping wizard lists real ones. A
          # recorded channel bridges only once it is mapped.
          discover_guild_channels(guild_id, channels)
          decision
        rescue StandardError => e
          logger.warn { "discord: guild-add handling failed: #{e.class}: #{e.message}" }
          nil
        end

        # Wraps a discordrb +Server+ so a guild found by enumeration can be handed
        # to {#handle_guild_added}, which only ever reads +event.server+.
        GuildSyncEvent = Struct.new(:server)

        # The boot-time counterpart to {#handle_guild_added}: run the same
        # decision for every guild READY reports, since discordrb raises no
        # server_create event for those. READY fires once per connect and not per
        # resume, so every known guild is re-evaluated on each restart.
        def sweep_known_guilds
          bot = @client.bot
          return if bot.nil?

          bot.servers.each_value { |server| handle_guild_added(GuildSyncEvent.new(server)) }
        rescue StandardError => e
          logger.warn { "discord: guild sweep at connect failed: #{e.class}: #{e.message}" }
        end

        def handle_channel_created(event)
          return nil if @discovery.nil?

          descriptor = channel_descriptor(channel_of(event))
          return nil if descriptor.nil?

          @discovery.saw(descriptor)
          nil
        rescue StandardError => e
          logger.warn { "discord: channel-create handling failed: #{e.class}: #{e.message}" }
          nil
        end

        # GUILD_MEMBER_ADD / GUILD_MEMBER_REMOVE: guild wide, with no channel of
        # its own, so every endpoint bridged in that guild gets its own join or
        # leave rather than one guessed off an arbitrary index. The fan-out
        # stays inside one community, which is all a guild-wide event can name.
        def handle_member_change(event, kind)
          guild_id = guild_id_of(server_of(event))
          return nil if guild_id.nil?

          endpoints_in_guild(guild_id, kind).each { |endpoint| emit_if(@inbound.member(event, kind, endpoint)) }
          nil
        rescue StandardError => e
          logger.warn { "discord: member #{kind} handling failed: #{e.class}: #{e.message}" }
          nil
        end

        # Routes discordrb's catch-all dispatch: a Guild Scheduled Event change,
        # a thread create/update (see #note_thread), or, named at debug rather
        # than dropped silently, anything else.
        def handle_unknown_dispatch(event)
          type = event.respond_to?(:type) ? event.type.to_s : nil
          data = event.respond_to?(:data) ? event.data : nil
          return note_thread_from_dispatch(data) if THREAD_DISPATCH_TYPES.include?(type)

          action = SCHEDULED_EVENT_ACTIONS[type]
          if action.nil?
            logger.debug { "discord: unhandled dispatch type #{type.inspect}" }
            return nil
          end
          return nil if data.nil?

          emit_native_event_change(native_event_change(action, data))
          nil
        rescue StandardError => e
          logger.warn { "discord: could not handle an unknown dispatch: #{e.class}: #{e.message}" }
          nil
        end

        private

        SCHEDULED_EVENT_ACTIONS = {
          "GUILD_SCHEDULED_EVENT_CREATE" => :created,
          "GUILD_SCHEDULED_EVENT_UPDATE" => :updated,
          "GUILD_SCHEDULED_EVENT_DELETE" => :deleted
        }.freeze

        # Raised through the unknown handler, same as a scheduled event change.
        THREAD_DISPATCH_TYPES = %w[THREAD_CREATE THREAD_UPDATE].freeze

        # Discord's scheduled-event status codes. An unrecognised code passes
        # through as the raw integer rather than being dropped.
        DISCORD_EVENT_STATUS = { 1 => :scheduled, 2 => :active, 3 => :completed, 4 => :cancelled }.freeze

        # The payload has the same shape for CREATE, UPDATE and DELETE.
        def native_event_change(action, data)
          Events::NativeEventChange.new(
            adapter: :discord, account: account, action: action,
            native_id: data["id"], guild_id: data["guild_id"], title: data["name"],
            starts_at: parse_native_time(data["scheduled_start_time"]),
            ends_at: parse_native_time(data["scheduled_end_time"]),
            status: DISCORD_EVENT_STATUS[data["status"]] || data["status"],
            raw: data
          )
        end

        def parse_native_time(value)
          return nil if value.to_s.empty?

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        # A guild whose channels could not be listed is kept, untouched, and
        # looked at again on the next sweep. Its channel ids are the only thing
        # that resolves a seeded connection's sentinel, so without them a core
        # community reads as a stranger, and walking out of one cannot be undone
        # from this side.
        def keep_unreadable_guild(guild_id, title, listing)
          logger.warn do
            "discord: keeping guild #{guild_id} until its channels can be listed (#{listing.reason})"
          end
          ControlPlane::JoinGuard::Decision.new(
            action: :stay, signal: join_signal(guild_id, title, nil, [])
          )
        end

        # A guild the discovery seam recognised is always kept, and with no guard
        # wired the bot never leaves.
        def stay_or_leave(known, guild_id, title, inviter:, channel_sample:)
          if known || join_guard.nil?
            return ControlPlane::JoinGuard::Decision.new(
              action: :stay, signal: join_signal(guild_id, title, inviter, channel_sample)
            )
          end

          join_guard.on_join(adapter: :discord, account: account, external_id: guild_id, title: title,
                             inviter: inviter, channel_sample: channel_sample)
        end

        # An unauthorized guild goes to pending review when a
        # {ControlPlane::PendingSpaces} service is wired, and is left immediately
        # when it is not, which is the same policy Telegram applies to a chat.
        def handle_unauthorized_guild(guild_id, title, inviter, decision)
          return leave_guild(guild_id, decision.notice) if pending_spaces.nil?

          pend_guild(guild_id, title, inviter)
        end

        # Hand a guild to the pending-review service and carry out what it
        # decided. A no-op when no service is wired, since there is no board.
        def pend_guild(guild_id, title, inviter)
          return if pending_spaces.nil?

          outcome = pending_spaces.on_join!(
            adapter: :discord, account: account, external_id: guild_id, name: title,
            inviter_native_id: inviter&.native_id, inviter_username: inviter&.username,
            inviter_display: inviter&.display_name, member_count: guild_member_count(guild_id),
            sample_channels: []
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

        # The guild's member count for the pending card, nil when the gateway
        # cannot answer, which the dashboard shows as unknown.
        def guild_member_count(guild_id)
          return nil unless @client.respond_to?(:guild_member_count)

          count = @client.guild_member_count(guild_id)
          count.is_a?(Integer) ? count : nil
        rescue StandardError
          nil
        end

        def join_signal(guild_id, title, inviter, channel_sample)
          ControlPlane::SpaceJoinSignal.new(
            adapter: :discord, account: account, external_id: guild_id,
            title: title, inviter: inviter, channel_sample: channel_sample
          )
        end

        # Who added the bot to this guild. Nil when the audit log is unreadable or
        # its entry has not landed yet.
        def capture_inviter(guild_id)
          return nil unless @client.respond_to?(:guild_inviter)

          own_id = wait_for_own_account_id
          data = @client.guild_inviter(guild_id, own_id)
          return nil if data.nil?

          Core::Author.new(native_id: data[:id], username: data[:username],
                           display_name: data[:display_name], kind: :user)
        rescue StandardError => e
          logger.info { "discord: could not determine who added the bot to guild #{guild_id}: #{e.message}" }
          nil
        end

        # Seconds #start's assignment of @own_account_id has to land before the
        # boot-time guild sweep gives up and reads it as still nil.
        OWN_ID_WAIT_SECONDS = 5
        OWN_ID_WAIT_INTERVAL = 0.05

        # Discord refuses the whole IDENTIFY, not just the one intent, when any
        # requested privileged intent is not enabled on the bot's page of the
        # developer portal, and its close frame never says which. Without
        # message_content specifically, every message event that does not
        # @mention the bot arrives with an empty body, useless for bridging, so
        # this is a hard refusal rather than a reduced mode.
        def privileged_intent_rejection_message
          "Discord refused to identify because a privileged gateway intent this account requested " \
            "(#{@client.requested_privileged_intents.join(", ")}) is not enabled on the bot's page of " \
            "the Discord developer portal. Enable it there, or remove it from this account's intents, " \
            "then restart."
        end

        # discordrb spawns a fresh, unjoined thread per registered handler for
        # the same event (Bot#call_event), so bot.ready { sweep_known_guilds }
        # and #start's own wait for READY race each other with no ordering
        # guarantee. Reading @own_account_id straight off would let the sweep
        # win that race and call guild_inviter with bot_user_id still nil,
        # which never matches a real audit log entry's target id. Once #start
        # has run at all, this returns immediately every other time it is
        # called: the wait is only ever paid at boot.
        def wait_for_own_account_id
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + OWN_ID_WAIT_SECONDS
          while @own_account_id.nil? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            sleep(OWN_ID_WAIT_INTERVAL)
          end
          @own_account_id
        end

        # A failed notice must not stop the leave, so it has its own rescue. When
        # the leave itself fails the "will remain inert" notice is posted
        # instead, at most once for this guild.
        def leave_guild(guild_id, notice)
          begin
            @client.post_guild_notice(guild_id, notice) if notice
          rescue StandardError => e
            logger.info { "discord: could not post the leave notice in guild #{guild_id}: #{e.message}" }
          end
          unless @client.leave_server(guild_id)
            logger.warn { "discord: guild #{guild_id} is not visible to this bot, so it could not be left" }
            return post_inert_fallback(guild_id)
          end

          logger.info { "discord: left unauthorized guild #{guild_id}" }
        rescue StandardError => e
          logger.warn { "discord: could not leave guild #{guild_id}: #{e.message}" }
          post_inert_fallback(guild_id)
        end

        # An unauthorized guild owns no platform_connection mapped into a room, so
        # routing already relays nothing for it; this only makes the stuck state
        # visible, once.
        def post_inert_fallback(guild_id)
          return if join_guard.nil?
          return unless join_guard.record_leave_failure(adapter: :discord, account: account, external_id: guild_id)

          @client.post_guild_notice(guild_id, ControlPlane::JoinGuard::INERT_NOTICE)
          logger.warn { "discord: could not leave guild #{guild_id}; posted the inert notice instead" }
        rescue StandardError => e
          logger.warn { "discord: could not post the inert notice in guild #{guild_id}: #{e.message}" }
        end

        def discover_guild_channels(guild_id, channels)
          return if @discovery.nil?

          @discovery.inventory(adapter: :discord, account: account, external_id: guild_id, channels: channels)
        rescue StandardError => e
          logger.warn { "discord: channel discovery for guild #{guild_id} failed: #{e.message}" }
        end

        # Nil when the channel is not a mappable routing leaf: a DM, a category, a
        # voice channel, or one with no guild. The guild id is the space id and
        # the channel id is the route key.
        def channel_descriptor(channel)
          return nil if channel.nil? || !text_channel?(channel)

          guild_id = guild_id_of(channel.respond_to?(:server) ? channel.server : nil)
          channel_id = channel.respond_to?(:id) ? channel.id.to_s : nil
          return nil if guild_id.nil? || channel_id.nil? || channel_id.empty?

          {
            adapter: :discord, account: account, external_id: guild_id,
            route_key: channel_id, name: (channel.respond_to?(:name) ? channel.name : nil).to_s
          }
        end

        # discordrb reports the kind through Channel#text?, or a numeric #type
        # where 0 is a guild text channel; a DM answers #pm?/#private?.
        def text_channel?(channel)
          return false if channel.respond_to?(:pm?) && channel.pm?
          return false if channel.respond_to?(:private?) && channel.private?
          return channel.text? if channel.respond_to?(:text?)
          return channel.type.to_i.zero? if channel.respond_to?(:type)

          true
        rescue StandardError
          false
        end

        def server_of(event) = event.respond_to?(:server) ? event.server : nil

        def channel_of(event) = event.respond_to?(:channel) ? event.channel : nil

        def server_name(event)
          server = server_of(event)
          server.respond_to?(:name) ? server.name : nil
        end

        def guild_id_of(server)
          return nil if server.nil? || !server.respond_to?(:id)

          id = server.id
          id.nil? || id.to_s.empty? ? nil : id.to_s
        end

        # ------------------------------------------------------------------
        # thread names
        # ------------------------------------------------------------------

        # Keep the thread-name map current from a message living in a thread. A
        # named thread reinforces the map (which also covers threads predating
        # this session); an unnamed one is stamped from what was already learned.
        def decorate_thread(message)
          thread = message.thread
          return message if thread.nil?

          if thread.named?
            thread_names.learn(scope: account, native_id: thread.native_id, name: thread.name)
            return message
          end

          name = thread_names.name_for(scope: account, native_id: thread.native_id)
          return message if name.nil?

          message.with(thread: Core::ThreadRef.new(native_id: thread.native_id, name: name,
                                                   creator: thread.creator,
                                                   creator_native_id: thread.creator_native_id))
        end

        # Only where the gateway library exposes the DSL for these; discordrb
        # 3.8.0 does not, so #handle_unknown_dispatch is the path that actually
        # fires today.
        def register_thread_handlers(bot)
          return unless bot.respond_to?(:thread_create)

          bot.thread_create { |event| note_thread_from_channel(thread_channel(event)) }
          return unless bot.respond_to?(:thread_update)

          bot.thread_update { |event| note_thread_from_channel(thread_channel(event)) }
        end

        def note_thread_from_channel(channel)
          return if channel.nil?

          id = channel.respond_to?(:id) ? channel.id : nil
          name = channel.respond_to?(:name) ? channel.name : nil
          note_thread(id, name)
        end

        # THREAD_CREATE and THREAD_UPDATE carry a full channel object as their
        # raw dispatch data, id and name included.
        def note_thread_from_dispatch(data)
          return if data.nil?

          note_thread(data["id"], data["name"])
        end

        # A thread id is a globally unique snowflake, so the account is a
        # sufficient scope.
        def note_thread(id, name)
          return if id.nil?

          thread_names.learn(scope: account, native_id: id, name: name)
        rescue StandardError => e
          logger.debug { "discord: could not note a thread name: #{e.message}" }
        end

        # discordrb exposes the thread channel as #thread; a duck-typed double
        # may use #channel.
        def thread_channel(event)
          return event.thread if event.respond_to?(:thread) && event.thread
          return event.channel if event.respond_to?(:channel)

          nil
        rescue StandardError
          nil
        end

        # The learned-thread-name store over the durable KV. Without a durable
        # store this returns a no-op wrapper, so the feature stays dormant rather
        # than needing a branch at each call site.
        def thread_names
          return @thread_names ||= Core::ThreadNames.new(store: storage) if storage

          Core::ThreadNames.new(store: nil)
        end

        # The learned message-to-channel store over the durable KV, the same
        # no-op-without-storage shape {#thread_names} uses.
        def thread_messages
          return @thread_messages ||= Core::ThreadMessages.new(store: storage) if storage

          Core::ThreadMessages.new(store: nil)
        end

        # Remember which channel +message+ actually lives in, when it is a
        # thread message: every ref it carries names the PARENT endpoint (see
        # Inbound#endpoint_for), so a later edit, delete, pin or reaction sync
        # addressing this same native id has to look the thread's own channel
        # back up rather than trust the endpoint's configured one.
        def learn_thread_message(message)
          return if message.thread.nil?

          thread_messages.learn(scope: account, native_id: message.ref.native_id,
                                channel_id: message.thread.native_id)
        end

        # The channel a message actually lives in: the thread's own id when
        # #learn_thread_message recorded one for it, else the endpoint's
        # configured channel.
        def channel_id_for(endpoint, native_id)
          thread_messages.channel_for(scope: account, native_id: native_id) || endpoint.settings[:channel_id]
        end

        # The thread id a webhook call needs, or nil when +channel_id+ IS the
        # endpoint's own channel and no thread targeting is required.
        def thread_id_for(channel_id, endpoint)
          return nil if channel_id.to_s == endpoint.settings[:channel_id].to_s

          channel_id
        end

        def build_interactions
          Interactions.new(
            client: @client,
            endpoint_for: method(:endpoint_for_with_thread_fallback),
            emit: method(:emit_if),
            logger: logger
          )
        end

        # #endpoint_for by itself only ever tries the exact channel id, which
        # misses for a slash command invoked inside a thread: a thread is
        # never separately mapped. Inbound#endpoint_for has the same fallback
        # to the parent channel for a gateway message; this gives an
        # interaction, which only ever carries a bare channel id rather than a
        # fetched channel object, the same answer.
        def endpoint_for_with_thread_fallback(channel_id)
          endpoint_for(channel_id) || endpoint_for_thread_parent(channel_id)
        end

        def endpoint_for_thread_parent(channel_id)
          channel = @client.channel(channel_id)
          parent_id = channel.respond_to?(:parent_id) ? channel.parent_id : nil
          return nil if parent_id.nil?

          endpoint_for(parent_id)
        rescue StandardError
          nil
        end

        # Register the slash-command set per guild, so edits show up within the
        # minute; falls back to a global registration only once
        # #every_known_guild_id has had a bounded chance to populate from gateway
        # guild sync, rather than reading whatever it happens to answer the
        # instant #start calls this. Logs at info which path ran and how many
        # commands went out, since nothing else distinguishes the two.
        def register_slash_commands
          guild_ids = wait_for_known_guild_ids
          log_slash_registration_path(guild_ids)
          @interactions.register_commands(guild_ids)
        rescue StandardError => e
          logger.warn { "could not register Discord slash commands: #{e.message}" }
        end

        # Polls #every_known_guild_id until it answers something or
        # SLASH_GUILDS_WAIT_SECONDS passes, so a gateway cache that is merely
        # cold for a moment does not read the same as a deployment that
        # genuinely knows no guild.
        def wait_for_known_guild_ids
          deadline = monotonic_now + SLASH_GUILDS_WAIT_SECONDS
          guild_ids = every_known_guild_id
          until guild_ids.any? || monotonic_now >= deadline
            sleep SLASH_GUILDS_WAIT_POLL_INTERVAL
            guild_ids = every_known_guild_id
          end
          guild_ids
        end

        def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def log_slash_registration_path(guild_ids)
          command_count = @interactions.definitions.size
          if guild_ids.empty?
            logger.info do
              "discord: registering #{command_count} slash command(s) globally, no guild known " \
                "after #{SLASH_GUILDS_WAIT_SECONDS}s wait; Discord caches a global registration " \
                "for about an hour"
            end
          else
            logger.info do
              "discord: registering #{command_count} slash command(s) in each of #{guild_ids.size} " \
                "guild(s) (#{guild_ids.join(", ")}); Discord reflects a per-guild registration " \
                "within about a minute"
            end
          end
        end

        # Every guild this account serves, across every community, resolved live
        # off the gateway because ChannelDiscovery never stamps a discovered
        # channel's settings with its guild; that setting is the fallback for a
        # channel the gateway does not know yet. Deployment-wide on purpose, and
        # right only for something that genuinely applies to all of them, like
        # registering the slash-command set. Anything acting FOR one community
        # wants {#guild_ids_in_community} instead, and the name says so because
        # this is the call that leaked an event into another tenant's server.
        def every_known_guild_id
          every_endpoint.filter_map { |endpoint| resolved_guild_id(endpoint) }.uniq
        end

        # The guilds reachable inside ONE community, in endpoint order. Empty
        # rather than falling back, so a caller that finds nothing here skips
        # its call instead of making it against another tenant's server.
        def guild_ids_in_community(community_id)
          Core::CommunityScope.within(every_endpoint, community_id)
                              .filter_map { |endpoint| resolved_guild_id(endpoint) }.uniq
        end

        # The guild to create a channel in: the template's own where one was
        # given, else this community's first, and never the deployment's. A
        # template in another tenant's guild is refused too, so a mistaken
        # endpoint key cannot carry the create across.
        def guild_for_new_channel(community_id, template, doing)
          allowed = guild_ids_in_community(community_id)
          guild_id = (template && guild_id_for_channel(template)) || allowed.first
          if guild_id.nil?
            logger.error { "discord: REFUSED to #{doing}: community #{community_id.inspect} reaches no guild here" }
            return nil
          end

          guild_in_community?(guild_id, community_id, doing) ? guild_id : nil
        end

        # The latch under both channel management calls, the same one
        # {#in_community} is for the native event calls: a guild serving no
        # room of this community is refused and logged rather than acted on. A
        # guild the gateway cannot name at all passes, since nil is not a guess.
        def guild_in_community?(guild_id, community_id, doing)
          return true if guild_id.nil? || guild_ids_in_community(community_id).include?(guild_id)

          logger.error do
            "discord: REFUSED to #{doing} in guild #{guild_id}, which serves no room of " \
              "community #{community_id.inspect}"
          end
          false
        end

        def resolved_guild_id(endpoint)
          guild_id_for_channel(endpoint.settings[:channel_id]) || endpoint.settings[:guild_id]&.to_s
        end

        # The guild a native call about +endpoint+ must target: that room's own
        # endpoint through {#resolved_guild_id}, else another endpoint of the
        # SAME community. It used to fall back to the first guild known to the
        # account, which on a multi-tenant token is another community's server.
        def guild_id_for_native_call(endpoint)
          raise ArgumentError, "a native scheduled-event call needs the room's own endpoint" if endpoint.nil?

          allowed = guild_ids_in_community(endpoint.community_id)
          in_community(resolved_guild_id(endpoint) || allowed.first, endpoint, allowed)
        end

        # The second latch under {#guild_id_for_native_call}: a guild no room of
        # this community bridges is refused and logged rather than posted into,
        # so a future path that learns a guild some other way still cannot reach
        # another tenant's server. nil skips the call.
        def in_community(guild_id, endpoint, allowed)
          return guild_id if guild_id.nil? || endpoint.community_id.nil? || allowed.include?(guild_id)

          logger.error do
            "discord: REFUSED a native scheduled-event call for #{endpoint.id} against guild #{guild_id}, " \
              "which serves no room of community #{endpoint.community_id}"
          end
          nil
        end

        # Every endpoint bridged in +guild_id+, so a guild scoped event (which
        # carries no channel_id of its own) reaches every bridged channel of
        # that guild instead of one guessed at. The guild is resolved per
        # endpoint the way the native event path resolves it, off the gateway
        # first, because nothing stamps a discovered channel's settings with a
        # guild_id and selecting on that setting alone matched nothing at all.
        def endpoints_for_guild(guild_id)
          every_endpoint.select { |endpoint| resolved_guild_id(endpoint) == guild_id }.uniq(&:id)
        end

        # The same set, narrowed to the ONE community that bridges the guild. A
        # guild two tenants both map names neither of them, so the fan-out is
        # refused and logged rather than announcing one community's arrivals
        # and departures in the other's channels.
        def endpoints_in_guild(guild_id, kind)
          endpoints = endpoints_for_guild(guild_id)
          communities = endpoints.map(&:community_id).uniq
          return endpoints if communities.size <= 1

          logger.error do
            "discord: REFUSED to fan a member #{kind} out from guild #{guild_id}, which serves rooms " \
              "of communities #{communities.map(&:inspect).join(", ")} and names none of them"
          end
          []
        end

        def every_endpoint
          return @index.values if @endpoint_resolver.nil?

          @endpoint_resolver.endpoints_for(:discord, account).map { |(_route_key, endpoint)| endpoint }
        end

        # Adapts a Discordrb::Message fetched from history into the shape the
        # inbound builder expects from a live gateway event, so backfill reuses
        # the live parsing path including the own-webhook skip.
        HistoricalEvent = Struct.new(:message) do
          def channel = message.channel
        end

        # A (Discordrb::Reaction, Discordrb::User) pair from history, reshaped to
        # quack like a live MESSAGE_REACTION_ADD so it runs through the same
        # inbound builder.
        HistoricalReaction = Struct.new(:channel, :message_id, :emoji, :user)

        # The inbound builder reads only #id off the channel, so this stand-in
        # avoids a REST channel fetch on a path that already knows the endpoint.
        ReactionChannel = Struct.new(:id)

        # Discord's epoch, 2015-01-01. Snowflakes encode a millisecond timestamp
        # in their high bits, so a time maps to an "everything after this instant"
        # id boundary; the low bits stay zero so the boundary sits just before any
        # real message posted in that millisecond.
        DISCORD_EPOCH_MS = 1_420_070_400_000

        # The page walk both {#backfill_messages} and {#backfill_candidates}
        # share: from the after-id boundary +since+ maps to, in pages of
        # 100, until +limit+ items are kept or the channel runs dry. The
        # block decides what counts as an item and whether to keep it;
        # +limit+ counts only what it returns, non nil, never raw history
        # rows.
        def history_items(endpoint, since:, limit: 500)
          channel_id = endpoint.settings[:channel_id]
          return [] if channel_id.nil?

          after_id = snowflake_at(since)
          collected = []
          loop do
            page = @client.history(channel_id, after_id: after_id, limit: 100)
            break if page.empty?

            page.each do |native|
              item = yield native
              collected << item unless item.nil?
            end
            after_id = page.last.id
            break if collected.size >= limit || page.size < 100
          end
          collected.first(limit)
        end

        def snowflake_at(time)
          ms = (time.to_f * 1000).to_i - DISCORD_EPOCH_MS
          (ms.positive? ? ms << 22 : 0).to_s
        end

        # Discord's API caps a timeout at 28 days; asking for longer silently
        # does nothing.
        MAX_TIMEOUT_MINUTES = 28 * 24 * 60
        DEFAULT_MUTE_MINUTES = 60

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        def moderate_delete(endpoint, native_id)
          delete(endpoint, native_id)
          ok(endpoint)
        end

        def moderate_ban(command, endpoint)
          server = server_for(endpoint)
          server.ban(command.target_user_id.to_i, reason: "bridged /ban by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_unban(command, endpoint)
          server = server_for(endpoint)
          server.unban(command.target_user_id.to_i)
          ok(endpoint)
        end

        def moderate_kick(command, endpoint)
          server = server_for(endpoint)
          server.kick(command.target_user_id.to_i, "bridged /kick by #{command.issuer}")
          ok(endpoint)
        end

        # Discord has a timeout rather than a mute: the member cannot speak until
        # a moment in the future, and unmuting sets that moment to nil.
        def moderate_timeout(command, endpoint, minutes:)
          server = server_for(endpoint)
          member = server.member(command.target_user_id.to_i)
          raise AdapterError.new("that person is not in this server", adapter: :discord) if member.nil?

          member.timeout = minutes.nil? ? nil : Time.now + (minutes * 60)
          ok(endpoint)
        end

        def moderate_pin(endpoint, native_id, pinned:)
          channel = @client.channel(channel_id_for(endpoint, native_id))
          target = fetch_message(channel, native_id)
          return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :not_found) if target.nil?

          pinned ? target.pin : target.unpin
          ok(endpoint)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord pin failed: #{e.message}", adapter: :discord)
        end

        # Discord has no bulk unpin, but it will list a channel's pins, so this
        # is the one platform where the sweep knows what it took. Each unpin is
        # its own call; a channel is capped at fifty pins, so the loop is bounded.
        def moderate_unpin_all(endpoint)
          channel = @client.channel(channel_id_for(endpoint, nil))
          Array(channel.pins).each(&:unpin)
          ok(endpoint)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("Discord unpinall failed: #{e.message}", adapter: :discord)
        end

        def mute_minutes(command)
          value = command.arguments.first.to_i
          return DEFAULT_MUTE_MINUTES if value <= 0

          [value, MAX_TIMEOUT_MINUTES].min
        end

        def server_for(endpoint)
          channel = @client.channel(endpoint.settings[:channel_id])
          server = channel.respond_to?(:server) ? channel.server : nil
          raise AdapterError.new("cannot find the server for #{endpoint.id}", adapter: :discord) if server.nil?

          server
        end

        # Post under the sender's own name and avatar. Webhook execute carries no
        # message_reference, so a webhook cannot make a native reply and
        # Outbound#compose falls back to a quoted one.
        def deliver_via_webhook(message, endpoint, hook)
          require "rest-client"
          content = @outbound.compose(message, endpoint, webhook: true)
          uploadable = message.attachments.select(&:resolvable?)
          username = message.sender_label || message.author.any_name
          avatar = webhook_avatar(message)

          sent, notes =
            if uploadable.empty?
              # Nothing to send by design, so Bridge must not record a loss.
              return Core::DeliveryReceipt::NOT_APPLICABLE if content.to_s.strip.empty?

              text_only = if @outbound.embed?(content, endpoint)
                            # The webhook already carries the sender's name, so no author field.
                            @webhooks.execute(hook, content: "", username: username, avatar_url: avatar,
                                                    embed: @outbound.embed_for(content),
                                                    allowed_mentions: @outbound.allowed_mentions(message, endpoint))
                          else
                            @webhooks.execute(hook, content: @outbound.clamp(content), username: username,
                                                    avatar_url: avatar,
                                                    allowed_mentions: @outbound.allowed_mentions(message, endpoint))
                          end
              [text_only, []]
            else
              upload_via_webhook(hook, message, content, uploadable, endpoint, username, avatar)
            end
          return nil if sent.nil? || sent["id"].nil?

          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: sent["id"], extra: { notes: notes })
        rescue RestClient::TooManyRequests => e
          # A rate limit is not a broken webhook: forgetting it would force a
          # needless re-resolve, and RateLimitedError reaching Bridge is what
          # gets the wait reported honestly and the retry pointed back at the
          # same webhook, instead of both being silently swallowed here.
          raise RateLimitedError.new(
            "discord: webhook rate limited posting to #{endpoint.id}: #{e.message}",
            adapter: :discord, retry_after: webhook_retry_after(e)
          )
        rescue StandardError => e
          # A webhook deleted in the channel settings, or a permission taken
          # away, must not cost the message.
          logger.warn { "webhook delivery to #{endpoint.id} failed (#{e.message}), posting as the bot" }
          @webhooks.forget(endpoint)
          deliver_as_bot(message, endpoint)
        end

        # Discord's 429 body carries retry_after in seconds, a float; round up,
        # the same shape the bot REST path and every other HTTP adapter read.
        def webhook_retry_after(error)
          body = error.respond_to?(:http_body) ? error.http_body : nil
          parsed = JSON.parse(body.to_s)
          parsed.is_a?(Hash) ? parsed["retry_after"]&.to_f&.ceil : nil
        rescue JSON::ParserError, TypeError
          nil
        end

        # Discord's cap on attachments carried by one message.
        DISCORD_MAX_ATTACHMENTS_PER_MESSAGE = 10

        # Upload every attachment through the webhook as the fewest possible executes,
        # so an album renders as one Discord message with a gallery. Only the first
        # group carries the caption, and its message id is what the message map
        # records, so deleting it takes the whole group with it; a failed attachment
        # is excluded and reported through the returned notes instead.
        #
        # @return [Array(Hash, Array<String>)] threaded back through the call stack,
        #   never stashed on the instance: this adapter is shared across every room's worker thread.
        def upload_via_webhook(hook, message, content, attachments, endpoint, username, avatar)
          mentions = @outbound.allowed_mentions(message, endpoint)
          fetched, missed = fetch_uploadable(attachments, endpoint)
          notes = []

          begin
            first_sent = nil
            group_for_upload(fetched).each_with_index do |group, index|
              caption = index.zero? ? @outbound.clamp(content) : ""
              sent = send_attachment_group(hook, group, caption, username, avatar, mentions, endpoint,
                                            first: index.zero?)
              if sent.nil?
                group.each do |entry|
                  missed << entry[:attachment]
                  logger.warn do
                    "webhook upload of #{entry[:attachment].label} to #{endpoint.id} failed: " \
                      "the webhook call returned no message id"
                  end
                end
              else
                first_sent ||= sent
              end
            end
            missed.each { |attachment| notes << failed_upload_note(attachment) }

            # Nothing crossed: relay the caption and the first reference in one
            # plain text message, then fall through to the loop below for whatever
            # else was missed. An early return here used to drop every missed
            # attachment past the first outright, rather than just losing their upload.
            if first_sent.nil?
              first_sent = @webhooks.execute(hook, content: @outbound.clamp(upload_fallback(content, missed.first)),
                                                    username: username, avatar_url: avatar,
                                                    allowed_mentions: mentions)
              missed = missed.drop(1)
            end

            missed.each do |attachment|
              @webhooks.execute(hook, content: @outbound.clamp(upload_fallback("", attachment)),
                                      username: username, avatar_url: avatar, allowed_mentions: mentions)
            end
            [first_sent, notes]
          ensure
            fetched.each { |entry| release_fetched(entry[:file]) }
          end
        end

        # Download every attachment up front so a group holding several of them
        # can go out as one request; +missed+ carries what the fetcher could
        # not produce a file for, already logged.
        def fetch_uploadable(attachments, endpoint)
          fetched = []
          missed = []
          Array(attachments).each do |attachment|
            file = @fetcher.fetch(attachment.url, filename: attachment.filename)
            if file.nil?
              missed << attachment
              logger.warn do
                "webhook upload of #{attachment.label} to #{endpoint.id} failed: the download produced no file"
              end
            else
              fetched << { attachment: attachment, file: file, bytes: file.size.to_i }
            end
          end
          [fetched, missed]
        end

        def release_fetched(file)
          file.close
          file.unlink
        rescue StandardError
          nil
        end

        # Greedy, in order: as many fetched files as fit under Discord's ten
        # attachment cap and this bridge's configured byte ceiling before
        # starting the next group, which is the fewest groups a single pass
        # over the album can make without reordering it.
        def group_for_upload(fetched)
          limit = upload_limit
          groups = []
          current = []
          current_bytes = 0
          fetched.each do |entry|
            fits = current.size < DISCORD_MAX_ATTACHMENTS_PER_MESSAGE &&
                   (current.empty? || current_bytes + entry[:bytes] <= limit)
            unless fits
              groups << current
              current = []
              current_bytes = 0
            end
            current << entry
            current_bytes += entry[:bytes]
          end
          groups << current unless current.empty?
          groups
        end

        # Send one group as a single webhook execute: a raise on the FIRST
        # group means nothing has crossed yet, so it propagates and
        # deliver_via_webhook's rescue falls back to posting as the bot, same
        # as a plain send. A later group only exists once an album needs more
        # than ten attachments; by then part of it already crossed through
        # the webhook, and letting that same fallback fire would repost that
        # part a second time under the bot, so a later group's failure is
        # swallowed here instead and its files reported as missed.
        def send_attachment_group(hook, group, caption, username, avatar, mentions, endpoint, first:)
          @webhooks.execute_files(hook, content: caption, username: username, avatar_url: avatar,
                                        files: group.map { |entry| entry[:file] }, allowed_mentions: mentions)
        rescue StandardError => e
          raise if first

          logger.warn { "a later group of a split album upload to #{endpoint.id} failed: #{e.message}" }
          nil
        end

        # Only avatars the target platform can fetch without being handed a
        # credential. A Telegram file URL embeds the bot token, so passing one as
        # avatar_url would leak it to Discord's servers; Telegram senders get a
        # name but no picture.
        def webhook_avatar(message)
          Util::SafeUrl.public(message.author&.avatar_url)
        end

        def deliver_as_bot(message, endpoint)
          channel = @client.channel(endpoint.settings[:channel_id])
          content = @outbound.compose(message, endpoint)
          uploadable = message.attachments.select(&:resolvable?)
          # Nothing to say and nothing to upload, so Bridge must not record a loss.
          return Core::DeliveryReceipt::NOT_APPLICABLE if uploadable.empty? && content.to_s.strip.empty?

          sent, notes = if uploadable.empty?
                          [send_text(channel, content, message, endpoint), []]
                        else
                          send_with_file(channel, content, uploadable, message, endpoint)
                        end
          return nil if sent.nil?

          Core::DeliveryReceipt.new(
            endpoint_id: endpoint.id, native_id: sent.id,
            extra: { notes: notes }
          )
        end

        def send_text(channel, content, message, endpoint)
          return nil if content.to_s.strip.empty?

          if @outbound.embed?(content, endpoint)
            return send_embed(channel, content, message, endpoint)
          end

          channel.send_message(
            @outbound.clamp(content), false, nil, nil,
            @outbound.allowed_mentions(message, endpoint),
            reply_reference(message, endpoint)
          )
        end

        # A message over Discord's 2000 character limit goes into an embed
        # (4096) rather than being silently cut.
        def send_embed(channel, content, message, endpoint)
          require "discordrb/webhooks"

          payload = @outbound.embed_for(@outbound.embed_body(message, endpoint),
                                        author_name: message.sender_label)
          embed = ::Discordrb::Webhooks::Embed.new(**payload)
          channel.send_embed(
            "", embed, nil, false,
            @outbound.allowed_mentions(message, endpoint),
            reply_reference(message, endpoint)
          )
        rescue NoMethodError, ArgumentError => e
          # If the library shape changes, a truncated message beats a dropped one.
          logger.warn { "could not send an embed (#{e.message}), falling back to truncated text" }
          channel.send_message(@outbound.clamp(content), false, nil, nil,
                               @outbound.allowed_mentions(message, endpoint),
                               reply_reference(message, endpoint))
        end

        # Discord will not fetch a remote URL, so the bytes come through this
        # process; a file too large or failing to download degrades to
        # posting the link, one per request, so an album becomes several
        # messages. The caption goes out separately through send_text rather
        # than as a send_file caption, because Discord's upload_file route
        # carries no allowed_mentions field and a caption of "@everyone"
        # there would ping the whole server; the first message sent is what
        # the message map points at.
        def send_with_file(channel, content, attachments, message, endpoint)
          first = nil
          notes = []
          Array(attachments).each do |attachment|
            sent, note = upload_one(channel, attachment, message, endpoint)
            notes << note if note
            first ||= sent
          end

          unless content.to_s.strip.empty?
            caption = send_text(channel, content, message, endpoint)
            first ||= caption
          end
          [first, notes]
        end

        # @return [Array(Object, String, nil)] what was sent, and a
        #   failed-upload note when the upload itself did not make it.
        def upload_one(channel, attachment, message, endpoint)
          result = @fetcher.with(attachment.url, filename: attachment.filename) do |file|
            channel.send_file(file, filename: attachment.filename)
          end
          return [result, nil] if result

          logger.info do
            "could not upload #{attachment.label}, relaying a reference instead"
          end
          fallback = send_text(channel, @outbound.clamp(attachment_reference(attachment)), message, endpoint)
          [fallback, failed_upload_note(attachment)]
        end

        # A note for the router to tell the sender their file did not make it
        # across. Returned to the caller rather than stashed on the instance:
        # this adapter is shared across every room's worker thread, so a
        # second room's concurrent delivery must never see or clear it (see
        # {#upload_via_webhook}).
        def failed_upload_note(attachment)
          size = attachment.size
          limit = upload_limit
          reason =
            if size && size > limit
              "it is #{format_bytes(size)}, over this bridge's #{format_bytes(limit)} limit"
            else
              "the upload failed"
            end
          "could not relay #{attachment.label} to Discord: #{reason}"
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

        # What to post when the file itself could not be uploaded. The URL is
        # included only when it carries no secret; see #attachment_reference.
        def upload_fallback(content, attachment)
          [content, attachment_reference(attachment)].reject { |part| part.to_s.empty? }.join("\n")
        end

        # A link when the source URL carries no secret, otherwise a bare marker.
        # A Telegram file URL embeds the bot token, so relaying it would put a
        # working credential into channel history for good.
        def attachment_reference(attachment)
          Util::SafeUrl.public(attachment.url) || "[#{attachment.label}, could not be relayed]"
        end

        def reply_reference(message, endpoint)
          id = @outbound.reply_id(message, endpoint)
          return nil if id.nil?

          { message_id: id.to_i, fail_if_not_exists: false }
        end

        # The message, or nil when Discord answered that it is gone. Every other
        # failure raises, because each caller reads a nil here as a fact about
        # the message: a swallowed 429 or a revoked Read Message History would
        # otherwise be filed as a completed delete, a placed reaction or a
        # dropped edit.
        def fetch_message(channel, native_id)
          channel.load_message(native_id.to_s)
        rescue StandardError => e
          raise unless message_gone?(e)

          nil
        end

        # Whether the error proves the message is gone rather than unreachable.
        # discordrb turns Discord's 10008 into Errors::UnknownMessage and leaves
        # a bodyless 404 as a RestClient class carrying the status, and those two
        # shapes share no ancestor worth matching on across library versions, so
        # this reads the name and the code instead.
        def message_gone?(error)
          return true if error.class.name.to_s.match?(/UnknownMessage|NotFound/)

          code = error.respond_to?(:http_code) ? error.http_code : nil
          code.to_i == 404
        end

        # An emoji Discord has never heard of is stepped over, since no retry
        # will ever place it. Everything else, a 403 and a 429 included, leaves
        # here and reaches the bridge, which then declines to record the mirror.
        def react(target, reaction)
          token = reaction_token(reaction)
          return if token.nil?

          target.create_reaction(token)
        rescue Discordrb::Errors::UnknownEmoji => e
          logger.warn { "could not add reaction #{reaction} on Discord: #{e.message}" }
        end

        def unreact(target, reaction)
          token = reaction_token(reaction)
          return if token.nil?

          target.delete_own_reaction(token)
        rescue Discordrb::Errors::UnknownEmoji => e
          logger.warn { "could not remove reaction #{reaction} on Discord: #{e.message}" }
        end

        # Discord identifies a custom emoji as "name:id" and a unicode one by the
        # character itself. Another platform's custom emoji has no name and an id
        # from an id space Discord knows nothing about, so the emoji it is drawn
        # from goes up instead, and nothing at all where there is none.
        def reaction_token(reaction)
          return reaction.emoji unless reaction.custom?
          return "#{reaction.custom_name}:#{reaction.custom_id}" if reaction.custom_name

          reaction.base_emoji
        end

        # ------------------------------------------------------------------
        # DM control gesture helpers
        # ------------------------------------------------------------------

        # Only when a lane is wired and the event is a non-empty private-channel
        # message that is not the bot's own.
        def control_gesture?(event)
          return false if control_lane.nil?
          return false unless dm_channel?(dm_channel(event))
          return false if own_message?(event)

          !dm_text(event).to_s.strip.empty?
        end

        def dm_channel(event)
          event.respond_to?(:channel) ? event.channel : nil
        end

        # discordrb reports a DM channel through Channel#pm?/#private?. A double
        # with neither is not treated as a DM, so an unconfigured guild channel
        # never triggers this.
        def dm_channel?(channel)
          return false if channel.nil?
          return true if channel.respond_to?(:pm?) && channel.pm?
          return true if channel.respond_to?(:private?) && channel.private?

          false
        rescue StandardError
          false
        end

        # The bot receives its own DM replies back as MESSAGE_CREATE, so without
        # this an answer would be answered again in a loop.
        def own_message?(event)
          id = dm_author_id(event)
          !id.nil? && id.to_s == @own_account_id.to_s
        end

        def dm_text(event)
          payload = dm_payload(event)
          payload.respond_to?(:content) ? payload.content.to_s : ""
        end

        def dm_payload(event)
          event.respond_to?(:message) ? event.message : nil
        end

        def dm_author_id(event)
          user = dm_user(event)
          user && user.respond_to?(:id) ? user.id : nil
        end

        def dm_user(event)
          payload = dm_payload(event)
          payload && payload.respond_to?(:author) ? payload.author : nil
        end

        def dm_author(event)
          user = dm_user(event)
          return nil if user.nil?

          Core::Author.new(
            native_id: dm_field(user, :id),
            username: dm_field(user, :username) || dm_field(user, :name),
            display_name: dm_field(user, :display_name) || dm_field(user, :global_name),
            kind: :user
          )
        end

        def dm_field(user, name)
          user.respond_to?(name) ? user.public_send(name) : nil
        rescue StandardError
          nil
        end

        # Send the lane's reply back into the DM channel as the bot. A failed
        # reply must not take down the gateway thread.
        # The content of the message this DM replied to, where discordrb
        # attached the referenced message. Duck typed like every other reader
        # here: the event is a library object, never a Hash, and a double that
        # does not carry a reference simply answers nothing.
        def quoted_text(event)
          payload = dm_payload(event)
          parent = payload.respond_to?(:referenced_message) ? payload.referenced_message : nil
          text = parent.respond_to?(:content) ? parent.content.to_s : ""
          text.strip.empty? ? nil : text
        rescue StandardError
          nil
        end

        def send_dm_reply(channel, text)
          return if channel.nil? || !channel.respond_to?(:send_message)

          channel.send_message(text.to_s)
        rescue StandardError => e
          logger.warn { "discord: could not reply to a DM control gesture: #{e.message}" }
        end

        def build_index(endpoints)
          endpoints.each_with_object({}) do |endpoint, index|
            index[endpoint.settings[:channel_id].to_s] = endpoint
          end
        end

        # Resolve an inbound channel_id to its endpoint: a nil channel_id (a
        # guild-level event such as a membership change) has no channel to key
        # off, so with a live resolver it always misses. Without one, in
        # config-file mode, the account's single endpoint is the honest
        # answer; guessing the first configured endpoint would be arbitrary
        # once an account bridges more than one guild.
        def endpoint_for(channel_id)
          if @endpoint_resolver
            return nil if channel_id.nil?

            return @endpoint_resolver.endpoint_for(:discord, account, channel_id.to_s)
          end

          return single_configured_endpoint if channel_id.nil?

          @index[channel_id.to_s]
        end

        # The account's own endpoint when config-file mode configured exactly
        # one, for a guild-level event that carries no channel to resolve by.
        # Nil rather than a guess the moment a second endpoint makes "the
        # first one" arbitrary.
        def single_configured_endpoint
          return nil unless @index.size == 1

          @index.values.first
        end

        # Turn a Discord id into something readable. The caches are populated by
        # the gateway, so a member the bot has never seen resolves to nil and the
        # parser falls back to a marker. +channel_id+, when known, is what lets
        # {#user_name} read the per-server nickname instead of the bot-wide name.
        def resolve_mention(type, id, channel_id: nil)
          bot = @client.bot
          return nil if bot.nil?

          case type
          when :user then user_name(bot, id, channel_id: channel_id)
          when :channel then channel_name(bot, id)
          when :role then role_name(bot, id)
          end
        rescue StandardError
          nil
        end

        # The guild MEMBER's nickname wins over the bot-wide User's global name,
        # the same lookup #moderate_timeout already uses to find a member: that is
        # what Discord's own client shows for someone typed as a mention, and a
        # bot-wide User carries no per-server nickname at all. Falls back to the
        # User when the channel's server is unknown or the member is not cached
        # there (a DM, or a member the gateway has not seen).
        def user_name(bot, id, channel_id: nil)
          member = member_for(channel_id, id)
          return "@#{member.display_name}" if member

          user = bot.user(id.to_i)
          return nil if user.nil?

          "@#{user.respond_to?(:display_name) ? user.display_name : user.username}"
        end

        # The Discordrb::Member behind +id+ in the server +channel_id+ belongs to,
        # or nil. Never raises: a channel the bot cannot resolve, or one with no
        # server (a DM), is exactly the case #user_name falls back to the bot-wide
        # User for.
        def member_for(channel_id, id)
          return nil if channel_id.nil?

          channel = @client.channel(channel_id)
          server = channel.respond_to?(:server) ? channel.server : nil
          server&.member(id.to_i)
        rescue StandardError
          nil
        end

        # The bare handle behind a user id, for an attribution that names someone
        # without rendering a mention. Nil for a user the bot cannot see.
        def user_handle(id)
          bot = @client.bot
          user = bot&.user(id.to_i)
          return nil unless user.respond_to?(:username)

          handle = user.username.to_s
          handle.empty? ? nil : handle
        rescue StandardError
          nil
        end

        def channel_name(bot, id)
          channel = bot.channel(id.to_i)
          channel && "##{channel.name}"
        end

        def role_name(bot, id)
          bot.servers.each_value do |server|
            role = server.roles.find { |candidate| candidate.id.to_s == id.to_s }
            return "@#{role.name}" if role
          end
          nil
        end
      end
    end
  end
end
