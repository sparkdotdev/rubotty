# frozen_string_literal: true

require "monitor"

module Rubotty
  module Core
    # One background thread that runs deferred actions at or after a
    # scheduled time; a single thread draining a time-ordered list costs one
    # thread no matter how many commands are in flight. An action may itself
    # schedule a follow-up when it runs, relative to the clock at that
    # moment, so a chain honours real elapsed time; a failing action is
    # logged and dropped rather than crashing the scheduler and stranding
    # every other pending action. {#healthy?} answers for the thread itself,
    # and {Runtime#healthy?} folds it into the health endpoint.
    class Scheduler
      DEFAULT_TICK = 1.0

      Job = Struct.new(:run_at, :seq, :action)

      # @param logger [#debug, nil]
      # @param clock [#call] returns the current Time. Injected in tests.
      # @param tick [Float] seconds the background thread sleeps between sweeps
      def initialize(logger: nil, clock: -> { Time.now }, tick: DEFAULT_TICK)
        @logger = logger
        @clock = clock
        @tick = tick
        @jobs = []
        @seq = 0
        @monitor = Monitor.new
        @thread = nil
        @running = false
        @failure = nil
      end

      # Run +action+ after +delay+ seconds, measured from the clock now.
      # A non positive delay runs it on the next sweep.
      def after(delay, &action)
        at(@clock.call + [delay.to_f, 0.0].max, &action)
      end

      # Run +action+ at or after the absolute time +run_at+.
      def at(run_at, &action)
        raise ArgumentError, "a block is required" unless action

        @monitor.synchronize do
          @seq += 1
          @jobs << Job.new(run_at, @seq, action)
          # Kept ordered so a sweep can stop at the first job not yet due.
          @jobs.sort_by! { |job| [job.run_at, job.seq] }
        end
        self
      end

      # Run every action whose time has arrived, oldest first, returning how
      # many ran. Public so a spec can advance a fake clock and drain
      # synchronously.
      def run_due
        due = @monitor.synchronize do
          now = @clock.call
          ready = []
          ready << @jobs.shift while @jobs.first && @jobs.first.run_at <= now
          ready
        end
        # Actions run OUTSIDE the lock: an action may schedule a follow up, and
        # holding the monitor while it did would block #after from other threads.
        due.each { |job| dispatch(job) }
        due.size
      end

      def start
        @monitor.synchronize do
          return self if @running

          @running = true
          @failure = nil
          @thread = Thread.new { supervise }
        end
        self
      end

      # Stop the thread: pending actions are abandoned, which is the right
      # call at shutdown. Safe to call when never started, and safe to call
      # twice.
      def stop
        thread = @monitor.synchronize do
          @running = false
          current = @thread
          @thread = nil
          current
        end
        thread&.kill
        self
      end

      def running? = @monitor.synchronize { @running }

      # How many actions are waiting. Test and diagnostics helper.
      def pending = @monitor.synchronize { @jobs.size }

      # Whether the sweep thread is still there to run what has been scheduled. A
      # scheduler that was never started is healthy; one that was started and
      # whose thread is gone is not.
      def healthy?
        @monitor.synchronize do
          return true unless @running

          !@thread.nil? && @thread.alive?
        end
      end

      # Why the sweep thread died, or nil.
      def failure = @monitor.synchronize { @failure }

      private

      # The sweep thread's body. A failing sweep is logged and the loop goes on;
      # anything that escapes THAT is recorded before the thread unwinds, so
      # {#healthy?} can report the loss.
      def supervise
        Thread.current.name = "command-cleanup"
        loop do
          sleep(@tick)
          begin
            run_due
          rescue StandardError => e
            @logger&.warn { "cleanup sweep failed: #{e.class}: #{e.message}" }
          end
        end
      rescue Exception => e # rubocop:disable Lint/RescueException
        detail = "#{e.class}: #{e.message}"
        @monitor.synchronize { @failure = detail }
        @logger&.error { "the cleanup scheduler thread died, deferred cleanups will not run: #{detail}" }
        nil
      end

      def dispatch(job)
        job.action.call
      rescue StandardError => e
        @logger&.debug { "a scheduled action failed: #{e.class}: #{e.message}" }
      end
    end
  end
end
