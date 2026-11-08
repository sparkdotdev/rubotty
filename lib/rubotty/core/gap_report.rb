# frozen_string_literal: true

require "time"

module Rubotty
  module Core
    # What a backfill sweep WOULD relay, worked out without relaying any of
    # it. {Backfill} resumes from a watermark that can hide a gap with
    # traffic on both sides, so this reads the plain window instead and
    # classifies each candidate: BELOW_FLOOR (too old to re-feed), CLAIMED
    # (already in the exactly-once ledger), OURS (our own copy, by
    # destination map or adapter check, :unknown counted as ours since
    # guessing wrong sent copies back down the bridge before), or GAP.
    # Writes and posts nothing; keeps no body per PRIVACY.md, only a reason and label.
    class GapReport
      Finding = Struct.new(:endpoint_id, :native_id, :timestamp, :reason, :author, keyword_init: true)

      Channel = Struct.new(:endpoint_id, :community, :since, :fetched, :gaps,
                           :ours, :claimed, :below_floor, :samples, :error,
                           keyword_init: true) do
        def gap? = gaps.positive?
      end

      # One gap in the shape {ControlPlane::BackfillProposals#propose} stores an
      # item, preview included.
      Gap = Struct.new(:native_id, :author_label, :preview, :sent_at, keyword_init: true)

      # A {Channel} plus, for the caller that asked, every gap behind its count.
      Assessment = Struct.new(:channel, :gaps, keyword_init: true)

      # How many findings to name per channel. Enough to go and look at one by
      # hand, short of reproducing the channel.
      SAMPLE_LIMIT = 10

      # Which count a classification reason belongs to.
      BUCKETS = {
        below_floor: :below_floor,
        claimed: :claimed,
        ours_destination_map: :ours,
        ours_adapter: :ours,
        ours_adapter_unknown: :ours,
        gap: :gaps
      }.freeze

      def initialize(storage:, logger: nil, clock: -> { Time.now })
        @storage = storage
        @logger = logger
        @clock = clock
      end

      # @return [Array<Channel>] one row per sweepable channel, worst first
      def run(adapters:, snapshot:)
        return [] if snapshot.nil?

        targets = Backfill.new(storage: @storage, logger: @logger, clock: @clock)
                          .sweepable(adapters: adapters, snapshot: snapshot)

        targets.map { |target| examine(target).channel }.sort_by { |row| -row.gaps }
      end

      # The same classification as {#run}, for ONE sweep target over the
      # window a proposal about it may cover, with every gap listed (not
      # sampled) and carrying the preview a proposal item needs. +since+ is
      # {Backfill#propose_from}, the plain window held at the channel's mapping
      # time with no last-relay watermark, so a hole with traffic on both sides
      # can still be raised here even though the sweep itself starts past it.
      #
      # @return [Assessment]
      def assess(target, since:) = examine(target, since: since, list_gaps: true)

      private

      def examine(target, since: nil, list_gaps: false)
        config = target.config
        now = @clock.call
        # The plain window, deliberately NOT resume_from. See the class comment.
        since ||= now - config[:lookback_seconds]
        floor = now - config[:safe_horizon_seconds]
        endpoint = target.channel.endpoint

        candidates = fetch_candidates(target, endpoint, since, config[:max_fetch])
        tally(target, endpoint, candidates, since: since, floor: floor, list_gaps: list_gaps)
      rescue StandardError => e
        @logger&.warn { "gap report for #{target.channel.endpoint.id} failed: #{e.class}: #{e.message}" }
        Assessment.new(gaps: [], channel: Channel.new(
          endpoint_id: target.channel.endpoint.id, community: target.community.slug,
          since: since, fetched: 0, gaps: 0, ours: 0, claimed: 0, below_floor: 0,
          samples: [], error: "#{e.class}: #{e.message}"
        ))
      end

      # Candidates paired with the adapter's ownership answer, the same
      # question the inbound path asks before it will relay one. An adapter
      # that cannot answer (Adapters::Base's default) is paired with nil
      # throughout, so {#classify} falls back to exactly what it did before
      # this existed rather than breaking.
      def fetch_candidates(target, endpoint, since, limit)
        adapter = target.adapter
        return adapter.backfill_candidates(endpoint, since: since, limit: limit) if adapter.supports_gap_ownership?

        adapter.backfill_messages(endpoint, since: since, limit: limit).map { |message| [message, nil] }
      end

      def tally(target, endpoint, candidates, since:, floor:, list_gaps:)
        counts = { gaps: 0, ours: 0, claimed: 0, below_floor: 0 }
        samples = []
        gaps = []

        candidates.each do |message, ownership|
          reason = classify(message, ownership, target.community.id, floor)
          counts[BUCKETS.fetch(reason)] += 1
          gaps << gap(message) if list_gaps && reason == :gap
          next unless sample?(reason) && samples.size < SAMPLE_LIMIT

          samples << finding(endpoint, message, reason)
        end

        Assessment.new(gaps: gaps, channel: Channel.new(
          endpoint_id: endpoint.id, community: target.community.slug, since: since,
          fetched: candidates.size, samples: samples, error: nil, **counts
        ))
      end

      # BELOW FLOOR and CLAIMED are old, trusted news. A GAP or an OURS this
      # cautious is exactly where a report earns or loses trust, so those are
      # what get named.
      def sample?(reason) = reason == :gap || reason.to_s.start_with?("ours_")

      def classify(message, ownership, community_id, floor)
        return :below_floor if message.timestamp && message.timestamp < floor
        return :claimed if relayed?(message.ref, community_id)
        return :ours_destination_map if written_by_us?(message.ref)

        case ownership
        when :ours then :ours_adapter
        when :unknown then :ours_adapter_unknown
        else :gap
        end
      end

      # Fails SAFE in the direction of under-reporting: an unreadable ledger is
      # treated as "already relayed", so a storage hiccup cannot invent a gap and
      # talk somebody into replaying a channel that was fine.
      def relayed?(ref, community_id)
        @storage.relay_claimed?(source: ref, operation: "new", community: community_id)
      rescue StandardError => e
        @logger&.warn { "gap report dedup check failed for #{ref}, counting it as relayed: #{e.message}" }
        true
      end

      # Our own copy, arriving from the far side of a relay we performed. Same
      # question {LoopGuard} asks, and the reason a report keyed only on source
      # refs would nominate every bridged message for a second trip.
      def written_by_us?(ref)
        @storage.destination?(ref)
      rescue StandardError
        true
      end

      # The one place this reads a message body, and only for a caller writing a
      # proposal that a decision prunes. {#finding} stays bodiless.
      def gap(message)
        Gap.new(native_id: message.ref.native_id.to_s, author_label: author_label(message.author),
                preview: message.body&.to_s, sent_at: message.timestamp)
      end

      def finding(endpoint, message, reason)
        Finding.new(endpoint_id: endpoint.id, native_id: message.ref.native_id,
                    timestamp: message.timestamp&.utc&.iso8601, reason: reason,
                    author: author_label(message.author))
      end

      # Enough to recognise a bridged copy on sight (its name, and whether the
      # platform flagged it as a bot, which a webhook post always is), and
      # nothing that PRIVACY.md says a report should not be keeping: no body,
      # no id beyond the native id already on the finding.
      def author_label(author)
        return nil if author.nil?

        author.bot? ? "#{author.any_name} (bot)" : author.any_name
      end
    end
  end
end
