# frozen_string_literal: true

require "set"
require "yamlcamel"

module Rubotty
  module Security
    # The deployment-configured owner floor: handles that always resolve
    # to an owner-level operator, so access cannot be lost through the
    # database, the CLI or the dashboard. It only grants, never revokes by
    # being absent, and matches only the username field, never the display
    # name. A missing, empty or malformed file grants no access. Matching is
    # shared with {DashboardViewers} through {HandleFloor}.
    class ProtectedOperators
      include HandleFloor

      # Compatibility constant: a fresh deployment has no configured owners.
      FALLBACK = { "usernames" => [], "matrix" => [] }.freeze

      # The shipped YAML, resolved relative to this file.
      DEFAULT_PATH = File.expand_path("../../../config/protected_operators.yml", __dir__)

      class << self
        # The process-wide instance, loaded once from {DEFAULT_PATH} folded over
        # {FALLBACK}.
        def default
          @default ||= load(ENV.fetch("RUBOTTY_PROTECTED_OPERATORS_FILE", DEFAULT_PATH))
        end

        # Build an instance from a YAML file unioned with {FALLBACK}: a
        # missing, empty or unreadable file leaves the fallback standing.
        # The "ids" section has no deployment-configured fallback, since no native id is
        # known here.
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

        # A missing path, empty document, non-hash top level or parse error all yield
        # {}, leaving the fallback to stand on its own.
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
      def initialize(usernames:, matrix_ids:, ids: {})
        handle_floor_init(usernames: usernames, matrix_ids: matrix_ids, ids: ids)
        freeze
      end

      # True when no identity has been configured.
      def empty? = handle_floor_empty?

      # The deployment-configured handles as { handle:, kind: } hashes, for display only.
      # Never for matching; use {#owner?}.
      def entries = handle_floor_entries

      # Does any of these { adapter:, username:, native_id: } identities belong to a
      # deployment-configured owner? A deletion refused on this basis would only look like a
      # revocation while the floor still grants the access underneath.
      def protects_any?(identities)
        Array(identities).any? do |identity|
          owner?(adapter: identity[:adapter], username: identity[:username], native_id: identity[:native_id])
        end
      end

      # Does this (adapter, handle) belong to a deployment-configured owner? Matches the
      # MXID on a federated adapter, the native id where one is on file for
      # a bare-handle adapter, and the bare username otherwise, never the
      # display name.
      #
      # @param adapter [String, Symbol] the platform the handle is on
      # @param username [String, nil] the stable handle (never the display name)
      # @param native_id [String, nil] the platform id; on Matrix this is the MXID
      def owner?(adapter:, username: nil, native_id: nil)
        handle_floor_match?(adapter: adapter, username: username, native_id: native_id)
      end

      # An owner-level {Core::Moderation::Operator} for a matching handle, or nil.
      # Carries no identities, since it is resolved by handle rather than native id.
      def operator_for(adapter:, username: nil, native_id: nil)
        return nil unless owner?(adapter: adapter, username: username, native_id: native_id)

        label = handle_floor_label(adapter: adapter, username: username, native_id: native_id)
        Core::Moderation::Operator.new(name: "protected-operator:#{label}", actions: :all, rooms: :all)
      end
    end
  end
end
