# frozen_string_literal: true

module Rubotty
  module Core
    # The identity map: one human, several platform accounts, so someone
    # authorised on one platform is authorised on the other and `@alex` typed on
    # Telegram pings sample_owner on Discord.
    #
    # Every operator is a person; most people are not operators.
    class Person
      attr_reader :name, :identities, :handles, :nicknames

      # @param name [String] human label, used in logs
      # @param identities [Hash{Symbol=>Array<String>}] adapter to native ids
      # @param handles [Hash{Symbol=>Array<String>}] adapter to usernames, lowercased
      # @param nicknames [Hash{Symbol=>String}] adapter to the name this person is
      #   bridged as there. Also folded into +handles+ by the builder, so a
      #   nickname resolves like any other handle.
      def initialize(name:, identities: {}, handles: {}, nicknames: {})
        @name = name.to_s
        @identities = normalise(identities).freeze
        @handles = normalise(handles) { |value| value.to_s.downcase.delete_prefix("@") }.freeze
        @nicknames = (nicknames || {}).to_h { |adapter, value| [adapter.to_sym, value.to_s] }.freeze
        freeze
      end

      # The name this person is bridged as on +adapter_name+, or nil to use
      # whatever the sender label would otherwise build.
      def nickname_on(adapter_name)
        value = @nicknames[adapter_name.to_sym]
        value unless value.nil? || value.empty?
      end

      def identity?(adapter_name, native_id)
        return false if native_id.nil?

        @identities.fetch(adapter_name.to_sym, []).include?(native_id.to_s)
      end

      def handle?(adapter_name, handle)
        return false if handle.nil?

        @handles.fetch(adapter_name.to_sym, []).include?(handle.to_s.downcase.delete_prefix("@"))
      end

      # This person's native id on +adapter_name+, or nil if they have no
      # account there.
      def id_on(adapter_name)
        @identities.fetch(adapter_name.to_sym, []).first
      end

      def to_s = name

      private

      def normalise(map)
        (map || {}).each_with_object({}) do |(adapter, values), out|
          out[adapter.to_sym] = Array(values).map { |value| block_given? ? yield(value) : value.to_s }
        end
      end
    end

    # Lookup over the configured people, indexed on construction rather than
    # scanned per message.
    class Directory
      def initialize(people = [])
        @people = people.freeze
        @by_identity = {}
        @by_handle = {}
        index!
        freeze
      end

      attr_reader :people

      def empty? = @people.empty?

      def size = @people.size

      # Find by platform user id.
      def by_identity(adapter_name, native_id)
        return nil if native_id.nil?

        @by_identity[[adapter_name.to_sym, native_id.to_s]]
      end

      # Find by username. Telegram `@handle` mentions carry no id, so this is
      # the only way to resolve them.
      def by_handle(adapter_name, handle)
        return nil if handle.nil?

        @by_handle[[adapter_name.to_sym, handle.to_s.downcase.delete_prefix("@")]]
      end

      # The people a message in +community+ may resolve against. A directory
      # built from config describes one deployment holding one people list, so
      # naming a community picks out the same people it already holds.
      def for_community(_community) = self

      # Resolve whatever a mention span happens to carry. Telegram supplies
      # either a user id (text_mention) or a bare handle (mention); Discord
      # always supplies an id; Matrix always supplies an id too, its MXID.
      #
      # @param attributes [Hash] a mention span's attributes
      # @return [Person, nil]
      def resolve_mention(attributes)
        return nil if attributes.nil?

        by_identity(:telegram, attributes[:tg_user_id]) ||
          by_identity(:discord, attributes[:discord_id]) ||
          by_identity(:matrix, attributes[:matrix_id]) ||
          by_handle(:telegram, attributes[:username]) ||
          by_handle(:discord, attributes[:username])
      end

      private

      def index!
        @people.each do |person|
          person.identities.each do |adapter, ids|
            ids.each { |id| @by_identity[[adapter, id]] ||= person }
          end
          person.handles.each do |adapter, handles|
            handles.each { |handle| @by_handle[[adapter, handle]] ||= person }
          end
        end
        @by_identity.freeze
        @by_handle.freeze
      end
    end

    # The whole deployment's people, kept community by community: a person is
    # unique only WITHIN a community, so the same platform account may hold a
    # different row (and nicknames) in each. {#for_community} is how a reader
    # asks on behalf of the community a message arrived in, and is the only
    # lookup that can answer for an account two communities both claim; the
    # deployment-wide lookups fail closed instead, resolving an account
    # claimed by more than one community to nobody rather than picking one
    # arbitrarily.
    class CommunityPeople
      # What an unresolved community resolves against: nobody.
      EMPTY = Directory.new([]).freeze

      # @param directories [Hash{Object=>Directory}] community id to that
      #   community's own people
      def initialize(directories = {})
        @by_community = directories.to_h.freeze
        @people = @by_community.values.flat_map(&:people).freeze
        freeze
      end

      attr_reader :people

      def empty? = @people.empty?

      def size = @people.size

      # This community's OWN directory, and NOTHING when no community was
      # resolved. It used to answer with the merged deployment-wide view, which
      # is the fail-open half of the bug this class was added to close: a caller
      # that lost its community resolved everybody instead of nobody, so a ban
      # target or a mention could land on another tenant's account. Every
      # community the snapshot holds gets an entry here even when it has no
      # people, so a miss means the id names no community rather than an empty
      # one, and the config path has no CommunityPeople at all.
      def for_community(community)
        id = community.respond_to?(:id) ? community.id : community
        @by_community.fetch(id, EMPTY)
      end

      def by_identity(adapter_name, native_id)
        sole { |directory| directory.by_identity(adapter_name, native_id) }
      end

      def by_handle(adapter_name, handle)
        sole { |directory| directory.by_handle(adapter_name, handle) }
      end

      def resolve_mention(attributes)
        sole { |directory| directory.resolve_mention(attributes) }
      end

      private

      # The single community's answer, or nil once a second community answers
      # too. Within one community the ordinary first-match rule still applies.
      def sole
        found = nil
        @by_community.each_value do |directory|
          person = yield(directory)
          next if person.nil?
          return nil unless found.nil?

          found = person
        end
        found
      end
    end
  end
end
