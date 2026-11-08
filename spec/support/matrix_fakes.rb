# frozen_string_literal: true

# Stand ins for the Matrix client-server client and the sync loop.
module MatrixFakes
  class Client
    attr_reader :sent_events, :redactions, :kicks, :bans, :unbans, :joins, :leaves, :created_rooms

    def initialize(user_id: "@bot:example.org", displaynames: {})
      @user_id = user_id
      @displaynames = displaynames
      @sent_events = []
      @redactions = []
      @kicks = []
      @bans = []
      @unbans = []
      @joins = []
      @leaves = []
      @join_failure = nil
      @counter = 0
      @joined_room_ids = []
      @room_names = {}
      @room_aliases = {}
      @created_rooms = []
      @direct_rooms = {}
    end

    def whoami = @user_id

    def sync(since: nil, timeout_ms: 0, full_state: false)
      { "next_batch" => "s1", "rooms" => { "join" => {} } }
    end

    def send_event(room_id, type, content, txn_id: nil)
      @counter += 1
      @sent_events << { room: room_id, type: type, content: content }
      "$event-#{@counter}"
    end

    def redact(room_id, event_id, reason: nil, txn_id: nil)
      @redactions << { room: room_id, event: event_id }
      "$redact-#{event_id}"
    end

    def displayname(user_id) = @displaynames[user_id]

    def media_http_url(mxc)
      return nil unless mxc.is_a?(String) && mxc.start_with?("mxc://")

      server, media_id = mxc.delete_prefix("mxc://").split("/", 2)
      return nil if media_id.nil?

      "https://example.org/_matrix/media/v3/download/#{server}/#{media_id}"
    end

    def kick(room_id, user_id, reason: nil)
      @kicks << { room: room_id, user: user_id }
      {}
    end

    def ban(room_id, user_id, reason: nil)
      @bans << { room: room_id, user: user_id }
      {}
    end

    def unban(room_id, user_id)
      @unbans << { room: room_id, user: user_id }
      {}
    end

    def joined_rooms = @joined_room_ids

    def set_joined_rooms(room_ids) = @joined_room_ids = room_ids

    def room_name(room_id) = @room_names[room_id]

    def set_room_name(room_id, name) = @room_names[room_id] = name

    def room_canonical_alias(room_id) = @room_aliases[room_id]

    def set_room_alias(room_id, alias_) = @room_aliases[room_id] = alias_

    def fail_next_join! = @join_failure = true

    def join_room(room_id_or_alias)
      if @join_failure
        @join_failure = nil
        raise Rubotty::AdapterError.new("Matrix POST join failed (403 M_FORBIDDEN): no", adapter: :matrix)
      end
      @joins << room_id_or_alias
      room_id_or_alias
    end

    def leave_room(room_id)
      @leaves << room_id
      {}
    end

    def create_room(invite:)
      @counter += 1
      room_id = "!dm#{@counter}:example.org"
      @created_rooms << { invite: invite, room_id: room_id }
      room_id
    end

    def direct_room_for(_my_id, user_id) = @direct_rooms[user_id]

    def remember_direct_room(_my_id, user_id, room_id) = (@direct_rooms[user_id] = room_id)

    def messages(room_id, from: nil, dir: "b", limit: 100) = [[], nil]

    def relations(room_id, event_id, rel_type: "m.annotation", limit: 100) = []

    def upload(bytes, filename: nil, content_type: nil) = nil
  end

  class Sync
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

    def describe = "fake sync"
  end

  module_function

  def message_event(sender: "@ada:example.org", id: "$m1", content: "hello", ts: 1_700_000_000_000, **rest)
    { "type" => "m.room.message", "event_id" => id, "sender" => sender,
      "origin_server_ts" => ts,
      "content" => { "msgtype" => "m.text", "body" => content }.merge(stringify(rest)) }
  end

  # The stripped state rooms.invite carries: at minimum the m.room.member
  # naming our own pending invite, optionally an m.room.name.
  def invite_state(invitee: "@bot:example.org", inviter: "@ada:example.org", title: nil)
    events = [
      { "type" => "m.room.member", "state_key" => invitee, "sender" => inviter,
        "content" => { "membership" => "invite" } }
    ]
    events << { "type" => "m.room.name", "state_key" => "", "sender" => inviter,
                "content" => { "name" => title } } if title
    events
  end

  def reaction_event(sender: "@ada:example.org", id: "$r1", target: "$m1", key: "👍")
    { "type" => "m.reaction", "event_id" => id, "sender" => sender,
      "origin_server_ts" => 1_700_000_000_000,
      "content" => { "m.relates_to" => { "rel_type" => "m.annotation", "event_id" => target, "key" => key } } }
  end

  def stringify(hash)
    hash.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
  end
end
