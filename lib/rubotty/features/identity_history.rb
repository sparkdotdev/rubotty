# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Keeps every username, display name and bridged nickname a person has
    # worn in a community, each with the date range it was worn, instead of
    # just the current one (#1477). Off by default: this is only the flag
    # and the /identity command that reads it, the writing itself happens
    # outside the pipeline in ControlPlane::IdentityDirectory#touch and
    # ControlPlane::BridgedNicknames#set/#clear, gated on the same flag.
    class IdentityHistory < Base
      COMMAND = :identity
      COMMANDS = [COMMAND].freeze
      NOTICE_NAME = "identity"

      Target = Struct.new(:native_id, :adapter, :label, keyword_init: true)

      def self.feature_name = "identity_history"

      def self.description
        "Keeps every username, display name and bridged nickname a person has worn in this " \
          "community, with the date range each was worn. /identity (reply or handle) prints it."
      end

      def self.default_enabled? = false

      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                desc: "seconds an /identity reply lives before it self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /identity invocation itself is removed together with its reply"
        end
      end

      def self.retention_notice
        "Switching this on makes rubotty keep every USERNAME, DISPLAY NAME and BRIDGED NICKNAME a " \
          "person has worn in this community, each with the date range it was worn, instead of " \
          "only the current one. A closed entry (one superseded by a later rename) is purged " \
          "automatically after #{ControlPlane::IdentityDirectory::NAME_HISTORY_RETENTION / 86_400} days."
      end

      # @param identity_directory [ControlPlane::IdentityDirectory, nil] the
      #   username/display-name history reader; nil without a control plane,
      #   which is also when Router skips constructing this feature at all
      # @param bridged_nicknames [ControlPlane::BridgedNicknames, nil]
      def initialize(topology:, adapters:, logger:, identity_directory:, bridged_nicknames: nil,
                     ephemeral: nil, cleanup: nil)
        super()
        @adapters = adapters
        @logger = logger
        @identity_directory = identity_directory
        @bridged_nicknames = bridged_nicknames
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        message = context.message
        action, arguments = split_command(message.body.text, prefixes_for(context))
        return Outcome.continue([]) if action.nil?

        operator = resolve_operator(context)
        if operator.nil?
          acknowledge(context, "You don't have permission to use that command: it needs operator standing.")
          return Outcome.halt([])
        end

        target = resolve_target(context, arguments)
        if target.nil?
          acknowledge(
            context,
            "/identity needs either a reply to the person's message, or a handle: /identity <handle>."
          )
          return Outcome.halt([])
        end

        acknowledge(context, history_text(context, target))
        Outcome.halt([])
      end

      private

      def resolve_target(context, arguments)
        reply_author = context.message.reply_preview&.author
        if reply_author&.native_id
          adapter = context.message.origin.adapter_name
          return Target.new(native_id: reply_author.native_id, adapter: adapter, label: reply_author.any_name)
        end

        handle = arguments.first
        return nil if handle.nil? || @identity_directory.nil?

        adapter = context.message.origin.adapter_name
        native_id = @identity_directory.resolve_unique(
          community_id: context.community&.id, adapter: adapter, handle: handle
        )
        return nil if native_id.nil?

        Target.new(native_id: native_id, adapter: adapter, label: handle)
      end

      def history_text(context, target)
        community_id = context.community&.id
        lines = ["Name history for #{target.label}:"]
        lines.concat(name_history_lines(community_id, target))
        lines.concat(nickname_history_lines(community_id, target))
        lines.join("\n")
      end

      def name_history_lines(community_id, target)
        return ["No history kept."] if @identity_directory.nil? || community_id.nil?

        rows = @identity_directory.name_history(
          community_id: community_id, adapter: target.adapter, native_id: target.native_id
        )
        return ["No history kept for this person, either identity_history has never been on, " \
                "or this is the first time rubotty has seen them."] if rows.empty?

        rows.map do |row|
          parts = [row.username && "username #{row.username}", row.display_name && "display name #{row.display_name}"]
          "#{date_range(row.started_at, row.ended_at)}: #{parts.compact.join(', ')}"
        end
      end

      def nickname_history_lines(community_id, target)
        return [] if @bridged_nicknames.nil? || community_id.nil?

        person = @bridged_nicknames.person_for_identity(
          community_id: community_id, adapter: target.adapter, native_id: target.native_id
        )
        return [] if person.nil?

        rows = @bridged_nicknames.nickname_history(community_id: community_id, person_id: person.id)
        return [] if rows.empty?

        ["Bridged nicknames:"] + rows.map do |row|
          "#{date_range(row.started_at, row.ended_at)}: #{row.nickname} (#{row.adapter})"
        end
      end

      def date_range(started_at, ended_at)
        start_label = started_at.strftime("%Y-%m-%d")
        ended_at ? "#{start_label} to #{ended_at.strftime('%Y-%m-%d')}" : "#{start_label} to now"
      end

      # A self-deleting reply that takes the /identity invocation with it, on the
      # shared terms every other command surface uses.
      def acknowledge(context, text)
        delay = Core::CommandAck.ttl_seconds(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin],
          body: Core::RichText.plain(text),
          name: NOTICE_NAME,
          delete_after: delay,
          also_delete: Core::CommandAck.pair_with(context.message, context.config),
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        group
      rescue StandardError => e
        logger.warn { "identity_history: could not post the acknowledgement: #{e.message}" }
        nil
      end

      def resolve_operator(context)
        # This community's own directory and nothing else, so an unresolved
        # community resolves nobody rather than reading the merged one.
        directory = context.operators
        return nil if directory.nil?

        author = context.message.author
        return nil if author.nil? || author.native_id.nil?

        directory.resolve(context.message.origin.adapter_name, author.native_id, username: author.username)
      end

      def split_command(text, prefixes)
        body = prefixes.strip(text)
        return [nil, nil] if body.nil?

        words = body.to_s.split(/\s+/)
        return [nil, nil] if words.empty?

        word = words.first.split("@").first.to_s.downcase
        return [nil, nil] if word.empty?

        action = word.to_sym
        return [nil, nil] unless COMMANDS.include?(action)

        [action, words[1..] || []]
      end

      def prefixes_for(context) = context.command_prefixes
    end
  end
end
