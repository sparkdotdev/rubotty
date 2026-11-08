# frozen_string_literal: true

module Rubotty
  module Core
    # Every holder of bridge-authored posts behind the one seam an adapter
    # reads. See Adapters::Base#card_lookup.
    class CardLookup
      # @param holders [Array<#holds_card?>] nils are dropped
      def initialize(holders)
        @holders = Array(holders).compact.freeze
      end

      def holds_card?(endpoint_id, native_id)
        @holders.any? { |holder| holder.holds_card?(endpoint_id, native_id) }
      end
    end
  end
end
