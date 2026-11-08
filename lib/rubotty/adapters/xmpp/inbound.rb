# frozen_string_literal: true

module Rubotty
  module Adapters
    module Xmpp
      # Converts an XMPP MUC message (a plain Hash from the Client) into a
      # canonical message. A MUC message is plain text, and the sender is the
      # occupant NICK, which the sender label and loop prevention both key on.
      class Inbound
        def initialize(endpoint_for:, logger: nil)
          @endpoint_for = endpoint_for
          @logger = logger
        end

        def message(event)
          endpoint = @endpoint_for.call(event["room_jid"])
          return nil if endpoint.nil?

          nick = presence(event["nick"])
          body = event["body"].to_s
          # No nick is a room subject or a system notice; an empty body is a state
          # change such as a chat state or a receipt.
          return nil if nick.nil? || body.empty?

          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, event["id"] || synth_id(nick)),
            origin: endpoint,
            author: Core::Author.new(native_id: "occupant:#{nick}", username: nick, kind: :user),
            body: Core::RichText.plain(body),
            timestamp: time_of(event),
            raw: event
          )
        end

        # An occupant's MUC presence (available/unavailable) as a canonical
        # :join or :leave message, so Features::Greetings and Features::AntiRaid
        # see the same shape a Discord member add/remove does.
        def membership(event)
          endpoint = @endpoint_for.call(event["room_jid"])
          return nil if endpoint.nil?

          nick = presence(event["nick"])
          return nil if nick.nil?

          Core::Message.new(
            kind: event["kind"] == "leave" ? :leave : :join,
            ref: Core::MessageRef.new(endpoint.id, "presence-#{nick}-#{Time.now.to_f}"),
            origin: endpoint,
            author: Core::Author.new(native_id: "occupant:#{nick}", username: nick, kind: :user),
            timestamp: time_of(event),
            raw: event
          )
        end

        private

        def synth_id(nick) = "#{nick}-#{Time.now.to_f}"

        def time_of(event)
          value = event["time"]
          value.is_a?(Time) ? value : Time.now
        end

        def presence(value)
          return nil if value.nil?

          string = value.to_s.strip
          string.empty? ? nil : string
        end
      end
    end
  end
end
