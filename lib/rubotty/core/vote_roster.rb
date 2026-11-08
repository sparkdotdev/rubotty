# frozen_string_literal: true

module Rubotty
  module Core
    # How a set of people is written next to what they answered. The bridge's
    # own `@handle@platform` form, minus the half the reader is standing on,
    # and a plain name for anybody the platform knows without a handle.
    module VoteRoster
      Voter = Struct.new(:identity, :platform, :handle, :name, keyword_init: true)

      INLINE_LIMIT = 3

      # Written where nothing human is known, since a platform id in that
      # place tells the room even less.
      UNKNOWN = "someone"

      # A bare number is a platform id (Telegram's, Discord's) and means
      # nothing in a room. Anything else is the nick a platform without ids
      # goes by, which is worth writing.
      PLATFORM_ID = /\A\d+\z/

      module_function

      # The names while there are at most {INLINE_LIMIT}, the count once there
      # are more, so a card stays readable at a glance.
      #
      # @param voters [Array<Voter>]
      # @param on_platform [String, Symbol, nil] the platform this is rendered for
      # @return [String, nil] nil for nobody at all
      def inline(voters, on_platform: nil)
        list = Array(voters)
        return nil if list.empty?
        return list.size.to_s if list.size > INLINE_LIMIT

        names(list, on_platform: on_platform).join(", ")
      end

      # Every name, never truncated.
      #
      # @return [String, nil]
      def long(voters, on_platform: nil)
        list = Array(voters)
        return nil if list.empty?

        names(list, on_platform: on_platform).join(", ")
      end

      # @return [Array<String>]
      def names(voters, on_platform: nil)
        Array(voters).map { |voter| handle_for(voter, on_platform: on_platform) }
      end

      # A real handle first, then the directory's name, then a nick identity.
      #
      # @param voter [Voter]
      # @return [String] {UNKNOWN} when none of those is known
      def handle_for(voter, on_platform: nil)
        handle = presence(voter.handle)
        return handle_label(handle, voter, on_platform) if handle

        name = presence(voter.name)
        return name_label(name, voter, on_platform) if name

        nick = nick_identity(voter)
        nick ? handle_label(nick, voter, on_platform) : UNKNOWN
      end

      def handle_label(handle, voter, on_platform)
        platform = elsewhere(voter, on_platform)
        platform ? "@#{handle}@#{platform}" : "@#{handle}"
      end

      # Unprefixed, since a sigil on a name that nobody can address reads as a
      # handle that would work.
      def name_label(name, voter, on_platform)
        platform = elsewhere(voter, on_platform)
        platform ? "#{name} (#{platform})" : name
      end

      # The voter's platform, or nil for a reader already standing on it.
      def elsewhere(voter, on_platform)
        platform = presence(voter.platform)
        return nil if platform.nil? || platform == presence(on_platform)

        platform
      end

      # @return [String, nil] the identity, unless it is a platform's own id
      def nick_identity(voter)
        identity = presence(voter.identity)
        return nil if identity.nil? || identity.match?(PLATFORM_ID)

        identity
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
