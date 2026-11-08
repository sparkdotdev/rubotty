# frozen_string_literal: true

module Rubotty
  module Core
    # A configurable set of leading tokens that mark a message as a command.
    # Discord reserves a leading "/" for its own native slash-command UI, so
    # "!" is accepted there too; this value object is the one place a prefix
    # is recognised AND the one place its configuration is resolved, through
    # {#strip} and {.from_scope} respectively. An unrecognised prefixed token
    # is not consumed here: {#strip} returns the body, and the calling surface
    # only takes it when the following word is one it recognises.
    class CommandPrefix
      # The out-of-the-box set: "/" for Telegram and everywhere it already worked,
      # "!" for Discord where "/" is reserved by the native slash UI.
      DEFAULT = ["/", "!"].freeze

      # The reserved feature_settings key the shared marker lives under, declared
      # by {Features::CommandMarkers} and read by every command-bearing feature.
      CONFIG_FEATURE = "commands"

      # Coerce +value+ (a String, an Array of strings, an existing CommandPrefix,
      # or nil) into a CommandPrefix.
      def self.from(value)
        return value if value.is_a?(self)

        new(Array(value))
      end

      # Resolves from a `commands`-shaped config hash: the canonical knob is
      # the `prefixes` list, with the legacy singular `prefix` string folded
      # in. A blank or absent value falls back to {DEFAULT}, never to no
      # prefix at all.
      def self.from_config(config)
        config = {} unless config.is_a?(Hash)
        list = config[:prefixes] || config["prefixes"]
        single = config[:prefix] || config["prefix"]
        new(Array(list) + Array(single))
      end

      # Resolve the shared command markers for one message's scope: the room's
      # own row over the community's over {DEFAULT}, the same shape
      # {ControlPlane::Snapshot::Community#feature_config} already gives every
      # other setting. +community+ is nil without a control plane, which reads
      # straight through to {DEFAULT}.
      #
      # @param community [ControlPlane::Snapshot::Community, nil]
      # @param channel_or_key [ControlPlane::Snapshot::Channel, String, nil]
      def self.from_scope(community, channel_or_key = nil)
        from_config(community&.feature_config(channel_or_key, CONFIG_FEATURE))
      end

      # @param prefixes [Array<String>] the configured markers; blanks are
      #   dropped and duplicates collapsed. An empty result falls back to {DEFAULT}.
      def initialize(prefixes = DEFAULT)
        cleaned = Array(prefixes).map(&:to_s).reject(&:empty?).uniq
        cleaned = DEFAULT.dup if cleaned.empty?
        @prefixes = cleaned.freeze
        # Match longest-first so that when one marker is a prefix of another (both
        # "!!" and "!") the longer one wins and no character is left dangling.
        @ordered = cleaned.sort_by { |token| -token.length }.freeze
        freeze
      end

      # The configured markers, in the order they were given.
      attr_reader :prefixes

      def to_a = @prefixes

      # The representative marker for help text and prompts (the first configured).
      def primary = @prefixes.first

      # The marker to PRINT where some of the configured ones never arrive:
      # Fluxer's own "/" menu intercepts three of our command names (/ban,
      # /kick, /nick), so a member typing those there reaches their client,
      # not the bridge. Asks +capabilities+ per marker, printing the first
      # survivor and falling back to {#primary} when none remain.
      #
      # @param capabilities [#reserves_prefix?, nil] nil reserves nothing
      def preferred(capabilities: nil)
        @prefixes.find { |token| !capabilities&.reserves_prefix?(token) } || primary
      end

      # The command body after whichever configured marker +text+ begins with, or
      # nil when it begins with none. The body is NOT tokenised.
      def strip(text)
        stripped = text.to_s.strip
        marker = @ordered.find { |token| stripped.start_with?(token) }
        return nil if marker.nil?

        stripped[marker.length..]
      end

      # Whether +text+ begins with any configured marker at all.
      def match?(text) = !strip(text).nil?
    end
  end
end
