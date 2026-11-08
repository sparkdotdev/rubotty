# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Keeps input only in rooms that opted in, then queues an offline room
    # summary when somebody asks. Scheduled delivery is driven by ::Rubotty::RoomSummaries::Service.
    class RoomSummaries < Base
      COMMAND = "summary"
      NOTICE_NAME = "rubotty"

      def self.feature_name = ::Rubotty::RoomSummaries::Service::FEATURE

      def self.description = "Posts a short room summary on command or on a cadence."

      # In dm mode nothing is consumed, so the thirty day backstop is what
      # bounds the transcript rather than the next summary.
      def self.retention_notice
        "Message text is kept for this room until its next successful summary, then removed. " \
          "In dm mode no summary consumes it, so it is kept for up to 30 days instead."
      end

      def self.default_enabled? = false

      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field :mode, :string, default: "command", one_of: ::Rubotty::RoomSummaries::Service::ALL_MODES,
                       desc: "command answers /summary; daily/weekly/monthly post on a cadence; " \
                             "count posts every message_threshold messages; dm answers anybody's " \
                             "/summary privately over a fixed 14 day window, posting nothing"
          field :weekday, :string, default: ::Rubotty::RoomSummaries::Service::DEFAULT_WEEKDAY,
                          one_of: ::Rubotty::RoomSummaries::Service::WEEKDAYS,
                          desc: "which day weekly mode posts on"
          field :day_of_month, :integer, default: ::Rubotty::RoomSummaries::Service::DEFAULT_DAY_OF_MONTH,
                               desc: "which calendar day (1-28) monthly mode posts on" do |value, path|
            "#{path}: must be between 1 and 28" unless (1..28).cover?(value)
          end
          field :min_messages, :integer, default: 0,
                               desc: "for daily/weekly/monthly, skip a cycle unless at least this many " \
                                     "messages arrived since the last summary"
          field :message_threshold, :integer, default: ::Rubotty::RoomSummaries::Service::DEFAULT_MESSAGE_THRESHOLD,
                                     desc: "in count mode, post a summary every this many messages"
          field :pin, :boolean, default: false,
                       desc: "pin the new summary and unpin rubotty's previous one, where the platform supports it"
        end
      end

      def initialize(topology:, adapters:, logger:, summaries: nil, ephemeral: nil, cleanup: nil)
        @logger = logger
        @summaries = summaries
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        return handle_command(context) if command?(context)

        @summaries&.record(context)
        Outcome.continue([])
      end

      private

      def handle_command(context)
        return Outcome.halt([]) if @summaries.nil?

        case mode(context)
        when "daily"
          acknowledge(context, "This room posts a summary each day.")
        when "weekly"
          acknowledge(context, "This room posts a summary each week.")
        when "monthly"
          acknowledge(context, "This room posts a summary each month.")
        when "count"
          acknowledge(context, "This room posts a summary every #{message_threshold(context)} messages.")
        when ::Rubotty::RoomSummaries::Service::DM_MODE
          # No pending? gate: this reads the last fourteen days whole rather
          # than what is left since the room's last posted summary, so "nothing
          # pending" is not the same question and would refuse a fair ask.
          acknowledge(context, dm_acknowledgement_for(@summaries.enqueue_dm(context)))
        when "command"
          return Outcome.halt([]) unless @summaries.pending?(context)

          result = @summaries.enqueue_command(context)
          acknowledge(context, acknowledgement_for(result))
        end
        Outcome.halt([])
      rescue StandardError => e
        logger.warn { "room summaries: could not handle /#{COMMAND}: #{e.class}: #{e.message}" }
        acknowledge(context, "Could not make a room summary right now.")
        Outcome.halt([])
      end

      # The room only ever learns that somebody asked, never what they got: the
      # summary itself goes to them privately, and a failure to reach them is
      # said later by the service, which is what knows whether the DM landed.
      def dm_acknowledgement_for(result)
        case result
        when :queued then "Sending you a summary of the last 14 days by DM."
        when :unconfigured then "Room summaries are not configured on this bridge."
        else "Could not make a room summary right now."
        end
      end

      def acknowledgement_for(result)
        case result
        when :queued then "Preparing a room summary."
        when :unconfigured then "Room summaries are not configured on this bridge."
        else "Could not queue a room summary right now."
        end
      end

      def command?(context)
        word, = CommandWord.parse(context)
        word == COMMAND
      end

      def mode(context)
        value = context.config.is_a?(Hash) ? (context.config[:mode] || context.config["mode"]) : nil
        ::Rubotty::RoomSummaries::Service::ALL_MODES.include?(value.to_s) ? value.to_s : "command"
      end

      def message_threshold(context)
        config = context.config
        value = config.is_a?(Hash) ? (config[:message_threshold] || config["message_threshold"]) : nil
        value.to_i.positive? ? value.to_i : ::Rubotty::RoomSummaries::Service::DEFAULT_MESSAGE_THRESHOLD
      end

      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text), name: NOTICE_NAME,
          delete_after: delay, also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
      rescue StandardError => e
        logger.warn { "room summaries: could not acknowledge a command: #{e.message}" }
      end
    end
  end
end
