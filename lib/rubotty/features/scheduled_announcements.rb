# frozen_string_literal: true

module Rubotty
  module Features
    # Scheduled and recurring announcements, as a catalog-registered feature. An
    # announcement fires on a clock, so this observes nothing and exists for the
    # feature_settings key and the schema; {Core::AnnouncementScheduler} does the work.
    #
    # Each `announcements` entry takes text and channels, then either `every` (a
    # recurrence interval such as "6 hours") or `at` (a one-off ISO-8601 time or unix
    # timestamp), plus an optional `name` sender label defaulting to "announcement".
    class ScheduledAnnouncements < Base
      def self.feature_name = Core::AnnouncementScheduler::FEATURE

      def self.description = "Posts an announcement on a schedule, once or recurring."

      # Off by default; a community announces nothing until an operator turns it on.
      def self.default_enabled? = false

      # Clock-driven, so it takes no part in the pipeline. AnnouncementScheduler
      # reads its enablement and config from the Snapshot directly.
      def self.observes = []

      def self.config_schema
        Config::Schema.define do
          field :announcements, :array, of: Config::Schema.define {
            field :text, :string, required: true, desc: "the message to post" do |value, path|
              "#{path}: cannot be blank" if value.strip.empty?
            end
            field :channels, :array, of: :string, required: true,
                             desc: "endpoint ids that receive this post" do |value, path|
              "#{path}: must name at least one endpoint" if value.empty?
            end
            field :every, :duration, desc: "repeat after this interval"
            field :at, :string, desc: "post once at this ISO-8601 time"
            field :name, :string, desc: "optional sender label"
          }, default: [],
                desc: "each: text, channels (endpoint ids), and either `every` (interval) or `at` (a time)"
        end
      end

      # Never invoked, since it observes nothing.
      def call(_context)
        Outcome.continue([])
      end
    end
  end
end
