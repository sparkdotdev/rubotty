# frozen_string_literal: true

require "time"

module Rubotty
  module Core
    # Paced, idempotent backfill of activity missed while the bot was down.
    # On boot, sweeps each backfill-enabled channel's recent history and
    # re-feeds anything not already in the relay ledger, reactions included.
    # Pacing is counted per destination through {RelayOutcomes::Pacer},
    # since that is what a platform actually rate limits, and a copy the
    # bridge gave up on is reconciled back out of the relayed count and
    # reported as abandoned. A gap bigger than `auto_relay_limit` becomes a
    # {ControlPlane::BackfillProposals} proposal instead of an automatic relay.
    class Backfill
      FEATURE = "backfill"

      # How long to wait for the copies already handed over to land before the
      # counts are read back. Generous, since a rate-limited retry waits out
      # whatever the platform asked for, and bounded, since an adapter wedged in
      # a send must not hold a sweep open.
      SETTLE_TIMEOUT = 90

      DEFAULTS = {
        # The furthest back the sweep may reach. The last relay from the channel,
        # or its mapping time, moves the start forward from here; this is only
        # the outer bound for a channel with neither.
        lookback_seconds: 72 * 60 * 60,
        # Milliseconds between two sends to ONE DESTINATION, the unit a platform
        # actually rate limits; a source message fans out to every endpoint in
        # its room, so the wait after it is the longest any destination wants.
        interval_ms: 1_000,
        # Ceiling on the interval a destination's own retry_after may push it to.
        # A platform asking for an hour between sends would otherwise pin a sweep
        # for the rest of the day.
        max_interval_ms: RelayOutcomes::Pacer::DEFAULT_MAX_INTERVAL_MS,
        # Never RELAY anything older than this. Kept under the claim TTL so a
        # re-fed message always still has its dedup claim.
        safe_horizon_seconds: 72 * 60 * 60,
        # Cap on messages actually relayed per channel; the rest of an over-long
        # gap is left unsynced and logged rather than flooding the channel.
        max_messages: 1_000,
        # Cap on messages FETCHED per channel; bounds REST cost on a busy channel.
        max_fetch: 2_000,
        # Cap on REACTIONS actually relayed per channel. Each is paced on the SAME
        # per-destination budget as a message.
        max_reactions: 100,
        # Gaps bigger than this are written down as a proposal and wait for a
        # person; zero holds every restore, however small.
        auto_relay_limit: ControlPlane::BackfillProposals::AUTO_RELAY_LIMIT
      }.freeze

      # @param storage [Storage::Base] the relay-claim ledger, for the dedup check
      # @param proposals [ControlPlane::BackfillProposals, nil] where an
      #   over-limit gap is written down instead of relayed; without one it
      #   is refused rather than sent.
      # @param outcomes [RelayOutcomes, nil] where the bridge reports what became
      #   of each copy; without one the sweep paces every destination at the
      #   configured interval, the prior behavior.
      # @param clock, sleeper, monotonic [#call] injected for tests
      def initialize(storage:, logger: nil, clock: -> { Time.now }, sleeper: ->(seconds) { sleep(seconds) },
                     proposals: nil, outcomes: nil, monotonic: RelayOutcomes::MONOTONIC)
        @storage = storage
        @logger = logger
        @clock = clock
        @sleeper = sleeper
        @proposals = proposals
        @outcomes = outcomes
        @monotonic = monotonic
      end

      # Kick the sweep on a background thread so a paced replay does not block
      # boot. A no-op without a snapshot (no control plane, so nothing is enabled).
      #
      # @return [Thread, nil]
      def start(adapters:, snapshot:)
        return nil if snapshot.nil?

        Thread.new do
          Thread.current.name = "rubotty-backfill"
          run(adapters: adapters, snapshot: snapshot)
        end
      end

      # Synchronous sweep, for tests and for callers that want to block. Never
      # raises: one channel failing must not take down the rest or the boot.
      def run(adapters:, snapshot:)
        return if snapshot.nil?

        targets, opted_out, confusing_lookback = collect_targets(adapters, snapshot)
        report_opted_out(opted_out)
        report_confusing_lookback(confusing_lookback)
        return if targets.empty?

        @logger&.info { "backfill: sweeping #{targets.size} channel(s) for missed activity" }
        unreadable = targets.filter_map { |target| target.channel.endpoint.id if sweep(target) == :unreadable }
        report_unreadable(unreadable)
      rescue StandardError => e
        @logger&.error { "backfill sweep aborted: #{e.class}: #{e.message}" }
      end

      # The channels this sweep would actually touch, with the config it would use.
      # Public so {GapReport} describes exactly the set the real sweep works on,
      # rather than a second opinion about it that can drift.
      def sweepable(adapters:, snapshot:)
        return [] if snapshot.nil?

        collect_targets(adapters, snapshot).first
      end

      # What relaying a list of native ids through one channel came to.
      # +relayed+ counts messages that reached every destination in the room; a
      # copy the bridge gave up on lands in +abandoned+ instead, so "relayed 24"
      # never means twenty-three arrived and one did not.
      RelayResult = Struct.new(:relayed, :skipped, :missing, :capped, :abandoned, :error, keyword_init: true)

      # Relays exactly the native ids a proposal was approved for, through the
      # same paced, deduped path #run uses, using +target+'s live config rather
      # than whatever was true when the proposal was written down. Fetches the
      # window at +since+ and keeps only the ids in +native_ids+, oldest first,
      # rather than recomputing which messages qualify today.
      #
      # @return [RelayResult] never raises; a mid-run failure is reported in
      #   +error+ rather than losing the count of whatever relayed before it
      def relay_approved(target:, native_ids:, since:)
        wanted = Array(native_ids).map(&:to_s)
        if wanted.empty?
          return RelayResult.new(relayed: 0, skipped: 0, missing: 0, capped: 0, abandoned: 0, error: nil)
        end

        relayed = 0
        skipped = 0
        missing = 0
        sent = []
        config = target.config
        pacer = pacer_for(config)
        destinations = destinations_for(target)
        begin
          community_id = target.community.id
          candidates = target.adapter.backfill_messages(
            target.channel.endpoint, since: since, limit: [config[:max_fetch], wanted.size * 4].max
          )
          by_id = candidates.each_with_object({}) { |message, index| index[message.ref.native_id.to_s] = message }

          wanted.each do |native_id|
            break if relayed >= config[:max_messages]

            message = by_id[native_id]
            if message.nil?
              missing += 1
              next
            end
            if already_relayed?(message.ref, "new", community_id)
              skipped += 1
              next
            end

            sent << message.ref
            @outcomes&.watch(message.ref)
            target.adapter.ingest(annotate(message))
            relayed += 1
            pacer.pace(destinations)
          end
          lost = reconcile(target, sent)
          relayed -= lost
          capped = wanted.size - relayed - skipped - missing - lost
          RelayResult.new(relayed: relayed, skipped: skipped, missing: missing, capped: capped,
                          abandoned: lost, error: nil)
        rescue StandardError => e
          lost = reconcile(target, sent)
          relayed -= lost
          capped = wanted.size - relayed - skipped - missing - lost
          RelayResult.new(relayed: relayed, skipped: skipped, missing: missing, capped: capped,
                          abandoned: lost, error: "#{e.class}: #{e.message}")
        end
      end

      private

      Target = Struct.new(:community, :channel, :adapter, :config, keyword_init: true)

      # Every (community, channel) whose "backfill" feature is enabled and whose
      # adapter can reconstruct history, paired with its resolved config, plus the
      # endpoint ids of the channels that COULD have been swept and were turned
      # off, plus the endpoint ids where lookback_seconds reaches past
      # safe_horizon_seconds. The second list is why anyone learns about an opted
      # out channel before the messages go missing; the third is why anyone
      # learns their lookback is not doing what they think it is.
      def collect_targets(adapters, snapshot)
        targets = []
        opted_out = []
        confusing_lookback = []
        snapshot.communities.each do |community|
          community.channels.each do |channel|
            adapter = adapters[[channel.adapter, channel.account]]
            next if adapter.nil? || !adapter.supports_backfill?

            unless community.feature_enabled?(channel, FEATURE)
              opted_out << "#{community.slug}/#{channel.endpoint.id}"
              next
            end

            config = config_for(community, channel)
            if config[:lookback_seconds] > config[:safe_horizon_seconds]
              confusing_lookback << "#{community.slug}/#{channel.endpoint.id}"
            end

            targets << Target.new(community: community, channel: channel, adapter: adapter, config: config)
          end
        end
        [targets, opted_out, confusing_lookback]
      end

      # Said at boot rather than left to be worked out from missing messages days
      # later. A warning, not a note: on these channels a restart loses whatever
      # was posted while the process was down, and nothing else recovers it.
      def report_opted_out(opted_out)
        return if opted_out.empty?

        @logger&.warn do
          "backfill is OFF on #{opted_out.size} channel(s) whose platform could recover history " \
            "(#{opted_out.join(", ")}); a restart loses whatever is posted there while this process is down"
        end
      end

      # Not unsafe on its own: {#resume_from} already takes whichever of
      # lookback_seconds and safe_horizon_seconds is smaller, so nothing past the
      # horizon is ever relayed. Said anyway because a lookback set past the
      # horizon has no effect there and is a sign the two got confused for the
      # same knob, which is what widened both to a week and caused the replay
      # this exists to catch.
      def report_confusing_lookback(endpoint_ids)
        return if endpoint_ids.empty?

        @logger&.warn do
          "backfill: lookback_seconds is set past safe_horizon_seconds on #{endpoint_ids.size} " \
            "channel(s) (#{endpoint_ids.join(", ")}); only the horizon bounds what actually gets " \
            "relayed, so raising the lookback alone reaches no further back"
        end
      end

      def config_for(community, channel)
        overrides = community.feature_config(channel, FEATURE) || {}
        DEFAULTS.merge(coerce(overrides))
      end

      def sweep(target)
        sent = []
        config = target.config
        now = @clock.call
        floor = now - config[:safe_horizon_seconds]
        endpoint = target.channel.endpoint
        community_id = target.community.id
        since = resume_from(target, now)
        # Declared before the fetch so the rescues below can still account for
        # whatever had already been handed over when something raised.
        sent = []

        candidates = target.adapter.backfill_messages(endpoint, since: since, limit: config[:max_fetch])
        verdict = gate(target, now, config)
        return verdict unless verdict == :relay

        relayed = 0
        skipped = 0
        reactions = 0
        pacer = pacer_for(config)
        destinations = destinations_for(target)
        candidates.each do |message|
          break if relayed >= config[:max_messages]
          # Below the safe floor the dedup claim may have been pruned, so a re-feed
          # could duplicate.
          next if message.timestamp && message.timestamp < floor

          if already_relayed?(message.ref, "new", community_id)
            skipped += 1
            next
          end

          sent << message.ref
          @outcomes&.watch(message.ref)
          target.adapter.ingest(annotate(message))
          relayed += 1
          pacer.pace(destinations)

          # For a gap message we ACTUALLY relayed, resync the reactions it accrued
          # while we were down, bounded by the remaining reaction budget.
          reactions += sweep_reactions(target, endpoint, message, community_id, pacer: pacer,
                                       destinations: destinations, budget: config[:max_reactions] - reactions)
        end

        lost = reconcile(target, sent)
        report(endpoint, candidates.size, relayed, skipped, reactions, lost, config[:max_messages], since)
      # A channel nobody granted Read Message History on is an ordinary state, not
      # a fault, and it is the same on every boot. Reported once, together, by the
      # caller rather than as a red line per channel per restart, which buried the
      # failures that DO deserve one.
      rescue PermissionError
        reconcile(target, sent)
        :unreadable
      # Whatever was already handed over is still owed an answer, exactly as in
      # #relay_approved: without this those refs sit watched for the life of the
      # process and a copy that never arrived is never counted as abandoned.
      rescue StandardError => e
        reconcile(target, sent)
        @logger&.error { "backfill for #{target.channel.endpoint.id} failed: #{e.class}: #{e.message}" }
      end

      # Whether this channel's window may go out unattended; {GapReport} does
      # the counting so the gate and what an operator reads can never disagree.
      # Classifies from {#propose_from}, which reaches further back than
      # {#resume_from}, so a channel that relayed since a hole can still raise
      # one, though what goes out unattended stays bounded by resume_from.
      #
      # @return [Symbol] :relay to sweep as normal, :proposed once the window is
      #   written down and waiting on a person, :blocked when it can be neither
      def gate(target, now, config)
        assessment = gap_report.assess(target, since: propose_from(target, now))
        channel = assessment.channel
        return blocked(target, "its gap could not be classified: #{channel.error}") if channel.error

        limit = config[:auto_relay_limit]
        return :relay if ControlPlane::BackfillProposals.auto_relayable?(channel.gaps, limit: limit)

        write_proposal(target, assessment, limit)
      end

      # Record what this channel's window came to and relay none of it. The send
      # belongs to whoever accepts it, through {BackfillProposalRelay}.
      def write_proposal(target, assessment, limit)
        channel = assessment.channel
        over = "#{channel.gaps} missing message(s), past this channel's auto_relay_limit of #{limit}"
        return blocked(target, "#{over}, and this process has no control plane to propose to") if @proposals.nil?

        row = @proposals.propose(community: target.community, report: channel, items: assessment.gaps)
        return blocked(target, "#{over}, and the proposal could not be written") if row.nil?

        @logger&.warn do
          "backfill #{channel.endpoint_id}: #{over}, so nothing was relayed. Proposal #{row[:id]} " \
            "is waiting on the Backfill proposals page and expires at #{row[:expires_at]}"
        end
        :proposed
      end

      def blocked(target, reason)
        @logger&.warn { "backfill relayed nothing on #{target.channel.endpoint.id}: #{reason}" }
        :blocked
      end

      def gap_report
        @gap_report ||= GapReport.new(storage: @storage, logger: @logger, clock: @clock)
      end

      # One line for every channel whose history we are not allowed to read, so a
      # clean boot reads as clean and an operator can still see the list.
      def report_unreadable(endpoint_ids)
        return if endpoint_ids.empty?

        @logger&.info do
          "backfill cannot read history on #{endpoint_ids.size} channel(s) and skipped them " \
            "(#{endpoint_ids.join(', ')}); grant Read Message History there if they should resync"
        end
      end

      # How a recovered message says so, in the reader's terms rather than ours.
      # The day is spelled by #ordinal, which strftime has no directive for.
      NOTE_FORMAT = "%B {day} at %H:%M UTC"

      # A gap message arrives hours or days after it was written and would
      # otherwise read as replying to the wrong thing, so it gets an italic
      # note on its own line marking it as the bridge talking rather than the
      # author. A message with no timestamp still gets a note, just without
      # the when, since the useful part is that it is not new.
      def annotate(message)
        message.with(body: message.body.concat(recovery_note(message.timestamp)))
      end

      def recovery_note(timestamp)
        sent = timestamp.nil? ? "" : " originally sent on #{stamp(timestamp)}"
        text = "\n(Message recovered;#{sent.empty? ? " it was sent while the bridge was down" : sent}.)"
        RichText.new(text, [Span.new(kind: :italic, begin_index: 1, end_index: text.length)])
      end

      def stamp(timestamp)
        utc = timestamp.utc
        utc.strftime(NOTE_FORMAT).sub("{day}", ordinal(utc.day))
      end

      # 11th, 12th and 13th break the last-digit rule and are the usual bug here.
      def ordinal(day)
        return "#{day}th" if (11..13).cover?(day % 100)

        "#{day}#{{ 1 => "st", 2 => "nd", 3 => "rd" }.fetch(day % 10, "th")}"
      end

      # Where this channel's sweep starts: the latest of the last relay from it,
      # the moment it was mapped into a room, and the lookback window. Taking the
      # latest is what keeps a newly mapped channel from replaying history nobody
      # bridged, and it also stops a channel down for three hours fetching twelve
      # and throwing nine away.
      def resume_from(target, now)
        [window(target, now), last_relay_at(target), target.channel.mapped_at].compact.max
      end

      # Where the PROPOSAL gate starts: the lookback window held at the
      # channel's mapping time, with the last-relay watermark deliberately
      # left out, since a hole with traffic after it would otherwise sit
      # behind that watermark and the busiest channels could never raise a
      # gap at all; mapped_at alone still keeps pre-bridge history from being
      # offered. Looking this far back is affordable because a person reads
      # a proposal before any of it is sent, which the unattended sweep does
      # not get.
      def propose_from(target, now)
        [window(target, now), target.channel.mapped_at].compact.max
      end

      # The furthest back either start may reach, held to the safe horizon since
      # nothing older than that may be relayed anyway.
      def window(target, now)
        now - [target.config[:lookback_seconds], target.config[:safe_horizon_seconds]].min
      end

      # Fails SAFE, in the direction of doing less: an unreadable ledger falls
      # back to the plain window rather than reaching further back than it should.
      def last_relay_at(target)
        @storage.last_relay_at(endpoint: target.channel.endpoint.id, community: target.community.id)
      rescue StandardError => e
        @logger&.warn { "backfill could not read the last relay for #{target.channel.endpoint.id}: #{e.message}" }
        nil
      end

      # Resync the reactions on one just-relayed gap message, through the SAME
      # paced, idempotent path a message takes: the react claim is the dedup
      # arbiter, so a re-run never double-posts. Returns the count relayed.
      def sweep_reactions(target, endpoint, message, community_id, pacer:, destinations:, budget:)
        relayed = 0
        return relayed if budget <= 0
        return relayed unless target.adapter.supports_reaction_backfill?

        target.adapter.backfill_reactions(endpoint, message.ref.native_id, limit: budget).each do |reaction|
          break if relayed >= budget

          operation = reaction_operation(reaction)
          next if operation.nil?
          next if already_relayed?(reaction.ref, operation, community_id)

          target.adapter.ingest(reaction)
          relayed += 1
          pacer.pace(destinations)
        end
        relayed
      rescue StandardError => e
        @logger&.warn { "backfill reactions for #{message.ref} failed: #{e.class}: #{e.message}" }
        relayed
      end

      # The exactly-once ledger is the arbiter: a claim already present for this
      # (source, operation) means it was relayed, so skip it. Fails SAFE (treats an
      # unknown as relayed), so a storage hiccup cannot turn backfill into a flood.
      def already_relayed?(source_ref, operation, community_id)
        @storage.relay_claimed?(source: source_ref, operation: operation, community: community_id)
      rescue StandardError => e
        @logger&.warn { "backfill dedup check failed for #{source_ref}, skipping: #{e.message}" }
        true
      end

      # The claim key for a backfilled reaction, IDENTICAL to
      # Features::Bridge#reaction_operation so one ledger entry dedups a reaction
      # whether it arrived live or via backfill.
      def reaction_operation(message)
        actor = message.author&.native_id
        return nil if actor.nil? || message.reaction.nil?

        "react:#{actor}:#{message.reaction.key}"
      end

      # This channel's pacing budget, one per destination. Built through the
      # outcomes when there are any, so the pacer and the rate news it reads
      # cannot end up on two different clocks.
      def pacer_for(config)
        interval = config[:interval_ms]
        ceiling = config[:max_interval_ms]
        if @outcomes
          @outcomes.pacer(interval_ms: interval, max_interval_ms: ceiling, sleeper: @sleeper)
        else
          RelayOutcomes::Pacer.new(interval_ms: interval, max_interval_ms: ceiling, sleeper: @sleeper,
                                   monotonic: @monotonic)
        end
      end

      # Every endpoint one message from this channel actually fans out to, which
      # is what a platform rate limits. Empty when the community cannot be asked
      # for its rooms, and the pacer then budgets the channel as a whole.
      def destinations_for(target)
        return [] unless target.community.respond_to?(:rooms)

        endpoint = target.channel.endpoint
        target.community.rooms
              .select { |room| room.include?(endpoint.id) }
              .flat_map { |room| room.targets_for(endpoint) }
              .map(&:id).uniq
      rescue StandardError => e
        @logger&.warn { "backfill could not read the destinations of #{target.channel.endpoint.id}: #{e.message}" }
        []
      end

      # How many of the messages we handed over never made it to the whole room.
      # Sends happen on each room's own worker, so the last is still in flight
      # when the loop ends; waiting for the handover to settle first is what
      # lets the counts describe deliveries rather than handovers.
      def reconcile(target, sent)
        return 0 if @outcomes.nil? || sent.empty?

        settle(target)
        result = @outcomes.reconcile(sent)
        return 0 if result.lost.zero?

        @logger&.error do
          "backfill #{target.channel.endpoint.id}: #{result.lost} message(s) were relayed and never " \
            "arrived (#{result.losses.join("; ")}); they are counted as abandoned rather than relayed"
        end
        result.lost
      rescue StandardError => e
        @logger&.warn { "backfill could not reconcile what it relayed on #{target.channel.endpoint.id}: #{e.message}" }
        0
      end

      def settle(target)
        dispatcher = target.adapter.dispatcher if target.adapter.respond_to?(:dispatcher)
        dispatcher.drain(timeout: SETTLE_TIMEOUT) if dispatcher.respond_to?(:drain)
      end

      # +relayed+ is the RAW in-loop count, which is what actually stopped the
      # loop at the cap. The line reports it with the abandoned copies taken back
      # out, and deciding capped from that reduced figure would drop the note
      # about an older gap whenever a copy was abandoned on the same run.
      def report(endpoint, fetched, relayed, skipped, reactions, abandoned, cap, since)
        capped = relayed >= cap
        landed = relayed - abandoned
        @logger&.info do
          note = capped ? ", capped at #{cap} (older gap left unsynced)" : ""
          lost = abandoned.positive? ? ", ABANDONED #{abandoned} (see the errors above)" : ""
          "backfill #{endpoint.id}: since #{since.utc.iso8601}, fetched #{fetched}, " \
            "relayed #{landed}, reactions #{reactions}, skipped #{skipped}#{lost}#{note}"
        end
      end

      # Config may arrive with string keys and string values, so normalise to
      # symbol keys and integers before the arithmetic above.
      def coerce(config)
        config.each_with_object({}) do |(key, value), out|
          out[key.to_sym] = value.is_a?(String) && value.match?(/\A-?\d+\z/) ? value.to_i : value
        end
      end
    end
  end
end
