# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # What a member said was wrong, kept until an operator has had a chance to
    # look. One row per reported MESSAGE, not per reporter: twenty people
    # reporting one thing is one thread with a count on it rather than twenty
    # alerts, which is the difference between a feature and an amplifier.
    #
    # The body is held because a reported message is usually gone by the time
    # anybody reads the alert. {RETENTION_DAYS} bounds that; see PRIVACY.md.
    class MemberReports
      # The same alphabet the content policy codes use, with no vowels and none
      # of the confusable pairs, so an operator can type one back accurately.
      CODE_ALPHABET = "23456789bcdfghjkmnpqrstvwxyz"
      CODE_LENGTH = 4
      MINT_ATTEMPTS = 8

      # How long a report is kept. Long enough for an operator to come back to
      # it after a weekend, short enough that this is not an archive of what
      # members said about each other.
      RETENTION_DAYS = 30

      # What one reporter may file in {RATE_WINDOW}. A report is a way for any
      # member to make the bot alert every operator, which is an amplification
      # vector before it is a feature.
      RATE_LIMIT = 5
      RATE_WINDOW = 3600

      PRUNE_KIND = "member_reports_prune"
      PRUNE_INTERVAL = 86_400

      Filed = Struct.new(:row, :first?, :rate_limited?, keyword_init: true)

      def initialize(models:, logger: nil, clock: -> { Time.now }, random: Random.new)
        @models = models
        @logger = logger
        @clock = clock
        @random = random
      end

      # File one report. A message already reported is counted onto the row that
      # already exists rather than opening a second thread about it, and the
      # answer says which happened so only a first report alerts anybody.
      #
      # @return [Filed]
      def file(community_id:, reporter:, route:, endpoint_id: nil, native_id: nil,
               author: nil, body: nil)
        return Filed.new(row: nil, first?: false, rate_limited?: true) if rate_limited?(community_id, reporter)

        existing = open_report(community_id, endpoint_id, native_id)
        if existing
          existing.update(reports: existing.reports.to_i + 1)
          return Filed.new(row: existing, first?: false, rate_limited?: false)
        end

        Filed.new(row: insert(community_id, reporter, route, endpoint_id, native_id, author, body),
                  first?: true, rate_limited?: false)
      end

      # The report an operator named, inside their own community. A code is
      # unique only there, so one community's can never resolve to another's.
      def by_code(community_id:, code:)
        @models.member_report.where(community_id: community_id, code: normalise(code)).first
      end

      # Mark one report dealt with. Kept rather than deleted, so a second
      # reporter's count still lands somewhere and the window still applies.
      def settle(row, status)
        row&.update(status: status.to_s)
      end

      # Whether the reporter of +row+ was ever told their report landed. A
      # rising count of reports nobody could acknowledge means members are
      # reporting and believe nothing happened, which is worth an operator
      # seeing rather than only a log line.
      def acknowledged!(row) = row&.update(acknowledged: true)

      def unacknowledged(community_id:, since: nil)
        scope = @models.member_report.where(community_id: community_id, acknowledged: false)
        scope = scope.where { created_at >= since } unless since.nil?
        scope.count
      end

      # Drop what has aged out. Returns how many went.
      def prune(now: @clock.call)
        @models.member_report.where { expires_at <= now }.delete
      rescue StandardError => e
        @logger&.warn { "member reports: could not prune: #{e.message}" }
        0
      end

      private

      # An open report about the same message, or nil. A settled one is left
      # alone: reporting a message again after an operator dismissed it is a
      # new thread, not a louder version of the old one.
      def open_report(community_id, endpoint_id, native_id)
        return nil if endpoint_id.nil? || native_id.nil?

        @models.member_report.where(
          community_id: community_id, endpoint_id: endpoint_id.to_s,
          native_id: native_id.to_s, status: "open"
        ).first
      end

      def rate_limited?(community_id, reporter)
        since = @clock.call - RATE_WINDOW
        @models.member_report.where(
          community_id: community_id,
          reporter_adapter: reporter[:adapter].to_s,
          reporter_native_id: reporter[:native_id].to_s
        ).where { created_at >= since }.count >= RATE_LIMIT
      end

      def insert(community_id, reporter, route, endpoint_id, native_id, author, body)
        now = @clock.call
        attributes = {
          community_id: community_id, route: route.to_s,
          endpoint_id: endpoint_id&.to_s, native_id: native_id&.to_s,
          author_native_id: author && author[:native_id]&.to_s,
          author_display: author && author[:display]&.to_s,
          body: body&.to_s, reporter_adapter: reporter[:adapter].to_s,
          reporter_native_id: reporter[:native_id].to_s,
          reporter_display: reporter[:display]&.to_s,
          created_at: now, expires_at: now + (RETENTION_DAYS * 86_400)
        }
        with_minted_code(community_id, attributes)
      end

      # A code is unique inside its community and the index says so, so a
      # collision is a retry rather than an error.
      def with_minted_code(community_id, attributes)
        MINT_ATTEMPTS.times do
          return @models.member_report.create(**attributes, code: mint_code)
        rescue Sequel::UniqueConstraintViolation
          next
        end
        raise Rubotty::Error, "could not mint a report code for community #{community_id}"
      end

      def mint_code = Array.new(CODE_LENGTH) { CODE_ALPHABET[@random.rand(CODE_ALPHABET.length)] }.join

      def normalise(code) = code.to_s.strip.downcase.delete_prefix("#")
    end
  end
end
