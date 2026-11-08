# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The /remind chat command: an operator posts an event's reminder into
    # its own room right now, rather than waiting on the automated ladder
    # {Events::Reminders} drives. Reuses {Events::Announcer#announce_reminder_now},
    # which in turn reuses the exact same message-building the automated DM
    # ladder posts through, so there is no second template to drift out of
    # sync. Shares {Features::Events.feature_name} and is deliberately excluded
    # from {Catalog.classes}, where {Features::Events} already carries "events".
    class EventRemindCommand < Base
      COMMAND = "remind"
      NOTICE_NAME = "rubotty"
      USAGE = "Usage: /remind <event id>"

      def self.feature_name = Features::Events.feature_name

      def self.default_enabled? = false

      def self.observes = %i[chat]

      # @param topology [Core::Topology] only to construct the standalone
      #   default ephemeral; the runtime injects a shared one
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param event_scheduling [ControlPlane::EventScheduling, nil] resolves
      #   the event by id; nil (no control plane) makes the feature a no-op
      # @param announcer [Events::Announcer, nil] posts via #announce_reminder_now
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires self-delete; else backstop sweeps at next boot
      def initialize(topology:, adapters:, logger:, event_scheduling: nil, announcer: nil, ephemeral: nil,
                     cleanup: nil)
        super()
        @logger = logger
        @event_scheduling = event_scheduling
        @announcer = announcer
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real /remind invocation instead of relaying it.
        raw = command_fields(context)
        return Outcome.continue([]) if raw.nil?

        return refuse_unconfigured(context) if @event_scheduling.nil? || @announcer.nil? || context.community.nil?

        handle_remind(context, raw)
        Outcome.halt([])
      end

      private

      # Recognised as /remind but nothing here can act on it: no operations
      # service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      def command_fields(context)
        word, arguments = CommandWord.parse(context)
        return nil unless word == COMMAND

        arguments.first
      end

      def handle_remind(context, id_text)
        unless operator?(context)
          acknowledge(context, "Only a room operator can trigger a reminder.")
          return
        end

        event = event_by_id(context, id_text)
        if event.nil?
          acknowledge(context, "Could not find that event here. #{USAGE}")
          return
        end

        unless event.scheduled?
          acknowledge(context, "Event ##{event.id} is #{event.status}; nothing to remind.")
          return
        end

        posted = @announcer.announce_reminder_now(event)
        acknowledge(
          context,
          posted ? "Posted a reminder for ##{event.id}: #{event.title}." \
                 : "Could not post a reminder for ##{event.id}: its room has no live endpoints."
        )
      end

      def event_by_id(context, id_text)
        id = Integer(id_text.to_s, exception: false)
        return nil if id.nil?

        @event_scheduling.find(community: context.community, id: id)
      end

      # Fail closed: an unresolvable directory or author is treated as a
      # regular member, the same posture {EventCommand#role_of} takes.
      def operator?(context)
        directory = context.operators
        author = context.message.author
        return false if directory.nil? || author.nil?

        !!directory.resolve(context.message.origin.adapter_name, author.native_id,
                            username: author.username)
      rescue StandardError => e
        logger.warn { "event_remind: operator? failed: #{e.class}: #{e.message}" }
        false
      end

      # A self-deleting acknowledgement to the channel the command came from.
      # Never raises: a lost reply must not derail the pipeline.
      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: NOTICE_NAME, delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "remind: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
