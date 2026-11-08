# frozen_string_literal: true

module Rubotty
  module Watchdog
    # The contract a concrete watchdog implements: inspect one {Features::Context}
    # and return a {Verdict}. Detection only, never deleting and never posting;
    # the {Runner} turns a removal verdict into the standard removal flow.
    class Base
      # @return [String] a stable label used in logs
      def name = self.class.name.to_s

      # @param context [Features::Context]
      # @return [Verdict]
      def evaluate(_context)
        Verdict.pass
      end
    end
  end
end
