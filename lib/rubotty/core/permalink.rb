# frozen_string_literal: true

require "uri"

module Rubotty
  module Core
    # The inverse of an adapter's +message_permalink+: a link somebody pasted,
    # read back into the endpoint settings and message id it names. There was no
    # way to do this at all, which is what stopped a member reporting a message
    # by pasting a link. Platform shaped rather than asked of each adapter: an
    # adapter answers for the account it is connected to, and a pasted link has
    # to be matched against every endpoint before anybody knows which connection
    # it belongs to.
    module Permalink
      # What one link resolved to, before it is matched against a topology:
      # +settings+ are the endpoint settings that would produce this link, and
      # +native_id+ is the message on it.
      Target = Struct.new(:adapter, :settings, :native_id, keyword_init: true)

      TELEGRAM = %r{\Ahttps://t\.me/c/(?<chat>\d+)(?:/(?<thread>\d+))?/(?<message>\d+)/?\z}
      DISCORD = %r{\Ahttps://(?:\w+\.)?discord(?:app)?\.com/channels/(?<guild>\d+)/(?<channel>\d+)/(?<message>\d+)/?\z}
      MATRIX = %r{\Ahttps://matrix\.to/\#/(?<room>[^/?]+)/(?<event>[^/?]+)}

      module_function

      # Read +text+ as a message link, or nil when it is not one. Only a whole
      # link is taken, not one mentioned inside a sentence: a report has to name
      # one message exactly, and guessing which of two links in a paragraph was
      # meant is worse than asking.
      #
      # @return [Target, nil]
      def parse(text)
        link = text.to_s.strip
        return nil if link.empty?

        telegram(link) || discord(link) || matrix(link)
      end

      # Whether +target+ names this endpoint. Compared on the settings the link
      # carries and nothing else, so an endpoint that merely sits on the same
      # account never matches another's link.
      def matches?(target, endpoint)
        return false if target.nil? || endpoint.nil?
        return false unless endpoint.adapter_name.to_sym == target.adapter

        target.settings.all? { |key, value| endpoint.settings[key].to_s == value.to_s }
      end

      # The endpoint in +endpoints+ this link names, or nil.
      def endpoint_for(target, endpoints)
        Array(endpoints).find { |endpoint| matches?(target, endpoint) }
      end

      def telegram(link)
        match = TELEGRAM.match(link)
        return nil if match.nil?

        settings = { chat_id: "-100#{match[:chat]}" }
        # A forum topic sits between the chat and the message, which is the same
        # order message_permalink writes the pair in.
        settings[:thread_id] = match[:thread] if match[:thread]
        Target.new(adapter: :telegram, settings: settings, native_id: match[:message])
      end

      def discord(link)
        match = DISCORD.match(link)
        return nil if match.nil?

        Target.new(adapter: :discord,
                   settings: { guild_id: match[:guild], channel_id: match[:channel] },
                   native_id: match[:message])
      end

      def matrix(link)
        match = MATRIX.match(link)
        return nil if match.nil?

        room = URI::DEFAULT_PARSER.unescape(match[:room])
        event = URI::DEFAULT_PARSER.unescape(match[:event])
        return nil unless room.start_with?("!") || room.start_with?("#")

        Target.new(adapter: :matrix, settings: { room_id: room }, native_id: event)
      end
    end
  end
end
