# frozen_string_literal: true

module Rubotty
  module Features
    # "/identify-topic <name>": manual fallback for a room or topic auto-discovery never
    # picked up or mis-named. {.always_enabled?} makes {Pipeline#enabled?} run this before
    # feature_settings is consulted, since the room it's a fallback for isn't configured
    # yet. An operator's request takes effect immediately; anyone else's is written to the
    # same channel row flagged +suggested+, for approval from the Rooms board.
    class IdentifyTopic < Base
      NOTICE_NAME = "rubotty"

      def self.feature_name = "identify_topic"

      def self.description = "/identify-topic <name>: name this room/topic if it was never auto-discovered."

      def self.default_enabled? = true

      def self.always_enabled? = true

      def self.observes = %i[chat]

      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on time
      # @param channel_discovery [ControlPlane::ChannelDiscovery, nil] the upsert
      #   target; nil without a control plane, which makes the command a no-op
      def initialize(topology:, adapters:, logger:, ephemeral: nil, cleanup: nil, channel_discovery: nil)
        super()
        @adapters = adapters
        @logger = logger
        @cleanup = cleanup
        @channel_discovery = channel_discovery
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        name = identify_topic_name(context)
        return Outcome.continue([]) if name.nil?

        acknowledge(context, safe_reply_for(context, name))
        Outcome.halt([])
      end

      private

      # {#reply_for} does real DB access through {ControlPlane::ChannelDiscovery},
      # so a raise there would escape {#call} and leave the asker with silence.
      def safe_reply_for(context, name)
        reply_for(context, name)
      rescue StandardError => e
        logger.warn { "identify_topic: reply_for failed: #{e.class}: #{e.message}" }
        "Sorry, something went wrong identifying this channel. Try again, or check the logs."
      end

      # nil when this is not the command, "" when it is the command with a blank
      # name. Read through {Core::CommandRegistry.canonical} so the underscored
      # "/identify_topic" Telegram's "/" menu offers counts too.
      def identify_topic_name(context)
        body = context.command_prefixes.strip(context.message.body.text)
        return nil if body.nil?

        words = body.to_s.split(/\s+/)
        return nil if words.empty?

        word = Core::CommandRegistry.canonical(words.first)
        return nil unless word == "identify-topic"

        words[1..].to_a.join(" ").strip
      end

      def reply_for(context, name)
        return "Usage: /identify-topic <name>" if name.empty?
        return "Sorry, I can't identify channels here (no control plane connected)." if @channel_discovery.nil?

        community = context.community
        return "Sorry, I can't identify channels here (this room resolves to no community)." if community.nil?

        operator = moderator?(context)
        channel = @channel_discovery.identify_known(
          community_id: community.id, endpoint_key: context.message.origin.id,
          name: name, operator: operator
        )
        return "Sorry, I couldn't identify this channel." if channel.nil?

        if operator
          "Identified this room/topic as #{name.inspect}."
        else
          "Suggested #{name.inspect} for this room/topic. An operator needs to approve it from the Rooms board " \
            "before it counts as identified."
        end
      end

      # Whether the asker is an operator in this scope. A missing directory or
      # author counts as a regular member; a raise is left to {#safe_reply_for},
      # since a broken lookup must not read as "you are not an operator" and
      # quietly file a suggestion instead.
      def moderator?(context)
        directory = context.operators
        author = context.message.author
        return false if directory.nil? || author.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      end

      # Post +text+ to the issuer's endpoint as the bot, self-deleting after the
      # standard TTL and taking the invocation with it. context.config is {} for
      # an unresolved scope, which Core::CommandAck reads as its own defaults.
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
        logger.warn { "identify_topic: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
