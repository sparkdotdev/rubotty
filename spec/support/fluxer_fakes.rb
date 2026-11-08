# frozen_string_literal: true

require "json"

# Stand ins for the Fluxer REST client and gateway, so the adapter runs with no
# network and no socket.
module FluxerFakes
  # Replaces Rubotty::Adapters::Fluxer::Client.
  class Client
    attr_reader :sent, :edited, :deleted, :reactions_added, :reactions_removed,
                :webhook_executes, :webhook_edits, :webhook_deletes, :created_webhooks,
                :bans, :unbans, :kicks, :channel_listings, :dms_opened,
                :left_guilds, :pins, :unpins, :timeouts, :fetch_user_calls,
                :members, :fetch_member_calls

    # +guilds+ and each entry of +guild_channels+ may be an exception instead of a
    # list, which is how a spec makes one guild refuse enumeration. +members+ is
    # keyed "guild_id/user_id", answered by #fetch_member.
    def initialize(own_id: "bot-fluxer", gateway_url: "wss://gateway.fluxer.test",
                   users: {}, members: {}, existing_webhooks: [], guilds: [], guild_channels: {})
      @own_id = own_id
      @gateway_url = gateway_url
      @users = users
      @members = members
      @existing_webhooks = existing_webhooks
      @guilds = guilds
      @guild_channels = guild_channels
      @channel_listings = []
      @sent = []
      @edited = []
      @deleted = []
      @reactions_added = []
      @reactions_removed = []
      @webhook_executes = []
      @webhook_edits = []
      @webhook_deletes = []
      @created_webhooks = []
      @bans = []
      @unbans = []
      @kicks = []
      @dms_opened = []
      @left_guilds = []
      @pins = []
      @unpins = []
      @timeouts = []
      @fetch_user_calls = []
      @fetch_member_calls = []
      @counter = 0
    end

    def own_id = @own_id

    def gateway_url = @gateway_url

    def fetch_user(id)
      @fetch_user_calls << id.to_s
      @users[id.to_s]
    end

    def fetch_member(guild_id, user_id)
      @fetch_member_calls << "#{guild_id}/#{user_id}"
      @members["#{guild_id}/#{user_id}"]
    end

    def list_guilds
      raise @guilds if @guilds.is_a?(Exception)

      @guilds
    end

    def list_guild_channels(guild_id)
      @channel_listings << guild_id.to_s
      channels = @guild_channels[guild_id.to_s]
      raise channels if channels.is_a?(Exception)

      Array(channels)
    end

    def send_message(channel_id, body)
      @counter += 1
      @sent << { channel: channel_id, body: body }
      { "id" => "sent-#{@counter}", "channel_id" => channel_id }
    end

    def send_message_with_files(channel_id, body, files)
      @counter += 1
      @sent << { channel: channel_id, body: body, files: files }
      { "id" => "sent-#{@counter}", "channel_id" => channel_id }
    end

    def create_dm(user_id)
      @dms_opened << user_id.to_s
      { "id" => "dm-channel-#{user_id}" }
    end

    def edit_message(channel_id, message_id, body)
      @edited << { channel: channel_id, id: message_id, body: body }
      { "id" => message_id.to_s }
    end

    def delete_message(channel_id, message_id)
      @deleted << { channel: channel_id, id: message_id }
      nil
    end

    def add_reaction(channel_id, message_id, emoji)
      @reactions_added << { channel: channel_id, message: message_id, emoji: emoji }
      nil
    end

    def remove_own_reaction(channel_id, message_id, emoji)
      @reactions_removed << { channel: channel_id, message: message_id, emoji: emoji }
      nil
    end

    def list_webhooks(_channel_id) = @existing_webhooks

    def create_webhook(channel_id, name)
      hook = { "id" => "wh-#{channel_id}", "name" => name, "token" => "tok" }
      @created_webhooks << hook
      @existing_webhooks << hook
      hook
    end

    def execute_webhook(webhook_id, webhook_token, body)
      @counter += 1
      @webhook_executes << { id: webhook_id, token: webhook_token, body: body }
      { "id" => "wh-msg-#{@counter}" }
    end

    def execute_webhook_with_files(webhook_id, webhook_token, body, files)
      @counter += 1
      @webhook_executes << { id: webhook_id, token: webhook_token, body: body, files: files }
      { "id" => "wh-msg-#{@counter}" }
    end

    def edit_webhook_message(webhook_id, webhook_token, message_id, body)
      @webhook_edits << { id: webhook_id, token: webhook_token, message: message_id, body: body }
      { "id" => message_id.to_s }
    end

    def delete_webhook_message(webhook_id, webhook_token, message_id)
      @webhook_deletes << { id: webhook_id, token: webhook_token, message: message_id }
      nil
    end

    def ban_member(guild_id, user_id, reason: nil)
      @bans << { guild: guild_id, user: user_id, reason: reason }
      nil
    end

    def unban_member(guild_id, user_id)
      @unbans << { guild: guild_id, user: user_id }
      nil
    end

    def kick_member(guild_id, user_id)
      @kicks << { guild: guild_id, user: user_id }
      nil
    end

    def leave_guild(guild_id)
      @left_guilds << guild_id.to_s
      nil
    end

    def pin_message(channel_id, message_id)
      @pins << { channel: channel_id, id: message_id }
      nil
    end

    def unpin_message(channel_id, message_id)
      @unpins << { channel: channel_id, id: message_id }
      nil
    end

    def timeout_member(guild_id, user_id, until_time, reason: nil)
      @timeouts << { guild: guild_id, user: user_id, until: until_time, reason: reason }
      nil
    end
  end

  # Replaces Rubotty::Adapters::Fluxer::Gateway.
  class Gateway
    attr_reader :started, :stopped

    def initialize
      @started = false
      @stopped = false
    end

    def start
      @started = true
      self
    end

    def stop
      @stopped = true
      self
    end

    def running? = @started && !@stopped

    def describe = "fake gateway"
  end

  # The WebSocket the real gateway owns, capturing the frames it writes so a
  # spec can read what went out on IDENTIFY.
  class Socket
    attr_reader :frames

    def initialize
      @frames = []
    end

    def send(payload)
      @frames << JSON.parse(payload)
      payload
    end

    def close = nil
  end

  # Records what the adapter feeds the discovery seam, with no database behind it.
  class Discovery
    attr_reader :sightings, :inventories

    def initialize
      @sightings = []
      @inventories = []
    end

    def saw(descriptor)
      @sightings << descriptor
      nil
    end

    def inventory(adapter:, account:, external_id:, channels:)
      @inventories << { adapter: adapter, account: account, external_id: external_id, channels: channels }
      channels.size
    end
  end

  # Records pended spaces, answering with the outcome a first pend gives.
  class PendingSpaces
    attr_reader :joins, :reconfirmed, :notices_marked

    def initialize(outcome: nil)
      @joins = []
      @reconfirmed = []
      @notices_marked = []
      @outcome = outcome
    end

    def on_join!(**args)
      @joins << args
      @outcome || Rubotty::ControlPlane::PendingSpaces::Outcome.new(action: :pending, row: nil, post_notice: false)
    end

    def reconfirm_denied!(row)
      @reconfirmed << row
      nil
    end

    def mark_notice_posted!(row)
      @notices_marked << row
      nil
    end
  end

  # Stands in for a control_lane: hands back a fixed reply, or none, and
  # records every DM it was asked to handle.
  class ControlLane
    attr_reader :handled

    def initialize(reply: nil)
      @handled = []
      @reply = reply
    end

    def handle_dm(**args)
      @handled << args
      @reply
    end
  end

  module_function

  # A dispatch frame wrapping one event payload.
  def dispatch(name, data) = { "t" => name, "d" => data }

  # A bot's READY, which carries an empty guild list: Fluxer follows it with one
  # GUILD_CREATE per guild.
  def ready = dispatch("READY", { "guilds" => [] })

  def guild_created(id:, name: nil, **rest)
    dispatch("GUILD_CREATE", { "id" => id, "name" => name }.merge(stringify(rest)))
  end

  # Fluxer's channel types: 0 guild text, 2 voice, 4 category.
  def channel_data(id:, name:, type: 0) = { "id" => id, "name" => name, "type" => type }

  def message_data(channel:, id: "700", author: nil, content: "hello", **rest)
    author ||= { "id" => "55", "username" => "ada", "global_name" => "Ada L" }
    { "id" => id, "channel_id" => channel, "author" => author, "content" => content }.merge(stringify(rest))
  end

  def member_data(guild_id:, user: nil, **rest)
    user ||= { "id" => "55", "username" => "ada", "global_name" => "Ada L" }
    { "guild_id" => guild_id, "user" => user }.merge(stringify(rest))
  end

  def reaction_add_many_data(channel:, message: "700", guild_id: nil, reactions: [])
    { "channel_id" => channel, "message_id" => message, "guild_id" => guild_id, "reactions" => reactions }.compact
  end

  def stringify(hash)
    hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
  end
end
