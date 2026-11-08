# frozen_string_literal: true

require "date"

module Rubotty
  module ControlPlane
    # What one community's model-backed features cost, counted as they run.
    # Measurements only: how long a call took, whether it failed, how much of
    # its token budget it used. No prompt, no answer and no message text ever
    # reaches this table, which is what lets a pending check's own text stay
    # transient. Shaped after {ScriptStats}: counts are coalesced in memory,
    # written on a threshold, reported per community and aged out by a daily
    # prune.
    class ModelCallStats
      RETENTION = 90 * 24 * 60 * 60

      # The durable job kind that ages them out, run once a day.
      PRUNE_KIND = "model_call_stats_prune"

      PRUNE_INTERVAL = 24 * 60 * 60

      # Every feature that reaches the model, and the name a reader sees. A
      # call attributed to anything else is dropped rather than recorded under
      # a name no page can explain.
      FEATURES = {
        "content_policy" => "Content policy",
        "room_summaries" => "Room summaries",
        "semantic_analysis" => "FAQ matching",
        "topic_routing" => "Topic routing"
      }.freeze

      # The durable job kind each one queues under, so a live queue depth can
      # be read for the same four names. Two of them differ from the feature's
      # own name, which is why this is written down rather than derived.
      KINDS = {
        "content_policy" => "content_policy",
        "room_summaries" => "room_summary",
        "semantic_analysis" => "semantic_faq",
        "topic_routing" => "topic_routing"
      }.freeze

      # The feature a durable job kind belongs to, or nil for a kind that never
      # reaches the model.
      def self.feature_for_kind(kind) = KINDS.key(kind.to_s)

      # Attempts, and the three ways one goes wrong. calls counts every
      # attempt, so successes are calls minus failures, and retries are the
      # subset that were a second attempt at the same question.
      CALLS = "calls"
      FAILURES = "failures"
      RETRIES = "retries"
      TRUNCATED = "truncated"

      # Jobs the scheduler dropped for being past their kind's max_age. Not a
      # call at all, which is exactly why nothing else would show it.
      DISCARDED = "discarded"

      # An answer that came back but could not be read as a decision: the
      # call itself succeeded, so this is kept apart from a failure. Without
      # it, a feature finding nothing and a feature unable to read its own
      # answers look identical.
      UNUSABLE = "unusable"

      BUDGET_TOKENS = "budget_tokens"
      USED_TOKENS = "used_tokens"

      LATENCY = "latency"

      # Upper bounds in milliseconds. A histogram rather than raw samples: a
      # percentile lands on a bound instead of an exact value, and in exchange
      # ninety days of calls stay a fixed handful of rows per day.
      LATENCY_BUCKETS = [250, 500, 1000, 2000, 4000, 8000, 15_000, 30_000, 60_000, 120_000].freeze

      # Anything slower than the last bound, including a read timeout.
      OVERFLOW = "over"

      COUNTERS = [CALLS, FAILURES, RETRIES, TRUNCATED, DISCARDED, UNUSABLE].freeze

      # Counted in individual counts rather than calls, and one call raises
      # about five of them, so this sits well above {ScriptStats}' own
      # threshold to reach a comparable cadence of writes.
      FLUSH_AFTER = 100

      # And a ceiling in time, so a quiet deployment's numbers still land.
      FLUSH_AFTER_SECONDS = 30

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
        @pending = Hash.new(0)
        @pending_count = 0
        @pending_since = nil
        @lock = Mutex.new
      end

      # One completion attempt's own numbers. +community_id+ is required: a
      # call that cannot name its tenant is not recorded at all.
      #
      # @param seconds [Numeric] wall time the caller waited, failures included
      # @param failed [Boolean] the attempt raised rather than answering
      # @param retried [Boolean] a second ask at the same question
      # @param used_tokens [Integer, nil] what the server said it generated
      # @param truncated [Boolean] the answer stopped on the budget
      def record(community_id:, feature:, seconds:, failed: false, retried: false,
                 budget_tokens: 0, used_tokens: nil, truncated: false)
        name = feature_key(feature)
        id = Integer(community_id, exception: false)
        return false if name.nil? || id.nil?

        day = today
        count(id, name, CALLS, "", day)
        count(id, name, LATENCY, bucket_for(seconds), day)
        count(id, name, RETRIES, "", day) if retried
        record_outcome(id, name, day, failed, budget_tokens, used_tokens, truncated)
        true
      end

      # A durable job dropped for being past its kind's max_age, which settles
      # as a success and would otherwise leave no trace anywhere.
      def discarded(community_id:, feature:, step: 1)
        name = feature_key(feature)
        id = Integer(community_id, exception: false)
        return false if name.nil? || id.nil?

        count(id, name, DISCARDED, "", today, step)
        true
      end

      # An answer a feature could not turn into a decision, called instead of
      # #record so a call that already succeeded is not counted twice.
      def unusable(community_id:, feature:, step: 1)
        name = feature_key(feature)
        id = Integer(community_id, exception: false)
        return false if name.nil? || id.nil?

        count(id, name, UNUSABLE, "", today, step)
        true
      end

      # Write out if the time ceiling has passed. Called on a timer, since
      # nothing else makes a bound in time mean anything on a quiet deployment.
      def flush_if_due(now: @clock.call)
        due = @lock.synchronize do
          !@pending_since.nil? && (now - @pending_since) >= FLUSH_AFTER_SECONDS
        end
        due ? flush : 0
      end

      # Write out whatever has been counted since the last flush, and answer
      # how many rows really landed.
      def flush
        batch = @lock.synchronize do
          held = @pending
          @pending = Hash.new(0)
          @pending_count = 0
          @pending_since = nil
          held
        end
        return 0 if batch.empty?

        batch.count { |key, amount| apply(key, amount) }
      end

      # One community's figures over the window ending now, as
      # { available:, features: [...], totals: {...} }. Whole days, since that
      # is the granularity the rows are kept at.
      def report(community:, since: nil)
        flush
        rows = live(community, since)
        return { available: true, features: [], totals: empty_totals } if rows.empty?

        features = FEATURES.keys.filter_map { |name| feature_report(name, rows[name]) }
        { available: true, features: features, totals: totals_of(features) }
      rescue StandardError => e
        @logger&.warn { "model call stats: could not report: #{e.class}: #{e.message}" }
        { available: false }
      end

      # Drop everything past the retention, anywhere. Run daily.
      def prune(now: @clock.call)
        flush
        cutoff = (now.utc.to_date - (RETENTION / 86_400))
        @models.model_call_stat.where { counted_on < cutoff }.delete
      end

      # The bucket a call of +seconds+ belongs in, as its row's bucket value.
      def self.bucket_for(seconds)
        milliseconds = (seconds.to_f * 1000).round
        bound = LATENCY_BUCKETS.find { |limit| milliseconds <= limit }
        bound ? bound.to_s : OVERFLOW
      end

      # The reader-facing name of one latency bucket.
      def self.bucket_label(key)
        return "over #{duration_label(LATENCY_BUCKETS.last)}" if key.to_s == OVERFLOW

        bound = key.to_i
        index = LATENCY_BUCKETS.index(bound)
        return key.to_s if index.nil?
        return "under #{duration_label(bound)}" if index.zero?

        "#{duration_label(LATENCY_BUCKETS[index - 1])} to #{duration_label(bound)}"
      end

      # The +fraction+ percentile over a { bucket => count } histogram, as the
      # label of the bucket it lands in. Nil when nothing was recorded.
      def self.percentile(counts, fraction)
        total = counts.values.sum(&:to_i)
        return nil if total.zero?

        target = (total * fraction).ceil
        seen = 0
        LATENCY_BUCKETS.each do |bound|
          seen += counts[bound.to_s].to_i
          return duration_label(bound) if seen >= target
        end
        "over #{duration_label(LATENCY_BUCKETS.last)}"
      end

      # Milliseconds as something short enough for a stat tile.
      def self.duration_label(milliseconds)
        return scaled(milliseconds, 3_600_000, "h") if milliseconds >= 3_600_000
        return scaled(milliseconds, 60_000, "m") if milliseconds >= 60_000
        return "#{milliseconds / 1000}s" if milliseconds >= 1000 && (milliseconds % 1000).zero?

        "#{(milliseconds / 1000.0).round(milliseconds < 1000 ? 2 : 1)}s"
      end

      # A whole number of units where it is one, a single decimal where it is
      # not, so a minute and a half does not read as two minutes.
      def self.scaled(milliseconds, unit, suffix)
        value = milliseconds / unit.to_f
        (value % 1).zero? ? "#{value.round}#{suffix}" : "#{value.round(1)}#{suffix}"
      end
      private_class_method :scaled

      private

      def bucket_for(seconds) = self.class.bucket_for(seconds)

      def today = @clock.call.utc.to_date

      def feature_key(feature)
        name = feature.to_s
        return name if FEATURES.key?(name)

        @logger&.debug { "model call stats: dropped a call attributed to #{name.inspect}" }
        nil
      end

      # Everything a finished attempt says beyond that it happened.
      def record_outcome(id, name, day, failed, budget_tokens, used_tokens, truncated)
        return count(id, name, FAILURES, "", day) if failed

        count(id, name, BUDGET_TOKENS, "", day, budget_tokens.to_i) if budget_tokens.to_i.positive?
        count(id, name, USED_TOKENS, "", day, used_tokens.to_i) if used_tokens.to_i.positive?
        count(id, name, TRUNCATED, "", day) if truncated
      end

      # Held in memory until a threshold, keyed by everything that identifies a
      # row, so a busy room hammering one bucket is still one write.
      def count(community_id, feature, metric, bucket, day, amount = 1)
        due = @lock.synchronize do
          @pending[[community_id, feature, metric, bucket, day]] += amount
          @pending_count += 1
          @pending_since ||= @clock.call
          @pending_count >= FLUSH_AFTER || (@clock.call - @pending_since) >= FLUSH_AFTER_SECONDS
        end
        flush if due
      end

      # One coalesced count, added in the database rather than read, added in
      # Ruby and written back: two threads inside flush with the same key would
      # each read the same total and write it, losing one count.
      def apply(key, amount)
        community_id, feature, metric, bucket, day = key
        now = @clock.call
        row = @models.model_call_stat.where(community_id: community_id, feature: feature,
                                            metric: metric, bucket: bucket, counted_on: day)
        return true if row.update(value: Sequel[:value] + amount, updated_at: now).positive?

        create_or_add(row, key, amount, now)
      rescue StandardError => e
        @logger&.warn { "model call stats: could not write #{key[2]}: #{e.class}: #{e.message}" }
        false
      end

      # A row this thread has just decided is missing, which another may be
      # creating at the same moment. Losing that race means the row exists now,
      # so the count is added to it rather than dropped.
      def create_or_add(row, key, amount, now)
        community_id, feature, metric, bucket, day = key
        @models.model_call_stat.create(community_id: community_id, feature: feature, metric: metric,
                                       bucket: bucket, counted_on: day, value: amount,
                                       created_at: now, updated_at: now)
        true
      rescue Sequel::UniqueConstraintViolation
        row.update(value: Sequel[:value] + amount, updated_at: now).positive?
      end

      # This community's rows over the window, as feature => metric => bucket
      # => value. Scoped by community id in the query itself, never filtered
      # afterwards.
      def live(community, since)
        scope = @models.model_call_stat.where(community_id: community.id)
        scope = scope.where { counted_on >= since.utc.to_date } if since
        scope.all.each_with_object({}) do |row, tree|
          by_metric = (tree[row.feature.to_s] ||= {})
          buckets = (by_metric[row.metric.to_s] ||= Hash.new(0))
          buckets[row.bucket.to_s] += row.value.to_i
        end
      end

      def feature_report(name, metrics)
        return nil if metrics.nil? || metrics.empty?

        latency = metrics[LATENCY] || {}
        {
          key: name, label: FEATURES.fetch(name),
          calls: scalar(metrics, CALLS), failures: scalar(metrics, FAILURES),
          retries: scalar(metrics, RETRIES), truncated: scalar(metrics, TRUNCATED),
          discarded: scalar(metrics, DISCARDED), unusable: scalar(metrics, UNUSABLE),
          budget_tokens: scalar(metrics, BUDGET_TOKENS), used_tokens: scalar(metrics, USED_TOKENS),
          median: self.class.percentile(latency, 0.5), slowest: self.class.percentile(latency, 0.95),
          latency: latency_rows(latency)
        }
      end

      def latency_rows(latency)
        keys = LATENCY_BUCKETS.map(&:to_s) + [OVERFLOW]
        keys.filter_map do |key|
          value = latency[key].to_i
          value.positive? ? { label: self.class.bucket_label(key), count: value } : nil
        end
      end

      def scalar(metrics, metric) = (metrics[metric] || {})[""].to_i

      def totals_of(features)
        COUNTERS.each_with_object({}) do |metric, totals|
          totals[metric.to_sym] = features.sum { |feature| feature.fetch(metric.to_sym, 0) }
        end
      end

      def empty_totals = COUNTERS.to_h { |metric| [metric.to_sym, 0] }
    end
  end
end
