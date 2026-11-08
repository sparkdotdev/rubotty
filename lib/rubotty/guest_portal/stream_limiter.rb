# frozen_string_literal: true

module Rubotty
  module GuestPortal
    # How many SSE streams one invite may hold open at once, in-process
    # (unlike {RateLimiter}, which counts durable rows): this protects only
    # this process's threads and its share of the Sequel pool, so a
    # cross-instance count would answer a question nobody asked. A refused
    # guest still has the polling endpoint the client already falls back to.
    class StreamLimiter
      def initialize(max:)
        @max = max.to_i
        @open = Hash.new(0)
        @mutex = Mutex.new
      end

      attr_reader :max

      # Run the block holding one slot for +key+, or return nil having run
      # nothing when the invite already holds its share.
      def hold(key)
        return nil unless claim(key)

        begin
          yield
        ensure
          release(key)
        end
      end

      # Open streams for +key+. Diagnostics and tests.
      def open_for(key) = @mutex.synchronize { @open[key.to_s] }

      private

      def claim(key)
        @mutex.synchronize do
          key = key.to_s
          return false if @open[key] >= @max

          @open[key] += 1
          true
        end
      end

      def release(key)
        @mutex.synchronize do
          key = key.to_s
          @open[key] -= 1
          @open.delete(key) if @open[key] <= 0
        end
      end
    end
  end
end
