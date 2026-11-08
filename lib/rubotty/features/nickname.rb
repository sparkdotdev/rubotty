# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Pick the name you are bridged as, per platform.
    #   /nickname                          show what you are shown as everywhere
    #   /nickname <platform> <name>        set it for one platform
    #   /nickname clear <platform>         drop your own
    #   /nickname clear <platform> <name>  an operator drops somebody else's
    #   /nickname list                     an operator reads the whole community's
    # Stored by {ControlPlane::BridgedNicknames} and folded into the person's
    # handles when the Snapshot builds, so it resolves like any other handle.
    class Nickname < Base
      include AdapterLookup

      COMMAND = "nickname"

      # The sender label a reply is posted under.
      NOTICE_NAME = "nickname"

      # Who may set one. Operators can always clear somebody else's, whichever of
      # these is in force, because that is the lever for a name that has become a
      # problem.
      WHO_NOBODY = "nobody"
      WHO_OPERATORS = "operators"
      WHO_EVERYONE = "everyone"
      WHO_CAN_SET = [WHO_NOBODY, WHO_OPERATORS, WHO_EVERYONE].freeze

      # The effective who_can_set value out of a feature config hash: whichever
      # of WHO_CAN_SET is stored, or WHO_OPERATORS when it is missing or not
      # recognised. Public, and the only place this fallback is decided, so the
      # dashboard's people page reads the exact policy the command enforces
      # rather than a second copy of it that could drift.
      def self.who_can_set(config)
        value = config[:who_can_set] || config["who_can_set"]
        WHO_CAN_SET.include?(value.to_s) ? value.to_s : WHO_OPERATORS
      end

      HELP_TEXT = <<~TEXT.strip
        /nickname - show the name you are bridged as on each platform.
        /nickname <platform> <name> - be shown as <name> when your messages reach <platform>.
        /nickname clear <platform> - go back to your ordinary handle there.
        /nickname list - operators only: every nickname claimed here.
      TEXT

      def self.feature_name = "nickname"

      def self.description = "Lets a member choose the name they are bridged as on each platform (/nickname)."

      # Off by default, and operators-only once on, until a community decides
      # otherwise.
      def self.default_enabled? = false

      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field :who_can_set, :string, default: WHO_OPERATORS, one_of: WHO_CAN_SET,
                desc: "who may set their own bridged nickname: nobody, operators (default) or everyone"
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                       desc: "seconds a /nickname reply lives before it " \
                                                             "self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the /nickname invocation itself is removed together with its reply"
        end
      end

      # @param nicknames [ControlPlane::BridgedNicknames, nil] the store. Nil (no
      #   control plane) makes the whole feature a no-op.
      # @param registry [ControlPlane::Registry, nil] reloaded after a write, so a
      #   new name is live without a restart
      def initialize(topology:, adapters:, logger:, nicknames: nil, registry: nil,
                     ephemeral: nil, cleanup: nil)
        super()
        @adapters = adapters
        @logger = logger
        @nicknames = nicknames
        @registry = registry
        @cleanup = cleanup
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        word, arguments = command_of(context)
        return Outcome.continue([]) unless word == COMMAND

        if @nicknames.nil? || context.community.nil?
          acknowledge(context, "Sorry, /#{COMMAND} is not available on this bridge.")
          return Outcome.halt([])
        end

        handle(context, arguments)
        Outcome.halt([])
      end

      private

      def command_of(context) = CommandWord.parse(context)

      def handle(context, arguments)
        case arguments.first&.downcase
        when nil then show(context)
        when "help" then acknowledge(context, HELP_TEXT)
        when "list" then list(context)
        when "clear" then clear(context, arguments[1..] || [])
        else assign(context, arguments)
        end
      end

      # Every nickname in the community, so an operator can see one that has
      # become a problem before deciding to clear it.
      def list(context)
        return acknowledge(context, "Only an operator can see everybody's nicknames.") unless operator?(context)

        rows = @nicknames.list(community_id: context.community.id)
        acknowledge(context, list_reply(rows))
      end

      def list_reply(rows)
        return "Nobody has chosen a bridged nickname here." if rows.empty?

        lines = rows.map { |row| "- #{row.nickname} on #{row.adapter} (set by #{row.set_by})" }
        (["Bridged nicknames here:"] + lines).join("\n")
      end

      def show(context)
        person = person_for(context)
        return acknowledge(context, "You are not shown under a chosen name anywhere.") if person.nil?

        held = @nicknames.for_person(community_id: context.community.id, person_id: person.id)
        acknowledge(context, show_reply(held))
      end

      def show_reply(held)
        return "You are not shown under a chosen name anywhere." if held.empty?

        lines = held.sort.map { |adapter, nickname| "- on #{adapter}: #{nickname}" }
        (["You are bridged as:"] + lines).join("\n")
      end

      # Everything after the platform is the name, joined back up, because a
      # display name has spaces in it and the dashboard would have taken it whole.
      def rest_of(arguments)
        name = (arguments[1..] || []).join(" ")
        name.empty? ? nil : name
      end

      def assign(context, arguments)
        adapter = arguments.first
        nickname = rest_of(arguments)
        return acknowledge(context, HELP_TEXT) if nickname.nil?
        return acknowledge(context, refusal(context)) unless may_set?(context)
        return acknowledge(context, "There is no #{adapter} in this community.") unless platform?(context, adapter)

        person = person_for(context, create: true)
        return acknowledge(context, "I could not work out who you are here.") if person.nil?

        write(context, person, adapter, nickname)
      end

      def write(context, person, adapter, nickname)
        result = @nicknames.set(
          community_id: context.community.id, person_id: person.id,
          adapter: adapter, nickname: nickname, set_by: "self"
        )
        if result.status == :taken
          return acknowledge(context, "#{result.nickname} is already taken on #{result.adapter}. Pick another.")
        end

        reload
        acknowledge(context, "On #{result.adapter} you are now shown as #{result.nickname}.")
      rescue ControlPlane::BridgedNicknames::Invalid => e
        acknowledge(context, e.message)
      end

      # An operator naming somebody clears theirs; anybody else clears their own.
      def clear(context, arguments)
        adapter = arguments.first
        target = rest_of(arguments)
        return acknowledge(context, HELP_TEXT) if adapter.nil?
        return clear_other(context, adapter, target) unless target.nil?

        person = person_for(context)
        return acknowledge(context, "You have no nickname on #{adapter} to clear.") if person.nil?

        result = @nicknames.clear(community_id: context.community.id, person_id: person.id, adapter: adapter)
        reload if result.ok?
        acknowledge(context, clear_reply(result, adapter))
      rescue ControlPlane::BridgedNicknames::Invalid => e
        acknowledge(context, e.message)
      end

      def clear_reply(result, adapter)
        return "You have no nickname on #{adapter} to clear." unless result.ok?

        "Cleared. On #{result.adapter} you are shown under your ordinary handle again."
      end

      def clear_other(context, adapter, target)
        return acknowledge(context, "Only an operator can clear somebody else's nickname.") unless operator?(context)

        person_id = @nicknames.person_id_for(community_id: context.community.id, nickname: target)
        return acknowledge(context, "Nobody here is called #{target}.") if person_id.nil?

        result = @nicknames.clear(community_id: context.community.id, person_id: person_id, adapter: adapter)
        reload if result.ok?
        acknowledge(context, clear_other_reply(result, adapter, target))
      rescue ControlPlane::BridgedNicknames::Invalid => e
        acknowledge(context, e.message)
      end

      def clear_other_reply(result, adapter, target)
        return "#{target} has no nickname on #{adapter}." unless result.ok?

        "Cleared #{result.nickname} on #{result.adapter}."
      end

      # nobody refuses everyone including operators, since an operator wanting one
      # can turn the setting up.
      def may_set?(context)
        case who_can_set(context)
        when WHO_EVERYONE then true
        when WHO_OPERATORS then operator?(context)
        else false
        end
      end

      def who_can_set(context)
        self.class.who_can_set(context.config)
      end

      def refusal(context)
        return "Nicknames are not being handed out here." if who_can_set(context) == WHO_NOBODY

        "Only an operator can set a bridged nickname here."
      end

      # Fail closed: an author the directory cannot resolve is an ordinary member.
      def operator?(context)
        directory = context.operators
        return false if directory.nil? || context.message.author.nil?

        !directory.resolve(context.message.origin.adapter_name, context.message.author.native_id,
                           username: context.message.author.username).nil?
      rescue StandardError => e
        logger.warn { "nickname: operator? failed: #{e.class}: #{e.message}" }
        false
      end

      # Refuse a platform this community does not bridge, so a typo does not store
      # a nickname nobody will ever see.
      def platform?(context, adapter)
        name = adapter.to_s.downcase
        return false if name.empty?

        context.community.channels.any? { |channel| channel.adapter.to_s == name }
      rescue StandardError
        false
      end

      def person_for(context, create: false)
        author = context.message.author
        return nil if author.nil?

        if create
          return @nicknames.person_for(
            community_id: context.community.id, adapter: context.message.origin.adapter_name,
            native_id: author.native_id, username: author.username, display: author.display_name
          )
        end

        existing = @nicknames.person_for(
          community_id: context.community.id, adapter: context.message.origin.adapter_name,
          native_id: author.native_id
        )
        existing
      end

      # A written nickname has to reach the live Snapshot, or the sender label and
      # mention lookup keep using the old one until the next reload.
      def reload
        @registry&.reload
      rescue StandardError => e
        logger&.warn { "nickname written but the registry would not reload: #{e.message}" }
      end

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
        logger&.warn { "nickname: could not post a reply: #{e.message}" }
        nil
      end
    end
  end
end
