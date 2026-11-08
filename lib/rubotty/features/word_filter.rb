# frozen_string_literal: true

require "yamlcamel"

module Rubotty
  module Features
    # Matches chat and edited messages against a per-scope word list before the
    # bridge relays them. `delete` removes the message and every relayed copy
    # via the same message-map path `/delete` uses, then halts the pipeline;
    # `flag` audits and lets the message through. `warn`/`mute` degrade to a
    # configured stub action until the warnings ladder is wired in. An enabled
    # scope also inherits a vendored base vulgar/slur list, gated by `mode`
    # (off by default, so enabling the filter alone filters nothing) and
    # extended by the scope's own `custom`/`entries` words regardless of mode.
    class WordFilter < Base
      # The two actions implemented for 1.0.
      IMPLEMENTED_ACTIONS = %w[delete flag].freeze

      # Recognised but deferred to the warnings ladder. A config naming one of
      # these degrades to the stub action instead of crashing.
      DEFERRED_ACTIONS = %w[warn mute].freeze

      ACTIONS = (IMPLEMENTED_ACTIONS + DEFERRED_ACTIONS).freeze

      # Severity order, used to pick one action when a single message matches
      # several entries. The most severe wins: a message that trips both a flag
      # entry and a delete entry is deleted.
      ACTION_SEVERITY = { "flag" => 0, "warn" => 1, "mute" => 2, "delete" => 3 }.freeze

      DEFAULT_ACTION = "delete"
      DEFAULT_STUB_ACTION = "delete"
      # How long a word-filter `mute` lasts when the config does not say. One hour,
      # the same sensible default the Discord adapter uses for a bare timeout.
      DEFAULT_MUTE_DURATION = 3600

      # The audit `source` key and the sender label the removal notice is posted
      # under, handed to the shared {Core::RemovalNotice} helper.
      SOURCE = "word_filter"
      NOTICE_NAME = "word filter"

      # The default reason shown to an author whose message was removed and stored
      # in the audit trail. Overridable per scope via the `removal_reason` field.
      DEFAULT_REMOVAL_REASON = "Message contained profanity or inappropriate language."

      # Vendored base word list: a snapshot of the language core's curated
      # vulgarity/slur terms, checked in beside this file and re-synced by
      # hand. Gives a freshly enabled filter a sensible default instead of an
      # empty list.
      BASE_LIST_PATH = File.expand_path("word_filter_base.yml", __dir__)

      # The base list's two categories, applied under the scope's action as its
      # `mode` selects.
      BASE_LIST_CATEGORIES = %w[vulgar slur].freeze

      # The three filter modes and the base-list categories each selects. `off`
      # (default) applies none of the base list, only the scope's own
      # `custom`/`entries`; `slurs` applies identity slurs only; `slurs_profanity`
      # applies both categories.
      FILTER_MODES = {
        "off" => [].freeze,
        "slurs" => %w[slur].freeze,
        "slurs_profanity" => %w[vulgar slur].freeze
      }.freeze

      # Off by default: a freshly enabled filter filters nothing from the base
      # list until an operator explicitly picks a tier, matching this feature's
      # dormant-by-default design.
      DEFAULT_MODE = "off"

      # Legacy `vulgarity_mode` values mapped onto their `mode` equivalent. Read
      # by {.resolve_mode} as a fallback so a scope that already set
      # `vulgarity_mode` keeps behaving as before; an unset `vulgarity_mode` now
      # falls through to {DEFAULT_MODE} instead of its old `slurs_only` default.
      LEGACY_MODE_ALIASES = {
        "none" => "off",
        "slurs_only" => "slurs",
        "all" => "slurs_profanity"
      }.freeze

      # The vendored base terms grouped by category, as a frozen
      # { category => [terms] } map, loaded once and memoised. A missing or
      # corrupt file degrades to empty categories rather than breaking message
      # handling.
      def self.base_terms_by_category
        @base_terms_by_category ||= load_base_terms_by_category.freeze
      end

      def self.load_base_terms_by_category
        data = YAMLCamel.load_file(BASE_LIST_PATH)
        data = {} unless data.is_a?(Hash)

        BASE_LIST_CATEGORIES.each_with_object({}) do |category, out|
          out[category] = Array(data[category]).map { |term| term.to_s.strip }.reject(&:empty?).freeze
        end
      rescue StandardError
        BASE_LIST_CATEGORIES.each_with_object({}) { |category, out| out[category] = [].freeze }
      end

      # How each vulgar term parses, as a frozen { term => part of speech } map,
      # so a rule that replaces a word can pick a replacement that fits the
      # sentence. Terms absent from the map default to noun.
      def self.base_parts_of_speech
        @base_parts_of_speech ||= load_base_parts_of_speech.freeze
      end

      def self.load_base_parts_of_speech
        data = YAMLCamel.load_file(BASE_LIST_PATH)
        parsed = data.is_a?(Hash) ? data["parts_of_speech"] : nil
        return {} unless parsed.is_a?(Hash)

        parsed.each_with_object({}) { |(term, part), out| out[term.to_s.downcase] = part.to_s }
      rescue StandardError
        {}
      end

      DEFAULT_PART_OF_SPEECH = "noun"

      def self.part_of_speech(term)
        base_parts_of_speech.fetch(term.to_s.downcase.strip, DEFAULT_PART_OF_SPEECH)
      end

      # The vendored base terms for +categories+, as a flat frozen list of bare
      # strings compiled like a per-scope literal entry. Defaults to both
      # categories; an empty +categories+ yields an empty list, which is how
      # `mode: off` opts out of the base entirely.
      def self.base_terms(categories = BASE_LIST_CATEGORIES)
        Array(categories).flat_map { |category| base_terms_by_category.fetch(category, []) }.freeze
      end

      # The base-list categories a +mode+ selects, falling back to the default
      # ({DEFAULT_MODE}) for an unset or unrecognised value.
      def self.mode_categories(mode)
        FILTER_MODES.fetch(mode.to_s, FILTER_MODES.fetch(DEFAULT_MODE))
      end

      # The effective filter mode a scope's raw config resolves to: the
      # canonical `mode` field if present and recognised, else the legacy
      # `vulgarity_mode` field mapped through {LEGACY_MODE_ALIASES}, else
      # {DEFAULT_MODE}. Public so the dashboard can resolve and display the
      # same effective mode a running filter would apply.
      def self.resolve_mode(config)
        mode = config_string(config, :mode)
        return FILTER_MODES.key?(mode) ? mode : DEFAULT_MODE unless mode.nil?

        legacy = config_string(config, :vulgarity_mode)
        return DEFAULT_MODE if legacy.nil?

        LEGACY_MODE_ALIASES.fetch(legacy, DEFAULT_MODE)
      end

      # Read one string key from a raw config hash, tolerating symbol or string
      # keys (see the instance-level {#config_value} for why). Returns nil when
      # the key is absent, distinct from an empty or blank value, so a caller can
      # tell "not set" from "set to something odd" and fall through accordingly.
      def self.config_string(config, key)
        return nil unless config.is_a?(Hash)
        return nil unless config.key?(key) || config.key?(key.to_s)

        (config.key?(key) ? config[key] : config[key.to_s]).to_s
      end

      def self.feature_name = "word_filter"

      def self.description = "Blocks or flags messages containing filtered words or phrases."

      # Off by default: a fresh community filters nothing until an operator turns
      # it on and supplies a list. Only the bridge defaults on (design 5.5).
      def self.default_enabled? = false

      # A word filter acts on text that a person typed. It runs on a new chat and
      # on an edit (someone editing a clean message to smuggle a term in), and
      # never on a delete, a reaction or a membership event.
      def self.observes = %i[chat edit]

      # The per-scope config shape, for the dashboard and loader to validate
      # against; the runtime path parses Context#config defensively and does not
      # depend on this being run. `entries` keeps its bare-word shorthand while
      # declaring the mapped rule form the dashboard edits field by field.
      def self.config_schema
        Config::Schema.define do
          field :action, :string, default: DEFAULT_ACTION, one_of: ACTIONS
          field :stub_action, :string, default: DEFAULT_STUB_ACTION, one_of: IMPLEMENTED_ACTIONS
          field :exempt_operators, :boolean, default: true
          field :removal_reason, :string, default: DEFAULT_REMOVAL_REASON,
                desc: "the reason shown to the author when a message is removed"
          field Core::RemovalNotice::TTL_FIELD, :integer, default: Core::RemovalNotice::DEFAULT_TTL_SECONDS,
                desc: "seconds the self-deleting removal notice lives before it is removed"
          field Core::RemovalNotice::NOTIFY_FIELD, :boolean, default: true,
                desc: "DM this community's operators when a message is removed here, so an " \
                      "automated removal is never something only the person removed from finds out about"
          field :mute_duration, :duration, default: DEFAULT_MUTE_DURATION
          field :mode, :string, default: DEFAULT_MODE, one_of: FILTER_MODES.keys,
                desc: "how much of the vendored base list applies: off (default), slurs, or slurs_profanity " \
                      "(issue #173)"
          field :vulgarity_mode, :string, one_of: LEGACY_MODE_ALIASES.keys,
                desc: "legacy mode field (none/slurs_only/all), folded into `mode` when `mode` is unset"
          field :custom, :array, default: [],
                desc: "per-scope supplemental words, applied on top of the base list `mode` selects (issue #173)"
          field :entries, :array, of: [:string, Config::Schema.define {
            field :pattern, :string, required: true, desc: "word or pattern to match" do |value, path|
              "#{path}: cannot be blank" if value.strip.empty?
            end
            field :mode, :string, one_of: Ruleset::MODES, default: "literal",
                          desc: "literal, glob, or regular expression matching"
            field :case_sensitive, :boolean, default: false
            field :whole_word, :boolean, default: true
            field :action, :string, one_of: ACTIONS, desc: "what to do when this rule matches"
          }], default: [],
                desc: "advanced per-scope patterns (bare words or mode/action mappings), unioned with `custom`"
          field :ocr, :boolean, default: false,
                desc: "also OCR each photo attachment and match this filter against the text it reads " \
                      "off the image; off by default since OCR is slower and noisier than a QR decode, " \
                      "and most photos carrying visible text are not an evasion attempt (issue #858)"
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
                     warnings: nil, audit: nil, admin_notifier: nil)
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @ephemeral = ephemeral
        @cleanup = cleanup
        @warnings = warnings
        # The shared watchdog removal engine: deletes the origin message and
        # every relayed copy, audits the action, and on a delete posts the
        # self-deleting @mention notice. Shared with the link filter, mention-spam
        # guard and cross-post watchdog, so deletion, shape and TTL live in one place.
        @removal = Watchdog::Removal.new(
          topology: @topology, adapters: @adapters, storage: @storage, logger: @logger,
          source: SOURCE, name: NOTICE_NAME, ephemeral: @ephemeral, cleanup: @cleanup, audit: audit,
          admin_notifier: admin_notifier, alerts: true
        )
      end

      attr_reader :logger

      def call(context)
        ruleset = Ruleset.compile(context.config, logger: @logger, base_terms: base_terms_for(context.config))
        return Outcome.continue([]) if ruleset.empty?
        return Outcome.continue([]) if exempt?(context)

        match = ruleset.match(matchable_text(context))
        return Outcome.continue([]) if match.nil?

        act(context, match)
      end

      private

      # The vendored base terms this scope inherits, chosen by its resolved
      # `mode` (see {WordFilter.resolve_mode}): off -> nothing, slurs -> slurs
      # only, slurs_profanity -> both. The per-scope `custom` and `entries`
      # extend whatever this yields.
      def base_terms_for(config)
        categories = self.class.mode_categories(self.class.resolve_mode(config))
        self.class.base_terms(categories)
      end

      # The text a rule is matched against: the message body plus whatever a
      # photo attachment's QR code decodes to and, when `ocr` is on, whatever
      # OCR reads off that same photo, each bounded so a pathologically long
      # message or attachment cannot become a denial-of-service vector
      # regardless of the pattern.
      def matchable_text(context)
        text = Matcher.bound_input(context.message.body.text)
        attachment_text = Matcher.bound_input(context.attachment_text.text(ocr: ocr_enabled?(context.config)))
        attachment_text.empty? ? text : "#{text}\n#{attachment_text}"
      end

      def ocr_enabled?(config)
        truthy(config_value(config, :ocr), default: false)
      end

      # Whether this message's author is exempt from filtering. Operators are
      # exempt by default (an operator may quote a slur to discuss moderating it);
      # `exempt_operators: false` subjects them to the filter like anyone else.
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

      # Carry out the matched action. delete removes and halts; flag leaves the
      # message and continues; warn and mute escalate the AUTHOR through the
      # warnings service and additionally contain the MESSAGE via the stub action.
      def act(context, match)
        # The person-level half of a warn / mute rule: feed the warnings ladder.
        # A no-op for delete and flag, and for a build with no warnings service.
        escalate(context, match)

        effective = effective_action(match.action, context.config)
        # The delete-everywhere and the audit / notice both live in the shared
        # removal engine: remove the message and its copies on a delete, then
        # record the action and, on a delete, post the notice.
        removed = effective == "delete" ? @removal.remove_everywhere(context.message) : []
        @removal.notice(
          context: context, action: effective, reason: reason_for(context.config),
          requested: match.action,
          metadata: { mode: match.mode, pattern: match.pattern }
        )
        # flag leaves the message (the bridge still relays it); delete halts so the
        # bridge never sees it. The audit event and any warning from #escalate are
        # the operator-facing signals in both cases.
        effective == "flag" ? Outcome.continue([]) : Outcome.halt(removed)
      end

      # The reason shown to the author and stored in the audit trail: the per-scope
      # `removal_reason` override, or the filter's default when it is unset.
      def reason_for(config)
        override = config_value(config, :removal_reason)
        override.nil? || override.to_s.strip.empty? ? DEFAULT_REMOVAL_REASON : override.to_s
      end

      # Escalate a warn / mute rule's AUTHOR through the shared warnings service.
      # A no-op for delete/flag or when no service is wired; never raises,
      # since a failed escalation must not stop the message being contained.
      def escalate(context, match)
        return unless @warnings && DEFERRED_ACTIONS.include?(match.action)

        author = context.message.author
        return if author.nil? || author.native_id.nil?

        origin = context.message.origin
        if match.action == "mute"
          @warnings.sanction(
            community: context.community, subject: author, origin: origin,
            action: :mute, duration: mute_duration(context.config), reason: filter_reason(match),
            issued_by: "word filter"
          )
        else # "warn"
          @warnings.warn(
            community: context.community, subject: author, origin: origin,
            ladder: warnings_ladder(context), max: warnings_max(context),
            expire_after: warnings_expire_after(context), reason: filter_reason(match), issued_by: "word filter"
          )
        end
      rescue StandardError => e
        @logger.warn { "word_filter: could not escalate #{match.action}: #{e.class}: #{e.message}" }
      end

      # The community's own "warnings" feature config, read once so a filter
      # `warn` and a `/warn` command feed one ladder, one maximum and one decay
      # policy. Empty without a control plane (no community to read it from).
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

      def filter_reason(match)
        "word filter: #{match.mode} match on #{match.pattern.inspect}"
      end

      # delete and flag pass through; warn and mute contain the message via the
      # configured stub action, leaving the person-level escalation to
      # #escalate. Without a warnings service only the containment runs.
      def effective_action(action, config)
        return action if IMPLEMENTED_ACTIONS.include?(action)

        stub = normalise_stub(config_value(config, :stub_action))
        unless @warnings
          @logger.warn do
            "word_filter: #{action} escalation needs the warnings service; " \
              "applying only the #{stub.inspect} containment"
          end
        end
        stub
      end

      def normalise_stub(value)
        candidate = value.to_s
        IMPLEMENTED_ACTIONS.include?(candidate) ? candidate : DEFAULT_STUB_ACTION
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      # The control plane hands symbol keys (SnapshotBuilder symbolises them); a
      # hand-built Context in a spec may use either.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def truthy(value, default:)
        return default if value.nil?
        return value if value == true || value == false

        %w[true yes on 1].include?(value.to_s.strip.downcase)
      end

      # A compiled word list: a set of rules plus the matching that picks the
      # decisive action for a piece of text. Compiled once per call from the
      # resolved config; word lists are small, and every compiled regex is bounded
      # so compilation is cheap and safe.
      class Ruleset
        # The bounds and the ReDoS guard live on the shared {Matcher} now; these
        # aliases keep the historical Ruleset-scoped names working for callers and
        # specs that reference them.
        MAX_PATTERN_LENGTH = Matcher::MAX_PATTERN_LENGTH
        MAX_INPUT_CHARS = Matcher::MAX_INPUT_CHARS
        REGEX_TIMEOUT_SECONDS = Matcher::REGEX_TIMEOUT_SECONDS
        MODES = Matcher::MODES
        NESTED_QUANTIFIER = Matcher::NESTED_QUANTIFIER

        # Compile the resolved config into a ruleset. +base_terms+ is the
        # mode-selected slice of the vendored base list, already picked by the
        # caller; Ruleset prepends it, then extends with the per-scope `custom`
        # and `entries` (order only affects {#match}'s severity pick, not
        # whether something matches).
        def self.compile(config, logger: nil, base_terms: [])
          config = {} unless config.is_a?(Hash)
          default_action = normalise_action(fetch(config, :action), logger) || WordFilter::DEFAULT_ACTION
          entries = Array(base_terms) + Array(fetch(config, :custom)) + Array(fetch(config, :entries))
          rules = entries.filter_map do |raw|
            build_rule(raw, default_action, logger)
          end
          new(rules)
        end

        def initialize(rules)
          @rules = rules.freeze
          freeze
        end

        attr_reader :rules

        def empty? = @rules.empty?

        # The decisive match for +text+: the matching rule with the most severe
        # action, or nil when nothing matches. The folded form is computed once
        # and handed to every rule, since there are ninety base-list rules
        # before a community adds a word and folding inside each one would
        # refold the same message ninety times over.
        def match(text)
          text = text.to_s
          folded = TextFold.fold(text)
          hits = @rules.select { |rule| rule.match?(text, folded: folded) }
          return nil if hits.empty?

          hits.max_by { |rule| ACTION_SEVERITY.fetch(rule.action, 0) }
        end

        def self.fetch(config, key)
          return nil unless config.is_a?(Hash)

          config.key?(key) ? config[key] : config[key.to_s]
        end

        # Coerce an entry boolean option (case_sensitive, whole_word) that may
        # arrive as a real boolean (YAML / JSON) or a string, to a boolean.
        def self.boolean(value, default:)
          return default if value.nil?
          return value if value == true || value == false

          %w[true yes on 1].include?(value.to_s.strip.downcase)
        end

        def self.normalise_action(value, logger)
          return nil if value.nil?

          candidate = value.to_s
          return candidate if ACTIONS.include?(candidate)

          logger&.warn { "word_filter: unknown action #{value.inspect}, ignoring" }
          nil
        end

        def self.build_rule(raw, default_action, logger)
          entry = coerce_entry(raw, logger)
          return nil if entry.nil?

          pattern = entry[:pattern].to_s
          if pattern.empty?
            logger&.warn { "word_filter: ignoring an entry with no pattern" }
            return nil
          end

          mode = (entry[:mode] || "literal").to_s
          unless MODES.include?(mode)
            logger&.warn { "word_filter: ignoring #{pattern.inspect}, unknown mode #{mode.inspect}" }
            return nil
          end

          case_sensitive = boolean(entry[:case_sensitive], default: false)
          whole_word = boolean(entry[:whole_word], default: true)
          action = normalise_action(entry[:action], logger) || default_action

          Rule.build(
            pattern: pattern, mode: mode, action: action,
            case_sensitive: case_sensitive, whole_word: whole_word, logger: logger
          )
        end

        # Normalise a raw entry (a bare string shorthand or a mapping) into a
        # symbol-keyed hash, or nil when it is neither.
        def self.coerce_entry(raw, logger)
          case raw
          when String then { pattern: raw }
          when Hash
            raw.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
          else
            logger&.warn { "word_filter: ignoring an entry that is neither text nor a mapping: #{raw.inspect}" }
            nil
          end
        end
      end

      # One compiled rule: a shared {Matcher} (the safe, bounded, ReDoS-guarded
      # compile-and-match core) plus the action to take when it hits. The
      # matching itself is entirely the Matcher's; a Rule only adds "and when it
      # matches, do THIS".
      class Rule
        attr_reader :action

        # Build a rule, or nil when the pattern cannot be compiled safely (too
        # long, pathological, or an invalid regex). Delegates the safety to the
        # shared Matcher, which logs every rejection.
        def self.build(pattern:, mode:, action:, case_sensitive:, whole_word:, logger:)
          matcher = Matcher.build(
            pattern: pattern, mode: mode,
            case_sensitive: case_sensitive, whole_word: whole_word, logger: logger
          )
          return nil if matcher.nil?

          new(action: action, matcher: matcher)
        end

        # +matcher+ is the usual path (from {.build}). The +pattern:/mode:/regex:/
        # substring:+ keywords are the low-level seam: a pre-built Matcher is
        # constructed from them, so a caller (or a spec) can thread in a Regexp it
        # compiled itself.
        def initialize(action:, matcher: nil, pattern: nil, mode: nil, regex: nil, substring: nil, logger: nil)
          @action = action
          @matcher = matcher || Matcher.new(
            pattern: pattern, mode: mode, regex: regex, substring: substring, logger: logger
          )
          freeze
        end

        def pattern = @matcher.pattern

        def mode = @matcher.mode

        def regex = @matcher.regex

        # +folded+ is the ruleset's one fold of this message, passed straight
        # through. A rule that does not fold ignores it.
        def match?(text, folded: nil)
          @matcher.match?(text, folded: @matcher.folds? ? folded : nil)
        end
      end
    end
  end
end
