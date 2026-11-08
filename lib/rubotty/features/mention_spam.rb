# frozen_string_literal: true

module Rubotty
  module Features
    # Mention-spam protection: runs before the bridge relays, counts distinct people,
    # roles, and mass pings a message addresses against its already-parsed mention spans
    # (so Discord's `<@id>` and Telegram's `@handle` need no per-platform code), and takes
    # a configured action when the count exceeds the per-scope threshold. The action
    # vocabulary is the word filter's, feeding the same escalation ladder a `/warn`
    # command does; without a warnings service wired, `warn` and `mute` degrade to the
    # stub action (delete by default) so the content is still contained.
    class MentionSpam < Base
      IMPLEMENTED_ACTIONS = %w[delete flag].freeze

      # Recognised but delegated to the warnings ladder: the author is escalated
      # and message containment degrades to the stub action.
      DEFERRED_ACTIONS = %w[warn mute].freeze

      ACTIONS = (IMPLEMENTED_ACTIONS + DEFERRED_ACTIONS).freeze

      # Five distinct targets in one message is squarely into ping-raid territory.
      DEFAULT_THRESHOLD = 5

      DEFAULT_ACTION = "delete"
      DEFAULT_STUB_ACTION = "delete"
      # How long a mention-spam `mute` lasts when the config does not say.
      DEFAULT_MUTE_DURATION = 3600

      # The audit `source` key and the sender label the removal notice is posted under.
      SOURCE = "mention_spam"
      NOTICE_NAME = "mention filter"

      # Shown to the author and stored in the audit trail; overridable per scope.
      DEFAULT_REMOVAL_REASON = "Message mentioned too many people at once."

      # Discord mass-ping tokens, matched on a word boundary so `@everyone` counts
      # but `something@everyone.example` does not.
      MASS_MENTIONS = /(?<![\w])@(everyone|here)\b/i

      def self.feature_name = "mention_spam"

      def self.description = "Blocks a message that pings too many people, roles, or uses mass mentions."

      # Off by default until an operator turns it on and supplies a threshold.
      def self.default_enabled? = false

      # Edits too, since somebody can edit a clean message to smuggle a flood in.
      def self.observes = %i[chat edit]

      # The per-scope config shape, for the dashboard and loader. Parsed
      # defensively at runtime, so it does not have to have been run.
      def self.config_schema
        Config::Schema.define do
          field :threshold, :integer, default: DEFAULT_THRESHOLD,
                desc: "the maximum number of distinct mentions allowed in one message"
          field :action, :string, default: DEFAULT_ACTION, one_of: ACTIONS
          field :stub_action, :string, default: DEFAULT_STUB_ACTION, one_of: IMPLEMENTED_ACTIONS
          field :count_mass, :boolean, default: true,
                desc: "count a Discord @everyone / @here as a mention target"
          field :exempt_operators, :boolean, default: true
          field :removal_reason, :string, default: DEFAULT_REMOVAL_REASON,
                desc: "the reason shown to the author when a ping-flood is removed"
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds the self-deleting removal notice lives before it is removed"
          field :mute_duration, :duration, default: DEFAULT_MUTE_DURATION
        end
      end

      # @param topology [Core::Topology] resolves a mapped ref back to a live endpoint during removal
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param storage the message map, for resolving cross-platform copies
      # @param ephemeral [Core::EphemeralMessage, nil] posts the removal notice
      # @param cleanup [Core::Scheduler, nil] fires self-delete; else swept on next boot
      # @param warnings [Core::Warnings::Service, nil] escalates warn/mute; nil degrades to the stub action
      # @param audit [Core::AuditLog::Sequel, Core::AuditLog::Null, nil] the durable moderation audit sink
      def initialize(topology:, adapters:, storage:, logger:,
                     ephemeral: nil, cleanup: nil,
                     warnings: nil, audit: nil)
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @ephemeral = ephemeral
        @cleanup = cleanup
        @warnings = warnings
        # The shared removal engine: remove-everywhere, the audit record and, on a
        # delete, the self-deleting notice.
        @removal = Watchdog::Removal.new(
          topology: @topology, adapters: @adapters, storage: @storage, logger: @logger,
          source: SOURCE, name: NOTICE_NAME, ephemeral: @ephemeral, cleanup: @cleanup, audit: audit
        )
      end

      attr_reader :logger

      def call(context)
        threshold = threshold_for(context.config)
        # A non-positive threshold means unset, so a blank config stays inert.
        return Outcome.continue([]) if threshold <= 0
        return Outcome.continue([]) if exempt?(context)

        count = mention_count(context.message, count_mass: count_mass?(context.config))
        return Outcome.continue([]) if count <= threshold

        act(context, count, threshold)
      end

      private

      # The number of distinct mention targets in a message. With +count_mass+ on,
      # each distinct `@everyone` / `@here` is a target too.
      def mention_count(message, count_mass:)
        body = message.body
        keys = body.spans.each_with_object([]) do |span, out|
          next unless span.kind == :mention

          out << mention_key(span, body.text)
        end

        keys.concat(mass_mention_keys(body.text)) if count_mass
        keys.uniq.size
      end

      # A stable identity for one mention span: its attributes when it has them,
      # else the text it covers, so two spans on the same target count once.
      def mention_key(span, text)
        return span.attributes unless span.attributes.nil? || span.attributes.empty?

        text[span.begin_index...span.end_index].to_s.downcase
      end

      # Distinct, so `@everyone @everyone` still counts as one target.
      def mass_mention_keys(text)
        text.to_s.scan(MASS_MENTIONS).map { |(word)| "@#{word.downcase}" }.uniq
      end

      # Operators are exempt by default because one may legitimately need to ping
      # several people at once; `exempt_operators: false` subjects them like anyone else.
      def exempt?(context)
        return false unless truthy(config_value(context.config, :exempt_operators), default: true)

        # This community's own directory and nothing else. A room key is unique
        # only within one, so an unresolved community denies rather than widening
        # to the merged deployment-wide view. Empty is still not short-circuited:
        # the deployment-configured owner floor is invisible to Directory#empty?.
        directory = context.operators
        return false if directory.nil?

        author = context.message.author
        return false if author.nil? || author.native_id.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      end

      # Carry out the action for a message that crossed the threshold.
      def act(context, count, threshold)
        requested = requested_action(context.config)
        escalate(context, requested, count)

        effective = effective_action(requested, context.config)
        removed = effective == "delete" ? @removal.remove_everywhere(context.message) : []
        @removal.notice(
          context: context, action: effective, reason: reason_for(context.config),
          requested: requested, metadata: { count: count, threshold: threshold }
        )
        effective == "flag" ? Outcome.continue([]) : Outcome.halt(removed)
      end

      # The per-scope `removal_reason` override, or the filter's default.
      def reason_for(config)
        override = config_value(config, :removal_reason)
        override.nil? || override.to_s.strip.empty? ? DEFAULT_REMOVAL_REASON : override.to_s
      end

      # Escalates the author through the shared warnings service: a no-op for
      # delete / flag or when no service is wired. Never raises, since an
      # escalation failure must not stop the message being contained.
      def escalate(context, requested, count)
        return unless @warnings && DEFERRED_ACTIONS.include?(requested)

        author = context.message.author
        return if author.nil? || author.native_id.nil?

        origin = context.message.origin
        if requested == "mute"
          @warnings.sanction(
            community: context.community, subject: author, origin: origin,
            action: :mute, duration: mute_duration(context.config), reason: "mention spam: #{count} mentions",
            issued_by: "mention filter"
          )
        else # "warn"
          @warnings.warn(
            community: context.community, subject: author, origin: origin,
            ladder: warnings_ladder(context), max: warnings_max(context),
            expire_after: warnings_expire_after(context), reason: "mention spam: #{count} mentions",
            issued_by: "mention filter"
          )
        end
      rescue StandardError => e
        @logger.warn { "mention_spam: could not escalate #{requested}: #{e.class}: #{e.message}" }
      end

      # Read from the community's own "warnings" config, so a mention-spam warn
      # and a `/warn` command feed one ladder, one maximum and one decay
      # policy. Empty without a control plane.
      def warnings_feature_config(context)
        community = context.community
        return {} unless community.respond_to?(:feature_config)

        community.feature_config(context.channel, "warnings") || {}
      end

      def warnings_ladder(context)
        Core::Warnings::Ladder.parse(warnings_feature_config(context), logger: @logger)
      end

      def warnings_max(context)
        value = config_value(warnings_feature_config(context), :max)
        value.nil? ? nil : value.to_i
      end

      def warnings_expire_after(context)
        Core::Warnings.duration_seconds(config_value(warnings_feature_config(context), :expires_after))
      end

      def mute_duration(config)
        Core::Warnings.duration_seconds(config_value(config, :mute_duration)) || DEFAULT_MUTE_DURATION
      end

      # The message-level action. delete and flag pass through; warn and mute
      # contain the message via the stub action, leaving the person-level
      # escalation to #escalate.
      def effective_action(action, config)
        return action if IMPLEMENTED_ACTIONS.include?(action)

        stub = normalise_stub(config_value(config, :stub_action))
        unless @warnings
          @logger.warn do
            "mention_spam: #{action} escalation needs the warnings service; " \
              "applying only the #{stub.inspect} containment"
          end
        end
        stub
      end

      # Coerced from an Integer or numeric string; anything else falls back.
      def threshold_for(config)
        value = config_value(config, :threshold)
        return DEFAULT_THRESHOLD if value.nil?
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)

        DEFAULT_THRESHOLD
      end

      def count_mass?(config)
        truthy(config_value(config, :count_mass), default: true)
      end

      def requested_action(config)
        candidate = config_value(config, :action).to_s
        ACTIONS.include?(candidate) ? candidate : DEFAULT_ACTION
      end

      def normalise_stub(value)
        candidate = value.to_s
        IMPLEMENTED_ACTIONS.include?(candidate) ? candidate : DEFAULT_STUB_ACTION
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
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
