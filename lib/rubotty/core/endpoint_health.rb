# frozen_string_literal: true

require "time"

module Rubotty
  module Core
    # How delivery to each destination is actually going, for the process
    # serving it. {RelayOutcomes} records only what a backfill sweep asked it
    # to watch, so live traffic wrote nothing anywhere and a platform that had
    # stopped accepting posts was invisible: the bot went on reporting itself
    # healthy while every message to that endpoint spent its whole retry
    # budget. Written from {Features::Bridge#deliver_one}, which sees both a
    # receipt and a spent AdapterError in one method.
    class EndpointHealth
      # Destinations tracked before the coldest is dropped. A deployment
      # bridges tens of endpoints, not thousands, and the bound is here so a
      # churn of one-off ids cannot grow this without limit.
      MAX_ENDPOINTS = 500

      # Upper edges in seconds, the shape {ControlPlane::ModelCallStats} reads
      # latency in, so the two read alike on a page showing both.
      BUCKETS = [0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 15.0].freeze

      # One destination's standing. +failures+ is the CONSECUTIVE run, reset by
      # the next receipt, which is the number a circuit breaker wants; +sent+
      # and +failed+ are the totals this process has seen.
      Entry = Struct.new(:sent, :failed, :failures, :last_sent_at, :last_failed_at,
                         :last_error, :latency, keyword_init: true)

      # Timing is the caller's: {Features::Bridge#deliver_one} measures the
      # whole retried delivery and passes the seconds in, so there is no
      # second clock in here to disagree with it.
      def initialize(clock: -> { Time.now })
        @clock = clock
        @mutex = Mutex.new
        @entries = {}
      end

      # A copy that landed. Clears the consecutive-failure run: one receipt is
      # what "reachable again" looks like from here.
      def delivered(endpoint_id, seconds: nil)
        touch(endpoint_id) do |entry|
          entry.sent += 1
          entry.failures = 0
          entry.last_sent_at = @clock.call
          bucket!(entry, seconds)
        end
      end

      # A copy that spent every attempt it had. The error's CLASS and message
      # are kept, not the exception: a timeout and a refusal want telling
      # apart, and holding the object would pin its backtrace here.
      def failed(endpoint_id, error: nil, seconds: nil)
        touch(endpoint_id) do |entry|
          entry.failed += 1
          entry.failures += 1
          entry.last_failed_at = @clock.call
          entry.last_error = describe(error)
          bucket!(entry, seconds)
        end
      end

      # The consecutive run against one destination, which is what says
      # "stop trying" rather than "one send went wrong".
      def failures(endpoint_id)
        @mutex.synchronize { @entries[endpoint_id.to_s]&.failures.to_i }
      end

      # Every destination this process has delivered to, worst first, so the
      # one worth looking at is the one at the top.
      def report
        rows = @mutex.synchronize { @entries.transform_values(&:dup) }
        ordered = rows.sort_by { |id, entry| [-entry.failures, -entry.failed, id] }
        ordered.map { |id, entry| serialize(id, entry) }
      end

      private

      def touch(endpoint_id)
        id = endpoint_id.to_s
        return if id.empty?

        @mutex.synchronize do
          entry = (@entries[id] ||= blank)
          yield entry
          # Re-insert so insertion order is recency, which is what the bound
          # below drops by.
          @entries[id] = @entries.delete(id)
          @entries.shift while @entries.size > MAX_ENDPOINTS
        end
        nil
      end

      def blank
        Entry.new(sent: 0, failed: 0, failures: 0, last_sent_at: nil, last_failed_at: nil,
                  last_error: nil, latency: {})
      end

      def bucket!(entry, seconds)
        return if seconds.nil?

        key = BUCKETS.find { |edge| seconds.to_f <= edge } || :over
        entry.latency[key] = (entry.latency[key] || 0) + 1
      end

      def describe(error)
        return nil if error.nil?
        return error.to_s if error.is_a?(String)

        "#{error.class}: #{error.message}"
      end

      def serialize(id, entry)
        {
          "endpoint_id" => id, "sent" => entry.sent, "failed" => entry.failed,
          "consecutive_failures" => entry.failures,
          "last_sent_at" => entry.last_sent_at&.utc&.iso8601,
          "last_failed_at" => entry.last_failed_at&.utc&.iso8601,
          "last_error" => entry.last_error,
          "latency" => latency_rows(entry.latency)
        }.compact
      end

      # Named edges rather than raw numbers, so a reader does not have to know
      # what the bucket keys meant.
      def latency_rows(latency)
        return nil if latency.empty?

        BUCKETS.each_with_index.filter_map do |edge, index|
          count = latency[edge]
          next if count.nil?

          { "label" => bucket_label(edge, index), "count" => count }
        end + over_row(latency)
      end

      def over_row(latency)
        count = latency[:over]
        count.nil? ? [] : [{ "label" => "over #{trim(BUCKETS.last)}s", "count" => count }]
      end

      def bucket_label(edge, index)
        return "under #{trim(edge)}s" if index.zero?

        "#{trim(BUCKETS[index - 1])}s to #{trim(edge)}s"
      end

      def trim(value)
        value == value.to_i ? value.to_i.to_s : value.to_s
      end
    end
  end
end
