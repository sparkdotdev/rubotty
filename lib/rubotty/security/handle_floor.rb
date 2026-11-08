# frozen_string_literal: true

require "set"

module Rubotty
  module Security
    # Shared matching for a floor that grants on a bare platform handle
    # (mixed into {ProtectedOperators} and {DashboardViewers}): a bare
    # username matches only on {BARE_HANDLE_ADAPTERS}, where the platform
    # issues it uniquely; {#handle_floor_match?} answers false everywhere
    # else rather than risk handing a stranger an unauthenticated or
    # federated handle's grant. A username is recyclable on rename, so a
    # native id on file always settles the match first, and Matrix only
    # matches on the full MXID, never the bare localpart.
    module HandleFloor
      FEDERATED_ADAPTERS = %i[matrix].freeze
      BARE_HANDLE_ADAPTERS = %i[telegram discord].freeze

      # Downcase then remove all whitespace, so "  M Szaro " and "mszaro"
      # compare equal. Returns nil for a blank value.
      def self.normalise(value)
        return nil if value.nil?

        key = value.to_s.downcase.gsub(/\s+/, "")
        key.empty? ? nil : key
      end

      # Matrix account IDs are case-sensitive opaque identifiers. This helper
      # validates the shape without changing any part of the identity.
      def self.matrix_id(value)
        return nil if value.nil?

        id = value.to_s
        id if id.bytesize <= 255 && /\A@[^:\s]+:[^\s]+\z/.match?(id)
      end

      private

      # @param ids [Hash] adapter (string or symbol) => native ids, for the
      #   adapters in {BARE_HANDLE_ADAPTERS} only
      def handle_floor_init(usernames:, matrix_ids:, ids: {})
        @usernames = handle_floor_set(usernames)
        @matrix_ids = Array(matrix_ids).filter_map { |value| HandleFloor.matrix_id(value) }.to_set
        source = ids.is_a?(Hash) ? ids : {}
        @ids = BARE_HANDLE_ADAPTERS.each_with_object({}) do |adapter, out|
          out[adapter] = handle_floor_set(source[adapter.to_s] || source[adapter])
        end
      end

      def handle_floor_empty?
        @usernames.empty? && @matrix_ids.empty? && @ids.values.all?(&:empty?)
      end

      # @param adapter [String, Symbol] the platform the handle is on
      # @param username [String, nil] the stable handle (never the display name)
      # @param native_id [String, nil] the platform id; on Matrix this is the MXID
      def handle_floor_match?(adapter:, username: nil, native_id: nil)
        name = adapter.to_s.to_sym
        if FEDERATED_ADAPTERS.include?(name)
          # A presented account id is authoritative. Only a caller with no id
          # may carry the full MXID in the username field instead.
          identity = native_id.nil? || native_id.to_s.empty? ? username : native_id
          id = HandleFloor.matrix_id(identity)
          !id.nil? && @matrix_ids.include?(id)
        elsif BARE_HANDLE_ADAPTERS.include?(name)
          # A configured id list is authoritative for this adapter. Retaining a
          # legacy handle must not grant its next holder the same privileges.
          if @ids[name].empty?
            handle_floor_contains?(@usernames, username)
          else
            handle_floor_contains?(@ids[name], native_id)
          end
        else
          false
        end
      end

      # Whichever value settled the match: the native id when one is on file
      # for this adapter, the username otherwise. Assumes {#handle_floor_match?}
      # already returned true for the same arguments.
      def handle_floor_label(adapter:, username: nil, native_id: nil)
        name = adapter.to_s.to_sym
        if FEDERATED_ADAPTERS.include?(name)
          native_id || username
        elsif BARE_HANDLE_ADAPTERS.include?(name) && handle_floor_contains?(@ids[name], native_id)
          native_id
        else
          username
        end
      end

      # The named handles as { handle:, kind: } hashes, for display only.
      def handle_floor_entries
        usernames = @usernames.map { |handle| { handle: handle, kind: "username" } }
        matrix_ids = @matrix_ids.map { |handle| { handle: handle, kind: "matrix" } }
        ids = @ids.flat_map do |adapter, set|
          set.map { |handle| { handle: handle, kind: "#{adapter}_id" } }
        end
        (usernames + matrix_ids + ids).sort_by { |entry| [entry[:kind], entry[:handle]] }
      end

      def handle_floor_contains?(set, value)
        key = HandleFloor.normalise(value)
        !key.nil? && set.include?(key)
      end

      def handle_floor_set(list)
        Array(list).filter_map { |value| HandleFloor.normalise(value) }.to_set
      end
    end
  end
end
