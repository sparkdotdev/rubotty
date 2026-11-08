# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # A backfill sweep's intentions, written down and waiting on a person: past
    # a channel's `auto_relay_limit` ({AUTO_RELAY_LIMIT} until set), a gap is
    # proposed instead of relayed automatically, and goes out only when an
    # operator accepts. A proposal is approved BY ID and relayed exactly as
    # stored at sweep time, never refetched, and it EXPIRES rather than staying
    # acceptable forever. Item previews are deleted once a proposal stops
    # needing them (rejected, expired, or relayed); the row itself stays so the
    # page can still say what happened.
    class BackfillProposals
      class Invalid < Rubotty::Error; end

      # Gaps at or under this relay without asking, where a channel has not set
      # its own `auto_relay_limit`. A restart losing thirty seconds should still
      # heal itself quietly; the review exists for the restores nobody would
      # have chosen.
      AUTO_RELAY_LIMIT = 25

      # How long an operator has before a proposal goes stale.
      DEFAULT_TTL_SECONDS = 24 * 60 * 60

      # As much of a message as a proposal keeps, so somebody can tell what it is
      # without this becoming a message archive.
      PREVIEW_LIMIT = 500

      STATUSES = %w[pending approved rejected expired relayed].freeze

      # The one way to read across every tenant, for the deployment wide admin
      # list. It exists so a wide read has to name itself: +community+ is
      # required everywhere below, and a nil raises rather than reading the
      # whole deployment the way a defaulted argument used to.
      EVERY_COMMUNITY = :every_community

      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Whether a gap of +count+ messages is small enough to relay unattended.
      # On the class as well, because the sweep asks this before it has any
      # reason to hold a proposal store (Core::Backfill#gate).
      def self.auto_relayable?(count, limit: AUTO_RELAY_LIMIT) = count <= limit

      # Whether a gap of +count+ messages is small enough to relay unattended.
      def auto_relayable?(count, limit: AUTO_RELAY_LIMIT) = self.class.auto_relayable?(count, limit: limit)

      # Record what a sweep found on one channel. Returns the proposal row, or
      # nil when there was nothing to propose.
      #
      # @param report [Core::GapReport::Channel] the classification for a channel
      # @param items [Array<#native_id, #author_label, #preview, #sent_at>]
      def propose(community:, report:, items:, ttl_seconds: DEFAULT_TTL_SECONDS)
        return nil if items.empty?

        now = @clock.call
        @models.db.transaction do
          supersede_pending(community.id, report.endpoint_id)
          row = insert_proposal(community, report, now, ttl_seconds)
          items.each { |item| insert_item(row, item, now) }
          row
        end
      end

      # Every proposal still awaiting a decision, freshest first. Expired ones
      # are marked rather than returned, so a stale list cannot be accepted by
      # somebody who left the page open.
      def pending(community:) = in_status("pending", community: community)

      # Every proposal in one status, freshest first. The three named readers
      # below are the states a person acts on; this is the same read for the
      # settled ones (rejected, relayed) a client may want to confirm.
      #
      # @param community [#id, EVERY_COMMUNITY] the tenant to read
      def in_status(status, community:)
        expire_stale!
        scope = @models.backfill_proposal.where(status: status.to_s)
        scope = scope.where(community_id: community_id!(community)) unless community == EVERY_COMMUNITY
        scope.reverse(:created_at).all
      end

      # One of +community+'s proposals by id, or nil. Expires first, so a stale
      # row reads as expired here rather than as still waiting. A row belonging
      # to another tenant reads as nil, the same answer a missing one gives, so
      # a guessed id cannot confirm that somebody else's proposal exists.
      def find(community:, proposal_id:)
        expire_stale!
        row = @models.backfill_proposal[id: proposal_id]
        row if row && owned_by?(row, community)
      end

      # One proposal whichever tenant owns it, for the deployment wide admin
      # list and its detail page. Deliberately not called +find+: nothing that
      # writes may reach for this, and the name is what says so.
      def find_in_any_community(proposal_id)
        expire_stale!
        @models.backfill_proposal[id: proposal_id]
      end

      # backfill_proposal_items carries no community of its own, so ownership
      # is the proposal row's and has to be checked there.
      def items(community:, proposal_id:)
        return [] unless owned?(community, proposal_id)

        @models.backfill_proposal_item.where(proposal_id: proposal_id).order(:sent_at, :id).all
      end

      # Every proposal that has expired, freshest first. Shown on the page
      # rather than hidden, so leaving a decision too long reads as "this
      # expired" instead of the row silently disappearing.
      def expired(community:) = in_status("expired", community: community)

      # Every proposal accepted but not yet relayed: the state a proposal sits
      # in between an operator clicking Accept and the bot finishing the paced
      # send, or indefinitely if the bot could never be reached at all.
      def awaiting_relay(community:) = in_status("approved", community: community)

      # Accept one channel's list. Returns the items to relay, exactly as stored.
      def approve(community:, proposal_id:, decided_by:)
        row = decidable!(community, proposal_id)
        stamp(row, status: "approved", decided_by: decided_by)
        items(community: community, proposal_id: row[:id])
      end

      def reject(community:, proposal_id:, decided_by:)
        row = decidable!(community, proposal_id)
        stamp(row, status: "rejected", decided_by: decided_by)
        forget_items([row[:id]])
        row
      end

      # Called once the approved items have actually gone out, so a proposal is
      # never relayed twice by a second boot picking up an approved row. The
      # previews go here rather than at approve: the relay reads them back.
      def mark_relayed(community:, proposal_id:)
        row = owned!(community, proposal_id, doing: "marking relayed")
        @models.backfill_proposal.where(id: row[:id])
               .update(status: "relayed", updated_at: @clock.call)
        forget_items([row[:id]])
      end

      # Past its window is past its usefulness. The row is marked rather than
      # deleted, so the page can say what happened; its previews are dropped,
      # since nothing can be accepted once it is out of time.
      def expire_stale!
        # Read the clock into a local first: Sequel instance-evals a virtual row
        # block, so an ivar is not in scope inside one.
        now = @clock.call
        ids = @models.backfill_proposal.where(status: "pending").where { expires_at <= now }.select_map(:id)
        return if ids.empty?

        @models.backfill_proposal.where(id: ids, status: "pending").update(status: "expired", updated_at: now)
        forget_items(ids)
      end

      private

      # One live proposal per channel. A fresh sweep replaces whatever the last
      # one left, since the older list is about a window that has moved.
      def supersede_pending(community_id, endpoint_id)
        ids = @models.backfill_proposal
                     .where(community_id: community_id, endpoint_id: endpoint_id, status: "pending")
                     .select_map(:id)
        return if ids.empty?

        @models.backfill_proposal.where(id: ids).update(status: "expired", updated_at: @clock.call)
        forget_items(ids)
      end

      # A preview is kept only while the proposal holding it still needs one.
      def forget_items(proposal_ids)
        @models.backfill_proposal_item.where(proposal_id: proposal_ids).delete
      end

      def insert_proposal(community, report, now, ttl_seconds)
        id = @models.backfill_proposal.insert(
          community_id: community.id, endpoint_id: report.endpoint_id, status: "pending",
          fetched: report.fetched.to_i, gaps: report.gaps.to_i, ours: report.ours.to_i,
          claimed: report.claimed.to_i, below_floor: report.below_floor.to_i,
          swept_since: report.since, expires_at: now + ttl_seconds,
          created_at: now, updated_at: now
        )
        @models.backfill_proposal[id: id]
      end

      def insert_item(row, item, now)
        @models.backfill_proposal_item.insert(
          proposal_id: row[:id], native_id: item.native_id.to_s,
          author_label: truncate(item.author_label, 200),
          preview: truncate(item.preview, PREVIEW_LIMIT),
          sent_at: item.sent_at, created_at: now
        )
      end

      def decidable!(community, proposal_id)
        expire_stale!
        row = owned!(community, proposal_id, doing: "deciding")
        raise Invalid, "that proposal is #{row[:status]}, not waiting for a decision" if row[:status] != "pending"

        row
      end

      # Approving replays somebody's message history into a live room, so a
      # row outside +community+ is refused at the point of action and logged
      # loudly. It raises the same words a missing row does, deliberately: the
      # refusal must not tell one tenant that another tenant's id is real.
      def owned!(community, proposal_id, doing:)
        row = @models.backfill_proposal[id: proposal_id]
        raise Invalid, "no such proposal" if row.nil?
        return row if owned_by?(row, community)

        @logger&.error do
          "backfill proposals: refusing #{doing} proposal #{proposal_id}, which belongs to community " \
            "#{row[:community_id]} and was addressed as community #{community_id!(community)}"
        end
        raise Invalid, "no such proposal"
      end

      def owned?(community, proposal_id)
        row = @models.backfill_proposal[id: proposal_id]
        !row.nil? && owned_by?(row, community)
      end

      def owned_by?(row, community) = row[:community_id] == community_id!(community)

      # EVERY_COMMUNITY reads, it never acts, and a nil is always a caller that
      # forgot rather than one that meant the whole deployment.
      def community_id!(community)
        raise ArgumentError, "a community is required (EVERY_COMMUNITY reads every tenant)" if community.nil?
        raise ArgumentError, "EVERY_COMMUNITY names no single tenant to act on" if community == EVERY_COMMUNITY

        community.id
      end

      def stamp(row, status:, decided_by:)
        now = @clock.call
        @models.backfill_proposal.where(id: row[:id])
               .update(status: status, decided_by: decided_by.to_s, decided_at: now, updated_at: now)
      end

      def truncate(value, limit)
        return nil if value.nil?

        text = value.to_s
        text.length > limit ? text[0, limit] : text
      end
    end
  end
end
