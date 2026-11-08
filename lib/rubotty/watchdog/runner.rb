# frozen_string_literal: true

module Rubotty
  module Watchdog
    # Runs the enabled watchdogs for a channel in order; the first {Verdict} that
    # votes to remove decides and HALTS the chain, so the bridge never relays the
    # message. Fail open: a watchdog that raises is logged and treated as a pass.
    class Runner
      # @param watchdogs [Array<#evaluate>] the watchdogs to run, in order
      # @param removal [Removal] the shared removal engine
      # @param logger [#warn, nil]
      def initialize(watchdogs:, removal:, logger: nil)
        @watchdogs = Array(watchdogs)
        @removal = removal
        @logger = logger
      end

      attr_reader :watchdogs

      # Run the chain for one message.
      #
      # @param context [Features::Context]
      # @return [Features::Outcome] halt (with the removed refs) on the first
      #   removal verdict, else continue
      def run(context)
        @watchdogs.each do |watchdog|
          verdict = evaluate(watchdog, context)
          next unless verdict&.remove?

          removed = @removal.apply(context: context, reason: verdict.reason, metadata: verdict.metadata)
          return Features::Outcome.halt(removed)
        end
        Features::Outcome.continue([])
      end

      private

      # One watchdog's verdict. A raise is a pass, so a bad watchdog cannot stop
      # the ones after it.
      def evaluate(watchdog, context)
        watchdog.evaluate(context)
      rescue StandardError => e
        @logger&.warn { "watchdog #{watchdog_name(watchdog)}: #{e.class}: #{e.message}" }
        nil
      end

      def watchdog_name(watchdog)
        watchdog.respond_to?(:name) ? watchdog.name : watchdog.class.name
      end
    end
  end
end
