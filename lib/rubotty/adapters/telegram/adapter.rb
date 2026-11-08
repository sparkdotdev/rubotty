# frozen_string_literal: true

require "rubotty/core/delivery_groups"

require "securerandom"

module Rubotty
  module Adapters
    module Telegram
      # The Telegram platform adapter: two mutually exclusive receive
      # transports, an entity model indexed in UTF-16 code units, forum topics
      # as sub endpoints, and no delete events at all.
      class Adapter < Base
        # What getFile will hand a bot talking to the cloud Bot API server. A member
        # may post a 2 GB file and a bot may upload 50 MB, but anything over this
        # cannot be downloaded at all, so a big file arriving from Telegram has no
        # bytes to relay, rehost or shrink. See {.max_fetch_bytes_for}: this is a
        # property of which Bot API server the bot talks to, not of Telegram itself.
        MAX_BOT_DOWNLOAD_BYTES = 20 * 1024 * 1024

        # What getFile raises the ceiling to on a self hosted Bot API server,
        # per Telegram's own local server documentation. Reachable only once
        # api_base points away from the cloud default.
        SELF_HOSTED_MAX_DOWNLOAD_BYTES = 2000 * 1024 * 1024

        # How many media groups this process remembers the sibling ids of. Only
        # the first message of a group is ever recorded anywhere downstream, so
        # a delete has nothing else to find the rest of an album by. Bounded
        # because a busy bridge would otherwise grow the map forever, and it does
        # not survive a restart: an album delivered by a previous process still
        # loses only its first message.
        MEDIA_GROUP_MEMORY = 512

        # Every Telegram supergroup id carries this prefix, and the web form of
        # the same chat is that id without it. The forum topic check below and
        # the message permalink further down both turn on the distinction.
        SUPERGROUP_PREFIX = "-100"

        class << self
          def adapter_name = :telegram

          # Telegram's published guidance: about one message a second to one
          # chat, and about thirty a second overall. Paced to those rather than
          # waiting to be told off, since a 429 here holds the room's worker for
          # the retry_after the platform names.
          def outbound_limits = { destination: { rate: 1.0, burst: 3 }, account: { rate: 30.0, burst: 30 } }

          # One account is one bot token, one connection, so a missing token
          # means "not yet connected".
          def dormant_on_missing_secret? = true

          def account_schema
            Config::Schema.define do
              field :token_env, :string, required: true, env: true,
                                         desc: "name of the environment variable holding the bot token"
              field :transport, :symbol, default: :long_polling, one_of: %i[long_polling webhook],
                                         desc: "how updates are received"
              field :api_base, :string, default: ApiClient::DEFAULT_BASE,
                                        desc: "override for a self hosted Bot API server"
              field :skip_backlog, :boolean, default: true,
                                             desc: "ignore updates that queued while the bridge was down"
              field :register_commands, :boolean, default: true,
                                                  desc: "publish the command list to Telegram at start, so " \
                                                        "typing / suggests the bot's commands. Off is for a " \
                                                        "shared bot token whose menu this deployment should " \
                                                        "not own: the write reaches every chat the token " \
                                                        "serves, bridged here or not."
              field :poll_timeout, :integer, default: 30,
                                             desc: "long polling only: seconds to hold each getUpdates open"
              field :poll_limit, :integer, default: 100,
                                           desc: "long polling only: updates per request"
              field :webhook_url, :string,
                    desc: "webhook only: the public HTTPS URL Telegram should POST to"
              field :webhook_path, :string, default: Transport::Webhook::DEFAULT_PATH,
                                            desc: "webhook only: local path to serve"
              field :webhook_bind, :string, default: Transport::Webhook::DEFAULT_BIND,
                                            desc: "webhook only: address to bind"
              field :webhook_port, :integer, default: 8080,
                                             desc: "webhook only: port to bind. PORT in the environment wins."
              field :webhook_secret_env, :string, env: true,
                                                  desc: "webhook only: env var holding the shared secret. " \
                                                        "One is generated if omitted."
              field :webhook_max_connections, :integer, default: 40
              field :cross_delete_on_discord, :boolean, default: true,
                                                        desc: "editing a message to a single full stop " \
                                                              "removes it here and everywhere it was " \
                                                              "relayed. Telegram sends no delete event, " \
                                                              "so this is the only unsend that works " \
                                                              "without configuring operators."
              field :album_window, :float, default: 1.5,
                                          desc: "seconds to wait for the rest of a media group before " \
                                                "relaying it as one message"
              field :reaction_policy, :symbol, default: :nearest,
                                               one_of: %i[nearest drop log],
                                               desc: "what to do with a reaction Telegram will not " \
                                                     "accept: substitute the nearest equivalent, drop " \
                                                     "it silently, or drop it and log"
            end
          end

          def endpoint_schema
            Config::Schema.define do
              field :chat_id, :string, required: true,
                                       desc: "Telegram chat id. Supergroups are negative, for example -1001234567890"
              field :thread_id, :integer,
                                desc: "forum topic id within the chat, omit for the General topic"
              field :sender_prefix, :boolean, default: true,
                                              desc: "prepend the sender name to relayed messages"
              field :sender_separator, :string, default: ":",
                                                desc: "printed after the sender name"
            end
          end

          def validate_endpoint(settings, path)
            problems = []
            chat_id = settings[:chat_id].to_s
            unless chat_id.match?(/\A-?\d+\z/)
              problems << "#{path}.chat_id: expected a numeric Telegram chat id, got #{chat_id.inspect}. " \
                          "Use the numeric id, not an @username or an invite link."
            end
            if settings[:thread_id] && !chat_id.start_with?(SUPERGROUP_PREFIX)
              problems << "#{path}.thread_id: forum topics only exist in supergroups, whose ids begin " \
                          "with #{SUPERGROUP_PREFIX}. #{chat_id.inspect} does not look like a supergroup."
            end
            problems
          end

          def validate_account(settings, path)
            return [] unless settings[:transport] == :webhook
            return [] if settings[:webhook_url]

            ["#{path}.webhook_url: required when transport is webhook"]
          end

          def discovers_channels? = true

          def route_key_for(endpoint)
            thread = endpoint.settings[:thread_id]
            thread.nil? ? endpoint.settings[:chat_id].to_s : "#{endpoint.settings[:chat_id]}/#{thread}"
          end

          # route_key is "chat_id" or "chat_id/thread_id"; external_id falls
          # back in for chat_id only for a route_key that somehow carries no
          # chat half at all, which live discovery never produces.
          def addressing(route_key, external_id: nil)
            chat_id, thread_id = route_key.to_s.split("/", 2)
            chat_id = chat_id.to_s.strip
            settings = { "chat_id" => (chat_id.empty? ? external_id.to_s : chat_id) }
            thread_id = thread_id.to_s.strip
            settings["thread_id"] = thread_id.to_i unless thread_id.empty?
            settings
          end

          def supports_leave? = true
          def supports_space_notice? = true
          def supports_admin_dm? = true

          # A DM is deleteMessage against the same chat_id sendMessage used,
          # no different from any other Telegram chat.
          def supports_admin_dm_delete? = true

          # A forum topic exists only inside a supergroup with topics turned
          # on, which the Bot API offers no way to check short of trying, so
          # support is reported unconditionally and createForumTopic's own
          # error surfaces.
          def supports_channel_management? = true

          # The pending-review flow is wired through #initialize's keyword below.
          def accepts_pending_spaces? = true

          # getFile's ceiling follows which Bot API server +settings[:api_base]+
          # names, cloud or self hosted, never a fixed platform constant. A blank
          # or absent api_base reads as the cloud default, the same fallback
          # #initialize applies when building the real client.
          def max_fetch_bytes_for(settings)
            base = settings[:api_base].to_s.strip
            base.empty? || base == ApiClient::DEFAULT_BASE ? MAX_BOT_DOWNLOAD_BYTES : SELF_HOSTED_MAX_DOWNLOAD_BYTES
          end
        end

        # Telegram's ChatPermissions, spelled out because restrictChatMember
        # replaces the whole set rather than merging.
        MUTED_PERMISSIONS = {
          can_send_messages: false, can_send_audios: false, can_send_documents: false,
          can_send_photos: false, can_send_videos: false, can_send_video_notes: false,
          can_send_voice_notes: false, can_send_polls: false,
          can_send_other_messages: false, can_add_web_page_previews: false
        }.freeze

        UNMUTED_PERMISSIONS = MUTED_PERMISSIONS.transform_values { true }.freeze

        # sendPhoto and friends take either a URL (fetched server side) or a real
        # upload, and Telegram caps the URL fetch tighter than the upload: 5 MB for
        # a photo, 20 MB for everything else. Outbound#media_call only ever hands
        # over a URL (see its own comment), so a relayed file between these numbers
        # and the 50 MB upload ceiling below needs to become a link instead.
        URL_RELAY_BYTES = { photo: 5 * 1024 * 1024, default: 20 * 1024 * 1024 }.freeze

        # Every capability except max_fetch_bytes, which depends on this account's
        # own api_base and so cannot be a shared frozen constant; see #capabilities.
        CAPABILITY_OPTIONS = {
          edits: true,
          deletes: true,
          replies: true,
          threads: true,
          max_attachment_bytes: 50 * 1024 * 1024,
          url_relay_bytes: URL_RELAY_BYTES,
          reactions: true,
          # A non-premium bot may set at most one reaction per message, read by
          # Reactions.choose.
          max_reactions: 1,
          # Inline keyboards, which is how a card offers a choice here: the
          # reaction whitelist has no keycap digits and one reaction is the
          # whole budget anyway.
          buttons: true,
          moderation: %i[delete ban unban kick mute unmute pin unpin unpinall],
          # Telegram has setMyCommands, which Commands#register pushes
          # Core::CommandRegistry into, so the "/" menu carries the commands.
          command_list: true
        }.freeze

        # The cloud Bot API server's capabilities, for a caller with no live
        # account to ask, such as the README table. A live instance's own
        # #capabilities reflects its actual api_base instead of this default.
        CAPABILITIES = Capabilities.new(**CAPABILITY_OPTIONS, max_fetch_bytes: MAX_BOT_DOWNLOAD_BYTES).freeze

        def initialize(account:, settings:, dispatcher:, logger:, endpoints: [],
                       endpoint_resolver: nil, control_lane: nil, join_guard: nil, discovery: nil,
                       pending_spaces: nil)
          super
          @client = ApiClient.new(
            token: settings[:token],
            base_url: settings[:api_base] || ApiClient::DEFAULT_BASE,
            logger: logger
          )
          @outbound = Outbound.new(logger: logger)
          @index = build_index(endpoints)
          @custom_emoji = build_custom_emoji
          @inbound = Inbound.new(
            endpoint_for: method(:endpoint_for),
            endpoint_for_reaction: method(:endpoint_for_reaction),
            file_resolver: @client.method(:file_url),
            avatar_resolver: method(:avatar_for),
            custom_emoji_resolver: @custom_emoji.method(:bases_for),
            logger: logger,
            unsend_on_dot: settings.fetch(:cross_delete_on_discord, true)
          )
          # The "/" menu Telegram offers when a member starts typing a command.
          @commands = Commands.new(client: @client, logger: logger)
          @avatars = nil
          @own_account_id = nil
          @transport = nil
          @albums = AlbumBuffer.new(
            window: settings[:album_window] || AlbumBuffer::DEFAULT_WINDOW,
            flush: ->(assembled) { emit(assembled) },
            logger: logger
          )
          # Protects lazy construction of the durable multipart identifier map.
          @media_groups_lock = Mutex.new
        end

        attr_reader :client, :commands, :avatars

        def replace_client(client)
          @client = client
          @inbound = Inbound.new(
            endpoint_for: method(:endpoint_for),
            endpoint_for_reaction: method(:endpoint_for_reaction),
            file_resolver: client.method(:file_url),
            avatar_resolver: method(:avatar_for),
            custom_emoji_resolver: @custom_emoji.method(:bases_for),
            logger: logger,
            unsend_on_dot: settings.fetch(:cross_delete_on_discord, true)
          )
          @commands = Commands.new(client: client, logger: logger)
          self
        end

        # The rehoster arrives after construction, like #storage, so the avatar
        # service is built when it does. Nil without a control plane or a usable
        # object store, which leaves every author's picture exactly as it was.
        def rehoster=(value)
          super
          @avatars = value.nil? ? nil : build_avatars
        end

        # Built per instance, not a shared constant: max_fetch_bytes follows this
        # account's own api_base, so two accounts (one cloud, one pointed at a
        # self hosted Bot API server) must not share one frozen answer.
        def capabilities
          @capabilities ||= Capabilities.new(**CAPABILITY_OPTIONS, max_fetch_bytes: self.class.max_fetch_bytes_for(settings))
        end

        # Sub conversations exist only as forum topics, so only an endpoint
        # pinned to one (thread_id set) can address a thread. The General topic
        # and every ordinary group cannot, and a threaded reply from another
        # platform degrades to a text notice.
        def capabilities_for(endpoint)
          return capabilities if endpoint.settings[:thread_id]

          @non_forum_capabilities ||= Capabilities.new(**capabilities.to_h.merge(threads: false))
        end

        def own_account_id = @own_account_id

        def running? = !@transport.nil? && @transport.running?

        # Both transports resume from the persisted getUpdates offset, so a
        # stalled one heals itself and the nightly reconnect leaves it alone.
        def persistent_connection? = false

        # ------------------------------------------------------------------
        # leave / notice / admin-dm capabilities
        # ------------------------------------------------------------------

        # Post +notice+ (nil skips the post) then leave the chat. True on a
        # confirmed leave even when the notice could not be posted; false only
        # when the leave call itself failed.
        def leave_space(external_id, notice: nil)
          begin
            @client.call("sendMessage", chat_id: external_id, text: notice) if notice
          rescue AdapterError => e
            logger.info { "telegram: could not post the leave notice in #{external_id}: #{e.message}" }
          end
          @client.call("leaveChat", chat_id: external_id)
          logger.info { "telegram: left chat #{external_id}" }
          true
        rescue AdapterError => e
          logger.warn { "telegram: could not leave chat #{external_id}: #{e.message}" }
          false
        end

        # Post +text+ into +external_id+ with no accompanying leave.
        def post_space_notice(external_id, text)
          return false if text.to_s.strip.empty?

          @client.call("sendMessage", chat_id: external_id, text: text)
          true
        rescue AdapterError => e
          logger.info { "telegram: could not post a space notice in #{external_id}: #{e.message}" }
          false
        end

        # A Telegram DM is sendMessage with the user's own id as chat_id, which
        # works only once that user has started a conversation with the bot.
        def send_admin_dm(native_id, text)
          return nil if text.to_s.strip.empty?

          sent = @client.call("sendMessage", chat_id: native_id, text: text)
          return nil unless sent.is_a?(Hash)

          # chat_id doubles as the DM's channel_ref: a private chat's id IS
          # the recipient's own native id, so deleteMessage needs nothing
          # #send_admin_dm was not already given.
          Core::DmReceipt.new(native_id: sent["message_id"], channel_ref: native_id)
        rescue AdapterError => e
          # Telegram refuses sendMessage to anyone who has never opened a
          # private chat with the bot ("chat not found"), which is a silently
          # dropped operator rather than a passing hiccup, so it is named.
          dm_refused(native_id, e.message)
        end

        # Remove a DM #send_admin_dm sent: deleteMessage against the same
        # chat, tolerating one already gone the same way #delete does.
        def delete_admin_dm(receipt)
          return false if receipt.nil?

          @client.call_tolerating_gone("deleteMessage", chat_id: receipt.channel_ref, message_id: receipt.native_id)
          true
        rescue AdapterError => e
          logger.info { "telegram: could not delete a DM: #{e.message}" }
          false
        end

        # ------------------------------------------------------------------
        # channel management
        # ------------------------------------------------------------------

        # Telegram permissions are group-wide rather than per topic, so
        # #copy_channel_permissions keeps the base "nothing to copy".

        # Create a forum topic in the chat +community_id+ bridges on this
        # account. Returns "<chat_id>/<message_thread_id>", the same route_key
        # shape a mapped topic carries, so {#delete_channel} can recover both
        # halves.
        def create_channel(name:, community_id:, template: nil)
          scoped_channel_call!(community_id, "creating the forum topic #{name.to_s.inspect}")
          chat_id = community_chat_id(community_id, doing: "create the forum topic #{name.to_s.inspect}")
          return nil if chat_id.nil?

          topic = @client.call("createForumTopic", chat_id: chat_id, name: name.to_s)
          thread_id = topic["message_thread_id"]
          return nil if thread_id.nil?

          "#{chat_id}/#{thread_id}"
        end

        # Takes "<chat_id>/<message_thread_id>", or a bare thread id resolved
        # against the one chat +community_id+ bridges. deleteForumTopic
        # destroys real content, so the chat is checked against that community
        # either way rather than trusted because the native id named it.
        def delete_channel(native_id, community_id:)
          doing = "delete the forum topic #{native_id.to_s.inspect}"
          scoped_channel_call!(community_id, doing)
          chat_id, thread_id = split_native_channel_id(native_id, community_id, doing: doing)
          return false if chat_id.nil? || thread_id.nil? || !chat_in_community?(chat_id, community_id, doing)

          @client.call("deleteForumTopic", chat_id: chat_id, message_thread_id: thread_id.to_i)
          true
        end

        # Confirm the token and learn our own user id. {Core::LoopGuard} depends
        # on the result: an adapter that cannot say who it is has lost its
        # strongest echo defence.
        def identify
          me = @client.call("getMe")
          @own_account_id = me["id"].to_s
          logger.info { "signed in to Telegram as @#{me["username"]} (#{@own_account_id})" }
          @own_account_id
        rescue AdapterError => e
          # Refuse to start rather than run without loop prevention.
          raise AdapterError.new(
            "could not authenticate with Telegram: #{e.message}. Check the token in " \
            "#{settings[:token_env]}.",
            adapter: :telegram
          )
        end

        def start
          identify
          # Publish the "/" menu once the token is known good and before any
          # update is taken. A list Telegram rejects is logged inside and never
          # fatal, so the bridge still runs with every command typable by hand.
          register_commands
          @transport = build_transport
          @transport.start
          logger.info { "telegram account #{account} ready via #{@transport.describe}" }
          self
        end

        def stop
          @transport&.stop
          @transport = nil
          # Flush rather than drop: a half assembled album is still content.
          @albums.stop
          @avatars&.stop
          self
        end

        # ------------------------------------------------------------------
        # outbound
        # ------------------------------------------------------------------

        def deliver(message, endpoint)
          calls = @outbound.send_calls(message, endpoint)
          # Nothing to send by design, so Bridge must not record a loss.
          return Core::DeliveryReceipt::NOT_APPLICABLE if calls.empty?

          # More than one call crosses for a mixed attachment set or an album
          # past the per group maximum, since #send_calls now sends every
          # attachment rather than only the first.
          sent, failures = run_calls(calls)
          # sendMediaGroup answers with an array of messages, one per item, where
          # every other send method answers with a single message. The very
          # first message of the very first call carries the caption, so an
          # edit or delete targets it.
          first = sent.first
          return nil if first.nil?

          logger.debug { "telegram: #{message.ref} crossed as #{calls.size} calls, #{sent.size} messages" } if calls.size > 1

          group_ids = sent.size > 1 ? sent.map { |m| m["message_id"].to_s } : nil
          remember_media_group(endpoint, first["message_id"], group_ids)
          Core::DeliveryReceipt.new(
            endpoint_id: endpoint.id,
            native_id: first["message_id"],
            extra: {
              chat_id: first.dig("chat", "id"),
              # Every id that crossed, the first included: a delete or a
              # future group aware reader that skipped it would strand that
              # copy in the chat.
              group_ids: group_ids,
              notes: failures.zero? ? nil : [multi_part_failure_note(failures, calls.size)]
            }.compact
          )
        rescue ChatMigratedError => e
          # This copy stays lost, and the channel follows the chat for every send after it.
          follow_migration(endpoint.settings[:chat_id], e.migrate_to_chat_id)
          raise
        end

        def edit(message, endpoint, native_id)
          method_name, params = @outbound.edit_call(message, endpoint, native_id)
          # A user can edit a message relayed long enough ago that the copy is
          # gone, or that Telegram no longer permits editing. That is normal.
          result = @client.call_tolerating_gone(method_name, params)
          return nil unless result.is_a?(Hash)

          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: result["message_id"])
        end

        # Removes every message an album crossed as, not only the one id the
        # message map holds, so a deleted media group leaves nothing behind.
        def delete(endpoint, native_id)
          key = media_group_key(endpoint, native_id)
          delivery_groups.members(key, fallback: native_id).each do |id|
            method_name, params = @outbound.delete_call(endpoint, id)
            @client.call_tolerating_gone(method_name, params)
          end
          delivery_groups.forget(key)
          nil
        rescue StorageError => e
          raise AdapterError.new("Telegram multipart deletion state failed: #{e.message}",
                                 adapter: :telegram, retryable: true)
        end

        # t.me publishes a message link for a supergroup and nothing else: the
        # web form of the chat is its id with SUPERGROUP_PREFIX dropped. A basic
        # group or a private chat has no browsable history to point at, so both
        # answer nil rather than a URL that would resolve to nothing.
        def message_permalink(endpoint, native_id)
          chat_id = endpoint.settings[:chat_id].to_s
          return nil if native_id.to_s.empty? || !chat_id.start_with?(SUPERGROUP_PREFIX)

          # A forum topic sits between the chat and the message, the same order
          # route_key_for already writes that pair in.
          parts = [chat_id.delete_prefix(SUPERGROUP_PREFIX), endpoint.settings[:thread_id], native_id]
          "https://t.me/c/#{parts.compact.join("/")}"
        end

        # The topic, or the whole chat for an endpoint with no topic, which is
        # the message link with nothing on the end. The supergroup rule above
        # applies unchanged: a basic group has no browsable history to open.
        def room_permalink(endpoint)
          chat_id = endpoint.settings[:chat_id].to_s
          return nil unless chat_id.start_with?(SUPERGROUP_PREFIX)

          parts = [chat_id.delete_prefix(SUPERGROUP_PREFIX), endpoint.settings[:thread_id]]
          "https://t.me/c/#{parts.compact.join("/")}"
        end

        def describe_endpoint(endpoint)
          thread = endpoint.settings[:thread_id]
          "#{endpoint.label} (telegram chat #{endpoint.settings[:chat_id]}#{thread ? " topic #{thread}" : ""})"
        end

        # ------------------------------------------------------------------
        # inbound
        # ------------------------------------------------------------------

        # Entry point for both transports. One update can yield several canonical
        # messages: a reaction change that swaps one emoji for another is a
        # removal plus an addition.
        def handle_update(update)
          # An upgraded group names its new id in both chats, and neither
          # service message is anything to relay or discover.
          migration = chat_migration(update)
          if migration
            follow_migration(*migration)
            return nil
          end

          # The bot being added to a group arrives as a my_chat_member update
          # rather than a message.
          return handle_membership_change(update) if bot_added?(update)

          # A DM to the bot owns no channel, so it misses the resolver and would
          # be dropped. With a control lane wired it is handled there instead.
          return handle_control_gesture(update) if control_gesture?(update)

          # Telegram cannot enumerate forum topics over the API, so discovery is
          # passive: a message carrying a message_thread_id reveals a topic without
          # consuming the update. The name must be learned BEFORE discovery runs, so
          # populating it here lets a topic be discovered under its real name on first sight.
          note_forum_topic(update)
          learn_forum_topic(update) if discovery

          # The presser's client spins until the query is answered, and what
          # the press means is worked out on the pipeline's own thread long
          # after this returns, so the answer cannot wait for it.
          answer_callback(update["callback_query"]) if update["callback_query"]

          produced = @inbound.call(update)
          # A message reaches nobody two ways: it can fail to resolve at all, or
          # resolve fine and then get dropped by Dispatcher#call for belonging to
          # no room (Snapshot tracks unmapped channels Core::Topology never does).
          # The below-the-pipeline command fallback, /identify-topic, covers both.
          if produced.nil? || roomless?(produced)
            answer_unresolved_command(update)
            return nil if produced.nil?
          end

          Array(produced).each do |message|
            # The payload for an ordinary message does not carry the thread name.
            message = name_thread(message)

            # Only this adapter can remove the Telegram original, because
            # Telegram sends no delete event for the router to act on; the router
            # handles the relayed copies through the message map.
            remove_original(message) if message.kind == :delete

            # Telegram has no album update: photos sent as one album arrive as
            # separate messages sharing a media_group_id, with the caption on
            # exactly one of them and not reliably the first. AlbumBuffer holds
            # the parts briefly and returns nil for one it has taken ownership of.
            ready = @albums.offer(message, group_id_of(message))
            emit(ready) if ready
          end
          produced
        end

        # Telegram replaces the bot's reactions wholesale, up to the budget
        # this endpoint's capabilities declare (one, for a non-premium bot),
        # so the declarative request collapses to a single set call.
        # +previous+ is read only to tell a real removal apart from a set that
        # maps onto nothing, which would otherwise send the same empty list.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          policy = settings[:reaction_policy] || :nearest
          max = capabilities_for(endpoint).max_reactions || desired.size
          chosen, dropped = Reactions.choose(desired, policy: policy, max: max)
          report_unshowable(endpoint, native_id, dropped, policy) if dropped.any?

          if chosen.empty? && !removal?(desired, previous, policy, max)
            logger.debug do
              "left the reaction on #{endpoint.id}:#{native_id} alone, nothing held maps onto Telegram"
            end
            return nil
          end

          @client.call_tolerating_gone(
            "setMessageReaction",
            chat_id: endpoint.settings[:chat_id],
            message_id: native_id.to_i,
            # An empty list removes a reaction; omitting the parameter would
            # leave the existing one in place.
            reaction: chosen.map { |emoji| { type: "emoji", emoji: emoji } }
          )
          nil
        end

        def moderate(command, endpoint, native_id)
          case command.action
          when :delete then moderate_delete(endpoint, native_id)
          when :ban then moderate_ban(command, endpoint)
          when :unban then moderate_unban(command, endpoint)
          when :kick then moderate_kick(command, endpoint)
          when :mute then moderate_mute(command, endpoint, muted: true)
          when :unmute then moderate_mute(command, endpoint, muted: false)
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

        # The chat's live member count, for RehostedFiles' download-serve
        # ceiling; see ControlPlane::CommunityMembers. Same nil safety as the
        # pending-card read this wraps: any Bot API failure reads as unknown.
        def community_member_count(chat_id) = chat_member_count(chat_id)

        private

        # Whether an empty setMessageReaction would be a removal the bridge means:
        # the empty list DELETES, so it is right only when nobody holds anything any
        # more, or when the emoji already placed here has left the set. A set that
        # maps onto nothing is neither, and clearing for one takes off an emoji
        # people are still holding.
        def removal?(desired, previous, policy, max)
          return true if desired.empty?

          !Reactions.choose(previous, policy: policy, max: max).first.empty?
        end

        # Say what Telegram will not show: info under the policy that asks for
        # it, debug otherwise, so this never needs a code read to answer.
        def report_unshowable(endpoint, native_id, dropped, policy)
          logger.public_send(policy == :log ? :info : :debug) do
            "Telegram cannot show #{dropped.map(&:label).join(", ")} on #{endpoint.id}:#{native_id}"
          end
        end

        def ok(endpoint) = Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)

        # Note the sibling ids of a media group against the one id anything
        # downstream records, dropping the oldest entry once the map is full.
        def remember_media_group(endpoint, native_id, group_ids)
          return if group_ids.nil? || group_ids.size < 2

          delivery_groups.remember(media_group_key(endpoint, native_id), group_ids)
        end

        # Every id to delete for +native_id+: an album's whole set the first
        # time, and the id alone once it has been consumed or was never a group.
        def media_group_key(endpoint, native_id) = [:telegram, account, endpoint.settings[:chat_id].to_s, native_id.to_s]

        def delivery_groups
          @media_groups_lock.synchronize do
            @delivery_groups ||= Core::DeliveryGroups.new(storage: -> { storage }, ttl: -> { delivery_state_ttl },
                                                          logger: logger)
          end
        end

        def moderate_delete(endpoint, native_id)
          delete(endpoint, native_id)
          ok(endpoint)
        end

        def moderate_ban(command, endpoint)
          @client.call("banChatMember",
                       chat_id: endpoint.settings[:chat_id],
                       user_id: command.target_user_id.to_i,
                       revoke_messages: false)
          ok(endpoint)
        end

        # only_if_banned makes lifting an already-gone ban a no-op rather than an
        # error.
        def moderate_unban(command, endpoint)
          @client.call("unbanChatMember",
                       chat_id: endpoint.settings[:chat_id],
                       user_id: command.target_user_id.to_i,
                       only_if_banned: true)
          ok(endpoint)
        end

        # Telegram has no kick, so it is a ban followed at once by an unban,
        # which removes the member while leaving them able to rejoin.
        def moderate_kick(command, endpoint)
          @client.call("banChatMember",
                       chat_id: endpoint.settings[:chat_id],
                       user_id: command.target_user_id.to_i,
                       revoke_messages: false)
          unban_after_kick(command, endpoint)
          ok(endpoint)
        end

        # The ban above has already landed by the time this runs, so a failure
        # here must not read like an ordinary kick failure: the member is left
        # banned outright rather than free to rejoin, the opposite of what
        # /kick promised. Re-raised with that spelled out, so #moderate's
        # rescue reports it as something other than the plain :failed a kick
        # that never touched Telegram at all would produce.
        def unban_after_kick(command, endpoint)
          @client.call("unbanChatMember",
                       chat_id: endpoint.settings[:chat_id],
                       user_id: command.target_user_id.to_i,
                       only_if_banned: true)
        rescue AdapterError => e
          raise AdapterError.new(
            "telegram kick banned user #{command.target_user_id} but the follow-up unban failed, leaving " \
            "them banned outright rather than free to rejoin: #{e.message}",
            adapter: :telegram, retryable: e.retryable?
          )
        end

        # restrictChatMember replaces the member's permissions wholesale, so
        # unmuting has to name every permission being handed back rather than
        # simply clearing can_send_messages.
        def moderate_mute(command, endpoint, muted:)
          @client.call("restrictChatMember",
                       chat_id: endpoint.settings[:chat_id],
                       user_id: command.target_user_id.to_i,
                       permissions: muted ? MUTED_PERMISSIONS : UNMUTED_PERMISSIONS)
          ok(endpoint)
        end

        # Clears every pinned message in the chat in one call, including pins
        # this bot never placed. Telegram exposes no way to read what is pinned,
        # so there is no selective version of this and no undo.
        def moderate_unpin_all(endpoint)
          @client.call("unpinAllChatMessages", chat_id: endpoint.settings[:chat_id])
          ok(endpoint)
        end

        def moderate_pin(endpoint, native_id, pinned:)
          method_name = pinned ? "pinChatMessage" : "unpinChatMessage"
          @client.call(method_name,
                       chat_id: endpoint.settings[:chat_id],
                       message_id: native_id.to_i)
          ok(endpoint)
        end

        # Run every #deliver call in order: a failure on the very first one means
        # nothing has crossed yet, so it propagates and #deliver returns nothing,
        # leaving the caller's retry free to run the whole send again. Once
        # something has crossed, a later failure is caught instead of raised, so a
        # retry never repeats the calls that already posted a message.
        #
        # @return [Array(Array<Hash>, Integer)] the flattened Bot API messages
        #   that crossed, and how many calls failed
        def run_calls(calls)
          sent = []
          failures = 0
          calls.each_with_index do |(method_name, params), index|
            result = @client.call(method_name, params)
            sent.concat(result.is_a?(Array) ? result : [result])
          rescue AdapterError => e
            raise if index.zero?

            failures += 1
            logger.warn { "telegram: one part of a multi-part send was left unsent: #{e.message}" }
          end
          [sent.compact, failures]
        end

        def multi_part_failure_note(failures, total)
          "#{failures} of #{total} parts of this message could not be sent to Telegram"
        end

        def remove_original(message)
          delete(message.origin, message.ref.native_id)
        rescue AdapterError => e
          logger.warn { "could not remove the unsent message #{message.ref}: #{e.message}" }
        end

        # Stop the spinner on the presser's client. Answered with no text, since
        # what a press is worth is the card's own business and the refreshed
        # tally is the answer everybody in the room sees.
        def answer_callback(query)
          id = query["id"]
          return if id.nil?

          @client.call("answerCallbackQuery", callback_query_id: id)
        rescue AdapterError => e
          logger.debug { "telegram: could not answer a callback query: #{e.message}" }
        end

        # [old chat id, new chat id] for either service message a basic group's
        # upgrade to a supergroup sends, nil for any other update.
        def chat_migration(update)
          message = update["message"]
          return nil unless message.is_a?(Hash)

          chat_id = message.dig("chat", "id")
          return [chat_id, message["migrate_to_chat_id"]] if message["migrate_to_chat_id"]

          [message["migrate_from_chat_id"], chat_id] if message["migrate_from_chat_id"]
        end

        # Hand an upgrade to the control plane so the channel bridging the old
        # chat follows it. Without one, nothing can be rewritten, so whoever
        # keeps the configuration is told which chat_id to change.
        def follow_migration(from, to)
          return nil if from.nil? || to.nil?

          if space_migration.nil?
            logger.warn { "telegram: chat #{from} was upgraded to supergroup #{to}; change its chat_id to #{to}" }
            return nil
          end

          space_migration.call(adapter: :telegram, account: account, from: from.to_s, to: to.to_s)
        rescue StandardError => e
          logger.warn { "telegram: could not follow chat #{from} to supergroup #{to}: #{e.class}: #{e.message}" }
          nil
        end

        def group_id_of(message)
          return nil unless message.kind == :chat

          message.raw.is_a?(Hash) ? message.raw["media_group_id"] : nil
        end

        # ------------------------------------------------------------------
        # thread (forum topic) names
        # ------------------------------------------------------------------

        # A topic is created (forum_topic_created) or renamed
        # (forum_topic_edited) as a service message whose message_thread_id is
        # the topic's id. The name is scoped by chat id because a Telegram thread id
        # is unique only within its chat, and an edit that changed only the icon
        # carries no name, so the known one is kept.
        def note_forum_topic(update)
          payload = update["message"] || update["channel_post"] ||
                    update["edited_message"] || update["edited_channel_post"]
          return unless payload.is_a?(Hash)

          learn_topic_name(payload)
          # Telegram reports a topic's OPENING message as the reply target of every
          # message in that topic (Inbound#reply_ref discards it as a reply for that
          # reason); the opener is the forum_topic_created service message carrying
          # the name, so reading it here names a topic that predates this bot.
          learn_topic_name(payload["reply_to_message"])
        rescue StandardError => e
          logger.debug { "telegram: could not note a forum topic name: #{e.message}" }
        end

        # A blank name is ignored rather than stored, so a malformed payload
        # cannot overwrite a good name with nothing.
        def learn_topic_name(payload)
          return unless payload.is_a?(Hash)

          info = payload["forum_topic_created"] || payload["forum_topic_edited"]
          return unless info.is_a?(Hash)

          name = info["name"].to_s
          return if name.strip.empty?

          thread_names.learn(
            scope: payload.dig("chat", "id"),
            native_id: payload["message_thread_id"] || payload["message_id"],
            name: name
          )
        end

        # Stamp a message's ThreadRef with the learned topic name, since every
        # ordinary Telegram message arrives without one. An already-named or
        # thread-less message is untouched.
        def name_thread(message)
          thread = message.thread
          return message if thread.nil? || thread.named?

          chat_id = message.raw.is_a?(Hash) ? message.raw.dig("chat", "id") : nil
          name = thread_names.name_for(scope: chat_id, native_id: thread.native_id)
          return message if name.nil?

          message.with(thread: Core::ThreadRef.new(native_id: thread.native_id, name: name,
                                                   creator: thread.creator,
                                                   creator_native_id: thread.creator_native_id))
        end

        # The learned-thread-name store over the durable KV. Without a durable
        # store this returns a no-op wrapper, so the feature stays dormant rather
        # than needing a branch at each call site.
        def thread_names
          return @thread_names ||= Core::ThreadNames.new(store: storage) if storage

          Core::ThreadNames.new(store: nil)
        end

        # Only when a lane is wired and the update is a private-chat text
        # message. A private chat never resolves to a channel.
        def control_gesture?(update)
          return false if control_lane.nil?

          payload = update["message"]
          return false unless payload.is_a?(Hash)
          return false unless (payload["chat"] || {})["type"] == "private"

          !payload["text"].to_s.strip.empty?
        end

        # What a forwarded message carries, for the DM report route. Nil for an
        # ordinary DM, which is every DM that forwarded nothing.
        def report_subject(payload, author)
          forwarded = @inbound.forwarded_author(payload)
          return nil if forwarded.nil?

          ControlPlane::ReportLane::Subject.new(
            author: forwarded, target: @inbound.forwarded_target(payload),
            body: payload["text"].to_s, adapter: :telegram,
            reporter_native_id: author&.native_id
          )
        rescue StandardError => e
          logger&.debug { "telegram[#{account}]: could not read a forward for a report: #{e.message}" }
          nil
        end

        # The lane is I/O-free and returns text; sending is the adapter's job.
        # Never raises out: a control gesture must not take down the receive loop.
        def handle_control_gesture(update)
          payload = update["message"]
          from = payload["from"] || {}
          author = Core::Author.new(
            native_id: from["id"], username: from["username"],
            first_name: from["first_name"], last_name: from["last_name"]
          )
          reply = control_lane.handle_dm(
            adapter: :telegram, account: account, author: author, text: payload["text"].to_s,
            # Replying to one of the bot's own alerts is how an operator names
            # the thing they are answering, so the quoted text travels with it.
            quoted: quoted_text(payload),
            # A forwarded message is the whole content of a report, and the text
            # alone says neither who wrote it nor where it came from, so what
            # the forward carried travels with it.
            subject: report_subject(payload, author)
          )
          send_dm_reply(payload.dig("chat", "id"), reply) if reply
          nil
        rescue StandardError => e
          logger.warn { "telegram: control gesture handling failed: #{e.class}: #{e.message}" }
          nil
        end

        # The text of the message this DM replied to, where there was one.
        # Telegram carries both a caption and a text depending on the parent.
        def quoted_text(payload)
          parent = payload["reply_to_message"]
          return nil unless parent.is_a?(Hash)

          presence = ->(value) { value.to_s.strip.empty? ? nil : value.to_s }
          presence[parent["text"]] || presence[parent["caption"]]
        end

        def send_dm_reply(chat_id, text)
          return if chat_id.nil?

          @client.call("sendMessage", chat_id: chat_id, text: text)
        rescue AdapterError => e
          logger.warn { "telegram: could not reply to a DM control gesture: #{e.message}" }
        end

        # ------------------------------------------------------------------
        # membership: auto-leave an unauthorized group
        # ------------------------------------------------------------------

        # my_chat_member reports the bot's own membership, so a genuine join is a
        # transition out of "left"/"kicked" into a present status, never a bare
        # permission change.
        BOT_PRESENT = %w[member administrator restricted creator].freeze
        BOT_ABSENT = %w[left kicked].freeze
        JOINABLE_CHAT = %w[group supergroup channel].freeze

        # Matches Features::IdentifyTopic::NOTICE_NAME and
        # Features::UtilityCommands::NOTICE_NAME so a below-the-pipeline reply
        # reads exactly like the pipeline's own.
        UNRESOLVED_REPLY_NAME = "rubotty"
        private_constant :BOT_PRESENT, :BOT_ABSENT, :JOINABLE_CHAT, :UNRESOLVED_REPLY_NAME

        def bot_added?(update)
          return false if join_guard.nil?

          member = update["my_chat_member"]
          return false unless member.is_a?(Hash)
          return false unless JOINABLE_CHAT.include?((member["chat"] || {})["type"])

          old_status = (member["old_chat_member"] || {})["status"]
          new_status = (member["new_chat_member"] || {})["status"]
          BOT_ABSENT.include?(old_status) && BOT_PRESENT.include?(new_status)
        end

        # Ask the join guard whether to stay, and if not, hand off to whichever
        # unauthorized-space policy is wired: pending review when a
        # {ControlPlane::PendingSpaces} service is present, an immediate leave when
        # not. Telegram has no enumerable channel list at join time, so
        # channel_sample is always empty here. A chat marked for review stays in
        # the pending flow while the bot stays put, so a whitelisted title reaches
        # the board on the join event and never on a leave.
        def handle_membership_change(update)
          member = update["my_chat_member"] || {}
          chat = member["chat"] || {}
          chat_id = chat["id"]
          decision = join_guard.on_join(adapter: :telegram, account: account, external_id: chat_id.to_s,
                                        title: chat["title"], inviter: membership_inviter(member),
                                        channel_sample: [])
          return nil unless decision.leave? || decision.review?

          if pending_spaces
            handle_pending_join(update, chat, chat_id)
          elsif decision.leave?
            # With no PendingSpaces row to track it, this site owns the "will
            # remain inert" fallback when the leave does not happen.
            post_inert_fallback(chat_id) unless leave_space(chat_id, notice: decision.notice)
          end
          nil
        rescue StandardError => e
          logger.warn { "telegram: membership handling failed: #{e.class}: #{e.message}" }
          nil
        end

        def membership_inviter(member)
          from = member["from"]
          return nil unless from.is_a?(Hash)

          Core::Author.new(
            native_id: from["id"], username: from["username"],
            first_name: from["first_name"], last_name: from["last_name"]
          )
        end

        # The safety net for a chat the bot could not leave. See the Discord
        # adapter's #post_inert_fallback.
        def post_inert_fallback(chat_id)
          return if join_guard.nil?
          return unless join_guard.record_leave_failure(adapter: :telegram, account: account,
                                                         external_id: chat_id.to_s)

          @client.call("sendMessage", chat_id: chat_id, text: ControlPlane::JoinGuard::INERT_NOTICE)
          logger.warn { "telegram: could not leave chat #{chat_id}; posted the inert notice instead" }
        rescue AdapterError => e
          logger.warn { "telegram: could not post the inert notice in chat #{chat_id}: #{e.message}" }
        end

        # Hand the join signal to the pending-spaces service and carry out what it
        # decided: post the one-time pending notice, or reconfirm the leave for a
        # re-added space that was already denied. my_chat_member's "from" field
        # is whoever performed the membership change, so it names who added the
        # bot.
        def handle_pending_join(update, chat, chat_id)
          from = update.dig("my_chat_member", "from") || {}
          outcome = pending_spaces.on_join!(
            adapter: :telegram, account: account, external_id: chat_id.to_s, name: chat["title"],
            inviter_native_id: from["id"], inviter_username: from["username"],
            inviter_display: telegram_inviter_name(from), member_count: chat_member_count(chat_id),
            sample_channels: []
          )
          if outcome.pending? && outcome.post_notice
            post_pending_notice(chat_id, outcome.row)
          elsif outcome.leave?
            pending_spaces.reconfirm_denied!(outcome.row)
          end
        end

        def post_pending_notice(chat_id, row)
          posted = post_space_notice(chat_id, ControlPlane::PendingSpaces::PENDING_NOTICE)
          pending_spaces.mark_notice_posted!(row) if posted
        end

        def telegram_inviter_name(from)
          parts = [from["first_name"], from["last_name"]].map { |part| part.to_s.strip }.reject(&:empty?)
          parts.empty? ? nil : parts.join(" ")
        end

        # The chat's member count, for the pending card. Not part of
        # my_chat_member, so this costs one extra Bot API call at join time; nil
        # shows as "unknown" on the dashboard.
        def chat_member_count(chat_id)
          count = @client.call("getChatMemberCount", chat_id: chat_id)
          count.is_a?(Integer) ? count : nil
        rescue StandardError
          nil
        end

        # ------------------------------------------------------------------
        # passive forum-topic discovery
        # ------------------------------------------------------------------

        # Learn a channel from a message and feed it to the discovery watch: Telegram
        # bots cannot list forum topics, so one is only learned by observing traffic;
        # chat_id plus message_thread_id is the channel's normalized route_key. Side
        # effect only, so this can fire on every message. A present thread_id only
        # means a real topic when chat.is_forum is true, since Telegram overloads the
        # field for reply-chain grouping in an ordinary group; treating that as a
        # topic route would split one flat group's traffic across a mapped channel
        # and a swallowed second one.
        def learn_forum_topic(update)
          message = update["message"] || update["channel_post"]
          return unless message.is_a?(Hash)

          chat = message["chat"] || {}
          return unless JOINABLE_CHAT.include?(chat["type"])

          chat_id = chat["id"].to_s
          thread_id = chat["is_forum"] ? message["message_thread_id"] : nil
          route_key, name, supersedes =
            if thread_id.nil?
              [chat_id, chat["title"].to_s, nil]
            else
              name, source = topic_name(chat, chat_id, thread_id, message)
              # A real name also says which placeholder it may replace: the exact
              # string this adapter would have invented for the topic. Only that
              # stand-in is overwritten, and only on an exact match, so ordinary
              # traffic cannot revert a name an operator chose.
              [(+"#{chat_id}/#{thread_id}"), name,
               source == :title_fallback ? nil : topic_placeholder(chat, thread_id)]
            end

          @discovery.saw(
            adapter: :telegram, account: account, external_id: chat_id,
            route_key: route_key, name: name, supersedes: supersedes
          )
        rescue StandardError => e
          logger.warn { "telegram: channel discovery failed: #{e.class}: #{e.message}" }
          nil
        end

        # Whether everything this update produced resolved to an endpoint no room
        # contains, meaning {Core::Dispatcher#call} is about to discard it. False
        # whenever the topology cannot be consulted, so a caller that cannot
        # prove a message is stranded never claims it is.
        def roomless?(produced)
          topology = dispatcher.respond_to?(:topology) ? dispatcher.topology : nil
          return false if topology.nil?

          messages = Array(produced).select { |message| message.respond_to?(:origin) && message.origin }
          return false if messages.empty?

          messages.all? { |message| topology.rooms_for(message.origin.id).empty? }
        end

        # The commands that answer BELOW the pipeline, in a chat that resolved
        # to no channel or to one no room contains, since the pipeline features
        # can never cover that case: a message resolving to nothing never
        # becomes a Core::Message and one in no room is dropped by
        # Dispatcher#call. Everything else about such an update is discarded,
        # which is why a bot in a group nobody has mapped yet gives no sign of
        # life at all.
        def answer_unresolved_command(update)
          message = update["message"]
          return unless message.is_a?(Hash)

          chat = message["chat"] || {}
          return unless JOINABLE_CHAT.include?(chat["type"])

          word, arguments = unresolved_command(message["text"])
          case word
          when "version" then version_from_unresolved(message, chat)
          when "identify-topic" then identify_topic_from_unresolved(message, chat, arguments)
          end
        end

        # /version has to answer wherever it is asked: a bot that says
        # nothing at all cannot be told apart from one that is down, which
        # is the whole point of the command. Only a DENIED space stays silent,
        # where the standing promise is that there are no interactions of any
        # kind, and what it discloses otherwise is tiered the way
        # Features::UtilityCommands tiers it, so a room the bot is not set up
        # for never learns the host details.
        def version_from_unresolved(message, chat)
          chat_id = chat["id"].to_s
          return if space_denied?(chat_id)

          from = message["from"] || {}
          level = version_disclosure(chat_id, from)
          thread_id = chat["is_forum"] ? message["message_thread_id"] : nil
          reply_to_unresolved(chat_id, thread_id, Core::Announcement.new(level: level).text,
                              invocation_id: message["message_id"])
        end

        # Full detail for an operator of the space, minimal for everyone else.
        # Fails closed on any error, so an unresolvable asker gets the short form.
        def version_disclosure(chat_id, from)
          operator = @discovery&.operator_for?(
            adapter: :telegram, account: account, external_id: chat_id,
            native_id: from["id"], username: from["username"]
          )
          operator ? :full : :minimal
        rescue StandardError
          :minimal
        end

        # Whether this chat was reviewed and denied, in which case the bot owes it
        # silence. False with no pending-review service, which is the wiring that
        # auto-leaves instead of reviewing.
        def space_denied?(chat_id)
          return false if pending_spaces.nil?

          pending_spaces.denied?(adapter: :telegram, account: account, external_id: chat_id)
        rescue StandardError
          false
        end

        # The /identify-topic fallback's other half (see
        # Features::IdentifyTopic for the pipeline-level one). An operator's
        # request takes effect immediately; anyone else's is recorded as the
        # same row but flagged +suggested+, for an operator to approve from
        # the Rooms board.
        def identify_topic_from_unresolved(message, chat, name)
          return if discovery.nil?

          chat_id = chat["id"].to_s
          thread_id = chat["is_forum"] ? message["message_thread_id"] : nil
          invocation_id = message["message_id"]

          if name.to_s.empty?
            reply_to_unresolved(chat_id, thread_id, "Usage: /identify-topic <name>", invocation_id: invocation_id)
            return
          end

          route_key = thread_id.nil? ? chat_id : "#{chat_id}/#{thread_id}"
          from = message["from"] || {}
          reply_to_unresolved(chat_id, thread_id, identify_topic_reply(chat_id, route_key, name, from),
                              invocation_id: invocation_id)
        end

        # The identify/suggest call and its outcome text, in its own rescue so a
        # DB-level failure still reaches the asker as a reply instead of leaving
        # them with nothing. #reply_to_unresolved never raises, so returning a
        # message here and always sending it needs no second guard.
        def identify_topic_reply(chat_id, route_key, name, from)
          operator = @discovery.operator_for?(
            adapter: :telegram, account: account, external_id: chat_id,
            native_id: from["id"], username: from["username"]
          )
          channel = @discovery.identify(
            descriptor: { adapter: :telegram, account: account, external_id: chat_id,
                          route_key: route_key, name: name },
            operator: operator
          )
          if channel.nil?
            "Sorry, I couldn't identify this channel."
          elsif operator
            "Identified this room/topic as #{name.inspect}. It still needs mapping into a room from the " \
              "dashboard's Rooms board before it starts bridging."
          else
            "Suggested #{name.inspect} for this room/topic. An operator needs to approve it from the " \
              "Rooms board before it counts as identified."
          end
        rescue StandardError => e
          logger.warn { "telegram: /identify-topic fallback failed: #{e.class}: #{e.message}" }
          "Sorry, something went wrong identifying this channel. Try again, or check the logs."
        end

        # The registry spelling of the command word and everything after it, or
        # [nil, nil] when the text is not a command at all, parsed against the
        # default prefix set since no scope has resolved here to read a custom one
        # from. Canonicalizing covers both the "@thebot" suffix Telegram appends in
        # a group and the underscored "/identify_topic" the "/" menu offers.
        def unresolved_command(text)
          body = Core::CommandPrefix.new.strip(text.to_s)
          return [nil, nil] if body.nil?

          words = body.split(/\s+/)
          return [nil, nil] if words.empty?

          [Core::CommandRegistry.canonical(words.first), words[1..].to_a.join(" ").strip]
        end

        # The reply, addressed by raw chat_id/thread_id since no live
        # Core::Endpoint resolved for this chat; outbound delivery has never
        # depended on inbound resolution, so it goes through the same
        # #deliver. With the ephemeral primitive wired, the reply
        # self-deletes and takes +invocation_id+ (the command being
        # answered) with it, using the shared defaults since no scope
        # resolved here to read a TTL from; without it, the reply is posted
        # plainly and stays.
        def reply_to_unresolved(chat_id, thread_id, text, invocation_id: nil)
          endpoint = unresolved_endpoint(chat_id, thread_id)
          return post_plain_reply(endpoint, text) if ephemeral.nil?

          delay = Core::CommandAck::DEFAULT_TTL_SECONDS
          group = ephemeral.post(
            endpoints: [endpoint], body: Core::RichText.plain(text), name: UNRESOLVED_REPLY_NAME,
            delete_after: delay, also_delete: unresolved_pairing(endpoint, invocation_id)
          )
          cleanup&.after(delay) { group.delete_now } if group.any?
          group
        rescue StandardError => e
          logger.warn { "telegram: could not post a reply in an unmapped chat: #{e.class}: #{e.message}" }
          nil
        end

        # The synthetic endpoint the fallback addresses, deliberately not in the
        # topology since it names a chat no channel row is mapped for. The
        # ephemeral durable row carries enough to rebuild it, so a reap after a
        # restart can still remove what was posted here.
        def unresolved_endpoint(chat_id, thread_id)
          Core::Endpoint.new(
            id: "unresolved:#{chat_id}/#{thread_id}", adapter_name: :telegram, account: account,
            settings: { chat_id: chat_id, thread_id: thread_id }.compact
          )
        end

        # The invocation, so it vanishes with the reply. Empty when the caller
        # named none.
        def unresolved_pairing(endpoint, invocation_id)
          return [] if invocation_id.to_s.empty?

          [Core::MessageRef.new(endpoint.id, invocation_id.to_s)]
        end

        def post_plain_reply(endpoint, text)
          notice = Core::Message.new(
            kind: :system, ref: Core::MessageRef.new(endpoint.id, "unresolved-#{SecureRandom.hex(4)}"),
            origin: endpoint, author: Core::Author.new(kind: :system),
            body: Core::RichText.plain(text), sender_label: UNRESOLVED_REPLY_NAME
          )
          deliver(notice, endpoint)
        end

        # The best name discovery can give a forum topic right now, as [name, source]:
        # the durable {Core::ThreadNames} store is read first (filled unconditionally
        # by #note_forum_topic from whichever message carried the name), since a
        # topic's name rides on its forum_topic_created/edited service message, almost
        # never the one that trips discovery. This message's own service payload is
        # the fallback for when that store hasn't processed it yet. The source
        # matters as much as the name: only :title_fallback is an invented
        # placeholder, and it must not sit on a channel once the real name shows up.
        def topic_name(chat, chat_id, thread_id, message)
          known = thread_names.name_for(scope: chat_id, native_id: thread_id)
          return [log_topic_name(chat_id, thread_id, known, :known_store), :known_store] if known

          service = (message["forum_topic_created"] || message["forum_topic_edited"] || {})["name"].to_s
          unless service.strip.empty?
            return [log_topic_name(chat_id, thread_id, service, :service_message), :service_message]
          end

          # Telegram attaches the topic's opening message to every message in the
          # topic (Inbound#reply_ref), and that opener carries the name via
          # forum_topic_created. Read straight off this update, because the durable
          # store is not wired on every deployment and naming would silently no-op.
          opener = message["reply_to_message"]
          if opener.is_a?(Hash)
            replied = (opener["forum_topic_created"] || opener["forum_topic_edited"] || {})["name"].to_s
            unless replied.strip.empty?
              return [log_topic_name(chat_id, thread_id, replied, :topic_opener), :topic_opener]
            end
          end

          name = topic_placeholder(chat, thread_id)
          [log_topic_name(chat_id, thread_id, name, :title_fallback), :title_fallback]
        end

        # The stand-in for a topic that cannot be named yet: the parent chat's
        # title plus the topic id. Every topic in one forum shares everything but
        # the number, which is why it must be replaceable once a real name turns
        # up.
        def topic_placeholder(chat, thread_id)
          title = chat["title"].to_s
          title.empty? ? "" : "#{title} (topic #{thread_id})"
        end

        # Which of #topic_name's sources resolved a topic's label, and to what.
        # Debug only because it fires on every message in a topic.
        def log_topic_name(chat_id, thread_id, name, source)
          logger.debug { "telegram: topic name for #{chat_id}/#{thread_id} resolved via #{source}: #{name.inspect}" }
          name
        end

        # Publish the command list, unless this account has been told not to own
        # the bot's menu. {Commands#register} swallows a rejection of its own;
        # this second rescue keeps a cosmetic menu from being the reason an
        # adapter fails to start.
        def register_commands
          return self unless settings.fetch(:register_commands, true)

          @commands.register
          self
        rescue StandardError => e
          logger.warn { "could not register telegram commands: #{e.class}: #{e.message}" }
          self
        end

        def build_transport
          klass = settings[:transport] == :webhook ? Transport::Webhook : Transport::LongPolling
          klass.new(
            client: @client,
            logger: logger,
            on_update: method(:handle_update),
            settings: settings,
            # Both transports persist their resume state here (an offset for
            # polling, a registration flag for webhook) so a restart replays
            # the gap instead of skipping to now. No durable store, no memory
            # of it, and both skip on every restart.
            storage: storage,
            account: account
          )
        end

        # Telegram addresses a forum topic with a (chat_id, message_thread_id)
        # pair, and the General topic has no thread id at all, so indexing on the
        # pair keeps a chat bridged both as a whole and per topic unambiguous.
        def build_index(endpoints)
          endpoints.each_with_object({}) do |endpoint, index|
            index[key(endpoint.settings[:chat_id], endpoint.settings[:thread_id])] = endpoint
          end
        end

        # Every endpoint this account bridges, across every community: the boot
        # index without a live resolver, and the resolver's whole route table
        # with one, the same two sources {#endpoints_in_chat} reads.
        def every_endpoint
          return @index.values if @endpoint_resolver.nil?
          return [] unless @endpoint_resolver.respond_to?(:endpoints_for)

          @endpoint_resolver.endpoints_for(:telegram, account).map { |(_route_key, endpoint)| endpoint }
        end

        # The chats reachable inside ONE community. Empty rather than falling
        # back to the account's other chats, so a caller that finds nothing
        # here refuses instead of acting on another tenant's supergroup.
        def chat_ids_in_community(community_id)
          Core::CommunityScope.within(every_endpoint, community_id)
                              .filter_map { |endpoint| endpoint.settings[:chat_id] }.map(&:to_s).uniq
        end

        # The chat to act in when the call named none: this community's, where
        # it bridges exactly one and there is nothing to choose. Several is
        # still ambiguous inside one tenant, and none means nothing on this
        # account belongs to it, so both refuse rather than pick.
        def community_chat_id(community_id, doing:)
          chats = chat_ids_in_community(community_id)
          return chats.first if chats.size == 1

          logger.error do
            "telegram: REFUSED to #{doing} for community #{community_id.inspect}: the call names no " \
              "chat and that community bridges #{chats.size} of them here (#{chats.join(", ")})"
          end
          nil
        end

        # The second latch, for a native id that did name a chat: one this
        # community bridges nothing in is refused rather than acted on, so a
        # stale or mistaken id cannot reach another tenant's supergroup.
        def chat_in_community?(chat_id, community_id, doing)
          return true if chat_ids_in_community(community_id).include?(chat_id.to_s)

          logger.error do
            "telegram: REFUSED to #{doing} in chat #{chat_id}, which community " \
              "#{community_id.inspect} bridges nothing in"
          end
          false
        end

        # "<chat_id>/<thread_id>" -> [chat_id, thread_id]. A bare thread id
        # carries no chat half at all, and thread ids repeat across chats, so
        # it is resolvable only against the community's own chat.
        def split_native_channel_id(native_id, community_id, doing:)
          chat_id, thread_id = native_id.to_s.split("/", 2)
          return [chat_id, thread_id] if thread_id

          [community_chat_id(community_id, doing: doing), chat_id]
        end

        # Resolve an inbound (chat_id, thread_id) to its endpoint: with a
        # live resolver the address is normalised into the same route_key
        # the seed wrote, without one it reads the boot-time index. An
        # unmapped pair is a miss and must never fall back to (chat_id,
        # nil)'s General-topic endpoint, since substituting General as the
        # origin breaks the router's echo exclusion, bouncing a topic's own
        # relayed message back to it if that topic shares a room with
        # General (see Snapshot#resolve).
        def endpoint_for(chat_id, thread_id)
          if @endpoint_resolver
            return @endpoint_resolver.endpoint_for(:telegram, account, route_key_for(chat_id, thread_id))
          end

          @index[key(chat_id, thread_id)]
        end

        # Resolve a reaction to its endpoint: MessageReactionUpdated and
        # MessageReactionCountUpdated carry no message_thread_id, so #endpoint_for
        # would miss every endpoint bridged to a topic. The topic is recovered
        # instead, cheaply when a chat bridges exactly one endpoint, otherwise from
        # the message map and then the card lookup. There is deliberately no last
        # resort past that: falling back to the bare chat id's General endpoint
        # would mirror a reaction into the wrong channel whenever the map and card
        # lookup go quiet for an ordinary reason; a dropped reaction is cheaper.
        def endpoint_for_reaction(chat_id, message_id)
          candidates = endpoints_in_chat(chat_id)
          return candidates.first if candidates.size == 1

          endpoint_holding(candidates, message_id) || undetermined_topic(chat_id, message_id, candidates)
        end

        # Nothing, having said why, for a chat bridging several endpoints where
        # the map cannot say which of them the reacted-to message is in.
        def undetermined_topic(chat_id, message_id, candidates)
          logger.debug do
            "dropped a Telegram reaction on #{chat_id}:#{message_id}, its topic could not be determined: " \
              "the update names none, the message map places the message in none of the " \
              "#{candidates.size} endpoints bridged in that chat, and guessing would mirror it " \
              "into a channel it does not belong in"
          end
          nil
        end

        # Every endpoint bridged anywhere in this chat: the chat itself and each
        # of its topics. A live resolver hands back the account's whole route
        # table and the narrowing happens here, since the shape of a route key
        # belongs to the adapter.
        def endpoints_in_chat(chat_id)
          bare = chat_id.to_s
          return @index.filter_map { |(chat, _thread), endpoint| endpoint if chat == bare } if @endpoint_resolver.nil?
          return [] unless @endpoint_resolver.respond_to?(:endpoints_for)

          @endpoint_resolver.endpoints_for(:telegram, account).filter_map do |route_key, endpoint|
            endpoint if route_key == bare || route_key.start_with?("#{bare}/")
          end
        end

        # Which candidate the message map, or failing that the card lookup, has
        # heard of for this message id, or nil: the message map is asked first,
        # both directions, as in Bridge#related_native_id, since the message
        # reacted to may be one relayed FROM here or a copy we wrote INTO here.
        # A bridge-authored post (an event card) was never relayed, so it leaves
        # no row there at all; #card_lookup is the second source for exactly that case.
        def endpoint_holding(candidates, message_id)
          return nil if message_id.nil?

          candidates.find { |endpoint| mapped?(endpoint, message_id) } ||
            candidates.find { |endpoint| carded?(endpoint, message_id) }
        end

        def mapped?(endpoint, message_id)
          return false if storage.nil?

          ref = Core::MessageRef.new(endpoint.id, message_id)
          !storage.counterparts(ref).empty? || !storage.origins(ref).empty?
        rescue StandardError => e
          logger.warn { "could not read the message map for #{endpoint.id}:#{message_id}: #{e.class}: #{e.message}" }
          false
        end

        def carded?(endpoint, message_id)
          return false if card_lookup.nil?

          card_lookup.holds_card?(endpoint.id, message_id)
        rescue StandardError => e
          logger.warn { "could not read the card lookup for #{endpoint.id}:#{message_id}: #{e.class}: #{e.message}" }
          false
        end

        # Reads @client when it runs rather than when it is built, so
        # #replace_client needs no rebuild here either.
        def build_custom_emoji
          CustomEmoji.new(
            stickers: ->(ids) { @client.call("getCustomEmojiStickers", custom_emoji_ids: ids) },
            logger: logger
          )
        end

        def build_avatars
          Avatars.new(
            # Both read @client when they run rather than when they are built, so
            # #replace_client needs no rebuild here.
            photos: ->(user_id) { @client.call("getUserProfilePhotos", user_id: user_id, limit: 1) },
            file_url: ->(file_id) { @client.file_url(file_id) },
            rehoster: rehoster,
            logger: logger
          )
        end

        # The public link to this sender's profile photo, or nil. Answered from
        # the avatar cache, so an inbound message never waits on a Bot API call
        # or a download.
        def avatar_for(user_id, chat_id, thread_id)
          return nil if @avatars.nil? || user_id.nil?
          # Rubotty's own relayed copies arrive back as messages from the bot,
          # and wearing its own face is what this exists to stop.
          return nil if !own_account_id.nil? && user_id.to_s == own_account_id.to_s

          community_id, retention_days = avatar_scope(chat_id, thread_id)
          return nil if community_id.nil?

          @avatars.url_for(user_id, community_id, retention_days: retention_days)
        end

        # Which community would keep the copy and for how long, or nil when this
        # room's community has not switched the feature on. Off is the default,
        # and off means no Bot API call, no copy and no picture.
        def avatar_scope(chat_id, thread_id)
          return nil unless @endpoint_resolver.respond_to?(:route)

          route = @endpoint_resolver.route(:telegram, account, route_key_for(chat_id, thread_id))
          return nil if route.nil?

          community, channel = route
          name = Features::TelegramAvatars.feature_name
          return nil unless community.feature_enabled?(channel, name)
          return nil unless puppeted_elsewhere?(community, channel)

          [community.id, Features::TelegramAvatars.retention_days(community.feature_config(channel, name))]
        end

        # Whether this room has anywhere else to show the picture: a second,
        # sending endpoint that could puppet this sender, the same targets
        # Bridge's own fan-out would reach. A Telegram-only room has none, and
        # fetching and storing a copy nobody will ever see is the whole cost
        # this feature warns about for no benefit at all.
        def puppeted_elsewhere?(community, channel)
          room_key = community.room_key_of(channel)
          room = room_key && community.rooms.find { |candidate| candidate.id == room_key }
          return false if room.nil?

          room.targets_for(channel.endpoint).any?
        end

        # The normalised inbound address: the bare chat_id for the General topic,
        # "<chat_id>/<thread_id>" for a forum topic. Mirrors #key here and
        # Seed#route_key_for on the write side.
        def route_key_for(chat_id, thread_id)
          thread_id.nil? ? chat_id.to_s : "#{chat_id}/#{thread_id}"
        end

        def key(chat_id, thread_id)
          [chat_id.to_s, thread_id.nil? ? nil : thread_id.to_i]
        end
      end
    end
  end
end
