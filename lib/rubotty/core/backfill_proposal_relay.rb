# frozen_string_literal: true

module Rubotty
  module Core
    # The bot side of the backfill proposal handoff: approving a proposal
    # happens in the web process, which holds no adapters, so this turns an
    # approved row into messages actually going out. It relays through
    # {Backfill#relay_approved} and marks the row relayed only after delivery,
    # so a later boot can't resend it. #kick (driven by
    # Core::HealthServer::RELAY_PROPOSAL_PATH) validates synchronously then
    # relays on a background thread, since a large approval can take minutes
    # at one message a second; #relay is the same work done synchronously.
    class BackfillProposalRelay
      Outcome = Struct.new(:ok, :error, keyword_init: true) do
        def ok? = ok
      end

      def initialize(models:, storage:, adapters:, snapshot:, logger: nil, clock: -> { Time.now }, sleeper: nil,
                     outcomes: nil)
        @models = models
        @storage = storage
        @adapters = adapters
        @snapshot = snapshot
        @logger = logger
        @proposals = ControlPlane::BackfillProposals.new(models: models, logger: logger, clock: clock)
        @sleeper = sleeper
        # Where the bridge reports what actually arrived, so the counts below
        # describe deliveries rather than handovers.
        @outcomes = outcomes
        # Exposed for tests, which join it to observe the outcome of the
        # background relay without a real wait.
        @last_relay_thread = nil
      end

      attr_reader :last_relay_thread

      # Validate, then relay on a background thread.
      #
      # @return [Outcome] ok when the paced relay has started; an error when it
      #   never will (no such proposal, not approved, or no live channel for it)
      def kick(proposal_id)
        row, target, precheck = validate(proposal_id)
        return precheck if precheck.error

        @last_relay_thread = Thread.new do
          Thread.current.name = "rubotty-backfill-relay"
          send_now(row, target)
        end
        Outcome.new(ok: true, error: nil)
      end

      # The whole handoff, synchronously: validate, relay the stored items,
      # mark relayed. Never raises.
      #
      # @return [Outcome]
      def relay(proposal_id)
        row, target, precheck = validate(proposal_id)
        return precheck if precheck.error

        send_now(row, target)
      end

      private

      # @return [Array(Sequel::Model row, Backfill::Target, Outcome)] the last
      #   element carries the error when +row+ or +target+ came back nil;
      #   check it before using the first two.
      def validate(proposal_id)
        row = @models.backfill_proposal[id: proposal_id]
        return [nil, nil, Outcome.new(ok: false, error: "no such proposal")] if row.nil?
        unless row[:status] == "approved"
          return [nil, nil, Outcome.new(ok: false, error: "that proposal is #{row[:status]}, not approved")]
        end

        backfill = build_backfill
        target = backfill.sweepable(adapters: @adapters, snapshot: @snapshot)
                          .find { |t| t.community.id == row[:community_id] && t.channel.endpoint.id == row[:endpoint_id] }
        if target.nil?
          return [nil, nil, Outcome.new(
            ok: false,
            error: "that channel is not available to relay through right now " \
                   "(its adapter isn't connected, or backfill has been turned off for it)"
          )]
        end

        [row, target, Outcome.new(ok: true, error: nil)]
      end

      def send_now(row, target)
        # target.community is the row's own, matched in #validate, and it is
        # what the service holds the items and the relayed stamp against.
        community = target.community
        items = @proposals.items(community: community, proposal_id: row[:id])
        native_ids = items.map { |item| item[:native_id] }
        since = items.filter_map { |item| item[:sent_at] }.min || row[:swept_since] || row[:created_at]

        result = build_backfill.relay_approved(target: target, native_ids: native_ids, since: since)
        if result.error
          @logger&.error { "backfill proposal #{row[:id]}: relay failed: #{result.error}" }
          return Outcome.new(ok: false, error: result.error)
        end

        # Marked relayed even when copies were abandoned: the exactly-once claim
        # was taken on the way out, so clicking Accept again would send nothing.
        @proposals.mark_relayed(community: community, proposal_id: row[:id])
        abandoned = result.abandoned.to_i
        if abandoned.positive?
          @logger&.error do
            "backfill proposal #{row[:id]}: #{abandoned} of the approved message(s) NEVER ARRIVED. " \
              "Relayed #{result.relayed}, abandoned #{abandoned}, skipped #{result.skipped}, " \
              "missing #{result.missing}, capped #{result.capped}"
          end
          return Outcome.new(ok: false, error: "#{abandoned} approved message(s) never arrived; see the log")
        end

        @logger&.info do
          "backfill proposal #{row[:id]}: relayed #{result.relayed}, skipped #{result.skipped}, " \
            "missing #{result.missing}, capped #{result.capped}"
        end
        Outcome.new(ok: true, error: nil)
      rescue StandardError => e
        @logger&.error { "backfill proposal #{row[:id]}: relay thread crashed: #{e.class}: #{e.message}" }
        Outcome.new(ok: false, error: "#{e.class}: #{e.message}")
      end

      def build_backfill
        opts = { storage: @storage, logger: @logger, outcomes: @outcomes }
        opts[:sleeper] = @sleeper if @sleeper
        Backfill.new(**opts)
      end
    end
  end
end
