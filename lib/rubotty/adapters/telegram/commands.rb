# frozen_string_literal: true

module Rubotty
  module Adapters
    module Telegram
      # Publishes the bot's command list to Telegram so typing "/" offers the
      # commands with their descriptions; registration only, since a command picked
      # from the menu still arrives as ordinary message text ("/delete@thebot").
      # setMyCommands REPLACES the whole list for a scope on every call, and scopes
      # never stack, so each of the three carries its own full set. The menu is a
      # presentation filter only, since {Core::Commands} and the operator console
      # both run their own fail-closed checks, and because scopes are a bot
      # property rather than a chat's, `register_commands` reaches every chat.
      class Commands
        # Telegram's own limits on a BotCommand. A name may hold only lowercase
        # latin letters, digits and underscores.
        NAME_LIMIT = 32
        DESCRIPTION_LIMIT = 256
        MAX_COMMANDS = 100
        NAME_PATTERN = /\A[a-z0-9_]+\z/

        # What separates a command's usage hint from its description. A plain
        # hyphen because that is what BotFather uses for a
        # "command - description" pair, and the only dash the style rule allows.
        SEPARATOR = " - "

        DEFAULT_SCOPE = { "type" => "default" }.freeze
        ADMIN_SCOPE = { "type" => "all_chat_administrators" }.freeze

        # Telegram's administrator scope covers administrators of groups and
        # supergroups, never a private chat, so a moderator verb published only
        # there is invisible in a DM. That is exactly where the operator console
        # lives, so private chats get their own list.
        PRIVATE_SCOPE = { "type" => "all_private_chats" }.freeze

        # One command as Telegram wants it: a name and a description. Telegram
        # has no typed options, no argument pickers and no permission bitfield.
        Definition = Struct.new(:name, :description, keyword_init: true) do
          def to_param = { "command" => name, "description" => description }
        end

        # @param client [ApiClient] the Bot API seam
        # @param registry [Core::CommandRegistry] the command source, injectable
        # @param logger [#warn, #info, nil]
        def initialize(client:, registry: Core::CommandRegistry, logger: nil)
          @client = client
          @registry = registry
          @logger = logger
        end

        # The definitions for one audience, in registry order.
        #
        # @param moderator [Boolean] true for the administrator scope's full
        #   set, false for the everyone-commands
        def definitions(moderator:)
          build(@registry.for_audience(moderator: moderator))
        end

        # What a private chat is offered: the everyone commands, plus the verbs
        # the operator console answers in a DM. The console's own check decides
        # who may actually run one, the same way the menu has never been the
        # gate for the moderation verbs it lists to administrators.
        def private_definitions
          console = @registry.for_audience(moderator: true).select(&:direct?)
          build(@registry.for_audience(moderator: false) + console)
        end

        def build(specs)
          usable = specs.uniq(&:name).filter_map { |spec| definition_for(spec) }
          return usable if usable.size <= MAX_COMMANDS

          # Never silently truncate: a surface that quietly lists 100 of 120
          # commands looks complete.
          dropped = usable.size - MAX_COMMANDS
          @logger&.warn do
            "telegram accepts at most #{MAX_COMMANDS} commands per scope; #{dropped} were not published"
          end
          usable.first(MAX_COMMANDS)
        end

        # Publish both scopes. Best effort: a list Telegram rejects is logged and
        # the bridge runs on with commands still typable by hand.
        #
        # @return [self]
        def register
          publish(DEFAULT_SCOPE, definitions(moderator: false))
          publish(PRIVATE_SCOPE, private_definitions)
          publish(ADMIN_SCOPE, definitions(moderator: true))
          self
        end

        private

        # An empty command array is a legitimate "clear this scope", which is why
        # there is no guard against sending one.
        def publish(scope, definitions)
          @client.call(
            "setMyCommands",
            commands: definitions.map(&:to_param),
            scope: scope
          )
          @logger&.info do
            "published #{definitions.size} telegram commands for the #{scope["type"]} scope"
          end
          true
        rescue StandardError => e
          @logger&.warn { "could not publish the telegram command list (#{scope["type"]}): #{e.message}" }
          false
        end

        # nil when the spec cannot be expressed as a Telegram command at all,
        # which is logged rather than passed through: one malformed entry makes
        # Telegram reject the ENTIRE setMyCommands call.
        def definition_for(spec)
          name = telegram_name(spec.name)
          unless name.match?(NAME_PATTERN) && name.length <= NAME_LIMIT
            @logger&.warn do
              "/#{spec.name} cannot be published to telegram: a command name may only hold " \
                "lowercase letters, digits and underscores, at most #{NAME_LIMIT} of them"
            end
            return nil
          end

          Definition.new(name: name, description: description_for(spec))
        end

        # Telegram allows no hyphen in a command name, so "identify-topic" is
        # published as "identify_topic". {Core::CommandRegistry.canonical}
        # recognises the underscored spelling as the same command.
        def telegram_name(name) = name.to_s.downcase.tr("-", "_")

        # Telegram gives a command no argument UI, so the shape of the invocation
        # has to live in the description. The usage hint leads, reading as a
        # continuation of the command name Telegram has already printed.
        def description_for(spec)
          hint = usage_hint(spec)
          text = hint.empty? ? spec.description : "#{hint}#{SEPARATOR}#{spec.description}"
          truncate(text)
        end

        # What the member has to supply, in order: the target first, then each
        # argument, angle-bracketed when required and square-bracketed when optional.
        def usage_hint(spec)
          parts = []
          # Bracketed when the verb also has a form that names no target, so
          # the hint does not tell somebody a reply is the only way in.
          parts << (spec.target_required? ? "reply to a message" : "[reply to a message]") if spec.targets_message?
          parts << "reply to that person" if spec.targets_user?
          spec.arguments.each do |argument|
            parts << (argument.required? ? "<#{argument.name}>" : "[#{argument.name}]")
          end
          parts.join(" ")
        end

        # Never fires today, since a registry description is already held under
        # 100 characters. Here so a long one cannot cost every command in the
        # menu its registration.
        def truncate(text)
          return text if text.length <= DESCRIPTION_LIMIT

          "#{text[0, DESCRIPTION_LIMIT - 1]}…"
        end
      end
    end
  end
end
