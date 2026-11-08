# frozen_string_literal: true

module Rubotty
  module Adapters
    module Discord
      # Thin wrapper over discordrb's Bot: everything that touches the
      # library lives here, the only seam a test needs to replace to
      # exercise the adapter without a gateway connection. discordrb is
      # required lazily, so a deployment using only Telegram never loads
      # it, and schemas and capabilities can be inspected without paying
      # for the library.
      class Client
        # MESSAGE_CONTENT is bit 15 of the intents bitfield, not present in
        # discordrb 3.8.0's INTENTS map (which stops at bit 14) or in
        # ALL_INTENTS, so a bot built with intents: :all receives every
        # message with an empty content field. calculate_intents ORs raw
        # Integers, so passing the bit directly is the supported escape
        # hatch.
        MESSAGE_CONTENT_INTENT = 1 << 15

        # GUILD_SCHEDULED_EVENTS is bit 16, missing from discordrb 3.8.0's
        # INTENTS map for the same reason MESSAGE_CONTENT is: the gem predates
        # the intent; unlike MESSAGE_CONTENT it is not privileged, so there is no
        # Developer Portal toggle to also flip. Without it Discord never sends
        # GUILD_SCHEDULED_EVENT_CREATE/UPDATE/DELETE at all, so a native event
        # created through Discord's own UI is invisible to Events::NativeMirror
        # no matter how correctly the rest of that path is wired.
        SCHEDULED_EVENTS_INTENT = 1 << 16

        # Discord's own opt-in intents: requesting one without first flipping it
        # on for this application on the developer portal gets the whole IDENTIFY
        # refused, not just that one intent. message_content predates discordrb
        # 3.8.0's INTENTS map (see above), so it is named here rather than looked
        # up in it.
        PRIVILEGED_INTENTS = %i[message_content server_members server_presences].freeze

        # The WS close code Discord sends for a refused privileged intent.
        PRIVILEGED_INTENT_CLOSE_CODE = 4014

        # discordrb only ever logs a refused IDENTIFY; nothing on Bot or Gateway
        # hands the WS close code back to the caller. Captured here, the one
        # place discordrb itself receives it, so a privileged-intent rejection is
        # something the adapter can act on instead of a line buried in the log.
        module CaptureCloseCode
          def handle_close(event)
            @rubotty_close_code = event.code if event.respond_to?(:code)
            super
          end

          def rubotty_close_code = @rubotty_close_code
        end

        def initialize(token:, logger:, intents: nil, log_mode: :quiet)
          @token = token
          @logger = logger
          @intents = intents
          @log_mode = log_mode
          @bot = nil
        end

        attr_reader :logger

        def bot = @bot

        def connect
          require "discordrb"
          ::Discordrb::Gateway.prepend(CaptureCloseCode) unless ::Discordrb::Gateway.ancestors.include?(CaptureCloseCode)

          @bot = ::Discordrb::Bot.new(
            token: @token,
            intents: intents_bitfield,
            log_mode: @log_mode,
            # The bridge does its own caching decisions; discordrb's member
            # chunking would pull every member of every guild at startup, which
            # on a large server is slow and rate limit heavy for no benefit.
            fancy_log: false
          )
          @bot
        rescue LoadError => e
          raise AdapterError.new(
            "the discordrb gem is not available: #{e.message}. Run `bundle install`.",
            adapter: :discord
          )
        end

        # Resolve the configured intents into the bitfield discordrb wants,
        # always including MESSAGE_CONTENT, SCHEDULED_EVENTS and the two a
        # bridge cannot receive anything without.
        def intents_bitfield
          require "discordrb"

          bits = configured_intents.reduce(0) do |sum, name|
            symbol = name.to_sym
            next sum | MESSAGE_CONTENT_INTENT if symbol == :message_content
            next sum | SCHEDULED_EVENTS_INTENT if symbol == :server_scheduled_events

            bit = ::Discordrb::INTENTS[symbol]
            if bit.nil?
              logger.warn { "unknown Discord intent #{symbol.inspect}, ignoring" }
              next sum
            end
            sum | bit
          end
          bits | MESSAGE_CONTENT_INTENT | SCHEDULED_EVENTS_INTENT | receiving_intents
        end

        # The account's own list, or the adapter's default when it resolves to
        # nothing at all. Config::Schema fills a default in for an ABSENT key
        # only, so a stored `intents: []` arrives here intact and used to mean
        # "subscribe to nothing", which is never what an operator means.
        def configured_intents
          list = Array(@intents).compact
          return list unless list.empty?

          logger.warn { "no Discord gateway intents configured, using the account default" }
          Adapter::DEFAULT_INTENTS
        end

        # GUILDS and GUILD_MESSAGES, forced for the same reason MESSAGE_CONTENT
        # is. Without them Discord still opens the gateway and still answers
        # READY, so the bot signs in and sends normally, but no message event is
        # ever delivered and no guild is ever cached: a bridge that looks healthy
        # and has silently gone one-directional. MESSAGE_CONTENT alone does not
        # cover it, being a modifier on GUILD_MESSAGES rather than a delivery
        # intent of its own.
        def receiving_intents
          ::Discordrb::INTENTS[:servers] | ::Discordrb::INTENTS[:server_messages]
        end

        # True once the gateway has actually closed with Discord's own
        # "disabled privileged intents" code, whatever @bot.profile's REST
        # fallback still makes #own_id and #own_name answer.
        def privileged_intent_rejected?
          gateway = @bot&.gateway
          gateway.respond_to?(:rubotty_close_code) && gateway.rubotty_close_code == PRIVILEGED_INTENT_CLOSE_CODE
        end

        # Which of the intents actually requested are privileged, and so the
        # candidates a rejection is about: the close frame never says which.
        def requested_privileged_intents
          (configured_intents.map(&:to_sym) + [:message_content]).uniq & PRIVILEGED_INTENTS
        end

        # Start the gateway on a background thread and wait until it is ready.
        #
        # discordrb's `run(true)` returns as soon as the thread is spawned, well
        # before the gateway has finished IDENTIFY. Sending anything in that
        # window fails, and `profile` is not populated, so the adapter would
        # start without knowing its own id and lose its main loop defence.
        def run_async(timeout: 30)
          ready = Thread::Queue.new
          @bot.ready { ready.push(:ready) }
          @bot.run(true)
          wait_for(ready, timeout)
          self
        end

        def stop
          @bot&.stop
          @bot = nil
        rescue StandardError => e
          logger.warn { "error while stopping the Discord gateway: #{e.message}" }
          nil
        end

        def connected? = !@bot.nil? && @bot.connected?

        def own_id
          @bot&.profile&.id&.to_s
        end

        def own_name
          @bot&.profile&.username
        end

        def channel(channel_id)
          @bot.channel(channel_id.to_i)
        rescue StandardError => e
          raise AdapterError.new("cannot reach Discord channel #{channel_id}: #{e.message}", adapter: :discord)
        end

        # The channel a read should work on, or nil when Discord no longer has
        # one under that id. A deleted or moved channel answers nil rather than
        # raising, which a caller walking a stored channel list has to be able
        # to skip: the sweep would otherwise die on the first stale row with a
        # NoMethodError for #history on nil, and take every later channel's
        # backfill with it.
        def resolved_channel(channel_id)
          found = @bot.channel(channel_id.to_i)
          logger&.warn { "discord: channel #{channel_id} is gone, skipping it" } if found.nil?
          found
        end

        # ------------------------------------------------------------------
        # guild membership and discovery
        # ------------------------------------------------------------------

        # These four methods are the ONLY place the discordrb guild/channel gateway
        # surface is touched for auto-leave and channel discovery; a fake client
        # implements the same four, working on neutral values (guild ids,
        # {id:, name:} hashes), so the whole join and discovery path is unit-testable.

        # Every text channel in a guild, as neutral {id:, name:} hashes; only
        # text channels are mappable routing leaves, and categories and voice
        # channels are skipped. Never raises: a listing that could not be
        # read comes back marked unavailable rather than empty, since
        # discordrb's Cache#server answers nil both for a guild the bot is
        # not in and for one the REST resolve was refused.
        #
        # @return [ChannelListing]
        def guild_text_channels(guild_id)
          server = @bot&.server(guild_id.to_i)
          return ChannelListing.unavailable("guild #{guild_id} is not visible to this bot") if server.nil?

          channels = server.respond_to?(:text_channels) ? server.text_channels : server.channels
          ChannelListing.listed(Array(channels).map do |channel|
            { id: channel.id.to_s, name: (channel.respond_to?(:name) ? channel.name : nil).to_s }
          end)
        rescue StandardError => e
          logger.warn { "cannot enumerate Discord channels for guild #{guild_id}: #{e.message}" }
          ChannelListing.unavailable("#{e.class}: #{e.message}")
        end

        # ------------------------------------------------------------------
        # channel management
        # ------------------------------------------------------------------

        # Create a text channel in +guild_id+, optionally under the same
        # category as +template_id+ (an existing channel's native id), so a
        # new room lands next to the channel it was modelled on rather than
        # loose at the guild root. Returns the new channel's native id.
        def create_guild_channel(guild_id, name, template_id: nil)
          server = @bot&.server(guild_id.to_i)
          raise AdapterError.new("discord: guild #{guild_id} is not visible to this bot", adapter: :discord,
                                                                                            retryable: false) if server.nil?

          parent = template_id ? channel(template_id)&.parent : nil
          created = server.create_channel(name.to_s, 0, parent: parent, reason: "rubotty: room provisioning")
          created.id.to_s
        rescue AdapterError
          raise
        rescue StandardError => e
          raise permission_or_adapter_error("create channel #{name.inspect} in guild #{guild_id}", e)
        end

        # Delete a channel by native id. Returns true on a confirmed delete.
        def delete_guild_channel(channel_id)
          target = channel(channel_id)
          return false if target.nil?

          target.delete("rubotty: room provisioning")
          true
        rescue StandardError => e
          raise permission_or_adapter_error("delete channel #{channel_id}", e)
        end

        # Copy every role and member permission overwrite from +from_id+ onto
        # +to_id+. Returns true when at least one overwrite was copied, false
        # when the source channel had none (a clean "nothing to copy", not a
        # failure).
        def copy_permission_overwrites(from_id, to_id)
          source = channel(from_id)
          target = channel(to_id)
          return false if source.nil? || target.nil?

          overwrites = source.permission_overwrites.values
          return false if overwrites.empty?

          overwrites.each { |overwrite| target.define_overwrite(overwrite) }
          true
        rescue StandardError => e
          raise permission_or_adapter_error("copy permissions from #{from_id} to #{to_id}", e)
        end

        # Leave a guild; discordrb's Server#leave removes the bot from the
        # guild. True only when a server was resolved and the leave call
        # went through: discordrb's Cache#server answers nil for a guild it
        # has no cached view of and cannot resolve over REST, and that must
        # not read as a departure that happened.
        #
        # @return [Boolean]
        def leave_server(guild_id)
          server = @bot&.server(guild_id.to_i)
          return false if server.nil?

          server.leave
          true
        end

        # How many members a guild has, for the pending-space card. Nil when the
        # gateway has no cached view of it, which the dashboard shows as unknown.
        def guild_member_count(guild_id)
          server = @bot&.server(guild_id.to_i)
          count = server&.member_count if server.respond_to?(:member_count)
          count.is_a?(Integer) ? count : nil
        rescue StandardError
          nil
        end

        # Post a plain departure notice in a guild, best effort; returns nil and
        # never raises, since a missed notice must not stop the leave. Discord has
        # no "post to a whole guild", so the system channel, else the first text
        # channel the bot can reach, is the closest to a group-wide notice.
        def post_guild_notice(guild_id, text)
          return nil if text.to_s.empty?

          server = @bot&.server(guild_id.to_i)
          channel = default_text_channel(server)
          channel&.send_message(text.to_s)
        rescue StandardError => e
          logger.info { "could not post the leave notice in guild #{guild_id}: #{e.message}" }
          nil
        end

        # DM +native_id+, best effort; discordrb resolves a user id to a private
        # channel and opens one if needed, so nothing to cache here. Discord refuses
        # the send (a 403) when the recipient shares no guild with the bot or has
        # DMs from server members off; that is reported, not raised, since an
        # unreachable operator is not a failure worth propagating.
        #
        # @return [Hash, nil] {message_id:, channel_id:} on success, enough
        #   to delete the DM later; nil when it did not go out
        def send_direct_message(native_id, text)
          return nil if text.to_s.empty?

          user = @bot&.user(native_id.to_i)
          return refused_dm(native_id, "no such user on this connection") if user.nil?

          message = user.pm(text.to_s)
          { message_id: message.id.to_s, channel_id: message.channel.id.to_s }
        rescue StandardError => e
          refused_dm(native_id, e.message)
        end

        # One refused DM, at warn rather than info: a silently dropped DM
        # shrinks the operator audience and nobody looks for it until an
        # alert has already gone missing.
        def refused_dm(native_id, reason)
          logger.warn { "could not DM discord user #{native_id}: #{reason}" }
          nil
        end

        # Who added the bot to a guild, best effort; without the "View Audit Log"
        # permission, or before the entry lands, this returns nil rather than
        # raising, since the join signal must never depend on a permission the bot
        # might not hold. Discord's GUILD_CREATE carries no inviter field, so this
        # reads the audit log's BOT_ADD entry targeting the bot's own account instead.
        #
        # @param bot_user_id [String, Integer] this bot's own account id
        # @return [Hash, nil] { id:, username:, display_name: } or nil
        def guild_inviter(guild_id, bot_user_id)
          server = @bot&.server(guild_id.to_i)
          return nil if server.nil?

          entry = server.audit_logs(action: :bot_add, limit: 10).entries
                        .find { |candidate| bot_add_target_id(candidate) == bot_user_id.to_s }
          user = entry&.user
          return nil if user.nil?

          {
            id: (user.respond_to?(:id) ? user.id.to_s : nil),
            username: (user.respond_to?(:username) ? user.username : nil),
            display_name: (user.respond_to?(:display_name) ? user.display_name : nil)
          }
        rescue StandardError => e
          logger.info { "could not read the bot-add audit log entry for guild #{guild_id}: #{e.message}" }
          nil
        end

        # ------------------------------------------------------------------
        # native slash commands
        # ------------------------------------------------------------------

        # The three methods below are the ONLY place the discordrb
        # application-command and interaction API is touched; a fake client
        # implements the same three, translating to and from the same neutral
        # value objects, so the whole slash path is unit testable with no gateway.

        # Register a handler so an invocation of +name+ reaches +block+, which is
        # called with a neutral {Interactions::Interaction}. discordrb both
        # declares the handler and (with server_id) scopes it; we register the
        # handler globally and let the per guild command definitions do the
        # scoping, so one handler serves every community.
        def on_application_command(name, &block)
          @bot.application_command(name.to_sym) do |event|
            block.call(build_interaction(event))
          end
        end

        # Catch every command interaction, known or not: Discord's generic
        # INTERACTION_CREATE fires through #interaction_create BEFORE discordrb
        # looks up a name-specific #application_command handler, so this fires for
        # a stale global command (e.g. /chatinfo, retired from CommandRegistry but
        # still registered with Discord) exactly as much as for a known one. The
        # caller must check the interaction's name against the registry and only
        # act on ones with no other handler; a known command still gets its normal
        # reply from #on_application_command, unaffected by this also firing.
        def on_unknown_application_command(&block)
          @bot.interaction_create do |event|
            next unless event.type == Discordrb::Interaction::TYPES[:command]

            block.call(build_interaction(event))
          end
        end

        # Prune GLOBAL application commands Discord still has registered that are
        # not in +current_names+, best effort: called once per boot, and a failure
        # here must not stop the rest of registration. Per-guild registration only
        # ever ADDS or UPDATES a command by name; it never removes one Discord
        # already knows about globally, so a command retired from CommandRegistry
        # lingers as a stale global forever until this actively deletes it.
        def prune_stale_global_commands(current_names)
          known = current_names.map(&:to_s)
          @bot.get_application_commands.each do |command|
            next if known.include?(command.name.to_s)

            @bot.delete_application_command(command.id, server_id: nil)
          end
        rescue StandardError => e
          raise AdapterError.new("cannot prune stale Discord global commands: #{e.message}", adapter: :discord)
        end

        # Push one application-command DEFINITION to Discord, per guild when a
        # +guild_id+ is given, otherwise global. Builds the option list from the
        # neutral {Interactions::Definition} so nothing discordrb-shaped leaks up.
        def register_application_command(definition, guild_id: nil)
          @bot.register_application_command(
            definition.name, definition.description,
            server_id: guild_id,
            default_member_permissions: definition.default_member_permissions
          ) do |builder|
            Array(definition.options).each { |option| add_option(builder, option) }
          end
        end

        # Up to +limit+ messages posted AFTER +after_id+ in +channel_id+,
        # returned oldest first, for the backfill sweep that recovers
        # activity missed while the gateway was down. discordrb's
        # Channel#history takes (amount, before, after) and Discord returns
        # at most 100 per call, so the caller advances +after_id+ to
        # paginate. Returned in id (chronological) order regardless of the
        # API's own ordering.
        def history(channel_id, after_id:, limit: 100)
          channel = resolved_channel(channel_id)
          return [] if channel.nil?

          messages = channel.history(limit, nil, after_id.to_s)
          messages.sort_by(&:id)
        rescue StandardError => e
          # Read Message History being absent is an ordinary, permanent state for a
          # channel nobody granted it on, until somebody changes the permission.
          # Separating it here is what lets the sweep say so once and quietly rather
          # than at ERROR on every boot.
          raise permission_or_adapter_error("fetch history for #{channel_id}", e)
        end

        # Every (emoji, user) pair currently reacting to message +message_id+ in
        # +channel_id+, as neutral [emoji, user] pairs the inbound builder shapes
        # exactly like a live MESSAGE_REACTION_ADD, bounded by +limit+ across all
        # emoji, with each emoji's user page capped at Discord's 100 maximum, so an
        # old, heavily-reacted message cannot make backfill unbounded. The gateway
        # RESUME window does not survive a long outage, so the backfill sweep
        # recovers reactions missed while the bot was down through this REST read.
        def reactions(channel_id, message_id, limit: 200)
          channel = resolved_channel(channel_id)
          return [] if channel.nil?

          message = channel.load_message(message_id.to_s)
          return [] if message.nil?

          pairs = []
          Array(message.reactions).each do |reaction|
            break if pairs.size >= limit

            page = [limit - pairs.size, 100].min
            message.reacted_with(reaction, limit: page).each do |user|
              pairs << [reaction, user]
              break if pairs.size >= limit
            end
          end
          pairs
        rescue StandardError => e
          raise AdapterError.new("cannot fetch Discord reactions for #{message_id}: #{e.message}", adapter: :discord)
        end

        # Edit a bot authored message, carrying an allowed_mentions whitelist.
        #
        # discordrb's Message#edit cannot: it calls API.edit_message with the
        # mentions argument left nil, so the edited content re parses every
        # mention token. API.edit_message DOES accept the whitelist (its
        # +mentions+ argument becomes the body's allowed_mentions), so the edit
        # goes straight through it, keeping the same suppression the send path
        # has.
        def edit_message(channel_id, message_id, content, allowed_mentions: nil)
          require "discordrb"

          ::Discordrb::API::Channel.edit_message(
            @bot.token, channel_id.to_i, message_id.to_s, content, allowed_mentions
          )
        end

        # ------------------------------------------------------------------
        # guild scheduled events
        # ------------------------------------------------------------------

        # discordrb 3.8.0 wraps neither Discord's Guild Scheduled Events REST
        # endpoints nor an event class for their gateway dispatches, so this and
        # the three calls below go straight through Discordrb::API.request, the
        # same authenticated, rate-limited primitive every wrapped endpoint (see
        # #edit_message above) is itself built on. ScheduledEvents never touches
        # the API module directly, so a release that adds real wrappers changes
        # only these four methods.
        def create_scheduled_event(guild_id, payload)
          require "discordrb"

          parse(::Discordrb::API.request(
            :guilds_gid_scheduled_events, guild_id.to_s, :post,
            "#{::Discordrb::API.api_base}/guilds/#{guild_id}/scheduled-events",
            payload.to_json,
            Authorization: @bot.token, content_type: :json
          ))
        rescue StandardError => e
          raise AdapterError.new("cannot create a Discord scheduled event in guild #{guild_id}: #{e.message}",
                                 adapter: :discord)
        end

        def update_scheduled_event(guild_id, event_id, payload)
          require "discordrb"

          parse(::Discordrb::API.request(
            :guilds_gid_scheduled_events_eid, guild_id.to_s, :patch,
            "#{::Discordrb::API.api_base}/guilds/#{guild_id}/scheduled-events/#{event_id}",
            payload.to_json,
            Authorization: @bot.token, content_type: :json
          ))
        rescue StandardError => e
          raise AdapterError.new("cannot update Discord scheduled event #{event_id}: #{e.message}", adapter: :discord)
        end

        def delete_scheduled_event(guild_id, event_id)
          require "discordrb"

          ::Discordrb::API.request(
            :guilds_gid_scheduled_events_eid, guild_id.to_s, :delete,
            "#{::Discordrb::API.api_base}/guilds/#{guild_id}/scheduled-events/#{event_id}",
            Authorization: @bot.token
          )
          nil
        rescue StandardError => e
          raise AdapterError.new("cannot delete Discord scheduled event #{event_id}: #{e.message}", adapter: :discord)
        end

        # Every user who marked interest in the scheduled event, up to
        # +limit+ (Discord caps a single page at 100; the adapter capability
        # (#read_native_rsvps) has no pagination need yet, so this stays a
        # single page rather than growing a cursor loop nothing calls for).
        def scheduled_event_users(guild_id, event_id, limit: 100)
          require "discordrb"

          Array(parse(::Discordrb::API.request(
            :guilds_gid_scheduled_events_eid_users, guild_id.to_s, :get,
            "#{::Discordrb::API.api_base}/guilds/#{guild_id}/scheduled-events/#{event_id}/users?limit=#{limit}",
            Authorization: @bot.token
          )))
        rescue StandardError => e
          raise AdapterError.new(
            "cannot read Discord scheduled event users for #{event_id}: #{e.message}", adapter: :discord
          )
        end

        private

        # discordrb raises Errors::NoPermission for a locally-known missing
        # permission and a RestClient error whose class name carries the HTTP status
        # otherwise; no single common ancestor is worth relying on across discordrb
        # versions, so this reads both signals off the exception rather than
        # matching a class. A 403 becomes {PermissionError}, never retried; a 429
        # becomes {RateLimitedError} carrying Discord's own wait; anything else is
        # a plain {AdapterError}.
        def permission_or_adapter_error(doing, error)
          if rate_limited?(error)
            return RateLimitedError.new("discord: rate limited while trying to #{doing}: #{error.message}",
                                        adapter: :discord, retry_after: retry_after_of(error))
          end

          forbidden = error.class.name.to_s.match?(/NoPermission|Forbidden/i) || error.message.to_s.include?("403")
          if forbidden
            PermissionError.new("discord: cannot #{doing}: #{error.message}", adapter: :discord)
          else
            AdapterError.new("discord: cannot #{doing}: #{error.message}", adapter: :discord, retryable: true)
          end
        end

        def rate_limited?(error)
          return true if error.respond_to?(:http_code) && error.http_code == 429

          error.class.name.to_s.include?("TooManyRequests") || error.message.to_s.include?("429")
        end

        # Discord's 429 body carries retry_after in seconds, a float; round up
        # like the other three HTTP adapters do.
        def retry_after_of(error)
          body = error.respond_to?(:http_body) ? error.http_body : nil
          parsed = JSON.parse(body.to_s)
          parsed.is_a?(Hash) ? parsed["retry_after"]&.to_f&.ceil : nil
        rescue JSON::ParserError, TypeError
          nil
        end

        # discordrb hands back a RestClient::Response; only the parsed JSON
        # body is wanted.
        def parse(response)
          body = response.respond_to?(:body) ? response.body : response
          return nil if body.nil? || body.to_s.empty?

          JSON.parse(body.to_s)
        rescue JSON::ParserError
          nil
        end

        # The id of a BOT_ADD audit-log entry's target (the bot that was added),
        # read defensively so a library shape change degrades to "no match"
        # rather than raising.
        def bot_add_target_id(entry)
          target = entry.target
          target.respond_to?(:id) ? target.id.to_s : nil
        rescue StandardError
          nil
        end

        # The channel a guild-wide notice should go to: the system channel when
        # the guild has one, else the first text channel. Nil when neither exists,
        # in which case the notice is simply skipped.
        def default_text_channel(server)
          return nil if server.nil?
          return server.system_channel if server.respond_to?(:system_channel) && server.system_channel

          channels = server.respond_to?(:text_channels) ? server.text_channels : server.channels
          Array(channels).first
        end

        # Turn a discordrb ApplicationCommandEvent into the neutral value object
        # {Interactions} works on, including a responder that sends Discord's
        # native EPHEMERAL interaction reply (only the invoker sees it, and there
        # is nothing left in the channel to clean up afterwards).
        def build_interaction(event)
          user = event.respond_to?(:user) ? event.user : nil
          Interactions::Interaction.new(
            name: command_name_of(event),
            channel_id: id_of(event, :channel_id),
            guild_id: id_of(event, :server_id),
            user: build_user(user),
            options: options_of(event),
            responder: ->(text) { event.respond(content: text, ephemeral: true) }
          )
        end

        def build_user(user)
          return nil if user.nil?

          Interactions::User.new(
            id: user.respond_to?(:id) ? user.id&.to_s : nil,
            username: user.respond_to?(:username) ? user.username : nil,
            # The raw per-guild nickname, nil if the member set none. Only a
            # Member (a guild slash invocation) exposes #nick at all; a plain
            # User (a DM invocation) has no guild to hold one in.
            nickname: user.respond_to?(:nick) ? user.nick : nil,
            # The pure global name, deliberately NOT Member#display_name: that
            # method already folds the nickname in ahead of it, which is exactly
            # the already-merged shape Interactions::User's nickname/display_name
            # split exists to avoid.
            display_name: user.respond_to?(:global_name) ? user.global_name : (
              user.respond_to?(:display_name) ? user.display_name : nil
            )
          )
        end

        # discordrb exposes the invoked command by name and the supplied options
        # as a hash. Both are read defensively so a library shape change degrades
        # to "unknown command" rather than raising on the gateway thread.
        def command_name_of(event)
          return event.command_name.to_s if event.respond_to?(:command_name)
          # The generic InteractionCreateEvent #on_unknown_application_command
          # feeds through here has no #command_name (only the specific
          # ApplicationCommandEvent subclass does), but it carries the same
          # raw interaction data, whose "name" key is the command word.
          return event.interaction.data["name"].to_s if event.respond_to?(:interaction) && event.interaction&.data

          nil
        end

        def options_of(event)
          return {} unless event.respond_to?(:options)

          (event.options || {}).each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        rescue StandardError
          {}
        end

        def id_of(event, method)
          return nil unless event.respond_to?(method)

          value = event.public_send(method)
          value&.to_s
        rescue StandardError
          nil
        end

        # Map a neutral option onto discordrb's OptionBuilder. A :message target
        # is a string (the message id), since Discord has no message option type
        # for a slash command; :user is a native member picker.
        def add_option(builder, option)
          description = option.description.to_s
          case option.type
          when :integer then builder.integer(option.name, description, required: option.required)
          when :boolean then builder.boolean(option.name, description, required: option.required)
          when :user then builder.user(option.name, description, required: option.required)
          else builder.string(option.name, description, required: option.required)
          end
        end

        def wait_for(queue, timeout)
          queue.pop(timeout: timeout)
        rescue ArgumentError
          # Thread::Queue#pop gained a timeout in Ruby 3.2. Older interpreters
          # fall back to a bounded poll rather than failing to boot.
          deadline = Time.now + timeout
          sleep(0.1) while queue.empty? && Time.now < deadline
        end
      end
    end
  end
end
