# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # The word filter's per-scope CUSTOM word/phrase list: the smaller,
    # secondary knob an operator layers on top of the shipped base list,
    # stored as a JSON array under the feature's `custom` config key. A thin
    # composition over {FeatureControls}, so scope resolution and the
    # inherited-enablement rule for a brand-new room row stay in exactly one
    # place. {#remove} is addressed by the word or phrase's own VALUE rather
    # than by its position in the array: an index is only correct for the
    # instant it was read, and a second browser tab racing a save shifts it.
    class WordFilterEntries
      # Raised for a request that cannot be carried out, carrying a message a
      # caller prints as-is.
      class Invalid < Rubotty::Error; end

      FEATURE = "word_filter"
      CONFIG_KEY = "custom"

      # @param feature_controls [FeatureControls] the config store this composes
      #   over; every read and write here is a `word_filter` / `custom` operation
      # @param logger [#info, nil]
      def initialize(feature_controls:, logger: nil)
        @feature_controls = feature_controls
        @logger = logger
      end

      # The current custom word/phrase list for a scope, as a plain array of
      # strings. Empty for a scope with no word_filter row yet, or whose row's
      # `custom` key is missing or not an array.
      #
      # @param community [Models::Community]
      # @param selector [String] `all`, a room key, a room label, or an
      #   endpoint/route key (see {FeatureControls} for the full match order)
      # @return [Array<String>]
      def list(community:, selector:)
        row = @feature_controls.list(community, selector: selector).find { |entry| entry[:feature] == FEATURE }
        entries = row && row[:config][CONFIG_KEY]
        entries.is_a?(Array) ? entries : []
      end

      # Replace the whole custom list for a scope in one write, so a caller always
      # hands the complete list it wants stored.
      #
      # @param community [Models::Community]
      # @param selector [String]
      # @param entries [Array<String>] the complete replacement list; the caller
      #   has already turned a raw textarea into this array
      # @return [Array<String>] +entries+, for a caller that wants to echo it back
      def replace(community:, selector:, entries:)
        list = Array(entries).map(&:to_s)
        @feature_controls.set(community: community, selector: selector, feature: FEATURE,
                              key: CONFIG_KEY, value: JSON.generate(list))
        @logger&.info do
          "word filter custom list replaced: community=#{community.slug} selector=#{selector} " \
            "count=#{list.length}"
        end
        list
      end

      # Remove a single word or phrase by its exact value, leaving the rest of
      # the list untouched.
      #
      # @param community [Models::Community]
      # @param selector [String]
      # @param value [String] the exact word or phrase to remove
      # @raise [Invalid] when +value+ is not in the current list
      # @return [Array<String>] the list after removal
      def remove(community:, selector:, value:)
        word = value.to_s
        updated = nil
        @feature_controls.update(community: community, selector: selector,
                                 feature: FEATURE, key: CONFIG_KEY) do |current|
          entries = current.is_a?(Array) ? current : []
          index = entries.index(word)
          raise Invalid, "no such word or phrase to remove." if index.nil?

          updated = entries.dup
          updated.delete_at(index)
          JSON.generate(updated)
        end
        @logger&.info do
          "word filter custom entry removed: community=#{community.slug} selector=#{selector}"
        end
        updated
      end
    end
  end
end
