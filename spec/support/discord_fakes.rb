# frozen_string_literal: true

# Stand ins for the discordrb objects the adapter touches, so the whole inbound
# and outbound path runs with no gateway and no network.
module DiscordFakes
  Emoji = Struct.new(:id, :name, keyword_init: true)

  Attachment = Struct.new(:url, :filename, :content_type, :size, :width, :height, keyword_init: true)

  class User
    attr_reader :id, :username, :global_name, :nick, :bot_account

    def initialize(id:, username:, global_name: nil, nick: nil, bot_account: false)
      @id = id
      @username = username
      @global_name = global_name
      @nick = nick
      @bot_account = bot_account
    end

    def name = @username

    def display_name = @nick || @global_name || @username

    def bot_account? = @bot_account
  end

  class Message
    attr_reader :id, :content, :author, :attachments, :referenced_message, :timestamp, :webhook_id
    attr_accessor :edited, :deleted, :edited_content, :reactions, :pinned, :channel

    def initialize(id:, content: "", author: nil, attachments: [], referenced_message: nil,
                   edited: false, timestamp: Time.now, webhook_id: nil)
      @id = id
      @content = content
      @author = author
      @attachments = attachments
      @referenced_message = referenced_message
      @edited = edited
      @timestamp = timestamp
      @webhook_id = webhook_id
      @deleted = false
      @pinned = false
      @reactions = []
    end

    def edited? = @edited

    def webhook? = !@webhook_id.nil?

    def edit(new_content)
      @edited_content = new_content
      self
    end

    def delete
      @deleted = true
    end

    def pin = (@pinned = true)

    def unpin = (@pinned = false)

    def create_reaction(token) = @reactions << token

    def delete_own_reaction(token) = @reactions.delete(token)
  end

  # A Discordrb::Webhooks::Client stand in.
  class WebhookClient
    attr_reader :executed, :edited, :deleted

    def initialize(id: "wh1", token: "wht")
      @id = id
      @token = token
      @executed = []
      @edited = []
      @deleted = []
      @counter = 0
      @fail_with = nil
    end

    def fail_next(error) = (@fail_with = error)

    def execute(builder, wait = false)
      raise_pending!
      @counter += 1
      @executed << {
        content: builder.content, username: builder.username,
        avatar_url: builder.avatar_url, file: builder.file,
        files: (builder.respond_to?(:files) ? builder.files : [builder.file].compact),
        allowed_mentions: builder.allowed_mentions,
        embeds: builder.embeds
      }
      return nil unless wait

      Struct.new(:body).new(%({"id":"wh-#{@counter}"}))
    end

    def edit_message(id, content: nil, allowed_mentions: nil, thread_id: nil, **)
      @edited << { id: id, content: content, allowed_mentions: allowed_mentions, thread_id: thread_id }
    end

    def delete_message(id)
      raise_pending!
      @deleted << id
    end

    private

    def raise_pending!
      return if @fail_with.nil?

      error = @fail_with
      @fail_with = nil
      raise error
    end
  end

  # A Discordrb::Webhook: `avatar` is nil until a custom one is set, and
  # avatar_writes counts the modify-webhook calls.
  class Hook
    attr_reader :id, :name, :token, :avatar, :avatar_writes

    def initialize(id:, name:, token:, avatar: nil)
      @id = id
      @name = name
      @token = token
      @avatar = avatar
      @avatar_writes = 0
    end

    def avatar=(value)
      @avatar = value
      @avatar_writes += 1
    end
  end

  # The guild (server) a channel belongs to; #name is what the auto-leave guard
  # matches against the protected-communities whitelist.
  Server = Struct.new(:id, :name, keyword_init: true)

  class Channel
    attr_reader :id, :sent, :files, :messages, :created_webhooks
    attr_accessor :existing_webhooks, :webhook_error, :server, :parent_id, :name

    # On a thread this is the member who started it, which is where the bridge
    # learns who to credit a thread to.
    attr_reader :owner_id

    # Both a thread and a channel sitting in a category carry a truthy
    # +parent_id+, Discord's own overload of that field, so +channel_type+ is
    # what the inbound path's #thread? check actually keys off.
    def initialize(id:, server: nil, parent_id: nil, name: nil, pm: false, channel_type: :text,
                   owner_id: nil)
      @id = id
      @server = server
      @parent_id = parent_id
      @name = name
      @owner_id = owner_id
      @pm = pm
      @channel_type = channel_type
      @sent = []
      @files = []
      @messages = {}
      @counter = 0
      @existing_webhooks = []
      @created_webhooks = []
      @webhook_error = nil
    end

    def pm? = @pm

    def private? = @pm

    # A guild text channel, the only kind channel discovery maps.
    def text? = !@pm && @channel_type == :text

    def thread? = @channel_type == :thread

    # Counted so a spec can prove the ownership check reads the list once per
    # channel rather than once per message it is asked about.
    def webhook_list_calls = @webhook_list_calls ||= 0

    def webhooks
      @webhook_list_calls = webhook_list_calls + 1
      raise @webhook_error if @webhook_error

      @existing_webhooks
    end

    def create_webhook(name, avatar = nil, _reason = nil)
      raise @webhook_error if @webhook_error

      hook = Hook.new(id: "created-#{name}", name: name, token: "tok", avatar: avatar)
      @created_webhooks << hook
      @existing_webhooks << hook
      hook
    end

    def store(message)
      @messages[message.id.to_s] = message
      message
    end

    def load_message(id) = @messages[id.to_s]

    def send_message(content, _tts = false, embed = nil, _attachments = nil,
                     allowed_mentions = nil, message_reference = nil, *_rest)
      @counter += 1
      @sent << {
        content: content, embed: embed, allowed_mentions: allowed_mentions,
        message_reference: message_reference
      }
      store(Message.new(id: "sent-#{@counter}", content: content))
    end

    def send_embed(message = "", embed = nil, _attachments = nil, _tts = false,
                   allowed_mentions = nil, message_reference = nil, *_rest)
      @counter += 1
      @sent << {
        content: message, embed: embed, allowed_mentions: allowed_mentions,
        message_reference: message_reference
      }
      store(Message.new(id: "sent-#{@counter}", content: message))
    end

    def send_file(file, caption: nil, filename: nil, spoiler: nil)
      @counter += 1
      @files << { bytes: file.read, caption: caption, filename: filename, spoiler: spoiler }
      store(Message.new(id: "file-#{@counter}", content: caption.to_s))
    end
  end

  # Replaces Rubotty::Adapters::Discord::Client.
  class Client
    attr_reader :channels, :handlers, :own_id, :own_name, :edited_messages,
                :registered_commands, :command_handlers, :left_servers, :guild_notices,
                :created_scheduled_events, :updated_scheduled_events, :deleted_scheduled_events,
                :pruned_global_command_ids,
                :created_guild_channels, :deleted_guild_channels, :copied_permission_overwrites,
                :direct_messages, :known_users

    def initialize(own_id: "bot-discord", own_name: "bridgebot")
      @channels = {}
      @handlers = {}
      # Users the bot can see, keyed by id. Empty by default, so an unlisted id
      # answers nil the way discordrb does for a member it never cached.
      @known_users = {}
      @own_id = own_id
      @own_name = own_name
      @connected = false
      # Empty means no privileged intent was rejected, the same as a real
      # gateway that never closed with a 4014.
      @rejected_privileged_intents = []
      @edited_messages = []
      # Admin DMs the adapter sent, and the ids it must refuse to reach.
      @direct_messages = []
      @unreachable = []
      # The native slash-command seam: what the adapter published, and the
      # handlers a spec fires interactions through.
      @registered_commands = []
      @command_handlers = {}
      # The guild membership and discovery seam.
      @guild_channels = {}
      @unlistable_guilds = []
      @unleavable_guilds = []
      @left_servers = []
      @guild_notices = []
      # The Guild Scheduled Events seam; the returned ids are canned but
      # overridable per test through the usual `allow(client).to receive(...)`.
      @created_scheduled_events = []
      @updated_scheduled_events = []
      @deleted_scheduled_events = []
      @next_scheduled_event_id = 0
      # Who "added" the bot to a guild, nil by default as for a real bot with no
      # View Audit Log permission.
      @guild_inviters = {}
      # Lets a spec force leave_server to fail, exercising the inert-notice fallback.
      @leave_error = nil
      @unknown_command_handler = nil
      @existing_global_commands = []
      @pruned_global_command_ids = []
      @created_guild_channels = []
      @deleted_guild_channels = []
      @copied_permission_overwrites = []
      @next_channel_id = 0
      @create_channel_error = nil
      @overwrites_by_channel = {}
      # The guilds READY reports as already joined, which #sweep_known_guilds
      # enumerates. Empty by default, matching a fresh bot in no guilds.
      @servers = {}
      # A guild's live member count, unset by default: a guild nobody
      # configured answers nil, the same as a real gateway with no cached view.
      @member_counts = {}
    end

    # Configure the global commands Discord reports as already registered, as
    # [{ id:, name: }].
    def set_existing_global_commands(commands) = (@existing_global_commands = commands)

    # Configure a guild's live member count, for the download-serve ceiling
    # seam. #guild_member_count reads this back.
    def set_member_count(guild_id, count) = (@member_counts[guild_id.to_s] = count)

    def guild_member_count(guild_id) = @member_counts[guild_id.to_s]

    # Stores the catch-all handler for a command interaction with no matching
    # name-specific handler bound.
    def on_unknown_application_command(&block) = (@unknown_command_handler = block)

    # Fire the catch-all for ANY command interaction, known or not, as discordrb's
    # generic interaction_create event would.
    def invoke_unknown(interaction) = @unknown_command_handler&.call(interaction)

    def prune_stale_global_commands(current_names)
      known = current_names.map(&:to_s)
      @existing_global_commands.each do |command|
        next if known.include?(command[:name].to_s)

        @pruned_global_command_ids << command[:id]
      end
    end

    # Configure the guilds this fake reports as already joined, keyed by guild id.
    def set_servers(servers) = @servers = servers.transform_keys(&:to_s)

    # Configure the text channels a guild reports.
    def set_guild_channels(guild_id, channels) = @guild_channels[guild_id.to_s] = channels

    # Make a guild's channel listing come back unavailable, as the real client
    # does when Discord throttles or refuses the enumeration.
    def throttle_guild_channels(guild_id) = @unlistable_guilds << guild_id.to_s

    def guild_text_channels(guild_id)
      listing = Rubotty::Adapters::Discord::ChannelListing
      return listing.unavailable("429 Too Many Requests") if @unlistable_guilds.include?(guild_id.to_s)

      listing.listed(@guild_channels[guild_id.to_s] || [])
    end

    # Configure who the audit log names as having added the bot to a guild, as
    # { id:, username:, display_name: }.
    def set_guild_inviter(guild_id, inviter) = @guild_inviters[guild_id.to_s] = inviter

    def guild_inviter(guild_id, _bot_user_id) = @guild_inviters[guild_id.to_s]

    # Make the next (and only the next) #leave_server call raise.
    def fail_next_leave(error) = (@leave_error = error)

    # Make a guild invisible to the leave call, as discordrb does when it has no
    # cached view of it and the REST resolve is refused.
    def hide_guild_from_leave(guild_id) = @unleavable_guilds << guild_id.to_s

    def leave_server(guild_id)
      if @leave_error
        error = @leave_error
        @leave_error = nil
        raise error
      end
      return false if @unleavable_guilds.include?(guild_id.to_s)

      @left_servers << guild_id.to_s
      true
    end

    def post_guild_notice(guild_id, text) = @guild_notices << { guild_id: guild_id.to_s, text: text }

    # Mark a native id Discord will not deliver to.
    def unreachable!(native_id) = @unreachable << native_id.to_s

    def send_direct_message(native_id, text)
      return nil if text.to_s.empty?
      return nil if @unreachable.include?(native_id.to_s)

      @direct_messages << { native_id: native_id.to_s, text: text.to_s }
      dm_channel = channel("dm-#{native_id}")
      message = dm_channel.store(Message.new(id: "dm-#{@direct_messages.size}", content: text.to_s))
      { message_id: message.id, channel_id: dm_channel.id }
    end

    # Records one application-command definition, with the guild it was scoped to
    # (nil for a global registration).
    def register_application_command(definition, guild_id: nil)
      @registered_commands << { definition: definition, guild_id: guild_id }
    end

    # Stores the handler for a command name; the block is called with a neutral
    # Interactions::Interaction, as the real client does.
    def on_application_command(name, &block)
      @command_handlers[name.to_s] = block
    end

    # Fire an interaction for +name+ through the stored handler.
    def invoke(name, interaction) = @command_handlers[name.to_s]&.call(interaction)

    def channel(id)
      @channels[id.to_s] ||= Channel.new(id: id.to_s)
    end

    # Records a bot message edit, the path the adapter uses so the edit can carry
    # an allowed_mentions whitelist, which discordrb's Message#edit cannot.
    def edit_message(channel_id, message_id, content, allowed_mentions: nil)
      edit = { channel_id: channel_id.to_s, message_id: message_id.to_s,
               content: content, allowed_mentions: allowed_mentions }
      @edited_messages << edit
      channel(channel_id).store(Message.new(id: message_id, content: content, edited: true))
      edit
    end

    def bot = self

    def connect
      @connected = true
      self
    end

    def run_async(timeout: nil)
      @connected = true
      self
    end

    def stop
      @connected = false
    end

    def connected? = @connected

    # Simulates a gateway that closed with Discord's own "disabled privileged
    # intents" code, naming the intents that would have been requested.
    def reject_privileged_intents!(*intents) = (@rejected_privileged_intents = intents.map(&:to_sym))

    def privileged_intent_rejected? = !@rejected_privileged_intents.empty?

    def requested_privileged_intents = @rejected_privileged_intents

    # discordrb's registration methods, recorded so a spec can fire an event.
    # Guild Scheduled Events arrive through `unknown`, where discordrb puts every
    # dispatch it has no event class for.
    %i[message message_edit message_delete reaction_add reaction_remove
       reaction_remove_all reaction_remove_emoji member_join member_leave
       server_create channel_create thread_create thread_update unknown ready].each do |name|
      define_method(name) { |&block| @handlers[name] = block }
    end

    def fire(name, event) = @handlers[name]&.call(event)

    def create_scheduled_event(guild_id, payload)
      @next_scheduled_event_id += 1
      @created_scheduled_events << { guild_id: guild_id.to_s, payload: payload }
      { "id" => @next_scheduled_event_id.to_s }
    end

    def update_scheduled_event(guild_id, event_id, payload)
      @updated_scheduled_events << { guild_id: guild_id.to_s, event_id: event_id.to_s, payload: payload }
      { "id" => event_id.to_s }
    end

    def delete_scheduled_event(guild_id, event_id)
      @deleted_scheduled_events << { guild_id: guild_id.to_s, event_id: event_id.to_s }
      nil
    end

    # Real return values are stubbed per test; this default keeps verified partial
    # doubles satisfied.
    def scheduled_event_users(_guild_id, _event_id, limit: 100) = []

    # Make the next (and only the next) #create_guild_channel call raise.
    def fail_next_create_channel(error) = (@create_channel_error = error)

    # Give a channel some overwrites to copy, as { id:, allow:, deny: }.
    def set_permission_overwrites(channel_id, overwrites) = (@overwrites_by_channel[channel_id.to_s] = overwrites)

    def create_guild_channel(guild_id, name, template_id: nil)
      if @create_channel_error
        error = @create_channel_error
        @create_channel_error = nil
        raise error
      end

      @next_channel_id += 1
      id = "created-channel-#{@next_channel_id}"
      @created_guild_channels << { guild_id: guild_id.to_s, name: name.to_s, template_id: template_id&.to_s }
      id
    end

    def delete_guild_channel(channel_id)
      @deleted_guild_channels << channel_id.to_s
      true
    end

    def copy_permission_overwrites(from_id, to_id)
      overwrites = @overwrites_by_channel[from_id.to_s] || []
      return false if overwrites.empty?

      @copied_permission_overwrites << { from: from_id.to_s, to: to_id.to_s, overwrites: overwrites }
      true
    end

    def user(id) = @known_users[id.to_s]

    def servers = @servers

    # History fetch used by the paced backfill.
    def history(_channel_id, after_id: nil, limit: 100) = []

    # Reaction-history fetch used by the paced backfill: a flat list of
    # [emoji, user] pairs currently reacting to a message.
    def reactions(_channel_id, _message_id, limit: 200) = []
  end

  MessageEvent = Struct.new(:message, :channel, keyword_init: true)
  DeleteEvent = Struct.new(:id, :channel, keyword_init: true)
  # user_id stands in for the bare id discordrb's real ReactionEvent parses
  # off the gateway payload before it goes looking for a Member; a real event
  # exposes no public reader for it, only #user, which a spec can leave nil to
  # exercise the fallback that reads it a different way.
  ReactionEvent = Struct.new(:message_id, :channel, :user, :emoji, :user_id, keyword_init: true)
  # GUILD_CREATE / CHANNEL_CREATE gateway events.
  ServerCreateEvent = Struct.new(:server, keyword_init: true)
  ChannelCreateEvent = Struct.new(:channel, keyword_init: true)
  # A THREAD_CREATE / THREAD_UPDATE gateway event, exposing the thread channel
  # via #thread.
  ThreadEvent = Struct.new(:thread, keyword_init: true)
  # discordrb's UnknownEvent stand-in: the raw dispatch type and its raw JSON
  # data, string keyed.
  UnknownEvent = Struct.new(:type, :data, keyword_init: true)
  # ServerMemberAddEvent / ServerMemberDeleteEvent stand-in: both carry the
  # guild as #server, with no channel of their own.
  MemberEvent = Struct.new(:user, :server, keyword_init: true)

  # Stand-ins for the discordrb objects the REAL Discord::Client reaches for, so
  # a spec can drive the guild path through the client itself rather than
  # replacing it. Only the guild membership surface is modelled.
  module Gateway
    Channel = Struct.new(:id, :name, keyword_init: true)

    # discordrb's Server, for the four guild methods.
    class Server
      attr_reader :id, :name

      def initialize(id:, name: "A Guild", channels: [], listing_error: nil, leave_error: nil)
        @id = id
        @name = name
        @channels = channels
        @listing_error = listing_error
        @leave_error = leave_error
        @left = false
      end

      def text_channels
        raise @listing_error if @listing_error

        @channels
      end

      # No View Audit Log, which is the common case for a bot nobody configured.
      def audit_logs(**) = raise(RuntimeError, "Missing Permissions")

      def system_channel = nil

      def leave
        raise @leave_error if @leave_error

        @left = true
      end

      def left? = @left
    end

    # discordrb's Cache#server answers nil for a guild it has no cached view of
    # and cannot resolve over REST, which is the shape both guild bugs turn on.
    class Bot
      def initialize(servers) = @servers = servers.transform_keys(&:to_s)

      def servers = @servers

      def server(id) = @servers[id.to_s]
    end
  end

  module_function

  def user(id: "u1", username: "ada", **rest) = User.new(id: id, username: username, **rest)

  def message_event(channel, message) = MessageEvent.new(message: message, channel: channel)
end
