# frozen_string_literal: true

# Stand in for the IRC client seam, so the whole adapter runs with no socket.
module IrcFakes
  class Client
    attr_reader :joined, :join_keys, :messages, :kicks, :bans, :unbans, :connected, :closed,
                :redactions, :reactions
    attr_accessor :negotiated_capabilities, :next_native_id, :next_extra_ids

    # @param negotiated_capabilities [Array<String>] what a real Client reports
    #   after CAP negotiation; empty means a server with no IRCv3 support.
    # @param next_native_id [String, nil] what #privmsg returns, standing in for
    #   an echo-message correlated msgid; nil makes #deliver use its synthetic id.
    def initialize(negotiated_capabilities: [], next_native_id: nil)
      @joined = []
      @join_keys = {}
      @messages = []
      @kicks = []
      @bans = []
      @unbans = []
      @redactions = []
      @reactions = []
      @connected = false
      @closed = false
      @alive = false
      @on_message = nil
      @on_dm = nil
      @negotiated_capabilities = negotiated_capabilities
      @next_native_id = next_native_id
      @next_extra_ids = []
    end

    def on_message(&block) = (@on_message = block)
    def on_dm(&block) = (@on_dm = block)

    def connect
      @connected = true
      @alive = true
      self
    end

    def alive? = @alive

    # Simulate the read loop ending on its own, e.g. a server EOF, with no
    # #close involved: what a healthy-looking but dead connection looks like.
    def kill_read_loop
      @alive = false
    end

    def negotiated?(name) = @negotiated_capabilities.include?(name.to_s)

    # +key+ is recorded separately so the shape of +joined+ stays as it is.
    def join(channel, key: nil)
      @joined << channel
      @join_keys[channel] = key if key
    end

    def privmsg(channel, text, tags: {})
      @messages << { channel: channel, text: text, tags: tags }
      @next_native_id
    end

    # Stands in for a real Client's own tracking of a wrapped send's extra
    # ids; set +next_extra_ids+ to whatever #privmsg's next call should have
    # split into.
    def ids_for(_first_id) = @next_extra_ids

    def react(channel, msgid, emoji)
      @reactions << { channel: channel, msgid: msgid, emoji: emoji }
      nil
    end

    def redact(channel, msgid, reason: nil)
      @redactions << { channel: channel, msgid: msgid, reason: reason }
      nil
    end

    def kick(channel, nick, reason: nil)
      @kicks << { channel: channel, nick: nick, reason: reason }
      nil
    end

    def ban(channel, nick)
      @bans << { channel: channel, nick: nick }
      nil
    end

    def unban(channel, nick)
      @unbans << { channel: channel, nick: nick }
      nil
    end

    def close
      @closed = true
      @alive = false
      nil
    end

    # Simulate an inbound channel message reaching the adapter.
    def emit(event) = @on_message&.call(event)

    # Simulate a DM reaching the adapter.
    def emit_dm(event) = @on_dm&.call(event)
  end

  module_function

  def message_event(channel:, nick: "ada", body: "hello", action: false, msgid: nil, reply_to: nil,
                     timestamp: nil)
    { "channel" => channel, "nick" => nick, "body" => body, "action" => action,
      "msgid" => msgid, "reply_to" => reply_to, "timestamp" => timestamp }
  end

  def dm_event(nick: "ada", body: "hi", timestamp: nil)
    { "nick" => nick, "body" => body, "timestamp" => timestamp }
  end

  def reaction_event(channel:, target_msgid:, reaction:, nick: "ada", timestamp: nil)
    { "channel" => channel, "kind" => "reaction", "nick" => nick, "target_msgid" => target_msgid,
      "reaction" => reaction, "timestamp" => timestamp }
  end

  def membership_event(channel:, kind:, nick: "ada", timestamp: nil)
    { "channel" => channel, "kind" => kind, "nick" => nick, "timestamp" => timestamp }
  end
end
