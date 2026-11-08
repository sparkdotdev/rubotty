# frozen_string_literal: true

module Rubotty
  module Core
    # What actually became of each copy of a relayed message, per destination:
    # a backfill sweep hands a message to the inbound path and returns at
    # once, since sends happen later on each room's worker thread, so without
    # this a delivery that exhausted every retry would still count as
    # relayed. {Features::Bridge} reports every completion and abandonment
    # here, the sweep reads them back before reporting a count, and {Pacer}
    # reads a destination's stated retry_after here too. Only messages a
    # sweep asked to {#watch} are recorded, so live traffic writes nothing here.
    class RelayOutcomes
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      # What a batch of relayed messages actually came to.
      Reconciliation = Struct.new(:lost, :losses, keyword_init: true)

      def initialize(logger: nil, monotonic: MONOTONIC)
        @logger = logger
        @monotonic = monotonic
        @mutex = Mutex.new
        # source ref => { destination id => [verdict, reason] }
        @outcomes = {}
        # destination id => [seconds it asked for, when it asked]
        @rate_limits = {}
      end

      # Start following one message's fan-out. Until this is called, the reports
      # below are dropped, which is how live traffic stays free.
      def watch(source_ref)
        @mutex.synchronize { @outcomes[source_ref.to_s] ||= {} }
        nil
      end

      def delivered(source_ref, destination_id)
        record(source_ref, destination_id, :delivered, nil)
      end

      # A copy that spent every attempt it had. Loud on purpose: nothing else
      # sends this one, and the whole point of backfill is that a message the
      # bridge was down for still arrives.
      def abandoned(source_ref, destination_id, reason)
        return unless record(source_ref, destination_id, :abandoned, reason)

        @logger&.error do
          "RELAY LOST: #{source_ref} never reached #{destination_id} (#{reason}). Delivery gave up after " \
            "every attempt it had, so that message is absent from #{destination_id} and nothing will resend it."
        end
      end

      # A destination said how long it wants between sends. Recorded on the
      # FIRST refusal rather than after the wait, so a sweep still feeding this
      # room slows down now.
      def rate_limited(destination_id, seconds)
        wait = seconds.to_f
        return if wait <= 0

        @mutex.synchronize { @rate_limits[destination_id.to_s] = [wait, @monotonic.call] }
        @logger&.warn do
          "#{destination_id} asked for #{wait}s between sends; pacing the rest of this relay at that rate"
        end
      end

      # The wait +destination_id+ last asked for, counted only when it asked at
      # or after +since+, so one sweep never inherits an old sweep's slowdown.
      #
      # @return [Float, nil]
      def rate_limit_for(destination_id, since:)
        seconds, at = @mutex.synchronize { @rate_limits[destination_id.to_s] }
        return nil if seconds.nil? || at < since

        seconds
      end

      # What became of the messages in +source_refs+, and forget them.
      #
      # A message counts as lost when ANY of its copies was given up on: it
      # reached some of the room and not the rest, which is not something a
      # count of relayed messages may quietly absorb.
      def reconcile(source_refs)
        refs = Array(source_refs).map(&:to_s)
        losses = []
        lost = 0
        @mutex.synchronize do
          refs.each do |ref|
            failures = (@outcomes.delete(ref) || {}).filter_map do |destination, (verdict, reason)|
              "#{ref} to #{destination} (#{reason})" if verdict == :abandoned
            end
            next if failures.empty?

            lost += 1
            losses.concat(failures)
          end
        end
        Reconciliation.new(lost: lost, losses: losses)
      end

      # Stop following these without reading the verdicts back.
      def forget(source_refs)
        refs = Array(source_refs).map(&:to_s)
        @mutex.synchronize { refs.each { |ref| @outcomes.delete(ref) } }
        nil
      end

      # A fresh per-destination pacing budget reading its rate news from here.
      def pacer(interval_ms:, max_interval_ms: nil, sleeper: nil)
        Pacer.new(outcomes: self, interval_ms: interval_ms, max_interval_ms: max_interval_ms,
                  sleeper: sleeper, monotonic: @monotonic)
      end

      # Per-destination pacing for one relay. The configured gap applies
      # between two sends to ONE place, since that is what a platform rate
      # limits; one source message fans out to every endpoint in a room, so
      # each destination keeps its own budget, slowed only when that platform
      # itself asks for it, for the rest of the relay.
      class Pacer
        # Stand-in for a channel whose room membership cannot be read, so a
        # sweep there still costs the configured interval per relayed action.
        WHOLE_CHANNEL = "*"

        # Ceiling on a wait this will honour when nothing else sets one. A
        # platform asking for an hour between sends would otherwise pin a sweep
        # for the rest of the day.
        DEFAULT_MAX_INTERVAL_MS = 60_000

        def initialize(interval_ms:, outcomes: nil, max_interval_ms: nil, sleeper: nil, monotonic: MONOTONIC)
          @outcomes = outcomes
          @default = seconds(interval_ms)
          @ceiling = [seconds(max_interval_ms || DEFAULT_MAX_INTERVAL_MS), @default].max
          @sleeper = sleeper || ->(wait) { sleep(wait) }
          @monotonic = monotonic
          @started_at = @monotonic.call
          @intervals = {}
        end

        # Book one send against each of +destination_ids+ and wait until the
        # slowest of them will take another. Costs nothing when the caller had
        # nothing to send, which is what keeps a sweep with nothing missing free.
        #
        # @return [Float] how long it waited
        def pace(destination_ids)
          ids = Array(destination_ids).map(&:to_s)
          ids = [WHOLE_CHANNEL] if ids.empty?
          wait = ids.map { |id| interval_for(id) }.max
          @sleeper.call(wait) if wait.positive?
          wait
        end

        # What one destination currently wants between sends. Starts at the
        # configured interval and only ever grows, held at the ceiling, because
        # a platform answering "wait 27 seconds" has named its real rate and we
        # have no reason to think it changed its mind mid-sweep.
        def interval_for(destination_id)
          id = destination_id.to_s
          stated = @outcomes&.rate_limit_for(id, since: @started_at)
          current = @intervals[id] || @default
          current = [stated, @ceiling].min if stated && stated > current
          @intervals[id] = current
        end

        # Every destination this has paced, and the interval it settled on.
        def intervals = @intervals.dup

        private

        def seconds(milliseconds) = milliseconds.to_f / 1000.0
      end

      private

      # @return [Boolean] whether anybody was following this message
      def record(source_ref, destination_id, verdict, reason)
        @mutex.synchronize do
          copies = @outcomes[source_ref.to_s]
          return false if copies.nil?

          copies[destination_id.to_s] = [verdict, reason]
          true
        end
      end
    end
  end
end
