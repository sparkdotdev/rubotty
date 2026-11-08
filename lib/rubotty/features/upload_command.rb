# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The /upload chat command: hand rubotty a file that is too big for the
    # room you are standing in. rubotty mints a one-time ticket, DMs its link
    # to whoever typed the command (a write capability into somebody else's
    # community should never go into the room), and posts the file they pick
    # back into the room. It shares {Features::FileRehosting}'s feature_name
    # deliberately, so one feature_settings row governs both, which is also
    # why it is not listed separately in {Catalog.classes}.
    class UploadCommand < Base
      include AdapterLookup

      COMMAND = "upload"
      NOTICE_NAME = "rubotty"

      def self.feature_name = Features::FileRehosting.feature_name

      def self.default_enabled? = false

      # A command is something a person just typed, so chat only.
      def self.observes = %i[chat]

      # @param topology [Core::Topology] only to construct the default ephemeral primitive
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map,
      #   used both for the reply and for the DM
      # @param tickets [ControlPlane::UploadTickets, nil] the operations service.
      #   Nil (no control plane) makes the feature a no-op.
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete
      # @param env [Hash] where GUEST_PORTAL_URL is read from, for the full link
      def initialize(topology:, adapters:, logger:, tickets: nil, ephemeral: nil, cleanup: nil, env: ENV)
        super()
        @adapters = adapters
        @logger = logger
        @tickets = tickets
        @cleanup = cleanup
        @env = env
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real /upload invocation instead of relaying it.
        return Outcome.continue([]) if command_text(context).nil?

        if @tickets.nil? || context.community.nil? || !Features::FileRehosting.upload_command_enabled?(context.config)
          return refuse_unconfigured(context)
        end

        handle(context)
        # Swallowed either way: the bare /upload is never relayed as content.
        Outcome.halt([])
      end

      private

      # Recognised as /upload but nothing here can act on it: no operations
      # service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      # Whether this message is /upload, and the text after it. Uses the shared
      # prefix set, so it honours the same markers every other surface does.
      def command_text(context)
        word, words = CommandWord.parse(context)
        return nil unless word == COMMAND

        words.join(" ")
      end

      def handle(context)
        author = context.message.author
        if author.nil?
          acknowledge(context, "Could not tell who asked, so there is nobody to send the link to.")
          return
        end

        adapter = adapter_for(context.message.origin)
        unless adapter && adapter.supports_admin_dm?
          acknowledge(context, "rubotty cannot send you a direct message on #{platform_label(context)}, " \
                               "so there is nowhere private to put the upload link.")
          return
        end

        issued = @tickets.issue(
          community_id: context.community.id,
          room_key: room_key_for(context),
          endpoint_key: context.channel&.endpoint_key.to_s,
          adapter: context.message.origin.adapter_name,
          native_id: author.native_id,
          label: author.any_name
        )
        deliver(context, adapter, author, issued)
      rescue StandardError => e
        logger.warn { "upload: could not issue a ticket: #{e.class}: #{e.message}" }
        acknowledge(context, "Could not set up an upload just now; try again in a minute.")
      end

      def deliver(context, adapter, author, issued)
        sent = begin
          !!adapter.send_admin_dm(author.native_id, dm_text(issued))
        rescue StandardError => e
          logger.warn { "upload: DM failed: #{e.class}: #{e.message}" }
          false
        end

        if sent
          acknowledge(context, "Sent you a direct message with an upload link. It is good for " \
                               "#{minutes(issued)} minutes and works once.")
        else
          # The minted ticket reached nobody, so it is left to expire rather than reused.
          acknowledge(context, "Could not send you a direct message. Start a chat with the bot " \
                               "first, then run /upload again.")
        end
      end

      def dm_text(issued)
        [
          "Upload one or more files into your room here: #{upload_link(issued.token)}",
          "The link works once for the whole selection and expires in #{minutes(issued)} minutes. " \
            "Don't pass it on: whoever opens it can post files into that room as you."
        ].join("\n")
      end

      # The room the command was typed in, so the finished upload goes back there.
      def room_key_for(context)
        community = context.community
        return nil unless community.respond_to?(:room_key_of)

        community.room_key_of(context.channel&.endpoint_key)
      rescue StandardError
        nil
      end

      def upload_link(token)
        base = @env["GUEST_PORTAL_URL"].to_s.sub(%r{/+\z}, "")
        "#{base}/u/#{token}"
      end

      # Read off the row rather than the constant, so what somebody is told
      # matches what was minted.
      def minutes(issued)
        ticket = issued&.ticket
        return ControlPlane::UploadTickets::DEFAULT_TTL_SECONDS / 60 if ticket.nil?

        [((to_time(ticket.expires_at) - to_time(ticket.created_at)) / 60).round, 1].max
      end

      def to_time(value)
        return value if value.is_a?(Time)

        value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
      end

      def platform_label(context) = context.message.origin.adapter_name.to_s

      # A self-deleting acknowledgement in the channel the command came from, paired
      # with the invocation so the exchange disappears together. Never raises.
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
        logger.warn { "upload: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
