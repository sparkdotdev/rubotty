# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # /platforms page's public join-link editor: each entry is a { platform, label,
    # url } row, one set per scope (community default or a room), advertised by the
    # /platforms chat command. A link is public, unauthenticated, one-directional,
    # a pointer to the community's other platform endpoints for a member already in
    # the room; {GuestInvites} is the separate guest-portal access token.
    # {.normalize} is the one place the entry shape is enforced, since the
    # dashboard writes these entries and {Features::UtilityCommands} reads them
    # back, and the two must not drift apart.
    class PlatformLinks
      # Raised for a request {#replace} cannot carry out. Nothing triggers this
      # today: a url-less or malformed row is silently dropped by {.normalize}.
      class Invalid < Rubotty::Error; end

      # The feature and config key the platform-link array is stored under
      # (Features::UtilityCommands.config_schema's `platforms` field).
      FEATURE = "utility_commands"
      CONFIG_KEY = "platforms"

      # Normalize a raw array of platform-link entries into clean, symbol-keyed
      # { platform:, label:, url: } maps: drop any entry with no usable url, and
      # default a missing label to the platform name, capitalised, or "Join". A
      # class method so {Features::UtilityCommands} can run this pure transform
      # with no +feature_controls:+, accepting either key shape (string or
      # symbol) and either platform field name, "platform" or "name".
      #
      # @return [Array<Hash>] symbol-keyed { platform:, label:, url: } maps
      def self.normalize(entries)
        Array(entries).filter_map do |raw|
          entry = symbolize(raw)
          url = presence(entry[:url])
          next if url.nil?

          platform = presence(entry[:platform] || entry[:name]).to_s
          label = presence(entry[:label]) || (platform.empty? ? "Join" : platform.capitalize)
          { platform: platform, label: label, url: url }
        end
      end

      # A raw Hash's keys normalised to symbols. A non-Hash entry normalises to {},
      # which {.normalize} then drops for having no url, rather than raising.
      def self.symbolize(raw)
        return {} unless raw.is_a?(Hash)

        raw.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end
      private_class_method :symbolize

      # +value+ stripped, or nil for a blank or whitespace-only string.
      def self.presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end
      private_class_method :presence

      # @param feature_controls [FeatureControls] reads and writes the
      #   underlying feature_settings rows
      # @param logger [#info, nil]
      def initialize(feature_controls:, logger: nil)
        @feature_controls = feature_controls
        @logger = logger
      end

      # The current, normalized platform-link entries for one scope. Runs the
      # stored config through {.normalize} on the way OUT as well as in, so a
      # caller never sees a row written by something that bypassed {#replace}.
      #
      # @param community [Models::Community]
      # @param selector [String] "all", or a room selector resolved the same
      #   way every other FeatureControls-backed read resolves one
      # @return [Array<Hash>] symbol-keyed { platform:, label:, url: } maps
      def list(community:, selector:)
        row = @feature_controls.list(community, selector: selector).find { |entry| entry[:feature] == FEATURE }
        self.class.normalize(row && row[:config][CONFIG_KEY])
      end

      # Replace one scope's whole platform-link set with +entries+, the raw rows
      # built from the dashboard form's parallel platform[]/label[]/url[] fields.
      # Normalized first, so a url-less row never reaches storage.
      #
      # @return [Array<Hash>] the normalized entries actually written, so a
      #   caller (the dashboard's flash message) can report how many landed
      def replace(community:, selector:, entries:)
        normalized = self.class.normalize(entries)
        @feature_controls.set(
          community: community, selector: selector, feature: FEATURE, key: CONFIG_KEY,
          value: JSON.generate(normalized)
        )
        @logger&.info do
          "platform links replaced: community=#{community.slug} selector=#{selector} count=#{normalized.length}"
        end
        normalized
      end
    end
  end
end
