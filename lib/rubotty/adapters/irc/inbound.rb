# frozen_string_literal: true

module Rubotty
  module Adapters
    module Irc
      # Converts an IRC channel message (delivered by the Client as a plain
      # Hash) into a canonical message. Plain IRC has no message ids, so a
      # synthetic ref is minted; where the connection negotiated msgid,
      # {Client} hands over the server assigned id instead and the ref
      # becomes real and stable. No {Core::ReplyPreview} is built, since a
      # PRIVMSG carries only the +draft/reply+ tag's bare msgid and there is
      # no parent text to preview without keeping scrollback, which this
      # adapter does not.
      class Inbound
        def initialize(endpoint_for:, logger: nil)
          @endpoint_for = endpoint_for
          @logger = logger
        end

        def message(event)
          return reaction(event) if event["kind"] == "reaction"
          return membership(event) if %w[join leave].include?(event["kind"])

          endpoint = @endpoint_for.call(event["channel"])
          return nil if endpoint.nil?

          nick = presence(event["nick"])
          body = event["body"].to_s
          return nil if nick.nil? || body.empty?

          # A "/me waves" action reads naturally relayed as "* nick waves".
          text = event["action"] ? "* #{nick} #{body}" : body

          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, native_id(event, nick)),
            origin: endpoint,
            author: Core::Author.new(native_id: nick, username: nick, kind: :user),
            body: Core::RichText.plain(text),
            reply_to: reply_ref(endpoint, event["reply_to"]),
            timestamp: event["timestamp"] || Time.now,
            raw: event
          )
        end

        private

        # A client-only +draft/react+ TAGMSG, always paired with a
        # +draft/reply+ tag naming the msgid it reacts to: kind
        # +:reaction_add+, +ref+ is the TARGET message, +reaction+ carries
        # the emoji. Nothing on the wire distinguishes "add" from "remove"
        # (the same reaction sent again is a toggle), so every inbound react
        # is emitted as +:reaction_add+ and a toggle-off typed on IRC is a
        # known limitation.
        def reaction(event)
          endpoint = @endpoint_for.call(event["channel"])
          return nil if endpoint.nil?

          nick = presence(event["nick"])
          target = event["target_msgid"].to_s
          emoji = event["reaction"].to_s
          return nil if nick.nil? || target.empty? || emoji.empty?

          Core::Message.new(
            kind: :reaction_add,
            ref: Core::MessageRef.new(endpoint.id, target),
            origin: endpoint,
            author: Core::Author.new(native_id: nick, username: nick, kind: :user),
            reaction: Core::Reaction.new(emoji: emoji),
            timestamp: event["timestamp"] || Time.now,
            raw: event
          )
        end

        # JOIN, PART, QUIT and KICK all reach here as a plain "join" or
        # "leave" kind with no message id of their own to carry.
        def membership(event)
          endpoint = @endpoint_for.call(event["channel"])
          return nil if endpoint.nil?

          nick = presence(event["nick"])
          return nil if nick.nil?

          Core::Message.new(
            kind: event["kind"].to_sym,
            ref: Core::MessageRef.new(endpoint.id, "member-#{nick}-#{Time.now.to_f}"),
            origin: endpoint,
            author: Core::Author.new(native_id: nick, username: nick, kind: :user),
            timestamp: event["timestamp"] || Time.now,
            raw: event
          )
        end

        def native_id(event, nick)
          msgid = presence(event["msgid"])
          msgid || synth_id(nick)
        end

        def reply_ref(endpoint, target_msgid)
          return nil if presence(target_msgid).nil?

          Core::MessageRef.new(endpoint.id, target_msgid)
        end

        def synth_id(nick) = "#{nick}-#{Time.now.to_f}"

        def presence(value)
          return nil if value.nil?

          string = value.to_s.strip
          string.empty? ? nil : string
        end
      end
    end
  end
end
