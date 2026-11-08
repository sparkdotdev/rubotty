# frozen_string_literal: true

require "json"
require "sequel"

module Rubotty
  module ControlPlane
    # Moves topic routing wants to make and the operator verdicts on them. One
    # row is both halves: it opens pending, an operator answers it or it lapses
    # unanswered, and it then stands as a labelled sample of what the
    # classifier got right and wrong, which is the whole reason for the mode.
    #
    # Codes come from {ContentPolicyActions}'s alphabet, so an operator types
    # the same shape of handle back whichever DM they are answering.
    class TopicMoveProposals
      PENDING = "pending"
      APPROVED = "approved"
      REJECTED = "rejected"
      LAPSED = "lapsed"
      STATES = [PENDING, APPROVED, REJECTED, LAPSED].freeze

      # How long an unanswered proposal stays actionable. Long enough that an
      # operator asleep when it fired still sees it, short enough that
      # approving never reposts a message the room has moved on from.
      DEFAULT_PENDING_HOURS = 48
      MAX_PENDING_HOURS = 168

      # Six months, measured from the message rather than the row: a training
      # window, deliberately longer than anything else here, and stated that
      # way because the text being kept is the message's.
      MAX_WINDOW_DAYS = 183
      DEFAULT_WINDOW_DAYS = 183

      MINT_ATTEMPTS = 8
      RECENT_LIMIT = 8

      PRUNE_KIND = "topic_move_proposals_prune"
      PRUNE_INTERVAL = 6 * 60 * 60
      LAPSE_KIND = "topic_move_proposals_lapse"
      LAPSE_INTERVAL = 15 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now }, random: Random.new)
        @models = models
        @logger = logger
        @clock = clock
        @random = random
      end

      # Open a proposal and answer the row, or nil when it could not be
      # written. A proposal that cannot be recorded is not announced either:
      # the caller checks for nil, since a DM naming a code that resolves to
      # nothing is worse than staying quiet.
      def open(community_id:, adapter:, endpoint_id:, native_id:, from_room:, to_room:,
               message_at:, author_native_id: nil, author_name: nil, body: nil,
               reasoning: nil, confidence: nil, here_confidence: nil, move_payload: nil)
        return nil if community_id.nil? || native_id.to_s.empty?

        attempt_insert(
          community_id: community_id, adapter: adapter.to_s, endpoint_id: endpoint_id.to_s,
          native_id: native_id.to_s, from_room: from_room.to_s, to_room: to_room.to_s,
          author_native_id: author_native_id&.to_s, author_name: author_name&.to_s,
          body: body, reasoning: reasoning&.to_s, confidence: confidence&.to_f,
          here_confidence: here_confidence&.to_f, move_payload: encode(move_payload),
          state: PENDING, message_at: message_at || @clock.call
        )
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not open: #{e.class}: #{e.message}" }
        nil
      end

      def find(community_id:, code:)
        return nil if community_id.nil? || code.to_s.strip.empty?

        @models.topic_move_proposal.where(community_id: community_id, code: normalise(code)).first
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not read #{code}: #{e.message}" }
        nil
      end

      # Claim a pending proposal for a verdict. False when somebody already
      # answered it or it has lapsed, so two operators cannot both decide one.
      def decide!(row, state:, by:, reason: nil)
        return false if row.nil? || !STATES.include?(state) || row.state != PENDING

        claimed = @models.topic_move_proposal
                         .where(id: row.id, state: PENDING)
                         .update(state: state, decided_by: by.to_s, decision_reason: presence(reason),
                                 decided_at: @clock.call)
        claimed.positive?
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not claim #{row&.code}: #{e.message}" }
        false
      end

      # What a bare approve or reject is answered with.
      def pending(community_id:, limit: RECENT_LIMIT)
        return [] if community_id.nil?

        @models.topic_move_proposal
               .where(community_id: community_id, state: PENDING)
               .order(Sequel.desc(:created_at), Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 25)).all
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not list: #{e.message}" }
        []
      end

      # Close what nobody answered, so an old proposal can never be approved
      # into a room that has moved on. Answers how many lapsed.
      def lapse(pending_hours: DEFAULT_PENDING_HOURS)
        cutoff = @clock.call - (self.class.pending_hours(pending_hours) * 3600)
        @models.topic_move_proposal
               .where(state: PENDING).where { created_at < cutoff }
               .update(state: LAPSED, decided_at: @clock.call)
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not lapse: #{e.message}" }
        0
      end

      # The training corpus, newest message first.
      def decided(community_id:, limit: 100)
        return [] if community_id.nil?

        @models.topic_move_proposal
               .where(community_id: community_id).exclude(state: PENDING)
               .order(Sequel.desc(:message_at), Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 500)).all
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not read the corpus: #{e.message}" }
        []
      end

      def counts(community_id:)
        return {} if community_id.nil?

        @models.topic_move_proposal.where(community_id: community_id)
               .group_and_count(:state).to_h { |row| [row[:state].to_s, row[:count]] }
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not count: #{e.message}" }
        {}
      end

      # Measured from the message, which is what the retention promise names.
      def prune(window_days: DEFAULT_WINDOW_DAYS)
        cutoff = @clock.call - (self.class.window_days(window_days) * 86_400)
        @models.topic_move_proposal.where { message_at < cutoff }.delete
      rescue StandardError => e
        @logger&.warn { "topic proposals: could not prune: #{e.message}" }
        0
      end

      def self.window_days(value)
        days = value.to_i
        return DEFAULT_WINDOW_DAYS unless days.positive?

        [days, MAX_WINDOW_DAYS].min
      end

      def self.pending_hours(value)
        hours = value.to_i
        return DEFAULT_PENDING_HOURS unless hours.positive?

        [hours, MAX_PENDING_HOURS].min
      end

      # The move as the router handed it over, ready to be replayed.
      def self.move_payload(row)
        raw = row&.move_payload
        return nil if raw.to_s.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      private

      def encode(payload) = payload.nil? ? nil : JSON.generate(payload)

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def attempt_insert(attributes)
        MINT_ATTEMPTS.times do
          row = insert_with_code(attributes, mint_code)
          return row if row
        end
        @logger&.warn { "topic proposals: no free code after #{MINT_ATTEMPTS} attempts" }
        nil
      end

      def insert_with_code(attributes, code)
        @models.topic_move_proposal.create(**attributes, code: code, created_at: @clock.call)
      rescue Sequel::UniqueConstraintViolation
        nil
      end

      def mint_code
        alphabet = ContentPolicyActions::CODE_ALPHABET
        Array.new(ContentPolicyActions::CODE_LENGTH) { alphabet[@random.rand(alphabet.length)] }.join
      end

      def normalise(code) = code.to_s.strip.downcase.delete_prefix("#")
    end
  end
end
