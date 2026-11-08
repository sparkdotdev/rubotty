# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module ControlPlane
    # Optional deployment-managed title patterns layered over database authorization.
    # A fresh deployment has no patterns. Missing or malformed configuration grants
    # nothing. Prefer immutable connection IDs for production authorization; title
    # patterns remain available only for explicitly configured compatibility use.
    class ProtectedCommunities
      # Empty compatibility constant. No community identities ship in the source.
      BAKED_IN = [].freeze

      # Where the shipped YAML lives, relative to this file. Used by {default}.
      DEFAULT_PATH = File.expand_path("../../../config/protected_communities.yml", __dir__)

      # Read private configuration only in production; development starts empty.
      def self.default
        @default ||= Environment.production? ? from_file(ENV.fetch("RUBOTTY_PROTECTED_COMMUNITIES_FILE", DEFAULT_PATH)) : new
      end

      # Drop the memoized {default}, so the next call re-reads ENVIRONMENT and the
      # file. For a spec that exercises {default} under more than one ENVIRONMENT
      # value in one run; the real process never needs it.
      def self.reset!
        @default = nil
      end

      # Build from optional YAML. A missing, empty or malformed file grants nothing.
      #
      # @param path [String]
      # @return [ProtectedCommunities]
      def self.from_file(path)
        data = read_data(path)
        patterns = data.is_a?(Hash) ? data["patterns"] : data
        communities = data.is_a?(Hash) ? Array(data["communities"]) : []
        slugs = communities.filter_map { |row| row["slug"] if row.is_a?(Hash) }
        new(patterns: Array(patterns).select { |entry| entry.is_a?(String) }, community_slugs: slugs)
      end

      # Reads the pattern list out of a YAML file, tolerantly: either a top-level
      # list, or a +patterns:+ key mapping to one. Anything unreadable is dropped
      # rather than granting access.
      #
      # @param path [String]
      # @return [Array<String>]
      def self.read_patterns(path)
        data = read_data(path)
        list = data.is_a?(Hash) ? data["patterns"] : data
        Array(list).select { |entry| entry.is_a?(String) }
      end

      def self.read_data(path)
        return {} unless path && File.file?(path)

        YAMLCamel.load(File.read(path))
      rescue YAMLCamel::Error, SystemCallError
        {}
      end
      private_class_method :read_data

      # @param patterns [Array<String>] explicitly configured patterns
      def initialize(patterns: [], community_slugs: [])
        @community_slugs = Array(community_slugs).select { |slug| slug.is_a?(String) && !slug.empty? }.uniq.freeze
        @patterns = (BAKED_IN + Array(patterns)).filter_map { |pattern| normalize(pattern) }
                                                .reject(&:empty?)
                                                .uniq
                                                .freeze
      end

      # The effective normalized configuration.
      #
      # @return [Array<String>]
      attr_reader :patterns, :community_slugs

      # Management guards identify configured communities by their stable slug.
      # Legacy title patterns can still guard an explicitly configured deployment,
      # but a slug never grants admission to an unrelated platform space.
      def protects_community?(community)
        return false if community.nil?

        @community_slugs.include?(community.slug.to_s) || protected?(community.name)
      end

      # Is a space with this title always-authorized by the whitelist?
      #
      # @param title [String, nil] the space title (Telegram chat title / Discord
      #   guild name); nil or blank is never protected
      # @return [Boolean]
      def protected?(title)
        normalized = normalize(title)
        return false if normalized.empty?

        @patterns.any? { |pattern| normalized.include?(pattern) }
      end

      private

      # Downcase and remove all whitespace, on both sides of the comparison.
      def normalize(value)
        value.to_s.downcase.gsub(/\s+/, "")
      end
    end
  end
end
