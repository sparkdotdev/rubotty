# frozen_string_literal: true

module Rubotty
  module Dashboard
    # The durable jobs that gave up, for the page an operator reads when a
    # feature has quietly stopped. The rows are already in `scheduled_jobs`, so
    # this is a reading surface rather than new bookkeeping: it picks the window,
    # groups by kind so a feature failing repeatedly reads as one problem, and
    # formats each row for the table.
    class JobFailures
      # How far back the page may look, longest last so the picker reads in
      # order. A failure older than a week is history rather than an alert.
      WINDOWS = { "1h" => 3600, "24h" => 86_400, "7d" => 604_800 }.freeze
      # What a reader is offered, rather than the token the form submits.
      WINDOW_LABELS = { "1h" => "Last hour", "24h" => "Last 24 hours", "7d" => "Last 7 days" }.freeze
      DEFAULT_WINDOW = "24h"
      LIMIT = 200

      class << self
        # Falls back rather than refusing, the same as the Logs page: this is
        # somewhere to look at a fault, not somewhere to be told off.
        def window_of(raw) = WINDOWS.key?(raw.to_s) ? raw.to_s : DEFAULT_WINDOW

        def seconds_of(window) = WINDOWS.fetch(window_of(window))

        # Option pairs for the window select, in the order WINDOWS declares.
        def window_options = WINDOWS.keys.map { |key| [key, WINDOW_LABELS.fetch(key, key)] }

        # One row per failure, newest first, as the table renders them.
        def rows(failures)
          failures.map do |job|
            { "when" => job.failed_at&.utc&.strftime("%Y-%m-%d %H:%M:%S UTC").to_s,
              "kind" => job.kind.to_s,
              "community" => job.community.to_s.empty? ? "deployment" : job.community.to_s,
              "attempts" => job.attempts.to_s,
              "reason" => job.failed_reason.to_s.empty? ? "not recorded" : job.failed_reason.to_s }
          end
        end

        # How many times each kind gave up in the window, worst first, so one
        # feature failing forty times reads as one problem rather than forty.
        def by_kind(failures)
          failures.group_by { |job| job.kind.to_s }
                  .map { |kind, jobs| { "kind" => kind, "failures" => jobs.length.to_s, "latest" => latest(jobs) } }
                  .sort_by { |row| -row["failures"].to_i }
        end

        def latest(jobs)
          newest = jobs.map(&:failed_at).compact.max
          newest.nil? ? "unknown" : newest.utc.strftime("%Y-%m-%d %H:%M:%S UTC")
        end
        private :latest
      end
    end
  end
end
