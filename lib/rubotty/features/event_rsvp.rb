# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Cross-platform RSVP: a card reaction and the /rsvp fallback (`/rsvp <event
    # id> yes|maybe|no|in`) both land in {Events::RsvpLedger}, which decides if a
    # response is legal against rsvp_mode. A reaction on a known card is always
    # swallowed, so unrelated reactions still reach {Bridge}'s aggregate mirror.
    # /rsvp takes an explicit event id, not a reply, so it still works once the
    # card scrolls out of view; a "cancel" reply on the card is the one reply read
    # here, via {CardCancellation}. Shares {Features::Events.feature_name} and
    # stays out of {Catalog.classes} like {EventCommand}.
    class EventRsvp < Base
      include CardCancellation

      COMMAND = "rsvp"
      NOTICE_NAME = "rubotty"
      USAGE = "Usage: /rsvp <event id> yes|maybe|no|in"

      def self.feature_name = Features::Events.feature_name

      def self.default_enabled? = false

      def self.observes = %i[chat reaction_add reaction_remove reaction_sync]

      # @param topology [Core::Topology] only to construct the standalone default ephemeral
      # @param event_scheduling [ControlPlane::EventScheduling, nil] resolves the
      #   /rsvp event id within the issuer's community; nil disables the feature
      # @param announcer [Events::Announcer, nil] the reverse card lookup and the
      #   live re-render once a response changes the tally
      # @param ledger [Events::RsvpLedger, nil] the write side, same control-plane database
      # @param ephemeral [Core::EphemeralMessage, nil] posts the /rsvp reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on time
      def initialize(topology:, adapters:, logger:, event_scheduling: nil, announcer: nil, ledger: nil,
                     ephemeral: nil, cleanup: nil)
        super()
        @logger = logger
        @event_scheduling = event_scheduling
        @announcer = announcer
        @ledger = ledger
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        case context.message.kind
        when :reaction_add, :reaction_remove, :reaction_sync
          # A reaction carries no command word to recognise, so an unconfigured
          # deployment has nothing to refuse; it just cannot see the tap.
          return Outcome.continue([]) if @ledger.nil? || @announcer.nil? || @event_scheduling.nil?

          handle_reaction(context)
        when :chat
          handle_chat(context)
        else
          Outcome.continue([])
        end
      end

      private

      def handle_chat(context)
        outcome = handle_cancel_reply(context)
        return outcome unless outcome.nil?

        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real /rsvp invocation instead of relaying it.
        args = command_args(context)
        return Outcome.continue([]) if args.nil?

        if @ledger.nil? || @announcer.nil? || @event_scheduling.nil? || context.community.nil?
          acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
          return Outcome.halt([])
        end

        handle_rsvp_command(context, args)
        Outcome.halt([])
      end

      # The words after "/rsvp ", or nil when this message is not the /rsvp
      # command at all.
      def command_args(context)
        word, arguments = CommandWord.parse(context)
        return nil unless word == COMMAND

        arguments
      end

      # nil hands the message on to the /rsvp command parser: no announcer to ask,
      # not a reply at all, a reply to something other than one of our own cards,
      # or a reply that does not ask to cancel.
      def handle_cancel_reply(context)
        return nil if @announcer.nil?

        message = context.message
        return nil if message.reply_to.nil?

        event = @announcer.event_for_card(message.reply_to)
        return nil if event.nil?

        text = message.body&.text.to_s.strip
        return nil if text.empty? || !cancel_reply?(context, text)

        handle_cancel(context, event)
      end

      # Checked ahead of #event.scheduled? so a duplicate cancel on an
      # already cancelled (or already past) event still gets a clear answer.
      def handle_cancel(context, event)
        unless may_cancel?(context, event)
          acknowledge(context, "Only event ##{event.id}'s creator or a room operator can cancel it.")
          return Outcome.halt([])
        end

        if event.scheduled?
          @event_scheduling.cancel(event: event)
          acknowledge(context, "Event ##{event.id}: #{event.title} canceled by #{cancel_actor_label(context)}.")
        else
          acknowledge(context, "Event ##{event.id}: #{event.title} is already #{event.cancelled? ? "canceled" : "over"}.")
        end
        Outcome.halt([])
      end

      def handle_reaction(context)
        message = context.message
        event = @announcer.event_for_card(message.ref)
        return Outcome.continue([]) if event.nil?

        if message.reaction_sync?
          # Same gap as PollSurface: an anonymous-reactions Telegram chat
          # reports its whole state with no author, so there is nobody to
          # record an RSVP against. Swallowed so it never reaches Bridge's
          # aggregate mirror as an ordinary reaction; /rsvp is the only way to answer here.
          logger.debug { "rsvp: an anonymous reaction synced on event #{event.id}, nobody to attribute it to" }
          return Outcome.halt([])
        end
        return Outcome.continue([]) if message.reaction.nil?

        apply_reaction(event, message)
        Outcome.halt([])
      end

      def apply_reaction(event, message)
        identity = identity_for(message.author)
        return if identity.nil?

        response = Rubotty::Events::RsvpReactions.response_for(event.rsvp_mode, message.reaction)
        return if response.nil?

        platform = message.origin.adapter_name.to_s
        changed =
          if message.kind == :reaction_add
            @ledger.record(event: event, identity: identity, platform: platform, response: response)
          else
            @ledger.clear(event: event, identity: identity, expected_response: response)
          end
        @announcer.refresh_rsvp(event) if changed
      rescue Rubotty::Events::RsvpLedger::Invalid => e
        logger.debug { "rsvp: ignored a reaction on event #{event.id}: #{e.message}" }
      end

      def handle_rsvp_command(context, args)
        id_text, response_text = args
        event = event_by_id(context, id_text)
        if event.nil?
          acknowledge(context, "Could not find that event here. #{USAGE}")
          return
        end

        identity = identity_for(context.message.author)
        if identity.nil?
          acknowledge(context, "Could not identify you for that RSVP.")
          return
        end

        response = @ledger.record(
          event: event, identity: identity, platform: context.message.origin.adapter_name.to_s,
          response: response_text
        )
        @announcer.refresh_rsvp(event)
        acknowledge(context, "Recorded ##{event.id} #{event.title}: #{response}.")
      rescue Rubotty::Events::RsvpLedger::Invalid => e
        acknowledge(context, "#{e.message} #{USAGE}")
      end

      def event_by_id(context, id_text)
        id = Integer(id_text.to_s, exception: false)
        return nil if id.nil?

        @event_scheduling.find(community: context.community, id: id)
      end

      def identity_for(author)
        return nil if author.nil?

        author.native_id || author.username
      end

      # The same "adapter:handle" shape EventCommand stamps created_by with,
      # so CardCancellation's creator check means the same thing at both ends.
      def issuer_label(context)
        author = context.message.author
        return context.message.origin.adapter_name.to_s if author.nil?

        handle = presence(author.username) || author.native_id.to_s
        "#{context.message.origin.adapter_name}:#{handle}"
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # A self-deleting acknowledgement to the channel the command came from.
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
        logger.warn { "rsvp: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
