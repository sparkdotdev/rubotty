# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The in-chat face of the operator request and approval flow: a thin chat
    # interface over {ControlPlane::OperatorFlow}. `/operator request` asks to
    # become an operator; `approve <id>`, `deny <id>` and `list` are operators
    # only, and answer anyone else with the requirement, nothing more. Every
    # recognised command halts the pipeline.
    class OperatorRequests < Base
      include AdapterLookup

      COMMAND = "operator"
      DEFAULT_NAME = "operators"

      # How long the "New operator request" notice lives in the notify room.
      NOTIFY_TTL_FIELD = :notify_ttl_seconds

      # A week: unlike an acknowledgement of something somebody just typed, this
      # names work an operator still has to do, so it outlives a holiday weekend
      # and then goes, since /operator list still holds anything undecided.
      DEFAULT_NOTIFY_TTL_SECONDS = 604_800

      # Said back to anyone who is not an operator, here and nowhere else: it names
      # the requirement, never who meets it or what community they are in.
      NOT_AN_OPERATOR = "You don't have permission to use that command: it needs operator standing."

      def self.feature_name = "operator_requests"

      def self.description = "Lets a member request operator status; operators approve or deny it."

      # Without a control plane there is no community to act in, so it is inert.
      def self.default_enabled? = false

      # A request or an approval is something a person just typed, so chat only.
      def self.observes = %i[chat]

      # The per-scope config shape, for the dashboard and loader.
      def self.config_schema
        Config::Schema.define do
          field :name, :string, default: DEFAULT_NAME
          field :notify_room, :string,
                desc: "room key of the operator channel new requests are posted to"
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                desc: "seconds an /operator reply lives before it self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /operator invocation itself is removed together with its reply"
          field NOTIFY_TTL_FIELD, :integer, default: DEFAULT_NOTIFY_TTL_SECONDS,
                desc: "seconds a new-request notice lives in the notify room before it " \
                      "self-deletes. 0 leaves it in place."
        end
      end

      # @param topology [Core::Topology] only to construct the default ephemeral primitive
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param operator_flow [ControlPlane::OperatorFlow, nil] the operations
      #   service; nil (no control plane) makes the feature a no-op
      # @param ephemeral [Core::EphemeralMessage, nil] posts acknowledgements and the operator notification
      # @param cleanup [Core::Scheduler, nil] the in-process fast path for an ack's
      #   self-delete; without one the durable backstop row is swept on next boot
      # @param name [String] fallback sender label for the bot's posts
      def initialize(topology:, adapters:, logger:, operator_flow: nil,
                     ephemeral: nil, cleanup: nil, name: DEFAULT_NAME)
        super()
        @adapters = adapters
        @logger = logger
        @operator_flow = operator_flow
        @cleanup = cleanup
        @name = name
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        # The word is read BEFORE the service/community check, so an unconfigured
        # deployment refuses a real /operator invocation instead of relaying it.
        command = parse(context)
        return Outcome.continue([]) if command.nil?

        return refuse_unconfigured(context) if @operator_flow.nil? || context.community.nil?

        handle(context, command)
        # Swallowed either way, so the bare `/operator ...` is never relayed.
        Outcome.halt([])
      end

      private

      # Recognised as `/operator ...` but nothing here can act on it: no operations
      # service wired, or no community resolved for this channel. Answered rather
      # than relayed, and the wording never distinguishes the two.
      def refuse_unconfigured(context)
        operator_ack(context, "Sorry, /#{COMMAND} is not available on this bridge.")
        Outcome.halt([])
      end

      # Parse `<prefix>operator <sub> <args...>` into [sub, args], or nil when the
      # message is not an operator command. A bare `<prefix>operator` defaults to
      # the request subcommand.
      def parse(context)
        head, words = CommandWord.parse(context)
        return nil unless head == COMMAND

        sub = (words.first || "request").downcase
        [sub, words[1..] || []]
      end

      def handle(context, (sub, args))
        case sub
        when "request" then handle_request(context)
        when "approve" then handle_decision(context, args, grant: true)
        when "deny"    then handle_decision(context, args, grant: false)
        when "list"    then handle_list(context)
        else
          operator_ack(context, "Unknown operator command #{sub.inspect}. Try request, approve, deny or list.")
        end
      end

      def handle_request(context)
        author = context.message.author
        if author.nil? || author.native_id.nil?
          @logger.debug { "operator request with no identifiable author on #{context.message.origin.id}" }
          return
        end

        result = @operator_flow.request(
          community_id: context.community.id,
          adapter: context.message.origin.adapter_name,
          native_id: author.native_id,
          username: author.username,
          display: author.any_name
        )

        case result.status
        when :created
          notify_operators(context, result.request)
          ack(context, "Your operator request (##{result.request.id}) is in. " \
                       "A current operator will review it.")
        when :duplicate
          ack(context, "You already have a pending operator request (##{result.request&.id}). " \
                       "Hang tight; an operator will get to it.")
        when :already_operator
          ack(context, "You are already an operator of this community.")
        else
          @logger.warn { "operator request refused (#{result.status}) on #{context.message.origin.id}" }
          ack(context, "I could not take that request. Try again, or ask an operator directly.")
        end
      end

      def handle_decision(context, args, grant:)
        approver = current_operator(context)
        # Fails closed, and says so: a stranger already knows the command
        # exists (they just typed it), so naming the requirement costs nothing
        # and saying nothing at all reads as the bot being broken.
        if approver.nil?
          @logger.warn do
            "refused operator #{grant ? "approve" : "deny"} from " \
              "#{context.message.author&.any_name} on #{context.message.origin.id}"
          end
          operator_ack(context, NOT_AN_OPERATOR)
          return
        end

        request = target_request(context, args)
        if request.nil?
          operator_ack(context, "No pending request ##{args.first} in this community.")
          return
        end

        result = grant ? @operator_flow.approve(request: request, approver: approver)
                       : @operator_flow.deny(request: request, approver: approver)
        acknowledge_decision(context, result, grant: grant)
      end

      def acknowledge_decision(context, result, grant:)
        case result.status
        when :approved
          operator_ack(context, approval_text(context, result))
        when :denied
          operator_ack(context, "Denied request ##{result.request.id} from #{requester_label(result.request)}.")
        when :not_pending
          operator_ack(context, "Request ##{result.request&.id} is not pending; nothing to #{grant ? "approve" : "deny"}.")
        when :forbidden
          @logger.warn { "operator decision forbidden on #{context.message.origin.id}" }
        else
          operator_ack(context, "Could not #{grant ? "approve" : "deny"} that request (#{result.status}).")
        end
      end

      # The approval acknowledgement, and the one thing a new operator has to
      # do before anything can reach them. Only added when a real DM to them
      # was actually refused, so it is never noise for somebody already
      # reachable, and the grant itself stands either way.
      def approval_text(context, result)
        granted = "Approved request ##{result.request.id}: " \
                  "#{requester_label(result.request)} is now an operator."
        return granted unless welcome_refused?(context, result.request)

        "#{granted} I cannot message them privately yet, so nothing will reach them: " \
          "they need to open a private chat with me and send /start, once."
      end

      # DM the new operator their welcome, which doubles as the reachability
      # check. The grant is already committed and nothing here can undo it, so
      # every way this can go wrong ends as "reachable, do not nag".
      def welcome_refused?(context, request)
        reachability.probe(
          community_id: context.community.id, adapter: request.adapter,
          native_id: request.requester_native_id, text: welcome_text(context)
        ) == :refused
      rescue StandardError => e
        @logger.warn { "operator request: could not check whether a new operator can be DMed: #{e.message}" }
        false
      end

      def welcome_text(context)
        "You are now an operator of #{context.community.name}. " \
          "Anything that needs an operator's eye reaches you here, in this chat."
      end

      def reachability
        @reachability ||= ControlPlane::OperatorReachability.new(
          models: @operator_flow.models, adapters: @adapters, logger: @logger
        )
      end

      def handle_list(context)
        approver = current_operator(context)
        if approver.nil?
          operator_ack(context, NOT_AN_OPERATOR)
          return
        end

        pending = @operator_flow.pending(community_id: context.community.id)
        if pending.empty?
          operator_ack(context, "No pending operator requests.")
          return
        end

        lines = pending.map { |req| "##{req.id} #{requester_label(req)}" }
        operator_ack(context, "Pending operator requests:\n#{lines.join("\n")}\n" \
                              "Approve with #{prefix_for(context)}#{COMMAND} approve <id>.")
      end

      # Tell the community's current operators about a new request, posted to every
      # endpoint of the configured `notify_room`; with none configured the request
      # is still recorded and picked up with `list`. Never raises.
      def notify_operators(context, request)
        room = notify_room(context)
        prefix = prefix_for(context)
        body = "New operator request ##{request.id} from #{requester_label(request)} " \
               "in #{context.community.name}. " \
               "#{prefix}#{COMMAND} approve #{request.id}  or  #{prefix}#{COMMAND} deny #{request.id}"

        if room.nil? || room.endpoints.empty?
          @logger.info do
            "operator request ##{request.id} recorded; no notify_room configured, " \
              "operators can review with '#{prefix}#{COMMAND} list'"
          end
          return
        end

        # Left to the durable sweep rather than an in-process timer: nothing
        # should hold a week-long callback open to remove one notice.
        @ephemeral.post(endpoints: room.endpoints, body: Core::RichText.plain(body),
                        name: name_for(context.config), delete_after: notify_ttl(context.config))
      rescue StandardError => e
        @logger.warn { "operator request: could not notify operators: #{e.message}" }
      end

      # A room key from config is unique only within its own community, so it is
      # resolved against that community's rooms and nowhere else. With no
      # community there is nothing to scope by, so it fails closed.
      def notify_room(context)
        community = context.community
        return nil if community.nil?

        key = config_value(context.config, :notify_room)
        return nil if key.nil? || key.to_s.strip.empty?

        community.rooms.find { |room| room.id == key.to_s }
      end

      # The operator behind the message author in this community, or nil. The
      # permission gate for approve, deny and list, and it fails closed.
      def current_operator(context)
        author = context.message.author
        return nil if author.nil? || author.native_id.nil?

        @operator_flow.resolve_operator(
          community_id: context.community.id,
          adapter: context.message.origin.adapter_name,
          native_id: author.native_id,
          username: author.username
        )
      end

      def target_request(context, args)
        id = args.first
        return nil if id.nil? || !id.to_s.match?(/\A\d+\z/)

        request = @operator_flow.find_request(community_id: context.community.id, id: id)
        return nil if request.nil? || request.state != "pending"

        request
      end

      def requester_label(request)
        return "someone" if request.nil?

        handle = presence(request.requester_username)
        display = presence(request.requester_display)
        base = display || (handle && "@#{handle}") || request.requester_native_id.to_s
        handle && display ? "#{display} (@#{handle})" : base
      end

      # A self-deleting acknowledgement to the channel the command came from,
      # taking the invocation with it on the shared terms every command uses.
      def ack(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin], body: Core::RichText.plain(text),
          name: name_for(context.config), delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        @logger.warn { "operator request: could not acknowledge: #{e.message}" }
        nil
      end
      alias operator_ack ack

      def prefixes_for(context)
        context.command_prefixes
      end

      # The representative marker for help text: the first configured, "/" by default.
      def prefix_for(context)
        prefixes_for(context).primary
      end

      def name_for(config)
        value = config_value(config, :name)
        value.nil? || value.to_s.strip.empty? ? @name : value.to_s
      end

      # How long a new-request notice sits in the notify room.
      def notify_ttl(config)
        duration(config_value(config, NOTIFY_TTL_FIELD), default: DEFAULT_NOTIFY_TTL_SECONDS)
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def duration(value, default:)
        return default if value.nil?
        return value.to_i if value.is_a?(Numeric)
        return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

        default
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
