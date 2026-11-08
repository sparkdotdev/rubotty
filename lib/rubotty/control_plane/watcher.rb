# frozen_string_literal: true

require "monitor"

module Rubotty
  module ControlPlane
    # THE control-plane watcher: one supervised thread per process that polls
    # the shared database and tells every subscriber what changed, since the
    # bot, dashboard and guest portal are separate processes over one
    # database. A subscriber failure is caught and isolated, recorded in
    # {#failure} and reported by {#healthy?}, so one bad subscriber does not
    # take down the rest and a dead watcher becomes a 503. The wait is a
    # queue pop with a timeout, not a bare sleep, so {#stop} and
    # {#reload_now} wake it immediately.
    class Watcher
      # Poll cadence. One tick is a handful of indexed aggregates against tiny
      # control-plane tables, so a dashboard edit applies within one interval.
      DEFAULT_INTERVAL = 20

      # The advisory lock name every process's watcher contends for: only one of
      # them should ever be mid-tick, i.e. mid-announce, at a time. One name for
      # every subscriber, so they cannot double-process independently.
      LOCK_NAME = "rubotty:control_plane:watcher:tick"

      # How long a tick waits for the lock before skipping this pass. Short: this
      # fires every {DEFAULT_INTERVAL}, so a loser should let its own next tick
      # cover it rather than block the loop.
      LOCK_TIMEOUT = 2

      Subscription = Struct.new(:name, :source)
      private_constant :Subscription

      # @param logger [#info, #warn, #error, nil]
      # @param interval [Numeric] seconds between ticks
      # @param storage [#with_advisory_lock, nil] guards each tick so that, when
      #   more than one process shares this store, only one of them ever applies
      #   a given control-plane change. Nil runs every tick unlocked.
      def initialize(logger: nil, interval: DEFAULT_INTERVAL, storage: nil)
        @logger = logger
        @interval = interval
        @storage = storage
        @subscriptions = []
        @monitor = Monitor.new
        # The wake channel. Pushing anything onto it interrupts the wait, which
        # is what makes both #stop and #reload_now immediate.
        @wake = Thread::Queue.new
        @thread = nil
        @running = false
        @failure = nil
        @ticks = 0
      end

      attr_reader :interval

      # Register something to be checked on every tick; a source is anything
      # answering #check. Registration is idempotent per name, so a second
      # call replaces rather than doubling the work.
      #
      # @param name [String, Symbol] for the log line and diagnostics
      # @param source [#check]
      def subscribe(name, source)
        return self if source.nil?

        @monitor.synchronize do
          @subscriptions.reject! { |entry| entry.name == name.to_s }
          @subscriptions << Subscription.new(name.to_s, source)
        end
        self
      end

      # The registered watcher names, in tick order. Diagnostics and tests.
      def subscribers = @monitor.synchronize { @subscriptions.map(&:name) }

      # Run every subscriber once, in registration order, each isolated from the
      # others; returns { name => result }, with the result of a subscriber
      # that raised recorded as nil. Public so {#reload_now} and the loop
      # share ONE body.
      def tick
        entries = @monitor.synchronize { @subscriptions.dup }
        with_lock { run_entries(entries) }
      rescue LockUnavailable
        # Another process is already mid-tick against the SAME store. Its tick
        # covers whatever this one would have applied.
        @logger&.debug { "control-plane watcher: tick skipped, another instance already has the lock" }
        {}
      end

      # Check RIGHT NOW rather than waiting for the next tick, running it on the
      # CALLING thread, then waking the loop so its next wait restarts from now.
      # Safe from any thread, and safe before {#start} or after {#stop}.
      #
      # @param reason [String] recorded in the log, so an out-of-band reload is
      #   distinguishable from a polled one
      # @return [Hash] the same shape {#tick} returns
      def reload_now(reason: "requested")
        @logger&.info { "control-plane watcher: out-of-band check (#{reason})" }
        results = tick
        @wake << :reloaded
        results
      end

      # Start the single watcher thread. Idempotent: a second call is a no-op.
      def start
        @monitor.synchronize do
          return self if @running

          @running = true
          @failure = nil
          # Discard wakes left over from a {#reload_now} made before the loop
          # existed, so the first wait is a full interval rather than a burst.
          @wake.clear
          @thread = Thread.new { supervise }
        end
        @logger&.info do
          "control-plane watcher: watching #{subscribers.join(", ")} every #{@interval}s"
        end
        self
      end

      # Stop the thread; the wait is woken rather than waited out, so shutdown
      # is prompt. Safe when never started and safe to call twice.
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

      # How many ticks have run. Diagnostics and tests.
      def ticks = @monitor.synchronize { @ticks }

      # Whether the watcher is still able to notice a control-plane change: one
      # that was never started is healthy, since a backend with no control
      # plane runs no watcher. One that WAS started and whose thread is gone
      # is not.
      def healthy?
        @monitor.synchronize do
          return true unless @running

          !@thread.nil? && @thread.alive?
        end
      end

      # Why the watcher thread died, or nil.
      def failure = @monitor.synchronize { @failure }

      private

      # Runs every subscriber once, in registration order, each isolated from the
      # others; {#tick} calls this from inside the lock.
      def run_entries(entries)
        results = {}
        entries.each do |entry|
          results[entry.name] = entry.source.check
        rescue StandardError => e
          results[entry.name] = nil
          @logger&.warn { "control-plane watcher: #{entry.name} check failed: #{e.class}: #{e.message}" }
        end
        @monitor.synchronize { @ticks += 1 }
        results
      end

      # Runs +block+ under the tick lock when storage supports one, or straight
      # through without it for a watcher built with no storage.
      def with_lock(&block)
        return yield unless @storage.respond_to?(:with_advisory_lock)

        @storage.with_advisory_lock(LOCK_NAME, timeout: LOCK_TIMEOUT, &block)
      end

      # The thread body. Every subscriber failure is already contained inside
      # {#tick}; this catches what no rescue there can (an Exception rather than a
      # StandardError) and records it, so the loss is reported.
      def supervise
        Thread.current.name = "control-plane-watcher"
        loop do
          signal = @wake.pop(timeout: @interval)
          break if signal == :stop
          break unless running?
          # Woken by an out-of-band {#reload_now}, which already ran the tick on
          # its caller's thread. Restart the wait rather than checking twice.
          next if signal == :reloaded

          tick
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        detail = "#{e.class}: #{e.message}"
        @monitor.synchronize { @failure = detail }
        @logger&.error do
          "the control-plane watcher thread died, live config changes will NOT be picked up " \
            "until this process restarts: #{detail}"
        end
        nil
      end
    end
  end
end
