# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Features
    # Welcome and goodbye messages, posted to the channel the membership event
    # happened on; a Discord join and a Telegram join both arrive as a
    # canonical :join message, so one code path greets on either platform. A
    # greeting is ADDITIONAL: it posts its own message and then CONTINUES, so
    # the bridge still relays "X joined the chat" across the room. Only the
    # resolved `{mention}` id can ping, so operator-authored text containing a
    # stray `@everyone` reaches the channel as inert text.
    class Greetings < Base
      include AdapterLookup

      # The sender label a greeting is posted under, unless the config overrides
      # it.
      DEFAULT_NAME = "greetings"

      # The member-reference tokens a greeting template may carry. Captured so the
      # same pattern both splits the template and recognises each part.
      PLACEHOLDER = /(\{(?:name|username|mention)\})/

      def self.feature_name = "greetings"

      def self.description = "Posts a welcome message when someone joins, and a goodbye when they leave."

      # Off by default: a fresh community greets nobody until an operator turns it
      # on and supplies the text.
      def self.default_enabled? = false

      def self.observes = %i[join leave]

      # The per-scope config shape, for the dashboard and the loader; the runtime
      # path reads Context#config defensively and does not depend on it.
      def self.config_schema
        Config::Schema.define do
          field :welcome, :string,
                desc: "message posted when a member joins; supports {name}, {username}, {mention}"
          field :goodbye, :string,
                desc: "message posted when a member leaves; supports {name}, {username}, {mention}"
          field :name, :string, default: DEFAULT_NAME, desc: "sender label a greeting is posted under"
          field :delete_after, :duration, default: 0,
                desc: "seconds until a greeting self-deletes; 0 (the default) keeps it"
        end
      end

      # @param topology [Core::Topology] used only to construct the standalone default ephemeral
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}]
      # @param ephemeral [Core::EphemeralMessage, nil] posts the greeting; a
      #   self-contained default is built when none is injected
      # @param cleanup [Core::Scheduler, nil] fires a greeting's self-delete on
      #   time when delete_after is set; without one the ephemeral primitive's
      #   durable row is swept on the next boot instead
      # @param name [String] fallback sender label for greetings
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
        template = template_for(context.message.kind, context.config)
        # A community may greet joins but not leaves, or the reverse.
        return Outcome.continue([]) if template.nil? || template.to_s.strip.empty?

        body = render(template.to_s, context.message.author, context.message.origin)
        post(context, body)
        Outcome.continue([])
      end

      private

      # The welcome text on a join, the goodbye text on a leave.
      def template_for(kind, config)
        case kind
        when :join then config_value(config, :welcome)
        when :leave then config_value(config, :goodbye)
        end
      end

      # Post one greeting to the origin endpoint, as the bot. Never raises: a lost
      # greeting must not derail the pipeline.
      def post(context, body)
        delay = delete_after(context.config)
        group = @ephemeral.post(
          endpoints: [context.message.origin],
          body: body,
          name: name_for(context.config),
          delete_after: delay
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
        audit(context)
        group
      rescue StandardError => e
        @logger.warn { "greetings: could not post a greeting: #{e.message}" }
        nil
      end

      # Expand a template into a {Core::RichText}, substituting each placeholder
      # and recording a mention span wherever `{mention}` resolved to a real ping.
      # Splitting on the capturing PLACEHOLDER keeps the offsets exact.
      def render(template, author, origin)
        text = +""
        spans = []
        template.split(PLACEHOLDER).each do |part|
          token = placeholder_token(part)
          if token.nil?
            text << part
            next
          end

          segment, span = expand(token, author, origin, at: text.length)
          text << segment
          spans << span if span
        end
        Core::RichText.new(text, spans)
      end

      # The token name inside a `{...}` part, or nil for a literal segment.
      def placeholder_token(part)
        match = part.match(/\A\{(name|username|mention)\}\z/)
        match && match[1]
      end

      # Expand one token to its [text, span] pair. Only `{mention}` yields a span,
      # and only when the member's origin-platform id is known.
      def expand(token, author, origin, at:)
        case token
        when "name" then [display_name(author), nil]
        when "username" then [username(author), nil]
        when "mention" then mention_segment(author, origin, at)
        else ["", nil]
        end
      end

      # A `{mention}` segment: the display name, plus a mention span carrying the
      # ORIGIN platform's id-for-target attribute so the renderer turns it into a
      # real ping (Discord `<@id>`, Telegram `tg://user`).
      def mention_segment(author, origin, at)
        name = display_name(author)
        native_id = author&.native_id
        return [name, nil] if native_id.nil? || origin.nil?

        key = :"#{origin.adapter_name}_id_for_target"
        span = Core::Span.new(
          kind: :mention, begin_index: at, end_index: at + name.length,
          attributes: { key => native_id }
        )
        [name, span]
      end

      def display_name(author)
        name = author&.any_name
        name.nil? || name.to_s.strip.empty? ? "someone" : name.to_s
      end

      def username(author)
        author&.username || display_name(author)
      end

      def name_for(config)
        value = config_value(config, :name)
        value.nil? || value.to_s.strip.empty? ? @name : value.to_s
      end

      def delete_after(config)
        Core::Warnings.duration_seconds(config_value(config, :delete_after)).to_i
      end

      # A structured, operator-facing record of every greeting posted. The interim
      # sink is the log; the durable one is audit_events, once that table has a
      # writer.
      def audit(context)
        @logger.info do
          fields = {
            event: "greetings.#{context.message.kind}",
            member: context.message.author&.any_name,
            message: context.message.ref.to_s,
            community: context.community&.slug,
            channel: scope_key(context)
          }
          "greetings " + fields.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
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
    end
  end
end
