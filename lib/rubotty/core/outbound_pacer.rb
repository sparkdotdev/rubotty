# frozen_string_literal: true

module Rubotty
  module Core
    # Paces outbound sends so a platform's rate limit is respected before it is
    # hit rather than only after. {RetryPolicy} already reads a 429 and waits
    # the stated retry_after, but by then the request has been refused and the
    # room worker is blocked. One virtual clock per key: each claim reserves the
    # next slot and answers how long to wait for it, so concurrent callers queue
    # rather than all waking onto the same free moment. A burst allowance lets a
    # quiet key send several at once, which every platform's own limiter allows.
    class OutboundPacer
      # What a key is paced at when a caller names no limit. Unpaced: a platform
      # that never declared a limit is not one to invent numbers for.
      NO_LIMIT = nil

      # Keys tracked before the coldest is dropped. A key is one destination or
      # one account, so this is generous; the cap only stops a deployment with
      # thousands of rooms holding a slot for every one forever.
      MAX_KEYS = 10_000

      # @param clock [#call] monotonic seconds, injectable for tests
      # @param sleeper [#call, nil] receives the seconds to wait
      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: nil, logger: nil)
        @clock = clock
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
        @logger = logger
        @next_free = {}
        @mutex = Mutex.new
      end

      # Wait out this key's pace, then run the block. Every caller of a paced
      # destination goes through here, so the wait is shared rather than each
      # caller keeping its own idea of the rate.
      def pace(key, rate:, burst: 1)
        wait = claim(key, rate: rate, burst: burst)
        if wait.positive?
          @logger&.debug { "pacing #{key} for #{wait.round(3)}s to stay under #{rate}/s" }
          @sleeper.call(wait)
        end
        yield
      end

      # Reserve this key's next slot and answer how long until it opens. Zero
      # when the key is idle enough to send now. A nil or non-positive rate is
      # unpaced and always answers zero, so a platform declaring no limit costs
      # nothing.
      #
      # @return [Float] seconds to wait
      def claim(key, rate:, burst: 1)
        return 0.0 if rate.nil? || rate.to_f <= 0

        interval = 1.0 / rate.to_f
        allowance = [burst.to_i, 1].max
        @mutex.synchronize do
          now = @clock.call
          # The slot this send takes, on a clock that runs ahead of real time
          # while callers are queueing and is pulled back to now once they stop.
          # Reserved rather than merely read, so two threads claiming at once
          # take different slots.
          start = [@next_free.fetch(key, now), now].max
          @next_free[key] = start + interval
          evict_coldest
          # The allowance is how far ahead of now that clock may run before
          # anybody actually waits, which is what lets a quiet key send several
          # at once the way every platform's own limiter allows.
          wait = start - now - ((allowance - 1) * interval)
          wait.negative? ? 0.0 : wait
        end
      end

      # How many keys are being paced. Diagnostics, and what the cap is read by.
      def tracked = @mutex.synchronize { @next_free.size }

      private

      # Ruby hashes keep insertion order, so the oldest inserted key is the
      # first one. Called with the mutex already held.
      def evict_coldest
        @next_free.shift while @next_free.size > MAX_KEYS
      end
    end
  end
end
