# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # FAQ / canned responses / custom commands. A command trigger like `/rules`
    # must be the whole message and halts the pipeline; an auto-response trigger
    # matches a keyword or pattern anywhere in an ordinary message (via the shared
    # {Matcher}) and posts alongside without halting. Commands are checked first,
    # and only the first matching auto-response fires, so one message can't
    # trigger a flood of canned answers. A response persists unless the entry
    # sets `delete_after`, and posts as plain text so `@everyone` or `<@123>`
    # can't ping anyone.
    class Faq < Base
      include AdapterLookup

      # The sender label an FAQ response is posted under, unless the config
      # overrides it.
      DEFAULT_NAME = "faq"

      def self.feature_name = "faq"

      def self.description = "Canned responses and custom commands, triggered by keyword or command."

      # Off by default: a fresh community answers nothing until an operator turns
      # it on and supplies entries.
      def self.default_enabled? = false

      # Only fresh chat: re-posting a canned answer when someone merely edits a
      # message would be surprising.
      def self.observes = %i[chat]

      # The per-scope config shape, for the dashboard and the loader; the runtime
      # path parses Context#config defensively and does not depend on it.
      # `entries` is a free list because an entry's shape differs by trigger mode.
      def self.config_schema
        Config::Schema.define do
          field :name, :string, default: DEFAULT_NAME
          field :entries, :array, default: []
        end
      end

      # @param topology [Core::Topology] used only to construct the standalone default ephemeral
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}]
      # @param ephemeral [Core::EphemeralMessage, nil] posts the response; a
      #   self-contained default is built when none is injected
      # @param cleanup [Core::Scheduler, nil] fires a response's self-delete on
      #   time when an entry sets delete_after; without one the ephemeral
      #   primitive's durable row is swept on the next boot instead
      # @param name [String] fallback sender label for responses
      def initialize(topology:, adapters:, logger:, ephemeral: nil, cleanup: nil, name: DEFAULT_NAME)
        super()
        @adapters = adapters
        @logger = logger
        @cleanup = cleanup
        @name = name
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        entries = Entry.compile(context.config, logger: @logger)
        return Outcome.continue([]) if entries.empty?

        text = Matcher.bound_input(context.message.body.text)

        prefixes = prefixes_for(context)
        command = entries.find { |entry| entry.command? && entry.matches_command?(text, prefixes) }
        if command
          respond(context, command)
          return Outcome.halt([])
        end

        auto = entries.find { |entry| entry.auto? && entry.matches_auto?(text) }
        return Outcome.continue([]) if auto.nil?

        respond(context, auto)
        Outcome.continue([])
      end

      private

      # Post one entry's response to the origin endpoint, as the bot. Never
      # raises: a lost answer must not derail the pipeline.
      def respond(context, entry)
        delay = entry.delete_after
        group = @ephemeral.post(
          endpoints: [context.message.origin],
          body: Core::RichText.plain(entry.response),
          name: name_for(context.config),
          delete_after: delay,
          reply_to: Core::CommandAck.reply_to(context.message)
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        audit(context, entry)
        group
      rescue StandardError => e
        @logger.warn { "faq: could not post a response: #{e.message}" }
        nil
      end

      def prefixes_for(context)
        context.command_prefixes
      end

      def name_for(config)
        value = config_value(config, :name)
        value.nil? || value.to_s.strip.empty? ? @name : value.to_s
      end

      # A structured, operator-facing record of every answer posted. The interim
      # sink is the log; the durable one is audit_events, once that table has a
      # writer.
      def audit(context, entry)
        @logger.info do
          fields = {
            event: "faq.match",
            trigger: entry.command? ? "command" : "auto",
            key: entry.key,
            persist: entry.delete_after.zero?,
            message: context.message.ref.to_s,
            author: context.message.author&.any_name,
            community: context.community&.slug,
            channel: scope_key(context)
          }
          "faq " + fields.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        end
      end

      def scope_key(context)
        if context.channel.respond_to?(:endpoint_key)
          context.channel.endpoint_key
        else
          context.message.origin.id
        end
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      # One configured entry: a trigger (a command key or a keyword {Matcher}) and
      # the response to post on a hit, plus an optional self-delete horizon.
      class Entry
        attr_reader :command, :response, :delete_after, :matcher

        # Compile the resolved config's entries into Entry objects, dropping and
        # logging any that are malformed.
        def self.compile(config, logger: nil)
          config = {} unless config.is_a?(Hash)
          Array(fetch(config, :entries)).filter_map { |raw| build(raw, logger) }
        end

        def self.build(raw, logger)
          unless raw.is_a?(Hash)
            logger&.warn { "faq: ignoring an entry that is not a mapping: #{raw.inspect}" }
            return nil
          end

          entry = symbolize(raw)
          response = entry[:response]
          if response.nil? || response.to_s.strip.empty?
            logger&.warn { "faq: ignoring an entry with no response: #{raw.inspect}" }
            return nil
          end
          delete_after = duration(entry[:delete_after])

          command = entry[:command].to_s.strip
          return new(command: command, response: response.to_s, delete_after: delete_after) unless command.empty?

          pattern = (entry[:keyword] || entry[:pattern]).to_s
          if pattern.strip.empty?
            logger&.warn { "faq: ignoring an entry with neither a command nor a keyword: #{raw.inspect}" }
            return nil
          end

          matcher = Matcher.build(
            pattern: pattern,
            mode: (entry[:mode] || "literal").to_s,
            case_sensitive: boolean(entry[:case_sensitive], default: false),
            whole_word: boolean(entry[:whole_word], default: true),
            logger: logger
          )
          return nil if matcher.nil?

          new(response: response.to_s, delete_after: delete_after, matcher: matcher)
        end

        def initialize(response:, delete_after: 0, command: nil, matcher: nil)
          @command = command
          @response = response
          @delete_after = delete_after
          @matcher = matcher
          freeze
        end

        def command? = !@command.nil?

        def auto? = !@matcher.nil?

        # The human-facing key for audit lines: the command name, or the keyword
        # pattern.
        def key = @command || @matcher&.pattern

        # Whether +text+ invokes this command: after a recognised prefix marker,
        # the remaining body IS the command word (case-insensitively), or begins
        # with it followed by whitespace so an argument may follow.
        def matches_command?(text, prefixes)
          return false unless command?

          body = prefixes.strip(text)
          return false if body.nil?

          word = @command.to_s
          return true if body.strip.casecmp?(word)

          body.strip.downcase.start_with?("#{word.downcase} ")
        end

        # Whether +text+ trips this auto-response, delegated to the shared matcher.
        def matches_auto?(text)
          return false unless auto?

          @matcher.match?(text.to_s)
        end

        def self.fetch(config, key)
          return nil unless config.is_a?(Hash)

          config.key?(key) ? config[key] : config[key.to_s]
        end

        def self.symbolize(hash)
          hash.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
        end

        # Coerce an entry option that may arrive as a real boolean or a string.
        def self.boolean(value, default:)
          return default if value.nil?
          return value if value == true || value == false

          %w[true yes on 1].include?(value.to_s.strip.downcase)
        end

        # Coerce a seconds value that may arrive as an Integer or a numeric string.
        # A non-numeric or absent value means 0: the response persists.
        def self.duration(value)
          return 0 if value.nil?
          return value.to_i if value.is_a?(Numeric)
          return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

          0
        end
      end
    end
  end
end
