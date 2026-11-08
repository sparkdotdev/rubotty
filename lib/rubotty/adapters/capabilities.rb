# frozen_string_literal: true

module Rubotty
  module Adapters
    # What a platform can actually do. The router consults this before anything
    # optional, so a platform that cannot do something degrades instead of
    # raising "not supported".
    class Capabilities
      # @param max_fetch_bytes [Integer, nil] largest file the bot can pull BACK,
      #   distinct from upload size (Telegram: 20 MB fetch vs 50 MB upload)
      # @param url_relay_bytes [Hash{Symbol=>Integer}, nil] largest URL a send
      #   method fetches server side, distinct from max_attachment_bytes
      # @param max_reactions [Integer, nil] how many reactions the BOT may hold on
      #   one message; Telegram allows exactly one for a non premium bot
      # @param reserved_command_prefixes [Array<String>] markers the platform's own
      #   client swallows before a bot sees them, so help text prints a different one
      def initialize(edits: false, deletes: false, replies: false, threads: false,
                     max_attachment_bytes: nil, max_fetch_bytes: nil, url_relay_bytes: nil,
                     reactions: false, max_reactions: nil, custom_reactions: false,
                     buttons: false, moderation: [], command_list: false,
                     reserved_command_prefixes: [], puppets_send: false, puppets_edit: false)
        @edits = edits
        @deletes = deletes
        @replies = replies
        @threads = threads
        @max_attachment_bytes = max_attachment_bytes
        @max_fetch_bytes = max_fetch_bytes
        @url_relay_bytes = url_relay_bytes
        @reactions = reactions
        @max_reactions = max_reactions
        @custom_reactions = custom_reactions
        @buttons = buttons
        @moderation = Array(moderation).map(&:to_sym).freeze
        @command_list = command_list
        @reserved_command_prefixes = Array(reserved_command_prefixes).map(&:to_s).freeze
        @puppets_send = puppets_send
        @puppets_edit = puppets_edit
        freeze
      end

      attr_reader :max_attachment_bytes, :max_fetch_bytes, :max_reactions, :moderation,
                  :reserved_command_prefixes

      def edits? = @edits

      def deletes? = @deletes

      def replies? = @replies

      def threads? = @threads

      def reactions? = @reactions

      def custom_reactions? = @custom_reactions

      def buttons? = @buttons

      def moderates?(action) = @moderation.include?(action.to_sym)

      def publishes_command_list? = @command_list

      # Whether a relayed message can wear the original sender's name and face
      # here. The axis that most separates the platforms worth adding next, and
      # it was invisible to the conformance suite until it had a field.
      def puppets_send? = @puppets_send

      # The same for an edit of a message already sent, separate because the two
      # differ: Slack puppets on send while chat.update takes neither a username
      # nor an icon_url, and a Discord webhook execute carries no
      # message_reference where a native reply does.
      def puppets_edit? = @puppets_edit

      # Whether either half puppets. A platform answering yes to send and no to
      # edit still puppets, it just cannot keep it up through an edit.
      def puppets? = @puppets_send || @puppets_edit

      # Whether the platform's client swallows +marker+ before the bot sees it.
      def reserves_prefix?(marker) = @reserved_command_prefixes.include?(marker.to_s)

      # The largest file this platform will fetch itself from a URL for
      # +kind+, or nil where it draws no such distinction from a real upload.
      def url_relay_ceiling(kind)
        return nil if @url_relay_bytes.nil?

        @url_relay_bytes[kind&.to_sym] || @url_relay_bytes[:default]
      end

      # A copy with +names+ turned off, for a transport whose remote genuinely
      # cannot do what this platform's floor claims. The vocabulary already had
      # negotiable, for a floor that understates what a platform can do; this is
      # the other direction, and without it an instance is held to promises it
      # cannot keep. A name that is not a capability is ignored rather than
      # raising, since it comes from an operator's configuration.
      def without(names)
        off = Array(names).map { |name| name.to_s.to_sym }
        return self if off.empty?

        attrs = to_h
        (off & FLAGS).each { |flag| attrs[flag] = false }
        attrs[:moderation] = attrs[:moderation] - off
        self.class.new(**attrs)
      end

      # Every boolean {#without} can turn off. The sizes and the prefixes are
      # not here: a ceiling is a number to lower, not a promise to withdraw.
      FLAGS = %i[edits deletes replies threads reactions custom_reactions buttons
                 command_list puppets_send puppets_edit].freeze

      def to_h
        {
          edits: @edits, deletes: @deletes, replies: @replies, threads: @threads,
          max_attachment_bytes: @max_attachment_bytes, max_fetch_bytes: @max_fetch_bytes,
          url_relay_bytes: @url_relay_bytes,
          reactions: @reactions, max_reactions: @max_reactions, custom_reactions: @custom_reactions,
          buttons: @buttons, moderation: @moderation,
          command_list: @command_list, reserved_command_prefixes: @reserved_command_prefixes,
          puppets_send: @puppets_send, puppets_edit: @puppets_edit
        }
      end
    end
  end
end
