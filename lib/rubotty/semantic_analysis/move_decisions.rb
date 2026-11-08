# frozen_string_literal: true

module Rubotty
  module SemanticAnalysis
    # What an operator's answer to a move proposal does. Approving replays the
    # move the classifier described, through the same redirection the automatic
    # path uses, so an approved move and an unattended one are the same thing
    # to everything downstream. Rejecting moves nothing and keeps the reason.
    #
    # Either way the row stays as a labelled sample: the message, both rooms,
    # what the classifier thought and how sure it was, and what a human said
    # about it. That corpus is the whole point of the confirm mode.
    class MoveDecisions
      AUDIT_SOURCE = "topic_routing"

      Outcome = Struct.new(:status, :state, :author, :from_room, :to_room, :moved, keyword_init: true)

      def initialize(proposals:, registry:, redirections: nil, scheduler: nil, audit: nil,
                     logger: nil, clock: -> { Time.now })
        @proposals = proposals
        @registry = registry
        @redirections = redirections
        @scheduler = scheduler
        @audit = audit || Core::AuditLog::Null.new
        @logger = logger
        @clock = clock
      end

      def available? = !@proposals.nil?

      def pending(community_id:) = @proposals&.pending(community_id: community_id) || []

      # Whether +code+ names a proposal in this community at all. Answers the
      # console's question of which community a reply to an alert is about,
      # since a code is unique per community rather than across them. The same
      # contract {ContentPolicy::Vindication#holds?} answers for the other
      # verb pair, so the console reads one shape for both rather than
      # reaching through this wrapper for the store's own #find.
      def holds?(community_id:, code:)
        !@proposals&.find(community_id: community_id, code: code).nil?
      rescue StandardError => e
        @logger&.warn { "topic moves: could not look up #{code}: #{e.message}" }
        false
      end

      # @param approve [Boolean] true moves the message, false leaves it put
      # @return [Outcome]
      def settle(community:, code:, operator:, approve:, reason: nil)
        row = @proposals&.find(community_id: community.id, code: code)
        return Outcome.new(status: :unknown) if row.nil?
        return already(row) unless row.state == ControlPlane::TopicMoveProposals::PENDING

        state = approve ? ControlPlane::TopicMoveProposals::APPROVED : ControlPlane::TopicMoveProposals::REJECTED
        return already(row) unless @proposals.decide!(row, state: state, by: operator, reason: reason)

        moved = approve ? replay(community, row) : false
        record_audit(community, row, operator, approve: approve, reason: reason, moved: moved)
        Outcome.new(status: :decided, state: state, author: row.author_name,
                    from_room: row.from_room, to_room: row.to_room, moved: moved)
      rescue StandardError => e
        @logger&.warn { "topic decisions: could not settle #{code}: #{e.class}: #{e.message}" }
        Outcome.new(status: :unknown)
      end

      private

      def already(row)
        lapsed = row.state == ControlPlane::TopicMoveProposals::LAPSED
        Outcome.new(status: lapsed ? :lapsed : :settled, state: row.state, author: row.author_name,
                    from_room: row.from_room, to_room: row.to_room)
      end

      # The same redirection the unattended path opens, so nothing downstream
      # can tell an approved move from an automatic one.
      def replay(community, row)
        item = ControlPlane::TopicMoveProposals.move_payload(row)
        target = community.rooms.find { |candidate| candidate.id == row.to_room }
        return false if item.nil? || target.nil? || @redirections.nil? || @scheduler.nil?
        return false if target.endpoints.none?(&:sends?)

        opened = @redirections.open(
          community_id: community.id, source_endpoint_id: row.endpoint_id,
          target_room_id: target.id, operator: operator_label(row), plan: [item]
        )
        @scheduler.schedule(
          kind: Features::Redirection::KIND, run_at: @clock.call, community: community.id.to_s,
          payload: { "redirection_id" => opened.id, "community_id" => community.id }
        )
        true
      rescue StandardError => e
        @logger&.warn { "topic decisions: could not move #{row.native_id}: #{e.class}: #{e.message}" }
        false
      end

      # Named for the redirection log, which shows who moved a run of messages.
      def operator_label(row) = "#{AUDIT_SOURCE} (#{row.decided_by})"

      def record_audit(community, row, operator, approve:, reason:, moved:)
        @audit.record(
          community: community.slug, source: AUDIT_SOURCE, action: approve ? "move_approved" : "move_rejected",
          adapter: row.adapter, channel: row.endpoint_id, actor: operator,
          subject: row.author_name, subject_native_id: row.author_native_id,
          target_ref: "#{row.endpoint_id}:#{row.native_id}",
          reason: presence(reason) || "#{row.from_room} to #{row.to_room}",
          outcome: approve ? (moved ? "moved" : "approved, not moved") : "left in place",
          metadata: { code: row.code, from_room: row.from_room, to_room: row.to_room,
                      confidence: row.confidence, here: row.here_confidence }
        )
      rescue StandardError => e
        @logger&.warn { "topic decisions: could not record the decision: #{e.message}" }
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end
    end
  end
end
