# frozen_string_literal: true

require "time"

module Rubotty
  module Polls
    # One polls row: /poll asks a question, /schedule asks which time slots
    # work, and kind tells them apart.
    class Poll
      KIND_POLL = "poll"
      KIND_SCHEDULE = "schedule"
      KINDS = [KIND_POLL, KIND_SCHEDULE].freeze

      STATUS_OPEN = "open"
      STATUS_CLOSED = "closed"
      STATUSES = [STATUS_OPEN, STATUS_CLOSED].freeze

      # The keycap vocabulary tops out at nine, so options do too.
      MAX_OPTIONS = 9

      DURATION_HOURS = [1, 2, 4, 8, 12, 24, 48, 72].freeze

      DEFAULT_DURATION_HOURS = 24

      DURATION_TOKENS = DURATION_HOURS.map { |hours| "#{hours}h" }.freeze

      # The hours a duration token names, or nil. Strict, so a typo like "2d"
      # is refused rather than silently becoming a different deadline.
      #
      # @param text [String, nil]
      # @return [Integer, nil]
      def self.duration_hours(text)
        token = text.to_s.strip.downcase
        DURATION_HOURS.find { |hours| token == "#{hours}h" }
      end

      attr_reader :row

      def initialize(row)
        @row = row
      end

      def id = row[:id]
      def community_id = row[:community_id]
      def room_id = row[:room_id]
      def kind = row[:kind]
      def question = row[:question]
      def detail = row[:detail]
      def timezone = row[:timezone]
      def status = row[:status]
      def created_by = row[:created_by]

      def schedule? = kind == KIND_SCHEDULE

      def open? = status == STATUS_OPEN

      def closed? = status == STATUS_CLOSED

      # Whether one person may back several options at once.
      def multi_select? = truthy(row[:multi_select])

      def reply_votes? = truthy(row[:reply_votes])

      def reply_options? = truthy(row[:reply_options])

      def closes_at = to_utc(row[:closes_at])

      # When the card was last put in front of the room, or nil.
      def last_posted_at
        value = row[:last_posted_at]
        value && to_utc(value)
      end

      def to_s = "#{question} (#{kind}, #{status})"

      def inspect = "#<Rubotty::Polls::Poll #{self}>"

      private

      # Sequel hands a boolean back as true/false on Postgres and as 1/0 on the
      # backends with no boolean type of their own.
      def truthy(value)
        return false if value.nil?

        [true, 1, "1", "t", "true"].include?(value)
      end

      def to_utc(value)
        time = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        time.utc
      end
    end

    # One answer on a poll, or one candidate time slot. +starts_at+ is filled
    # in only by the scheduling surface.
    class Option
      attr_reader :row

      def initialize(row)
        @row = row
      end

      def id = row[:id]
      def poll_id = row[:poll_id]
      def position = row[:position]
      def label = row[:label]
      def suggested_by = row[:suggested_by]

      def starts_at
        value = row[:starts_at]
        return nil if value.nil?

        time = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        time.utc
      end

      def to_s = label.to_s
    end
  end
end
