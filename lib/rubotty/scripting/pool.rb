# frozen_string_literal: true

module Rubotty
  module Scripting
    # A fixed set of Lua children, checked out one invocation at a time: since
    # only one invocation is ever in flight on a child's pipe, the protocol can
    # skip correlation ids. The pool is shared by the whole deployment, so a
    # slow script in one room occupies a slot every other room draws from too;
    # size comes from RUBOTTY_SCRIPT_POOL_SIZE.
    class Pool
      DEFAULT_SIZE = 4

      # These are idle almost all the time, waiting on a pipe, so the ceiling is
      # about memory and stray processes rather than parallelism.
      MAX_SIZE = 16

      # How many children to run, from the environment when it says.
      def self.configured_size(env = ENV)
        wanted = Integer(env["RUBOTTY_SCRIPT_POOL_SIZE"], exception: false)
        return DEFAULT_SIZE if wanted.nil?

        wanted.clamp(1, MAX_SIZE)
      end

      # How long to wait for a free child before giving up: the message a queued
      # script was going to act on is stale by then anyway.
      DEFAULT_CHECKOUT_TIMEOUT = 2

      def initialize(size: DEFAULT_SIZE, logger: nil, checkout_timeout: DEFAULT_CHECKOUT_TIMEOUT, **child_options)
        @logger = logger
        @checkout_timeout = checkout_timeout
        @children = Array.new(size) { Child.new(logger: logger, **child_options) }
        @free = @children.dup
        @mutex = Mutex.new
        @available = ConditionVariable.new
      end

      def size = @children.size

      def available? = @children.first&.available? || false

      # Run one invocation on a free child; arguments are {Child#run}'s. A
      # child that timed out has already been killed and respawns on its next
      # use, so it goes back in the pool either way: keeping it out would
      # shrink the pool permanently every time somebody wrote a slow script.
      def run(**options)
        child = checkout
        begin
          warm(child)
          child.run(**options)
        ensure
          checkin(child)
        end
      end

      # Closes every child only once it is back in the pool rather than while an
      # invocation still has it checked out: nothing here guards a child's own
      # pid, stdin and stdout, so closing one out from under a request thread
      # mid-read would SIGKILL its process and yank its pipes closed while that
      # thread was still blocked reading from them.
      def close
        @children.size.times.map { checkout_for_close }.each(&:close)
        nil
      end

      private

      def checkout
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @checkout_timeout
        @mutex.synchronize do
          while @free.empty?
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            raise Unavailable, "every Lua child is busy" if remaining <= 0

            @available.wait(@mutex, remaining)
          end
          @free.pop
        end
      end

      # {#checkout}, without the timeout: closing has nowhere else to send a
      # script that would have raised Unavailable, so it waits as long as it
      # takes for the last outstanding invocation to check its child back in.
      def checkout_for_close
        @mutex.synchronize do
          @available.wait(@mutex) while @free.empty?
          @free.pop
        end
      end

      def checkin(child)
        @mutex.synchronize do
          @free.push(child)
          @available.signal
        end
      end

      # A cold child's fork, exec and interpreter boot, billed to its own timeout rather than the caller's.
      def warm(child)
        return if child.running?

        child.run(source: "return true", timeout: Child::DEFAULT_TIMEOUT)
      end
    end
  end
end
