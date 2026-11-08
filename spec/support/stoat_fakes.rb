# frozen_string_literal: true

# Stand ins for the Stoat REST client and gateway, so the adapter runs with no
# network and no socket.
module StoatFakes
  # Replaces Rubotty::Adapters::Stoat::Client.
  class Client
    attr_reader :sent, :edited, :deleted, :reactions_added, :reactions_removed,
                :bans, :unbans, :kicks, :fetched_channels, :fetched_members, :dms_opened,
                :pins, :unpins, :timeouts, :timeout_clears, :uploads
    attr_accessor :upload_result

    # +members+ is keyed "server_id/user_id", the pair the real endpoint takes.
    def initialize(own_id: "bot-stoat", users: {}, channels: {}, members: {})
      @own_id = own_id
      @users = users
      @channels = channels
      @members = members
      @sent = []
      @edited = []
      @deleted = []
      @reactions_added = []
      @reactions_removed = []
      @bans = []
      @unbans = []
      @kicks = []
      @fetched_channels = []
      @fetched_members = []
      @dms_opened = []
      @pins = []
      @unpins = []
      @timeouts = []
      @timeout_clears = []
      @uploads = []
      @upload_result = "FILE01"
      @counter = 0
      @refuse_masquerade = false
      @refuse_send_message = false
    end

    # Behave like a channel where the bot was never granted the Masquerade
    # permission. crates/delta/src/routes/channels/message_send.rs checks it
    # before writing anything, so the whole send is refused whenever the field
    # is present, and nothing is posted.
    def refuse_masquerade!
      @refuse_masquerade = true
      self
    end

    # Behave like a channel where the bot lacks SendMessage entirely, a 403
    # with nothing to do with masquerade even though the request happened to
    # carry it.
    def refuse_send_message!
      @refuse_send_message = true
      self
    end

    def own_id = @own_id

    def fetch_user(id) = @users[id.to_s]

    # Records every pair looked up, so a spec can prove the cache spares the API.
    def fetch_member(server_id, user_id)
      key = "#{server_id}/#{user_id}"
      @fetched_members << key
      @members[key]
    end

    # Records every id fetched, so a spec can assert discovery looked up exactly
    # the channels it needed to and no more.
    def fetch_channel(id)
      @fetched_channels << id.to_s
      @channels[id.to_s]
    end

    def send_message(channel_id, body)
      if @refuse_send_message
        raise Rubotty::PermissionError.new(
          "Stoat refused POST /channels/#{channel_id}/messages (403): MissingPermission (SendMessage)",
          adapter: :stoat
        )
      end
      if @refuse_masquerade && body[:masquerade]
        raise Rubotty::PermissionError.new(
          "Stoat refused POST /channels/#{channel_id}/messages (403): MissingPermission (Masquerade)",
          adapter: :stoat
        )
      end

      @counter += 1
      @sent << { channel: channel_id, body: body }
      { "_id" => "sent-#{@counter}", "channel" => channel_id }
    end

    def open_dm(user_id)
      @dms_opened << user_id.to_s
      { "_id" => "dm-channel-#{user_id}" }
    end

    def edit_message(channel_id, message_id, body)
      @edited << { channel: channel_id, id: message_id, body: body }
      { "_id" => message_id.to_s }
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

    def ban_member(server_id, user_id, reason: nil)
      @bans << { server: server_id, user: user_id, reason: reason }
      nil
    end

    def unban_member(server_id, user_id)
      @unbans << { server: server_id, user: user_id }
      nil
    end

    def kick_member(server_id, user_id)
      @kicks << { server: server_id, user: user_id }
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

    def timeout_member(server_id, user_id, until_time)
      @timeouts << { server: server_id, user: user_id, until: until_time }
      nil
    end

    def clear_timeout(server_id, user_id)
      @timeout_clears << { server: server_id, user: user_id }
      nil
    end

    def upload_file(io, filename:, content_type: nil)
      @uploads << { filename: filename, content_type: content_type, bytes: io.respond_to?(:read) ? io.read : io.to_s }
      @upload_result
    end

    def file_url(file)
      return nil unless file.is_a?(Hash)

      id = file["_id"] || file["id"]
      return nil if id.nil?

      tag = file["tag"] || "attachments"
      filename = file["filename"] || id
      "https://cdn.stoatusercontent.com/#{escape(tag)}/#{escape(id)}/#{escape(filename)}"
    end

    def escape(value) = URI::DEFAULT_PARSER.escape(value.to_s, %r{[^A-Za-z0-9\-_.~]})
  end

  # Replaces Rubotty::Adapters::Stoat::Gateway: records lifecycle, opens nothing.
  class Gateway
    attr_reader :started, :stopped, :refusals

    def initialize
      @started = false
      @stopped = false
      @refusals = []
    end

    def start
      @started = true
      self
    end

    def stop
      @stopped = true
      self
    end

    def note_refused(reason)
      @refusals << reason
      self
    end

    def running? = @started && !@stopped && @refusals.empty?

    def describe = "fake gateway"
  end

  module_function

  # A "Message" gateway event.
  def message_event(channel:, id: "m1", author: "u-ada", content: "hello", **rest)
    { "type" => "Message", "_id" => id, "channel" => channel, "author" => author,
      "content" => content }.merge(stringify(rest))
  end

  # A Stoat channel object, as it appears in Ready's `channels` array, a
  # ChannelCreate event, or a GET /channels/{id} response.
  def channel(id:, server:, name:, channel_type: "TextChannel")
    { "_id" => id, "channel_type" => channel_type, "server" => server, "name" => name }
  end

  # A Stoat server object; `channels` is a bare list of ids, matching the real
  # API, with the full objects only in Ready or behind a REST fetch.
  def server(id:, name:, channels:)
    { "_id" => id, "name" => name, "channels" => channels }
  end

  # The bulk state sync sent right after authenticating.
  def ready_event(servers: [], channels: [])
    { "type" => "Ready", "servers" => servers, "channels" => channels }
  end

  # The envelope wrapping several events into one gateway frame.
  def bulk_event(*events)
    { "type" => "Bulk", "v" => events }
  end

  # A "ServerMemberJoin"/"ServerMemberLeave" event.
  def member_event(type:, server:, user:, member: nil)
    { "type" => type, "id" => server, "user" => user, "member" => member }.compact
  end

  # The bot was added to a server after Ready: the Server object with the event
  # type folded in.
  def server_create_event(server)
    stringify(server).merge("type" => "ServerCreate")
  end

  # A new channel appeared in a known server: the Channel object with the event
  # type folded in.
  def channel_create_event(channel)
    stringify(channel).merge("type" => "ChannelCreate")
  end

  def stringify(hash)
    hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
  end
end
