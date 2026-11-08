# frozen_string_literal: true

require "monitor"

module Rubotty
  module Core
    # A recent-error ledger, one entry per adapter, read by Runtime#healthy?
    # instead of a bare "is it connected right now" snapshot (#1478). An
    # adapter that has not yet had the chance to fail (a fresh boot, or one
    # that never errored) reads healthy immediately; one that just failed to
    # start or reconnect stays unhealthy only for +window+ seconds, not
    # forever, so a platform health check answers quickly at boot and still
    # means something once the process has been up for a while.
    class AdapterHealth
      DEFAULT_WINDOW = 300

      def initialize(window: DEFAULT_WINDOW, clock: -> { Time.now.utc })
        @window = window
        @clock = clock
        @monitor = Monitor.new
        @errors = {}
      end

      attr_reader :window

      # @param adapter_key [Array] the same [adapter_name, account] tuple
      #   Runtime keys @adapters with.
      def record_error(adapter_key, error)
        @monitor.synchronize { @errors[adapter_key] = [@clock.call, error.message] }
      end

      # A fresh connect or reconnect succeeded; the failure it followed no
      # longer describes the adapter's current state.
      def clear(adapter_key)
        @monitor.synchronize { @errors.delete(adapter_key) }
      end

      # True when this adapter has never errored, or its last error has aged
      # out of the window.
      def healthy?(adapter_key)
        @monitor.synchronize do
          at, = @errors[adapter_key]
          at.nil? || (@clock.call - at) >= @window
        end
      end

      # Every adapter with an error still inside the window, newest detail
      # first, for the admin debug surface.
      def recent_failures
        @monitor.synchronize do
          now = @clock.call
          @errors.filter_map do |adapter_key, (at, message)|
            age = now - at
            next if age >= @window

            { adapter_key: adapter_key, at: at, message: message, seconds_ago: age.round }
          end.sort_by { |failure| failure[:seconds_ago] }
        end
      end
    end
  end
end
