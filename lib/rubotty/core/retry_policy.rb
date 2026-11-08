# frozen_string_literal: true

module Rubotty
  module Core
    # Retries only {AdapterError} with `retryable` set (network faults, 5xx,
    # rate limits); a {PermissionError} is never retried. A platform-given wait
    # (Telegram's `retry_after`, Discord's `X-RateLimit-Reset-After`) is used
    # verbatim instead of the backoff curve. Sleeping here blocks the room's
    # own worker on purpose: moving on and retrying later would reorder its
    # messages, and other rooms are unaffected since each has its own worker.
    class RetryPolicy
      DEFAULT_ATTEMPTS = 3
      DEFAULT_BASE_DELAY = 0.5
      DEFAULT_MAX_DELAY = 30.0

      # A retry_after longer than this is not waited out inline, because holding
      # a room worker for minutes is worse than dropping one message.
      MAX_INLINE_RATE_LIMIT = 60

      def initialize(attempts: DEFAULT_ATTEMPTS, base_delay: DEFAULT_BASE_DELAY,
                     max_delay: DEFAULT_MAX_DELAY, logger: nil, sleeper: nil)
        @attempts = [attempts.to_i, 1].max
        @base_delay = base_delay
        @max_delay = max_delay
        @logger = logger
        @sleeper = sleeper || ->(seconds) { sleep(seconds) }
      end

      attr_reader :attempts

      # Run the block, retrying on retryable adapter errors.
      #
      # @param description [String] used in log lines
      # @return [Object] whatever the block returns
      # @raise [AdapterError] the last error, when every attempt failed
      def call(description = "delivery")
        attempt = 0
        begin
          attempt += 1
          yield
        rescue AdapterError => e
          raise e unless e.retryable?
          raise e if attempt >= @attempts

          delay = delay_for(e, attempt)
          if delay.nil?
            @logger&.warn { "#{description}: rate limited for too long to wait inline, giving up" }
            raise e
          end

          @logger&.warn do
            "#{description} failed (#{e.message}), retry #{attempt} of #{@attempts - 1} in #{delay.round(2)}s"
          end
          @sleeper.call(delay)
          retry
        end
      end

      # @return [Float, nil] nil means "do not wait, give up"
      def delay_for(error, attempt)
        if error.retry_after
          wait = error.retry_after.to_f
          return nil if wait > MAX_INLINE_RATE_LIMIT

          # Platforms report the moment the limit lifts, so a small margin
          # avoids arriving exactly on the boundary and being refused again.
          return wait + 0.25
        end

        exponential(attempt)
      end

      # Exponential with jitter, so several rooms hitting the same platform outage
      # do not retry in lockstep.
      def exponential(attempt)
        base = @base_delay * (2**(attempt - 1))
        capped = [base, @max_delay].min
        capped * (0.5 + (rand * 0.5))
      end
    end
  end
end
