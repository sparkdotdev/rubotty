# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Adapters
    module Discord
      # Native Discord slash commands. It registers the bot's commands from the
      # neutral {Core::CommandRegistry} and turns an invocation into the same
      # canonical {Core::Message} a typed "!delete" produces.
      #
      # Pure Ruby: it works on the neutral {Interaction} value object, and
      # {Client} is the one place that speaks to discordrb.
      class Interactions
        # A member has invoked a command. The neutral shape the handler works on,
        # built by {Client} from the discordrb event. +options+ is a plain hash of
        # option name to value; +respond+ sends the ephemeral interaction reply.
        # +nickname+ is the raw per-guild nickname alone (nil if the member has
        # none set); +display_name+ is the global name (or username), never the
        # nickname-merged form discordrb's own Member#display_name returns, so a
        # reader that wants each source separately (Core::Author, and through it
        # {ControlPlane::TimezoneInference}) can have both.
        User = Struct.new(:id, :username, :nickname, :display_name, keyword_init: true)

        Interaction = Struct.new(:name, :channel_id, :guild_id, :user, :options, :responder,
                                 keyword_init: true) do
          def option(key) = (options || {})[key.to_s] || (options || {})[key.to_sym]

          def respond(text) = responder&.call(text)
        end

        # A command as Discord wants it registered: a name, a description, the
        # native permission bitfield that gates it (nil for an everyone command),
        # and its options. {Client} does the final discordrb translation.
        Definition = Struct.new(:name, :description, :default_member_permissions, :options,
                                keyword_init: true)

        Option = Struct.new(:name, :type, :description, :required, keyword_init: true)

        # Discord permission bits. A moderator command is gated to the matching
        # native permission so a member without it never sees it in the picker.
        MANAGE_MESSAGES = 1 << 13
        BAN_MEMBERS = 1 << 2
        KICK_MEMBERS = 1 << 1
        MODERATE_MEMBERS = 1 << 40
        MANAGE_GUILD = 1 << 5

        PERMISSIONS = {
          "delete" => MANAGE_MESSAGES,
          "pin" => MANAGE_MESSAGES,
          "unpin" => MANAGE_MESSAGES,
          "ban" => BAN_MEMBERS,
          "kick" => KICK_MEMBERS,
          "mute" => MODERATE_MEMBERS,
          "unmute" => MODERATE_MEMBERS
        }.freeze

        # @param client [Client] the discordrb seam
        # @param endpoint_for [#call] channel_id -> Core::Endpoint or nil
        # @param emit [#call] hands a Core::Message to the dispatcher (the
        #   adapter's own emit_if), so an interaction routes exactly as an inbound
        #   message does
        # @param registry [Core::CommandRegistry] the command source, injectable
        # @param logger [#warn, nil]
        def initialize(client:, endpoint_for:, emit:, registry: Core::CommandRegistry, logger: nil)
          @client = client
          @endpoint_for = endpoint_for
          @emit = emit
          @registry = registry
          @logger = logger
        end

        # The commands, as Discord definitions. One per registry Spec.
        # Room verbs only. A slash command Discord lists is dispatched into the
        # channel it was typed in, so registering a verb the operator console
        # answers in a DM would offer a picker entry that reaches nothing.
        def definitions
          @registry.room_commands.map { |spec| definition_for(spec) }
        end

        # Register a handler for every command so an invocation reaches {#handle},
        # plus a catch-all for a command Discord still lists that the current
        # registry no longer defines, which would otherwise go unacknowledged.
        def register_handlers
          @registry.room_commands.each do |spec|
            @client.on_application_command(spec.name) { |interaction| handle(interaction) }
          end
          @client.on_unknown_application_command do |interaction|
            next if @registry.find(interaction.name)

            respond(interaction, "That command is not available.")
          end
          self
        end

        # Register the command SET with Discord: per guild when guild ids
        # are known, since a global registration propagates slowly,
        # otherwise globally. Best effort, since a registration Discord
        # rejects is logged, never fatal; this also prunes stale GLOBAL
        # commands, which per-guild registration never removes on its own.
        def register_commands(guild_ids)
          guilds = Array(guild_ids).compact.uniq
          if guilds.empty?
            definitions.each { |definition| safely_register(definition, nil) }
          else
            guilds.each { |guild| definitions.each { |definition| safely_register(definition, guild) } }
          end
          prune_stale_globals
          self
        end

        # Turn one invocation into the canonical command message and dispatch it,
        # then acknowledge to the member privately. Never raises.
        def handle(interaction)
          spec = @registry.find(interaction.name)
          return respond(interaction, "That command is not available.") && nil if spec.nil?

          endpoint = @endpoint_for.call(interaction.channel_id)
          if endpoint.nil?
            respond(interaction, "Commands are not available in this channel.")
            return nil
          end

          message = build_message(spec, interaction, endpoint)
          @emit.call(message)
          respond(interaction, acknowledgement(spec))
          message
        rescue StandardError => e
          @logger&.error { "Discord interaction #{interaction&.name} failed: #{e.class}: #{e.message}" }
          nil
        end

        private

        # Reconstruct the message a typed command would have been. The command
        # word carries the "/" prefix so the shared CommandPrefix strips it, and
        # the target becomes the reply the parser reads.
        def build_message(spec, interaction, endpoint)
          reply_to, reply_preview = target(spec, interaction, endpoint)
          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, "slash-#{spec.name}-#{SecureRandom.hex(4)}"),
            origin: endpoint,
            author: author_for(interaction.user),
            body: Core::RichText.plain(body_text(spec, interaction)),
            reply_to: reply_to,
            reply_preview: reply_preview,
            timestamp: Time.now,
            raw: interaction,
            # This ref names no real, deletable, relayable Discord message
            # (see Core::Message#synthetic).
            synthetic: true
          )
        end

        # "/verb arg arg", the exact text form the parser expects, with only the
        # non-target arguments becoming words since the target is carried as a reply.
        #
        # A plain (unkeyed) argument becomes its bare value, exactly as before, since
        # there is only one value to lose the name of; a `keyed:` argument becomes
        # "name=value" instead, quoted when the value holds a space, so several native
        # Discord options come back together as the same key=value text a person would
        # type directly on a platform with no options at all (see Core::CommandRegistry::Argument).
        def body_text(spec, interaction)
          words = ["/#{spec.name}"]
          spec.arguments.each do |argument|
            value = interaction.option(argument.name)
            next if value.nil? || value.to_s.strip.empty?

            words << (argument.keyed? ? keyed_word(argument.name, value) : value.to_s)
          end
          words.join(" ")
        end

        # "name=value", written by the same module that reads it back, so
        # the two halves of the round trip cannot drift apart.
        def keyed_word(name, value) = Core::KeyedArguments.field(name, value)

        # A message target becomes a reply to that message's id. A user target
        # becomes a reply whose preview author IS the chosen member, where the
        # parser reads the person to act on; the ref is a sentinel.
        def target(spec, interaction, endpoint)
          if spec.targets_message?
            id = interaction.option("message_id")
            return [nil, nil] if id.nil? || id.to_s.strip.empty?

            [Core::MessageRef.new(endpoint.id, id.to_s), nil]
          elsif spec.targets_user?
            id = interaction.option("user")
            return [nil, nil] if id.nil? || id.to_s.strip.empty?

            preview = Core::ReplyPreview.new(author: Core::Author.new(native_id: id.to_s, kind: :user))
            [Core::MessageRef.new(endpoint.id, "slash-user-#{id}"), preview]
          else
            [nil, nil]
          end
        end

        def author_for(user)
          return Core::Author.new(kind: :user) if user.nil?

          Core::Author.new(
            native_id: user.id,
            username: user.username,
            nickname: user.nickname,
            display_name: user.display_name || user.username,
            kind: :user
          )
        end

        def definition_for(spec)
          Definition.new(
            name: spec.name,
            description: spec.description,
            default_member_permissions: spec.moderator? ? (PERMISSIONS[spec.name] || MANAGE_GUILD) : nil,
            options: options_for(spec)
          )
        end

        # The target option first (a member picker or a message id), then each of
        # the command's own arguments in order.
        def options_for(spec)
          options = []
          if spec.targets_message?
            options << Option.new(name: "message_id", type: :message, required: spec.target_required?,
                                  description: "ID of the message to act on.")
          elsif spec.targets_user?
            options << Option.new(name: "user", type: :user, required: spec.target_required?,
                                  description: "The member to act on.")
          end
          spec.arguments.each do |argument|
            options << Option.new(name: argument.name, type: argument.type,
                                  description: argument.description, required: argument.required?)
          end
          options
        end

        def acknowledgement(spec) = "Acknowledged, #{spec.acknowledgement}."

        def prune_stale_globals
          @client.prune_stale_global_commands(@registry.all.map(&:name))
        rescue StandardError => e
          @logger&.warn { "could not prune stale Discord global commands: #{e.message}" }
        end

        def safely_register(definition, guild_id)
          @client.register_application_command(definition, guild_id: guild_id)
        rescue StandardError => e
          @logger&.warn do
            "could not register the /#{definition.name} slash command#{guild_id ? " in guild #{guild_id}" : ""}: #{e.message}"
          end
        end

        def respond(interaction, text)
          interaction.respond(text)
          true
        rescue StandardError => e
          @logger&.debug { "could not respond to a Discord interaction: #{e.message}" }
          false
        end
      end
    end
  end
end
