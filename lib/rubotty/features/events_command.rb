# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The /events chat command: bare, lists this room's upcoming events;
    # pointed at an id, shows who's signed up for that one. The read-only
    # counterpart to {EventCommand} (which creates one) and {EventRsvp}
    # (which records a response); everyone's to run, the same as looking at
    # an already-posted card. Shares {Features::Events.feature_name} and is
    # deliberately excluded from {Catalog.classes}, where {Features::Events}
    # already carries "events".
    class EventsCommand < Base
      COMMAND = "events"
      NOTICE_NAME = "rubotty"

      def self.feature_name = Features::Events.feature_name

      def self.default_enabled? = false

      def self.observes = %i[chat]

      # @param topology [Core::Topology] only to construct the standalone default ephemeral
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param event_scheduling [ControlPlane::EventScheduling, nil] resolves the
      #   room and looks events up; nil (no control plane) is a no-op
      # @param announcer [Events::Announcer, nil] {Events::Announcer#roster},
      #   the same tally a card's own summary line folds RSVPs through
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
        # deployment refuses a real /events invocation instead of relaying it.
        raw = command_fields(context)
        return Outcome.continue([]) if raw.nil?

        return refuse_unconfigured(context) if @event_scheduling.nil? || @announcer.nil? || context.community.nil?

        handle_events(context, raw)
        Outcome.halt([])
      end

      private

      # Recognised as /events but nothing here can act on it: no operations
      # service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      def command_fields(context)
        word, arguments = CommandWord.parse(context)
        return nil unless word == COMMAND

        arguments.join(" ").strip
      end

      def handle_events(context, raw)
        if raw.empty?
          list_upcoming(context)
        else
          show_one(context, raw)
        end
      end

      def list_upcoming(context)
        community = @event_scheduling.community_by_id(context.community.id)
        room = community && @event_scheduling.room_for_endpoint_key(
          community: community, endpoint_key: context.channel.endpoint_key
        )
        if community.nil? || room.nil?
          logger.warn { "events: could not resolve a room for #{context.message.origin.id}" }
          acknowledge(context, "This room isn't linked to a community yet, so /#{COMMAND} can't run here.")
          return
        end

        events = @event_scheduling.upcoming(community: community, room: room)
        if events.empty?
          acknowledge(context, "No upcoming events in this room.")
          return
        end

        lines = ["Upcoming events:"] + events.map { |event| summary_line(event) }
        acknowledge(context, lines.join("\n"))
      end

      def show_one(context, id_text)
        event = event_by_id(context, id_text)
        if event.nil?
          acknowledge(context, "Could not find that event here. Usage: /events [event id]")
          return
        end

        acknowledge(context, roster_text(context, event))
      end

      def summary_line(event) = "##{event.id}: #{event.title} at #{event.starts_at.strftime("%Y-%m-%d %H:%M UTC")}"

      def roster_text(context, event)
        lines = [summary_line(event)]
        if event.rsvp_none?
          lines << "RSVP is not enabled for this event."
          return lines.join("\n")
        end

        roster = @announcer.roster(event)
        platform = context.message.origin.adapter_name.to_s
        if event.rsvp_affirm?
          lines << Rubotty::Events::RsvpLabels.attending_line(
            Core::VoteRoster.long(roster["in"], on_platform: platform)
          )
        else
          Rubotty::Events::RsvpLabels::FULL.each do |response, label|
            lines << "#{label}: #{names_for(roster[response], platform)}"
          end
        end
        lines.join("\n")
      end

      def names_for(voters, platform)
        Core::VoteRoster.long(voters, on_platform: platform) || Rubotty::Events::RsvpLabels::NOBODY
      end

      def event_by_id(context, id_text)
        id = Integer(id_text.to_s, exception: false)
        return nil if id.nil?

        @event_scheduling.find(community: context.community, id: id)
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
        logger.warn { "events: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
