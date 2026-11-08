# frozen_string_literal: true

require "monitor"

module Rubotty
  module Core
    # One supervised thread that drops and re-establishes every long-lived
    # gateway connection nightly, bounding how long a stall (still
    # authenticating and heartbeating, but delivering no inbound event) can go
    # undetected. The schedule is absolute UTC from this process's own clock,
    # ignoring container and database timezones, so every deployment cycles at
    # the same instant. Only adapters declaring
    # {Adapters::Base#persistent_connection?} are cycled; a poller resumes on
    # its own and has nothing to gain from being interrupted.
    class GatewayCycle
      # When the cycle runs, "HH:MM" in UTC.
      DEFAULT_AT = "00:00"

      # Longest one wait may be, so a clock jump (a suspended host, an NTP step)
      # is noticed within the hour rather than slept through.
      MAX_WAIT = 3600

      # Shortest one wait may be, so a clock that does not advance spins slowly
      # rather than as fast as the CPU allows.
      MIN_WAIT = 0.5

      TIME_OF_DAY = /\A([01]\d|2[0-3]):([0-5]\d)\z/

      SECONDS_PER_DAY = 86_400

      # @param adapters [Hash{Array=>Adapters::Base}] the runtime's live adapters
      # @param at [String] "HH:MM" in UTC
      # @param logger [#info, #warn, #error, nil]
      # @param clock [#call] returns the current Time, read as UTC
      # @param after_cycle [#call, nil] called once a cycle finishes, with the
      #   adapters that came back up. This is where the backfill sweep is kicked,
      #   which is what recovers whatever the reconnect dropped in flight.
      def initialize(adapters:, at: DEFAULT_AT, logger: nil, clock: -> { Time.now.utc }, after_cycle: nil)
        @adapters = adapters
        @at = parse_at(at)
        @logger = logger
        @clock = clock
        @after_cycle = after_cycle
        @monitor = Monitor.new
        @wake = Thread::Queue.new
        @thread = nil
        @running = false
        @cycling = false
        @cycles = 0
        @last_cycle_day = nil
        @failure = nil
      end

      attr_reader :at

      # Whether +adapter+ holds a connection this class can drop and re-establish.
      # {QuietGatewayWatchdog} asks the same question before it calls an endpoint's
      # silence a stall, so one answer decides both what can be cycled and what can
      # go quiet in a way that means anything.
      def self.persistent?(adapter)
        adapter.respond_to?(:persistent_connection?) && adapter.persistent_connection?
      end

      # The adapters this would cycle, in a stable order.
      def targets
        @adapters.values.select { |adapter| GatewayCycle.persistent?(adapter) }
      end

      # Start the one cycle thread. Idempotent, and a no-op when no adapter holds
      # a persistent connection, so a Telegram-only bridge runs no thread at all.
      def start
        return self if targets.empty?

        @monitor.synchronize do
          return self if @running

          @running = true
          @failure = nil
          @wake.clear
          # A process that boots just after the hour must not cycle straight
          # away: today's slot has passed, so claim it and wait for tomorrow.
          now = utc_now
          @last_cycle_day = day_key(now) if now >= slot_on(now)
          @thread = Thread.new { supervise }
        end
        @logger&.info do
          "gateway cycle: reconnecting #{targets.size} gateway(s) daily at #{@at} UTC, " \
            "next in #{seconds_until_next.round}s"
        end
        self
      end

      # Stop the thread. The wait is woken rather than waited out.
      def stop
        thread = @monitor.synchronize do
          @running = false
          current = @thread
          @thread = nil
          current
        end
        return self if thread.nil?

        @wake << :stop
        thread.join(1)
        thread.kill if thread.alive?
        self
      end

      def running? = @monitor.synchronize { @running }

      # Whether a cycle is in progress. The health endpoint asks, because an
      # adapter that is deliberately down for a moment is not a sick bridge.
      def cycling? = @monitor.synchronize { @cycling }

      # How many cycles have run. Diagnostics and tests.
      def cycles = @monitor.synchronize { @cycles }

      # Whether the thread is still there to run the next cycle. One that was
      # never started is healthy, the terms every other supervised thread here is
      # judged on.
      def healthy?
        @monitor.synchronize do
          return true unless @running

          !@thread.nil? && @thread.alive?
        end
      end

      # Why the cycle thread died, or nil.
      def failure = @monitor.synchronize { @failure }

      # Whether today's slot has arrived and has not been served yet.
      def due?(now = utc_now)
        return false if now < slot_on(now)

        @monitor.synchronize { @last_cycle_day != day_key(now) }
      end

      # Seconds from +now+ until the next slot, at least zero.
      def seconds_until_next(now = utc_now)
        slot = slot_on(now)
        slot += SECONDS_PER_DAY if slot <= now
        [slot - now, 0].max
      end

      # Drop and re-establish every persistent connection, one at a time. Public
      # so a spec can run it synchronously, and never raises: an adapter that
      # fails to come back is logged and left to its own reconnect logic.
      def cycle(reason: "nightly")
        due = targets
        mark_served
        return [] if due.empty?

        perform(due, reason: reason, count: true)
      end

      # Drops and re-establishes just +adapters+, out of band from the
      # nightly slot: what {QuietGatewayWatchdog} calls after sibling
      # comparison proves ONE adapter has stalled, so only that one is
      # touched. Anything not in {#targets} is ignored rather than
      # force-cycled, and {#cycling?} is true for the duration, so a
      # deliberate drop here reads no differently than a scheduled one
      # while it is in flight.
      def reconnect(adapters, reason:)
        due = targets & Array(adapters)
        return [] if due.empty?

        perform(due, reason: reason, count: false)
      end

      private

      # Shared by {#cycle} and {#reconnect}: announce, drop and re-establish
      # +due+, report what came back, then kick the backfill sweep. +count+
      # is false for an out-of-band reconnect, so {#cycles} keeps meaning
      # "how many NIGHTLY cycles have run" rather than counting every ad hoc
      # reconnect too.
      def perform(due, reason:, count:)
        announce(due, reason)
        @monitor.synchronize { @cycling = true }
        recovered = due.select { |adapter| recycle(adapter) }
        @monitor.synchronize do
          @cycling = false
          @cycles += 1 if count
        end
        report(due, recovered)
        run_after_cycle(recovered)
        recovered
      ensure
        @monitor.synchronize { @cycling = false }
      end

      def utc_now = @clock.call.utc

      def day_key(time) = time.strftime("%Y-%m-%d")

      # Today's slot as an absolute UTC instant.
      def slot_on(now)
        hour, minute = @at.split(":").map(&:to_i)
        Time.utc(now.year, now.month, now.day, hour, minute)
      end

      def mark_served
        @monitor.synchronize { @last_cycle_day = day_key(utc_now) }
      end

      def parse_at(value)
        text = value.to_s.strip
        return text if text.match?(TIME_OF_DAY)

        raise ArgumentError, "the gateway cycle time must be HH:MM in UTC, got #{value.inspect}"
      end

      # Says what is about to happen and why the backfill lines that follow it are
      # there, so a nightly gap and its resync read as one deliberate event.
      def announce(due, reason)
        @logger&.info do
          "gateway cycle (#{reason}): dropping #{due.size} gateway connection(s). " \
            "Anything in flight across the reconnect is recovered by the backfill sweep that follows."
        end
      end

      # Stop then start one adapter. Truthy when it is receiving again.
      def recycle(adapter)
        name = "#{adapter.adapter_name}/#{adapter.account}"
        begin
          adapter.stop
        rescue StandardError => e
          @logger&.warn { "gateway cycle: #{name} did not stop cleanly: #{e.class}: #{e.message}" }
        end
        adapter.start
        true
      rescue StandardError => e
        @logger&.error do
          "gateway cycle: #{name} did not come back up: #{e.class}: #{e.message}. " \
            "That platform receives nothing until it reconnects or this process restarts."
        end
        false
      end

      def report(due, recovered)
        lost = due.size - recovered.size
        @logger&.info do
          note = lost.positive? ? ", #{lost} still down" : ""
          "gateway cycle: #{recovered.size} of #{due.size} gateway(s) reconnected#{note}"
        end
      end

      def run_after_cycle(recovered)
        return if @after_cycle.nil? || recovered.empty?

        @after_cycle.call(recovered)
      rescue StandardError => e
        @logger&.warn { "gateway cycle: the post-reconnect sweep failed: #{e.class}: #{e.message}" }
      end

      # The thread body. Waits in bounded hops so a suspended host or a stepped
      # clock cannot sleep through the slot, and records what no rescue inside
      # {#cycle} can catch so {#healthy?} reports the loss.
      def supervise
        Thread.current.name = "gateway-cycle"
        loop do
          # Asked before the wait as well as after it, so a slot that arrived
          # while the length of the next wait was being worked out is still
          # served rather than missed by an hour.
          cycle if due?
          signal = @wake.pop(timeout: next_wait)
          break if signal == :stop
          break unless running?
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        detail = "#{e.class}: #{e.message}"
        @monitor.synchronize { @failure = detail }
        @logger&.error do
          "the gateway cycle thread died, gateways will NOT be reconnected nightly " \
            "until this process restarts: #{detail}"
        end
        nil
      end

      def next_wait = seconds_until_next.clamp(MIN_WAIT, MAX_WAIT)
    end
  end
end
