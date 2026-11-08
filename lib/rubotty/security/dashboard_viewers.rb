# frozen_string_literal: true

require "set"
require "yamlcamel"

module Rubotty
  module Security
    # Who holds the dashboard's viewer dimension: read every community, change
    # nothing. This is a floor like {ProtectedOperators}: a handle named here
    # reads every community no matter what the database holds, and
    # {ControlPlane::DashboardViewers} only adds granted rows on top
    # (administrator-only, since viewer spans every community). Empty, and
    # never an error, when the file is missing, unreadable or malformed;
    # matching itself is shared with {ProtectedOperators} through {HandleFloor}.
    class DashboardViewers
      include HandleFloor

      # The shipped YAML, resolved relative to this file.
      DEFAULT_PATH = File.expand_path("../../../config/dashboard_viewers.yml", __dir__)

      class << self
        # The process-wide instance, loaded once from {DEFAULT_PATH}.
        def default
          @default ||= load(ENV.fetch("RUBOTTY_VIEWERS_FILE", DEFAULT_PATH))
        end

        # Build an instance from a YAML file. A missing, empty, unreadable or
        # malformed file yields no viewers at all.
        def load(path = DEFAULT_PATH)
          data = read_file(path)
          new(usernames: data["usernames"], matrix_ids: data["matrix"], ids: data["ids"])
        end

        # Downcase then remove all whitespace, so "  O wner " and "owner"
        # compare equal. Returns nil for a blank value.
        def normalise(value) = HandleFloor.normalise(value)

        # Drop the memoised default. For tests only.
        def reset!
          @default = nil
        end

        private

        # A missing path, empty document, non-hash top level or parse error all
        # yield {}, which is nobody.
        def read_file(path)
          return {} unless path && File.file?(path)

          parsed = YAMLCamel.load(File.read(path, encoding: "UTF-8"))
          parsed.is_a?(Hash) ? parsed : {}
        rescue StandardError
          {}
        end
      end

      # @param usernames [Array<String>] bare handles for non-federated platforms
      # @param matrix_ids [Array<String>] full MXIDs for the Matrix adapter
      # @param ids [Hash] adapter => native ids, for {HandleFloor::BARE_HANDLE_ADAPTERS}
      def initialize(usernames: [], matrix_ids: [], ids: {})
        handle_floor_init(usernames: usernames, matrix_ids: matrix_ids, ids: ids)
        freeze
      end

      # True when nobody at all holds viewer status, the shipped default.
      def empty? = handle_floor_empty?

      # The named handles as { handle:, kind: } hashes, for display only.
      # Never for matching; use {#viewer?}.
      def entries = handle_floor_entries

      # Does this (adapter, handle) hold viewer status? Matches the MXID on
      # a federated adapter, the native id where one is on file for a
      # bare-handle adapter, and the bare username otherwise, never the
      # display name.
      #
      # @param adapter [String, Symbol] the platform the handle is on
      # @param username [String, nil] the stable handle (never the display name)
      # @param native_id [String, nil] the platform id; on Matrix this is the MXID
      def viewer?(adapter:, username: nil, native_id: nil)
        handle_floor_match?(adapter: adapter, username: username, native_id: native_id)
      end
    end
  end
end
