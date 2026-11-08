# frozen_string_literal: true

require "set"

module Rubotty
  module Adapters
    module Irc
      # The IRC platform adapter. One connection is one nick, so identity is
      # a text prefix; plain RFC 1459 has no native edits, deletes, reactions
      # or replies, so those degrade to text, and {#capabilities_for}
      # upgrades the floor from what this connection negotiated.
      # Bridging modes: per_room (default) joins one channel per room; hub mirrors every
      # room into one `hub_channel`, at most one endpoint `receives: true` since IRC
      # can't tell which room a shared-channel message was meant for. See {Client#connect}
      # for SASL/JOIN ordering, {Client#ban_mask} for hostmask bans.
      class Adapter < Adapters::Base
        class << self
          def identity_durability = :session

          def adapter_name = :irc

          def account_schema
            Config::Schema.define do
              field :server, :string, required: true, desc: "IRC server host, for example irc.libera.chat"
              field :port, :integer, default: 6697, desc: "server port (6697 is the usual TLS port)"
              field :tls, :boolean, default: true, desc: "connect over TLS"
              field :nick, :string, required: true, desc: "the nick to connect as"
              field :realname, :string, default: "rubotty", desc: "the GECOS/realname field"
              field :password_env, :string, env: true,
                                            desc: "env var holding a server password (PASS), if the server needs one"
              field :sasl_user, :string,
                                desc: "SASL PLAIN account name, often the same as nick. Set alongside " \
                                      "sasl_password_env to identify to services before any channel is " \
                                      "joined, which many networks require for a +r channel"
              field :sasl_password_env, :string, env: true,
                                                 desc: "env var holding the SASL PLAIN password"
              field :mode, :symbol, default: :per_room, one_of: %i[hub per_room],
                                    desc: "'per_room' (the default) joins one IRC channel per bridged " \
                                          "room. 'hub' mirrors every bridged room into hub_channel " \
                                          "instead; see the class documentation for how that is wired"
              field :hub_channel, :string,
                                  desc: "the one channel every bridged room mirrors into. Required, and " \
                                        "used only, when mode is 'hub'"
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :channel, :string, required: true, desc: "IRC channel, for example #general"
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages"
              field :sender_separator, :string, default: ":", desc: "printed after the sender name"
              field :channel_key_env, :string, env: true,
                                               desc: "env var holding this channel's +k key, if it needs one"
              field :room_label, :string,
                                 desc: "printed before the sender name, e.g. '[gaming] ', so an IRC " \
                                       "reader can tell rooms apart when several endpoints share one " \
                                       "channel (hub mode). Leave unset for a plain per-room mapping"
              field :short_code, :string,
                                 desc: "explicit two letter hub-mode addressing code for this room " \
                                       "(issue #231), e.g. 'gs' for '!gs hello'. Leave unset to derive " \
                                       "one from room_label automatically; only meaningful when this " \
                                       "endpoint shares a channel with others (hub mode)"
            end
          end

          def validate_endpoint(settings, path)
            channel = settings[:channel].to_s
            return [] if Protocol.channel?(channel)

            ["#{path}.channel: expected an IRC channel like #general, got #{channel.inspect}"]
          end

          def validate_account(settings, path)
            return [] unless settings[:mode] == :hub

            hub_channel = settings[:hub_channel].to_s
            return [] if Protocol.channel?(hub_channel)

            ["#{path}.hub_channel: required, and must look like an IRC channel, when mode is 'hub'; " \
             "got #{hub_channel.inspect}"]
          end

          # No .addressing override: nothing in this adapter calls
          # ChannelDiscovery, so {.discovers_channels?} stays false. Downcased
          # because every inbound lookup here downcases first: a seeded
          # "#Rubotty" that kept its capitals would never match the
          # "#rubotty" a PRIVMSG arrives under.
          def route_key_for(endpoint) = endpoint.settings[:channel].to_s.downcase

          # A PRIVMSG to a nick is an ordinary DM, so #send_admin_dm works
          # regardless of what the server negotiates. Deleting one needs
          # draft/message-redaction, which is a per connection capability
          # rather than a fact about the platform, so admin_dm_delete stays
          # unclaimed here rather than promising something a given server
          # may never offer.
          def supports_admin_dm? = true
        end

        # What this adapter can do with no IRCv3 capability negotiated at all,
        # i.e. classic RFC 1459. #capabilities_for layers a per connection
        # upgrade on top.
        CAPABILITIES = Capabilities.new(
          edits: false,
          deletes: false,
          replies: false,
          threads: false,
          max_attachment_bytes: nil,
          reactions: false,
          moderation: %i[kick ban unban]
        ).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil)
          super
          @nick = settings[:nick]
          @client = Client.new(
            server: settings[:server], port: settings[:port] || 6697,
            tls: settings.fetch(:tls, true), nick: @nick,
            realname: settings[:realname] || "rubotty", password: settings[:password],
            sasl_user: settings[:sasl_user], sasl_password: settings[:sasl_password], logger: logger
          )
          @outbound = Outbound.new(logger: logger)
          # Every endpoint addressing the same physical channel, grouped so a
          # hub channel joins once and resolves inbound to exactly one of them.
          @channel_groups = group_by_channel(endpoints)
          @index = build_index(@channel_groups)
          @inbound = Inbound.new(endpoint_for: method(:endpoint_for), logger: logger)
          # Physical channels joined so far, boot time plus anything
          # {#reconcile_channels} has added since; downcased, matching what
          # {.route_key_for} and {#join_route} both put into a channel row.
          @joined_channels = Set.new(
            @channel_groups.values.map { |group| group.first.settings[:channel].to_s.downcase }
          )
          # Hub-mode short codes, so a code exists only where more than one room
          # of ONE community shares a channel.
          @hub_router = HubRouter.new(channel_groups: hub_groups(endpoints))
          @started = false
          # Set in #start once negotiation has settled; nil falls back to the floor.
          @capabilities = nil
        end

        attr_reader :client

        def replace_client(client)
          @client = client
          self
        end

        # The static, connection independent floor. Prefer {#capabilities_for}
        # wherever an endpoint is available; this underclaims on a network that
        # negotiated message-tags, msgid or draft/message-redaction.
        def capabilities = CAPABILITIES

        # The origin platform token for the sender label: the server host the
        # bridge connected to, since a bare nick means nothing across networks.
        def origin_label(_endpoint = nil) = settings[:server].to_s

        # Core::SenderLabel prefixes the handle with this protocol token:
        # "irc::ada@irc.example.org".
        def origin_protocol(_endpoint = nil) = "irc"

        # What this one connection can do. Every endpoint on an account shares
        # one physical connection, so the endpoint parameter is unused and this
        # is memoized once in {#start}.
        def capabilities_for(_endpoint) = @capabilities || CAPABILITIES

        # Our nick. IRC never echoes our own PRIVMSG back, so this is only the
        # loop guard's registered identity, never actually matched inbound.
        def own_account_id = @nick

        # @started only ever clears in #stop, so it alone would report a
        # connection the server dropped as healthy forever. Asking the client
        # whether its read loop is still up catches that.
        def running? = @started && @client.alive?

        # One IRC socket, held open for the life of the process.
        def persistent_connection? = true

        def start
          @client.on_message(&method(:handle_message))
          @client.on_dm(&method(:handle_dm))
          @client.connect
          # Negotiation is settled by the time #connect returns.
          @capabilities = resolved_capabilities(@client.negotiated_capabilities)
          join_channels
          @started = true
          logger.info { "joined #{@channel_groups.size} IRC channel(s) as #{@nick}" }
          start_reconcile_loop
          self
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("IRC adapter failed to start: #{e.class}: #{e.message}", adapter: :irc)
        end

        def stop
          @client.close
          @started = false
          self
        end

        def deliver(message, endpoint)
          body = @outbound.compose(
            message, endpoint, capabilities: capabilities_for(endpoint), short_code: @hub_router.code_for(endpoint)
          )
          # Nothing to send by design, so Bridge must not record a loss.
          return Core::DeliveryReceipt::NOT_APPLICABLE if body.strip.empty?

          native_id = @client.privmsg(endpoint.settings[:channel], body, tags: reply_tags(message, endpoint))
          extra_ids = native_id && @client.ids_for(native_id)
          # A synthetic id satisfies the receipt where the server assigned no
          # msgid, and is never used to address the message again. extra[:ids]
          # carries every id a wrapped send crossed as, first included, so a
          # future multi-line aware delete or react has somewhere to read it.
          extra = extra_ids.to_a.empty? ? {} : { ids: [native_id, *extra_ids] }
          Core::DeliveryReceipt.new(
            endpoint_id: endpoint.id, native_id: native_id || "irc-#{Time.now.to_f}",
            extra: extra.merge(notes_extra(message))
          )
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("IRC send failed: #{e.class}: #{e.message}", adapter: :irc, retryable: true)
        end

        # DM +text+ to +native_id+ (a nick): a PRIVMSG addressed to a nick
        # rather than a channel, the same #privmsg a channel send uses. A nil
        # native_id here means the server named no msgid, not that the send
        # failed, so a synthetic one stands in the same way #deliver's does.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          sent = @client.privmsg(native_id, text)
          Core::DmReceipt.new(native_id: sent || "irc-#{Time.now.to_f}")
        rescue AdapterError => e
          dm_refused(native_id, e.message)
        end

        # Only called when {Capabilities#deletes?} is true, which needs the
        # server to have advertised draft/message-redaction.
        def delete(endpoint, native_id)
          @client.redact(endpoint.settings[:channel], native_id)
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("IRC redact failed: #{e.class}: #{e.message}", adapter: :irc, retryable: true)
        end

        # IRC's draft/react has no separate add/remove wire form, only a toggle
        # (send the same reaction again to remove it), so both sides of the diff
        # below send the identical TAGMSG.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          channel = endpoint.settings[:channel]
          ((desired - previous) + (previous - desired)).each do |reaction|
            @client.react(channel, native_id, reaction.label)
          end
        rescue AdapterError
          raise
        rescue StandardError => e
          raise AdapterError.new("IRC react failed: #{e.class}: #{e.message}", adapter: :irc, retryable: true)
        end

        def moderate(command, endpoint, native_id)
          channel = endpoint.settings[:channel]
          case command.action
          when :kick then moderate_kick(command, endpoint, channel)
          when :ban then moderate_ban(command, endpoint, channel)
          when :unban then moderate_unban(command, endpoint, channel)
          when :delete then moderate_delete(endpoint, channel, native_id)
          else
            Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end
        rescue PermissionError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :forbidden, detail: e.message)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        def describe_endpoint(endpoint)
          "#{endpoint.label} (irc channel #{endpoint.settings[:channel]})"
        end

        # Entry point the client drives, one message Hash at a time.
        def handle_message(event)
          emit_if(apply_hub_routing(event))
        end

        # Entry point for a DM to the bot: the operator control lane's
        # receiving half. Logs and drops when no control lane is wired.
        def handle_dm(event)
          nick = event["nick"].to_s
          return if nick.empty?

          if control_lane.nil?
            logger.info { "irc: dropped a direct message from #{nick}: no control lane configured" }
            return
          end

          author = Core::Author.new(native_id: nick, username: nick, kind: :user)
          reply = control_lane.handle_dm(adapter: self.class.adapter_name, account: account, author: author,
                                         text: event["body"].to_s)
          @client.privmsg(nick, reply) unless reply.nil?
        rescue StandardError => e
          logger.error { "irc: error handling a direct message: #{e.class}: #{e.message}" }
        end

        # Hub-mode short-code addressing, applied before the ordinary inbound
        # parse: a room-addressing prefix is stripped from the text and turned
        # into {Core::Message#hub_target_room_id}/#hub_exclude_endpoint_ids.
        def apply_hub_routing(event)
          return @inbound.message(event) if %w[reaction join leave].include?(event["kind"])

          channel = event["channel"]
          # Whose traffic this physical channel carries. Two communities can map
          # the same channel on one shared account, and only the owner's rooms
          # may be addressed or listed from here.
          community_id = endpoint_for(channel)&.community_id
          return @inbound.message(event) unless @hub_router.hub?(community_id, channel)

          resolution = @hub_router.resolve(community_id, channel, event["body"].to_s)
          return @inbound.message(event) if resolution.nil?

          case resolution.kind
          when :listing
            notify_hub(channel, @hub_router.listing_text(community_id, channel))
            nil
          when :unknown_code
            notify_hub(channel, @hub_router.unknown_code_text(resolution.code))
            nil
          when :addressed
            addressed_message(event, resolution)
          end
        end

        def addressed_message(event, resolution)
          message = @inbound.message(event.merge("body" => resolution.text))
          return nil if message.nil?

          message.with(
            hub_target_room_id: resolution.target_endpoint_id,
            hub_exclude_endpoint_ids: resolution.exclude_ids
          )
        end

        # Best effort: a missed hub notice must never raise into the receive loop.
        def notify_hub(channel, text)
          @client.privmsg(channel, text)
        rescue StandardError => e
          logger.info { "irc: could not post the hub-routing notice in #{channel}: #{e.message}" }
        end

        def emit_if(message)
          return nil if message.nil?

          emit(message)
          message
        rescue StandardError => e
          logger.error { "error handling an IRC message: #{e.class}: #{e.message}" }
          nil
        end

        # {Adapters::Base#reconcile_channels} joins whatever the live snapshot
        # maps; hub short-code addressing has to catch up the same way, since
        # @hub_router is otherwise fixed at whatever #initialize saw at boot,
        # which on a database-only deployment is nothing until a room is later
        # shared into a hub channel through ChannelMapper#add_hub_room.
        def reconcile_channels
          super
          rebuild_hub_router
        end

        private

        # Rebuilt whole rather than patched: a HubRouter's short codes are
        # assigned together across its whole group, so a partial update could
        # hand out a code the rest of the group already answers to. A no-op
        # with no live resolver, or one too old to answer #hub_groups_for, so
        # every existing plain endpoint_for/endpoints_for resolver keeps
        # working exactly as it did before this existed.
        def rebuild_hub_router
          return if @endpoint_resolver.nil?
          return unless @endpoint_resolver.respond_to?(:hub_groups_for)

          groups = @endpoint_resolver.hub_groups_for(self.class.adapter_name, account)
          @hub_router = HubRouter.new(channel_groups: groups)
        end

        # Told to the sender through Features::Bridge#report_notes, the same
        # signal Discord's note_failed_upload gives when a file never crosses.
        # Empty, not a key holding an empty array, when nothing failed.
        def notes_extra(message)
          notes = @outbound.unrelayed_attachments(message).map do |attachment|
            "could not relay #{attachment.label} to IRC: the source URL could not be shown"
          end
          notes.empty? ? {} : { notes: notes }
        end

        # Upgrade the {CAPABILITIES} floor with what this connection negotiated: a
        # client-only tag can be resolved back to a real message id only with
        # message-tags and msgid both, so replies and reactions need the pair. The
        # :delete moderation verb rides on the same draft/message-redaction grant as
        # the deletes capability: without it there is no wire form to carry a
        # moderator's /delete at all.
        def resolved_capabilities(negotiated)
          client_only_tags = negotiated.include?("message-tags") && negotiated.include?("msgid")
          redaction = negotiated.include?("draft/message-redaction")
          Capabilities.new(**CAPABILITIES.to_h.merge(
            replies: client_only_tags,
            reactions: client_only_tags,
            deletes: redaction,
            moderation: redaction ? CAPABILITIES.moderation + [:delete] : CAPABILITIES.moderation
          ))
        end

        # The +draft/reply+ tag for an outbound send, or {} unless this endpoint
        # can reply natively AND the parent lives on it. {Outbound#quote} makes
        # the matching decision about the text fallback, so the two stay in sync.
        def reply_tags(message, endpoint)
          return {} unless capabilities_for(endpoint).replies?
          return {} if message.reply_to.nil? || message.reply_to.endpoint_id != endpoint.id

          { "+draft/reply" => message.reply_to.native_id }
        end

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        def moderate_kick(command, endpoint, channel)
          @client.kick(channel, command.target_user_id, reason: "bridged /kick by #{command.issuer}")
          ok(endpoint)
        end

        def moderate_ban(command, endpoint, channel)
          @client.ban(channel, command.target_user_id)
          ok(endpoint)
        end

        def moderate_unban(command, endpoint, channel)
          @client.unban(channel, command.target_user_id)
          ok(endpoint)
        end

        # No target message resolved (a reply-less /delete the feature could not
        # place) reads as unsupported here rather than sending a REDACT with
        # nothing to redact.
        def moderate_delete(endpoint, channel, native_id)
          return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported) if native_id.nil?

          @client.redact(channel, native_id)
          ok(endpoint)
        end

        # What {#reconcile_channels} joins against: physical channels joined so far.
        def joined_route_keys = @joined_channels.to_a

        def join_route(route_key, endpoint)
          channel = route_key.to_s
          @client.join(channel, key: endpoint&.settings&.dig(:channel_key))
          @joined_channels << channel
          logger.info { "irc: joined #{channel} (live snapshot reconcile)" }
        rescue StandardError => e
          logger.warn { "irc: could not join #{channel} during reconcile: #{e.message}" }
        end

        def group_by_channel(endpoints)
          endpoints.group_by { |endpoint| endpoint.settings[:channel].to_s.downcase }
        end

        # The config path's own hub groups, keyed the way
        # {ControlPlane::ChannelResolver#hub_groups_for} keys the live ones, so
        # HubRouter is fed one shape from both and neither can hand it a group
        # spanning communities.
        def hub_groups(endpoints)
          endpoints.group_by { |ep| HubRouter.key_for(ep.community_id, ep.settings[:channel]) }
        end

        # channel (lower case) => the one endpoint inbound traffic on it resolves to.
        def build_index(channel_groups)
          channel_groups.transform_values { |group| receiving_endpoint(group) }
        end

        # Which endpoint answers for one physical channel's inbound traffic.
        # More than one +receives: true+ on a channel is ambiguous config: logged,
        # and the first in configuration order wins rather than raising at boot.
        def receiving_endpoint(group)
          return group.first if group.size == 1

          receiving = group.select(&:receives?)
          if receiving.size > 1
            logger.error do
              "IRC channel #{group.first.settings[:channel]} is receives: true on more than one " \
              "endpoint (#{receiving.map(&:id).join(", ")}); only one endpoint per physical channel " \
              "may receive inbound messages. Using #{receiving.first.id}; set the others to " \
              "receives: false to fix this."
            end
          end
          receiving.first || group.first
        end

        # Join each physical channel once even when several endpoints share it,
        # passing a +k key when any endpoint names one.
        def join_channels
          @channel_groups.each_value do |group|
            channel = group.first.settings[:channel]
            key = group.filter_map { |endpoint| endpoint.settings[:channel_key] }.first
            @client.join(channel, key: key)
          end
        end

        # IRC channel names are case insensitive, so the index is keyed lower case.
        def endpoint_for(channel)
          if @endpoint_resolver
            return nil if channel.nil?

            return @endpoint_resolver.endpoint_for(:irc, account, channel.to_s.downcase)
          end

          return nil if channel.nil?

          @index[channel.to_s.downcase]
        end
      end
    end
  end
end
