# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # The public, non-moderation command surface: any member may run /find,
    # /platforms, or /help. Each posts a self-deleting reply and swallows the
    # invocation, so the command is never relayed to the room.
    #
    # The marker printed is whichever one actually works on the platform where
    # the listing is read: an adapter names the markers its own client
    # swallows, so those are skipped. On a platform with no native command
    # list, this also posts one /help pointer the first time it sees a channel.
    class UtilityCommands < Base
      include AdapterLookup

      # The sender label a reply is posted under.
      NOTICE_NAME = "rubotty"
      # Most results a /find lists, so one query cannot dump a whole community.
      DEFAULT_FIND_LIMIT = 25

      def self.feature_name = "utility_commands"

      def self.description = "Public commands like /find, /help and /platforms, open to anyone."

      # Off by default until an operator turns the feature on.
      def self.default_enabled? = false

      # A command can only ride a chat message, so this observes only :chat.
      def self.observes = %i[chat]

      # The per-scope config shape, for the dashboard and loader.
      def self.config_schema
        Config::Schema.define do
          field Core::CommandAck::TTL_FIELD, :integer, default: Core::CommandAck::DEFAULT_TTL_SECONDS,
                                                        desc: "seconds a command reply lives before it " \
                                                              "self-deletes. 0 leaves it in place."
          field Core::CommandAck::DELETE_COMMAND_FIELD, :boolean,
                default: Core::CommandAck::DELETE_COMMAND_DEFAULT,
                desc: "whether the command message itself is removed together " \
                      "with its reply, so the exchange leaves no trace"
          field :find_enabled, :boolean, default: true,
                                         desc: "whether /find is offered in this community"
          field :find_limit, :integer, default: DEFAULT_FIND_LIMIT,
                                       desc: "most identities a single /find lists"
          field :help_pointer, :boolean, default: true,
                desc: "on a platform with no command menu of its own, post one line " \
                      "naming the help command the first time this channel is seen"
          field :platforms, :array, of: Config::Schema.define {
            field :platform, :string, desc: "platform name, such as discord or telegram"
            field :name, :string, desc: "legacy alias for platform"
            field :label, :string, desc: "link label shown to members"
            field :url, :string, required: true, desc: "the join URL" do |value, path|
              "#{path}: cannot be blank" if value.strip.empty?
            end
          }, default: [],
                            desc: "join links per platform, each { platform, label, url }, " \
                                  "for /platforms to advertise the other ends of the bridge"
        end
      end

      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param ephemeral [Core::EphemeralMessage, nil] posts the reply
      # @param cleanup [Core::Scheduler, nil] fires the reply's self-delete on time
      # @param identity_directory [ControlPlane::IdentityDirectory, nil] the
      #   directory /find searches; nil (no control plane) makes /find report nothing to search
      # @param help_pointer [Core::HelpPointer, nil] remembers which endpoints
      #   have already been shown where the commands are. A default one is built
      #   when none is injected, which keeps the marker in process only.
      def initialize(topology:, adapters:, logger:, ephemeral: nil, cleanup: nil,
                     identity_directory: nil, help_pointer: nil)
        super()
        @adapters = adapters
        @logger = logger
        @cleanup = cleanup
        @identity_directory = identity_directory
        @help_pointer = help_pointer || Core::HelpPointer.new
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      # A handled command halts, since it is swallowed and never relayed. Anything
      # else continues so the bridge relays it normally.
      def call(context)
        word, arguments = command_of(context)
        return point_at_help(context) if word.nil?

        case word
        when "find" then handle_find(context, arguments)
        when "platforms" then handle_platforms(context)
        when "help" then handle_help(context)
        when "version" then handle_version(context)
        else Outcome.continue([])
        end
      end

      private

      def command_of(context) = CommandWord.parse(context)

      # The marker to PRINT in this channel: the first configured one the
      # platform's own client does not swallow. Asked of the adapter rather than
      # of the platform's name, so a second platform that claims "/" inherits
      # this by declaring it in its capabilities.
      def marker_for(context)
        capabilities = capabilities_of(context.message.origin)
        context.command_prefixes.preferred(capabilities: capabilities)
      end

      # The origin platform's capabilities, or nil when no adapter serves it.
      # Never raises: help text has to come out either way.
      def capabilities_of(origin)
        adapter = adapter_for(origin)
        adapter.respond_to?(:capabilities) ? adapter.capabilities : nil
      rescue StandardError
        nil
      end

      # Say once, in a channel whose platform publishes no native command menu (Telegram
      # and Discord do; Fluxer doesn't), where the commands are. Never halts, so the
      # carrying message still relays; the pointer persists rather than self-deleting so
      # it can be found later by somebody who wasn't watching when it landed.
      def point_at_help(context)
        return Outcome.continue([]) unless pointer_wanted?(context)

        endpoint = context.message.origin
        return Outcome.continue([]) if @help_pointer.pointed?(endpoint.id)

        group = @ephemeral.post(
          endpoints: [endpoint], body: Core::RichText.plain(pointer_text(context)), name: NOTICE_NAME
        )
        @help_pointer.mark_pointed!(endpoint.id) if group&.any?
        Outcome.continue([])
      rescue StandardError => e
        logger.warn { "utility_commands: could not post the help pointer: #{e.message}" }
        Outcome.continue([])
      end

      def pointer_wanted?(context)
        return false unless truthy(config_value(context.config, :help_pointer), default: true)

        capabilities = capabilities_of(context.message.origin)
        !capabilities.nil? && !capabilities.publishes_command_list?
      end

      def pointer_text(context)
        marker = marker_for(context)
        "This channel is bridged by rubotty. Type #{marker}help to see what you can ask it to do."
      end

      # Surface the identities whose handle or display name matches the query. With
      # /find withdrawn per community the command is not claimed at all.
      def handle_find(context, arguments)
        return Outcome.continue([]) unless find_enabled?(context.config)

        query = arguments.join(" ").strip
        usage = "Usage: #{marker_for(context)}find <name or handle>"
        reply = query.empty? ? usage : find_reply(context, query)
        acknowledge(context, reply)
        Outcome.halt([])
      end

      def find_reply(context, query)
        matches = find_matches(context, query)
        return "No one matching #{query.inspect} has been seen in this community." if matches.empty?

        lines = matches.map { |row| format_identity(row) }
        (["Matches for #{query.inspect}:"] + lines).join("\n")
      end

      # Scoped to this community's own directory, so a lookup never surfaces
      # identities from other communities the bot serves.
      def find_matches(context, query)
        return [] if @identity_directory.nil? || context.community.nil?

        @identity_directory.search(
          community_id: context.community.id, query: query, limit: find_limit(context.config)
        )
      rescue StandardError => e
        logger.warn { "find: search failed: #{e.message}" }
        []
      end

      # "handle@platform [Display Name]". Handle and display name only, for privacy;
      # the native id is a fallback when no handle was observed.
      def format_identity(row)
        handle = presence(field(row, :username)) || field(row, :native_id)
        display = presence(field(row, :display_name))
        base = "#{handle}@#{field(row, :adapter)}"
        display ? "#{base} [#{display}]" : base
      end

      def find_enabled?(config) = truthy(config_value(config, :find_enabled), default: true)

      def find_limit(config)
        value = Integer(config_value(config, :find_limit).to_s, exception: false)
        value.nil? || value <= 0 ? DEFAULT_FIND_LIMIT : value
      end

      # Always swallowed once recognised. The invoker's own platform is excluded,
      # since they are already there.
      def handle_platforms(context)
        others = other_platforms(context)
        acknowledge(context, others.empty? ? "Nothing is linked here yet." : platforms_reply(others))
        Outcome.halt([])
      end

      # The configured platforms other than the one the command came from.
      def other_platforms(context)
        origin = context.message.origin.adapter_name.to_s
        platform_links(context.config).reject { |link| link[:platform] == origin }
      end

      def platforms_reply(links)
        lines = links.map { |link| "- #{link[:label]}: #{link[:url]}" }
        (["Join this community on:"] + lines).join("\n")
      end

      # Normalised through {ControlPlane::PlatformLinks.normalize}, the same rule the
      # dashboard applies at write time, so the two cannot disagree.
      def platform_links(config)
        ControlPlane::PlatformLinks.normalize(config_value(config, :platforms))
      end

      # The same banner the bot posts at startup, on demand; independent of whether a
      # community has that startup banner turned on, since that setting only governs an
      # unprompted restart announcement, not whether somebody may ask. Tiered: an
      # operator gets the full banner (hostname, kernel, distribution) for debugging a
      # deploy, everyone else gets just the service, version, and build, so the room
      # doesn't learn the machine.
      def handle_version(context)
        level = moderator?(context) ? :full : :minimal
        acknowledge(context, Core::Announcement.new(level: level).text)
        Outcome.halt([])
      end

      # Open to anyone, tiered by whether they are an operator. Enumerated from
      # {Core::CommandRegistry}, so a new command appears without a second edit here.
      def handle_help(context)
        acknowledge(context, help_text(context))
        Outcome.halt([])
      end

      # Every line carries the marker that actually works where the listing is
      # being read, so a Fluxer member is not told to type "/ban" into a client
      # that answers "/ban" itself.
      def help_text(context)
        marker = marker_for(context)
        # Room surface only: the console's DM verbs are answered in a DM and
        # would be a dead line in a list read where people talk.
        specs = Core::CommandRegistry.for_audience(moderator: moderator?(context), surface: :room)
        lines = specs.map { |spec| command_line(spec, marker) }
        # A non-operator cannot see the moderator /delete but may still delete
        # their own message, so /help says so.
        own_delete = "#{marker}delete - reply to your own message to delete it everywhere."
        lines << own_delete unless moderator?(context)
        (["Commands you can use:"] + lines).join("\n")
      end

      # Whether the asker is an operator in this scope. Fails closed: an
      # unresolvable asker is treated as a regular member.
      def moderator?(context)
        directory = context.operators
        author = context.message.author
        return false if directory.nil? || author.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      rescue StandardError => e
        logger.warn { "utility_commands: moderator? failed: #{e.class}: #{e.message}" }
        false
      end

      # The invocation, then its one-line description. A required argument shows in
      # <angle brackets>, an optional one in [square brackets].
      def command_line(spec, marker)
        "#{usage(spec, marker)} - #{spec.description}"
      end

      def usage(spec, marker)
        parts = ["#{marker}#{spec.name}"]
        spec.arguments.each do |argument|
          parts << (argument.required? ? "<#{argument.name}>" : "[#{argument.name}]")
        end
        parts.join(" ")
      end

      # Post +text+ to the issuer's endpoint as the bot, self-deleting after the
      # standardised TTL and taking the invocation with it, so the command and its
      # answer share one horizon and one removal. Never raises.
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
        logger.warn { "utility_commands: could not post a reply: #{e.message}" }
        nil
      end

      # A directory row may be a model object or a plain struct; read from either.
      def field(row, name)
        row.respond_to?(name) ? row.public_send(name) : nil
      end

      def presence(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end

      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def truthy(value, default:)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end
    end
  end
end
