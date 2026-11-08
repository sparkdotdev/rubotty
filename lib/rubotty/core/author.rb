# frozen_string_literal: true

module Rubotty
  module Core
    # Who sent a message, in platform neutral terms.
    #
    # Not every platform supplies every field. Adapters fill in what they have and
    # leave the rest nil; nil and empty string are treated identically by
    # {DisplayName}, which is what stops the "FirstName ()" class of bug.
    class Author
      attr_reader :native_id, :username, :first_name, :last_name, :nickname, :display_name,
                  :bot, :kind, :avatar_url

      # @param native_id [String, nil] platform user id
      # @param username [String, nil] stable handle, without any @ sigil
      # @param first_name [String, nil]
      # @param last_name [String, nil]
      # @param nickname [String, nil] per space nickname, Discord guild nick
      # @param display_name [String, nil] platform supplied display name
      # @param bot [Boolean] whether the platform flags this account as a bot
      # @param kind [Symbol] :user, :channel or :system
      def initialize(native_id: nil, username: nil, first_name: nil, last_name: nil,
                     nickname: nil, display_name: nil, bot: false, kind: :user,
                     avatar_url: nil)
        @native_id = presence(native_id)
        @username = presence(username)
        @first_name = presence(first_name)
        @last_name = presence(last_name)
        @nickname = presence(nickname)
        @display_name = presence(display_name)
        @bot = !!bot
        @kind = kind.to_sym
        # Only ever a URL a THIRD PARTY may fetch. Telegram file URLs embed the
        # bot token, so they must never end up here.
        @avatar_url = presence(avatar_url)
        freeze
      end

      def bot? = @bot

      def system? = kind == :system

      # A last resort label when no display name template produces output.
      def any_name
        display_name || nickname || first_name || username || native_id || "unknown"
      end

      # The human name shown ALONGSIDE the handle, the "[display name]" half; never
      # falls back to username, which already fills the bold half. nil when the
      # sender has no name distinct from the handle.
      def profile_name
        display_name || self[:full_name] || nickname
      end

      # Field lookup used by {DisplayName} template expansion.
      def [](field)
        case field.to_sym
        when :native_id then native_id
        when :username then username
        when :first_name then first_name
        when :last_name then last_name
        when :nickname then nickname
        when :display_name then display_name
        when :full_name then [first_name, last_name].compact.join(" ").then { |s| s.empty? ? nil : s }
        end
      end

      # Fields a display name template may reference.
      FIELDS = %i[native_id username first_name last_name nickname display_name full_name].freeze

      def to_h
        {
          native_id: native_id, username: username, first_name: first_name, last_name: last_name,
          nickname: nickname, display_name: display_name, bot: bot, kind: kind,
          avatar_url: avatar_url
        }
      end

      def ==(other) = other.is_a?(Author) && other.to_h == to_h
      alias eql? ==

      def hash = to_h.hash

      private

      # nil, "" and "   " all mean absent, so the rest of the system only has to
      # check for nil.
      def presence(value)
        return nil if value.nil?

        string = value.to_s
        string = string.strip
        string.empty? ? nil : string
      end
    end
  end
end
