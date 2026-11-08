# frozen_string_literal: true

require "json"
require "securerandom"

module Rubotty
  module ControlPlane
    # FAQ / custom-command entries, per scope, stored as a JSON array under
    # the `faq` feature's `entries` config key: one hash per trigger, a
    # `response` plus either a `command` (fires on `/name` or `!name`) or a
    # `keyword` (posts alongside). A thin composition over {FeatureControls}
    # rather than a fresh read/write path, so scope resolution stays correct
    # in one place. {#add} stamps a random `id` and {#remove} matches on it
    # rather than array position, so a stale index cannot delete the wrong
    # entry; an entry from before this scheme has no `id` and needs a manual fix.
    class FaqEntries
      # Raised for a request that cannot be carried out (a missing trigger or
      # response, an id that matches no entry). Carries a human-readable message.
      class Invalid < Rubotty::Error; end

      FEATURE = "faq"
      CONFIG_KEY = "entries"
      ID_BYTES = 4

      # @param feature_controls [FeatureControls] the config store this composes
      #   over; every read and write here is a `faq` / `entries` operation on it
      # @param logger [#info, nil]
      def initialize(feature_controls:, logger: nil)
        @feature_controls = feature_controls
        @logger = logger
      end

      # The current FAQ entries for a scope, as a plain array of string-keyed
      # hashes. Empty for a scope with no faq row, or whose `entries` key is
      # missing or holds something other than an array.
      #
      # @param community [Models::Community]
      # @param selector [String] `all`, a room key, a room label, or an
      #   endpoint/route key (see {FeatureControls} for the full match order)
      # @return [Array<Hash>]
      def list(community:, selector:)
        row = @feature_controls.list(community, selector: selector).find { |entry| entry[:feature] == FEATURE }
        entries = row && row[:config][CONFIG_KEY]
        entries.is_a?(Array) ? entries : []
      end

      # Append one new FAQ entry, minting its stable `id` here.
      #
      # @param trigger_type [String] "command" stores +trigger+ under the
      #   `command` key; anything else (in practice "keyword" from the
      #   dashboard's <select>) stores it under `keyword`
      # @raise [Invalid] when +trigger+ or +response+ is blank
      # @return [Hash] the stored entry, id included
      def add(community:, selector:, trigger:, response:, trigger_type:)
        trig = presence(trigger)
        resp = presence(response)
        raise Invalid, "An FAQ entry needs both a trigger and a response." if trig.nil? || resp.nil?

        entry = { "id" => SecureRandom.hex(ID_BYTES), "response" => resp }
        entry[trigger_type.to_s == "command" ? "command" : "keyword"] = trig
        update(community: community, selector: selector) { |entries| entries + [entry] }
        @logger&.info { "faq entry added: community=#{community.slug} selector=#{selector} id=#{entry["id"]}" }
        entry
      end

      # Remove the entry whose `id` matches, by exact string comparison
      # (+id.to_s+, so either a String or a Symbol works).
      #
      # @param community [Models::Community]
      # @param selector [String]
      # @param id [String]
      # @raise [Invalid] when no entry's id matches
      # @return [Array<Hash>] the entries after removal
      def remove(community:, selector:, id:)
        target = id.to_s
        updated = nil
        update(community: community, selector: selector) do |entries|
          index = entries.index { |entry| entry["id"].to_s == target }
          raise Invalid, "No such FAQ entry to remove." if index.nil?

          updated = entries.dup
          updated.delete_at(index)
          updated
        end
        @logger&.info { "faq entry removed: community=#{community.slug} selector=#{selector} id=#{target}" }
        updated
      end

      private

      # Trim and blank out: "" and "  " both mean "not given".
      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def write(community:, selector:, entries:)
        @feature_controls.set(community: community, selector: selector, feature: FEATURE,
                              key: CONFIG_KEY, value: JSON.generate(entries))
      end

      # Read the list and write it back under one lock, so an operator adding an
      # entry while another removes one cannot drop the other's change.
      def update(community:, selector:)
        @feature_controls.update(community: community, selector: selector,
                                 feature: FEATURE, key: CONFIG_KEY) do |current|
          JSON.generate(yield(current.is_a?(Array) ? current : []))
        end
      end
    end
  end
end
