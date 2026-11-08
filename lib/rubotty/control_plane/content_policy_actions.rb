# frozen_string_literal: true

require "sequel"

module Rubotty
  module ControlPlane
    # What a content policy action did, and the handle an operator names it
    # back by. The alert is a DM, so the reply needs a short word rather than
    # a native id nobody can type: {#record} mints one per community and
    # {#find} reads it back. Rows lapse on a window because one of them holds
    # the text of a removed message, which is the most sensitive thing this
    # schema keeps anywhere.
    class ContentPolicyActions
      # No vowels, so a code can never spell a word, and none of the pairs a
      # reader confuses: 0 and O, 1 and l and I are all absent.
      CODE_ALPHABET = "23456789bcdfghjkmnpqrstvwxyz"
      CODE_LENGTH = 4

      # The ceiling the config validator holds callers to, and the fallback a
      # community that names nothing gets. A removed message's text is kept
      # this long and no longer.
      MAX_WINDOW_DAYS = 30
      DEFAULT_WINDOW_DAYS = 30

      # A code has to be unique inside its community, and the index says so,
      # so a collision is a retry rather than an error.
      MINT_ATTEMPTS = 8

      # How many open actions a bare `vindicate` lists back. Short enough to
      # read on a phone, which is where an alert is answered.
      RECENT_LIMIT = 8

      # The durable job that keeps a removed message's text from outliving the
      # window, on the same shape the identity directory's own prune uses.
      PRUNE_KIND = "content_policy_actions_prune"
      PRUNE_INTERVAL = 6 * 60 * 60

      def initialize(models:, logger: nil, clock: -> { Time.now }, random: Random.new)
        @models = models
        @logger = logger
        @clock = clock
        @random = random
      end

      # Write one action down and answer the row, or nil when it could not be
      # written: the caller has already moderated by the time this runs, and a
      # bookkeeping failure must never undo that.
      def record(community_id:, adapter:, endpoint_id:, native_id:, action:,
                 author_native_id: nil, author_name: nil, policy: nil, body: nil,
                 reasoning: nil, confidence: nil, context: nil)
        return nil if community_id.nil? || native_id.to_s.empty?

        attributes = {
          community_id: community_id, adapter: adapter.to_s, endpoint_id: endpoint_id.to_s,
          native_id: native_id.to_s, action: action.to_s, author_native_id: author_native_id&.to_s,
          author_name: author_name&.to_s, policy: policy&.to_s, body: body,
          reasoning: reasoning&.to_s, confidence: confidence&.to_f, context: context
        }
        # An edit is judged again, so the same message reaches here twice. Reuse
        # the code it already has rather than minting a second: two codes for one
        # message means reversing one leaves the other standing, with the
        # reaction still on it and an alert nobody can answer.
        open_row = open_for(community_id, endpoint_id, native_id)
        return refresh(open_row, attributes) if open_row

        attempt_insert(attributes)
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not record #{action}: #{e.class}: #{e.message}" }
        nil
      end

      # The row an operator named, within its own community so one community's
      # code can never reach another's action.
      def find(community_id:, code:)
        return nil if community_id.nil? || code.to_s.strip.empty?

        @models.content_policy_action.where(community_id: community_id, code: normalise(code)).first
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not read #{code}: #{e.message}" }
        nil
      end

      # The actions still open to reversal here, newest first: what a bare
      # `vindicate` is answered with, so an operator who lost the alert can
      # still see which codes are live.
      def recent(community_id:, limit: RECENT_LIMIT)
        return [] if community_id.nil?

        @models.content_policy_action
               .where(community_id: community_id, reversed_at: nil)
               .order(Sequel.desc(:created_at), Sequel.desc(:id))
               .limit(limit.to_i.clamp(1, 25)).all
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not list: #{e.message}" }
        []
      end

      # Note the strike a warn_and_delete issued, so reversing the action can
      # clear that exact warning rather than whichever happens to be newest.
      def note_warning(row, warning_id, sanction_id: nil)
        return false if row.nil? || warning_id.nil?

        @models.content_policy_action.where(id: row.id)
               .update(warning_id: warning_id, sanction_id: sanction_id).positive?
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not note the warning: #{e.message}" }
        false
      end

      # Claim a row for reversal. False when somebody got there first, so two
      # operators answering the same alert cannot both undo it.
      def reverse!(row, by:)
        return false if row.nil? || !row.reversed_at.nil?

        claimed = @models.content_policy_action
                         .where(id: row.id, reversed_at: nil)
                         .update(reversed_at: @clock.call, reversed_by: by.to_s)
        claimed.positive?
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not claim #{row&.id}: #{e.message}" }
        false
      end

      # Drop rows past the window, which is what keeps a removed message's text
      # from outliving the chance to restore it.
      def prune(window_days: DEFAULT_WINDOW_DAYS)
        cutoff = @clock.call - (clamp_window(window_days) * 86_400)
        @models.content_policy_action.where { created_at < cutoff }.delete
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not prune: #{e.message}" }
        0
      end

      # A window an operator asked for, held to the ceiling and the floor.
      # Read here rather than trusted from config, so a value stored before the
      # ceiling existed is pulled down instead of honoured.
      def self.window_days(value)
        days = value.to_i
        return DEFAULT_WINDOW_DAYS unless days.positive?

        [days, MAX_WINDOW_DAYS].min
      end

      private

      # The record still open against one message, if there is one.
      def open_for(community_id, endpoint_id, native_id)
        @models.content_policy_action.where(
          community_id: community_id, endpoint_id: endpoint_id.to_s,
          native_id: native_id.to_s, reversed_at: nil
        ).order(Sequel.desc(:id)).first
      end

      # Carry the newer judgement onto the row, keeping its code and the moment
      # it was first written: the window it lapses on is the message's age here,
      # so an edit cannot keep a body alive indefinitely by refreshing it.
      def refresh(row, attributes)
        row.update(**attributes.except(:community_id, :adapter, :endpoint_id, :native_id))
        row
      rescue StandardError => e
        @logger&.warn { "content policy actions: could not refresh #{row.code}: #{e.message}" }
        row
      end

      def clamp_window(value) = self.class.window_days(value)

      def attempt_insert(attributes)
        MINT_ATTEMPTS.times do
          row = insert_with_code(attributes, mint_code)
          return row if row
        end
        @logger&.warn { "content policy actions: no free code after #{MINT_ATTEMPTS} attempts" }
        nil
      end

      def insert_with_code(attributes, code)
        @models.content_policy_action.create(**attributes, code: code, created_at: @clock.call)
      rescue Sequel::UniqueConstraintViolation
        nil
      end

      def mint_code = Array.new(CODE_LENGTH) { CODE_ALPHABET[@random.rand(CODE_ALPHABET.length)] }.join

      def normalise(code) = code.to_s.strip.downcase.delete_prefix("#")
    end
  end
end
