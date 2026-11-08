# frozen_string_literal: true

module Rubotty
  module Core
    # The one place a receiving endpoint's last inbound moment is kept. An
    # adapter's #running? says the socket is open, not that anything has
    # arrived on it; this fills that gap. {Dispatcher#call} touches it on
    # every message that reaches core, whether or not it gets routed;
    # {QuietGatewayWatchdog} is the reader.
    class InboundActivity
      # How many deliveries an endpoint has to have made before the average gap
      # between them is worth calling its cadence. Two moments describe a single
      # gap, which any lull can produce; three describe a rhythm.
      MIN_CADENCE_SAMPLES = 3

      def initialize(clock: -> { Time.now.utc })
        @clock = clock
        @seen = {}
        @first = {}
        @counts = Hash.new(0)
        @mutex = Mutex.new
      end

      # Record that +endpoint_id+ delivered a message right now.
      def touch(endpoint_id)
        key = endpoint_id.to_s
        at = @clock.call
        @mutex.synchronize do
          @first[key] ||= at
          @counts[key] += 1
          @seen[key] = at
        end
      end

      # When +endpoint_id+ last delivered a message, or nil if it never has.
      def last_seen(endpoint_id) = @mutex.synchronize { @seen[endpoint_id.to_s] }

      # How many messages +endpoint_id+ has delivered since this process came up.
      def deliveries(endpoint_id) = @mutex.synchronize { @counts[endpoint_id.to_s] }

      # The average seconds between +endpoint_id+'s deliveries, or nil while too
      # few have arrived to call anything typical of it. What {QuietGatewayWatchdog}
      # measures a silence against, so an endpoint that has always been slow is
      # judged on its own rhythm.
      def typical_gap(endpoint_id)
        key = endpoint_id.to_s
        @mutex.synchronize do
          count = @counts[key]
          next nil if count < MIN_CADENCE_SAMPLES

          span = @seen[key] - @first[key]
          next nil unless span.positive?

          span / (count - 1)
        end
      end
    end
  end
end
