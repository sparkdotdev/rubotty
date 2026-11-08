# frozen_string_literal: true

# Stand in for the XMPP client seam, so the whole adapter runs with no XMPP stream.
module XmppFakes
  class Client
    attr_reader :joined, :said, :kicks, :bans, :unbans, :connected, :closed, :dms_sent, :retracts, :reacts
    # Set before #start to script what the bookmarks and disco#items enumeration finds.
    attr_accessor :bookmarks, :disco_items

    def initialize
      @joined = []
      @said = []
      @kicks = []
      @bans = []
      @unbans = []
      @dms_sent = []
      @retracts = []
      @reacts = []
      @connected = false
      @closed = false
      @on_message = nil
      @on_presence = nil
      @on_dm = nil
      @counter = 0
      @bookmarks = []
      @disco_items = {}
      @alive = false
    end

    def on_message(&block) = (@on_message = block)
    def on_presence(&block) = (@on_presence = block)
    def on_dm(&block) = (@on_dm = block)

    def alive? = @alive

    def connect
      @connected = true
      @alive = true
      self
    end

    def join(room_jid, nick)
      @joined << { room: room_jid, nick: nick }
      self
    end

    def joined_rooms = @joined.map { |j| j[:room] }

    # Every nick a join was recorded under, mirroring Client#nicks: usually
    # one value, more than one once a spec simulates a per-room fallback by
    # calling #join with a different nick for one room.
    def nicks = @joined.map { |j| j[:nick] }.uniq

    def say(room_jid, body)
      @counter += 1
      @said << { room: room_jid, body: body }
      "xmpp-#{@counter}"
    end

    def retract(room_jid, target_id)
      @retracts << { room: room_jid, target_id: target_id }
      nil
    end

    def react(room_jid, target_id, emojis)
      @reacts << { room: room_jid, target_id: target_id, emojis: emojis }
      nil
    end

    def send_dm(jid, body)
      @dms_sent << { jid: jid, body: body }
      "xmpp-dm"
    end

    def retract_dm(jid, target_id)
      @retracts << { jid: jid, target_id: target_id }
      nil
    end

    def kick(room_jid, nick, reason: nil)
      @kicks << { room: room_jid, nick: nick, reason: reason }
      nil
    end

    def ban(room_jid, jid, reason: nil)
      @bans << { room: room_jid, jid: jid, reason: reason }
      nil
    end

    def unban(room_jid, jid)
      @unbans << { room: room_jid, jid: jid }
      nil
    end

    def close
      @closed = true
      @alive = false
      nil
    end

    # Scripted stand ins for Client's real IQ round trips.
    def bookmarked_rooms(timeout: 5) = @bookmarks

    def discover_rooms(service_jid, timeout: 5) = @disco_items[service_jid.to_s] || []
    def set_disco_items(service_jid, items) = (@disco_items[service_jid.to_s] = items)

    # No upload service found by default, the same "not configured" answer a
    # real Client gives with nothing to stub in the reply from disco#info.
    def upload(bytes, filename:, content_type:) = nil

    # Simulate an inbound MUC message reaching the adapter.
    def emit(event) = @on_message&.call(event)

    # Simulate an occupant's join/leave presence reaching the adapter.
    def emit_presence(event) = @on_presence&.call(event)

    # Simulate a direct message reaching the adapter.
    def emit_dm(event) = @on_dm&.call(event)
  end

  module_function

  def message_event(room_jid:, nick: "ada", body: "hello", id: "m1")
    { "room_jid" => room_jid, "nick" => nick, "body" => body, "id" => id, "time" => Time.now }
  end

  def presence_event(room_jid:, nick: "ada", kind: "join")
    { "room_jid" => room_jid, "nick" => nick, "kind" => kind }
  end

  def dm_event(jid: "someone@example.org", body: "hi")
    { "jid" => jid, "body" => body }
  end
end
