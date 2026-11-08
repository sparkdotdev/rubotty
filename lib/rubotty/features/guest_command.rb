# frozen_string_literal: true

require "securerandom"
require "shellwords"

module Rubotty
  module Features
    # The /guest chat command: mint a guest invite from inside a bridged room, the
    # same operation the dashboard's guest invite form performs
    # ({ControlPlane::GuestInvites#issue}). Usage: /guest <nickname> [duration].
    #
    # One free-text argument, not one per field, because Discord only round-trips
    # a slash invocation losslessly when there is exactly one. Reuses
    # {Features::GuestPortal.feature_name} deliberately, so one feature_settings row
    # governs both the guest endpoint and this command (why it's not in {Catalog.classes}).
    class GuestCommand < Base
      include AdapterLookup

      COMMAND = "guest"
      NOTICE_NAME = "rubotty"

      USAGE = "Usage: /guest <nickname> [duration], e.g. /guest Sam 2h " \
              '(default 24h; quote a multi-word nickname, e.g. "Jane Doe").'

      # Mirrors the dashboard guest form's own 24-hour default.
      DEFAULT_TTL_SECONDS = 24 * 3600

      def self.feature_name = Features::GuestPortal.feature_name

      def self.default_enabled? = false

      def self.observes = %i[chat]

      # @param topology [Core::Topology] only to construct the standalone default ephemeral
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}]
      # @param guest_invites [ControlPlane::GuestInvites, nil] the operations
      #   service; nil (no control plane) makes the feature a no-op
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on
      #   time; without one the durable row is swept on the next boot
      # @param env [Hash] where GUEST_PORTAL_URL is read from; injectable for tests
      def initialize(topology:, adapters:, logger:, guest_invites: nil, ephemeral: nil, cleanup: nil, env: ENV)
        super()
        @adapters = adapters
        @logger = logger
        @guest_invites = guest_invites
        @cleanup = cleanup
        @env = env
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real /guest invocation instead of relaying it.
        raw = command_text(context)
        return Outcome.continue([]) if raw.nil?

        return refuse_unconfigured(context) if @guest_invites.nil? || context.community.nil?

        handle_invite(context, raw)
        # Swallowed either way: the bare /guest is never relayed as content.
        Outcome.halt([])
      end

      private

      # Recognised as /guest but nothing here can act on it: no operations
      # service wired, or no community resolved for this channel.
      def refuse_unconfigured(context)
        acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      # The raw text after "/guest ", or nil when this message is not the guest
      # command at all.
      def command_text(context)
        word, words = CommandWord.parse(context)
        return nil unless word == COMMAND

        words.join(" ")
      end

      def handle_invite(context, raw)
        community = @guest_invites.community_by_id(context.community.id)
        room = community && @guest_invites.room_for_endpoint_key(
          community: community, endpoint_key: context.channel.endpoint_key
        )
        if community.nil? || room.nil?
          logger.warn { "guest: could not resolve a room for #{context.message.origin.id}" }
          acknowledge(context, "Could not resolve this room; run /guest from inside a bridged channel.")
          return
        end

        tokens = parse_tokens(raw)
        if tokens.nil?
          acknowledge(context, "Could not parse that; check your quoting. #{USAGE}")
          return
        elsif tokens.empty?
          acknowledge(context, USAGE)
          return
        elsif tokens.size > 2
          acknowledge(context, "Quote a multi-word nickname, e.g. \"Jane Doe\" 2h. #{USAGE}")
          return
        end

        nickname, duration_token = tokens
        ttl_seconds = resolve_ttl(duration_token)
        if ttl_seconds.nil?
          acknowledge(context, "Could not read that duration, try 2h, 45m or 1d. #{USAGE}")
          return
        end

        issued = @guest_invites.issue(
          community: community, room: room, nickname: nickname, ttl_seconds: ttl_seconds,
          created_by: issuer_label(context), as: role_of(context)
        )
        acknowledge(context, success_reply(issued, ttl_seconds))
      rescue ControlPlane::GuestInvites::Invalid => e
        acknowledge(context, e.message)
      end

      # Shellwords-split the free-text argument, so a quoted value keeps its
      # internal space. Returns nil for text that cannot be tokenised at all (an
      # unmatched quote), never raises.
      def parse_tokens(raw)
        Shellwords.split(raw.to_s)
      rescue ArgumentError
        nil
      end

      # +DEFAULT_TTL_SECONDS+ when no duration was typed, the parsed duration, or
      # nil for one that could not be read at all: an operator who typed a
      # duration and got it wrong should be told.
      def resolve_ttl(duration_token)
        return DEFAULT_TTL_SECONDS if duration_token.nil?

        seconds = Core::Warnings.duration_seconds(duration_token)
        seconds&.positive? ? seconds : nil
      end

      # Whether the asker is an operator in this scope, which
      # {ControlPlane::GuestInvites#issue} enforces against the room's
      # who_can_invite. Fails closed: an unresolvable asker counts as a member.
      def role_of(context)
        directory = context.operators
        author = context.message.author
        return :member if directory.nil? || author.nil?

        resolved = directory.resolve(context.message.origin.adapter_name, author.native_id,
                                     username: author.username)
        resolved ? :operator : :member
      rescue StandardError => e
        logger.warn { "guest: role_of failed: #{e.class}: #{e.message}" }
        :member
      end

      def issuer_label(context)
        author = context.message.author
        return context.message.origin.adapter_name.to_s if author.nil?

        handle = presence(author.username) || author.native_id.to_s
        "#{context.message.origin.adapter_name}:#{handle}"
      end

      # The success reply. Worded so the link is unmistakably a one-time
      # credential that should go to the guest privately: the reply is public in
      # the room until it self-deletes, and the token is not recoverable after it.
      def success_reply(issued, ttl_seconds)
        [
          "Guest invite for #{issued.invite.nickname}, valid #{human_duration(ttl_seconds)}: " \
            "#{guest_link(issued.token)}",
          "One-time credential, shown here only once: send it to your guest directly. " \
            "Don't post it anywhere public; whoever holds it can join as them."
        ].join("\n")
      end

      # The full guest link for a freshly issued token, mirroring the dashboard's
      # own +guest_link+ helper. GUEST_PORTAL_URL names the public base the portal
      # is served at, read from the environment the same way both web surfaces do.
      def guest_link(token)
        base = @env["GUEST_PORTAL_URL"].to_s.sub(%r{/+\z}, "")
        "#{base}/g/#{token}"
      end

      # "2h" / "45m" / "1d", the same compact vocabulary {Core::Warnings}'s own
      # acknowledgements and /watch use.
      def human_duration(seconds)
        seconds = seconds.to_i
        seconds = 0 if seconds.negative?
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end

      # A self-deleting acknowledgement to the channel the command came from,
      # paired with the invocation so the exchange disappears together. Never
      # raises: a lost reply must not derail the pipeline.
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
        logger.warn { "guest: could not post a reply: #{e.message}" }
        nil
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
