# frozen_string_literal: true

require "monitor"

module Rubotty
  module Features
    # Flood and duplicate detection, run before the bridge on every chat
    # message with no external call. Flood counts per (channel, author);
    # duplicate keys on normalised text alone, so a copy-paste drop across
    # several accounts is caught too. On a hit it takes the word filter's own
    # configured action, so a spam warn or mute feeds the same escalation
    # ladder a /warn command does; without a warnings service wired, warn and
    # mute degrade to the stub action.
    class AntiSpam < Base
      IMPLEMENTED_ACTIONS = %w[delete flag].freeze
      DEFERRED_ACTIONS = %w[warn mute].freeze
      ACTIONS = (IMPLEMENTED_ACTIONS + DEFERRED_ACTIONS).freeze
      ACTION_SEVERITY = { "flag" => 0, "warn" => 1, "mute" => 2, "delete" => 3 }.freeze

      DEFAULT_ACTION = "delete"
      DEFAULT_STUB_ACTION = "delete"

      DEFAULT_FLOOD_THRESHOLD = 5
      DEFAULT_FLOOD_WINDOW = 5
      DEFAULT_DUPLICATE_THRESHOLD = 3
      DEFAULT_DUPLICATE_WINDOW = 60
      # Shorter messages are ignored for duplicate detection, so ordinary short
      # replies are not mistaken for a spam drop.
      DEFAULT_DUPLICATE_MIN_LENGTH = 8

      # Every other filter explains itself when it removes a message. Without a
      # default here a member's message simply vanished with nothing said.
      DEFAULT_NOTICE = "That message was removed because it looked like spam."
      DEFAULT_NOTICE_DELETE_AFTER = 15
      DEFAULT_MUTE_DURATION = 3600

      # The audit `source` key and the log prefix the shared removal engine uses.
      SOURCE = "anti_spam"
      NOTICE_NAME = "anti-spam"

      # Cap on distinct recent messages one channel tracks for duplicate
      # detection, a backstop against unbounded growth between prunes.
      MAX_TRACKED_DUPLICATES = 512

      # Cap on distinct (channel, author) pairs the flood window tracks. One
      # bucket per person per channel outlives the window it holds, so without
      # this a long-lived process keeps a key for everyone it ever saw.
      MAX_TRACKED_FLOOD_KEYS = 4096

      def self.feature_name = "anti_spam"

      def self.description = "Detects message flooding and duplicate spam and acts on it."

      def self.default_enabled? = false

      # New chats only: an edit is not a new message for flood purposes, and
      # re-counting an edited message as a fresh duplicate would be wrong.
      def self.observes = %i[chat]

      def self.config_schema
        Config::Schema.define do
          field :flood_threshold, :integer, default: DEFAULT_FLOOD_THRESHOLD,
                desc: "messages within the flood window that trip the flood action; 0 disables flood detection"
          field :flood_window, :duration, default: DEFAULT_FLOOD_WINDOW, desc: "the flood detection window, in seconds"
          field :duplicate_threshold, :integer, default: DEFAULT_DUPLICATE_THRESHOLD,
                desc: "repeats of a message within the window that trip the action; 0 disables duplicate detection"
          field :duplicate_window, :duration, default: DEFAULT_DUPLICATE_WINDOW,
                desc: "the duplicate detection window, in seconds"
          field :duplicate_min_length, :integer, default: DEFAULT_DUPLICATE_MIN_LENGTH,
                desc: "shortest message length considered for duplicate detection"
          field :action, :string, default: DEFAULT_ACTION, one_of: ACTIONS
          field :stub_action, :string, default: DEFAULT_STUB_ACTION, one_of: IMPLEMENTED_ACTIONS
          field :exempt_operators, :boolean, default: true
          field :notice, :string, default: DEFAULT_NOTICE,
                desc: "what the author is told when a message is removed as spam; blank stays silent"
          field :notice_delete_after, :duration, default: DEFAULT_NOTICE_DELETE_AFTER
          field :mute_duration, :duration, default: DEFAULT_MUTE_DURATION
        end
      end

      # @param topology [Core::Topology] resolves a mapped ref back to a live
      #   endpoint during removal
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param storage the message map, for resolving cross-platform copies
      # @param ephemeral [Core::EphemeralMessage, nil] posts the removal notice
      # @param cleanup [Core::Scheduler, nil] fires the notice's self-delete
      # @param warnings [Core::Warnings::Service, nil] the shared warnings coordinator
      def initialize(topology:, adapters:, storage:, logger:,
                     ephemeral: nil, cleanup: nil,
                     warnings: nil, audit: nil,
                     clock: -> { Time.now })
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @ephemeral = ephemeral
        @cleanup = cleanup
        @warnings = warnings
        @clock = clock
        # Anti-spam posts its own removal notice in {#notify}, so the shared
        # removal engine is constructed for deletion only, without a notice.
        @remover = Watchdog::Removal.new(
          topology: @topology, adapters: @adapters, storage: @storage, logger: @logger,
          source: SOURCE, audit: audit
        )
        @monitor = Monitor.new
        # [scope, author] => Array<Float> recent message times, the flood window.
        @flood = {}
        # scope => { normalised_text => Array<Float> }, the duplicate window.
        @dupes = {}
      end

      attr_reader :logger

      def call(context)
        return Outcome.continue([]) if exempt?(context)

        reason = detect(context)
        return Outcome.continue([]) if reason.nil?

        act(context, reason)
      end

      private

      # Records both windows before checking either, so a message counts toward
      # each enabled mode regardless of which one trips. Returns [mode, count] or nil.
      def detect(context)
        config = context.config
        message = context.message
        scope = scope_id(message)
        now = @clock.call.to_f

        flood_count = record_flood(scope, message, now, config)
        dupe_count = record_duplicate(scope, message, now, config)

        threshold = flood_threshold(config)
        return [:flood, flood_count] if threshold.positive? && flood_count && flood_count >= threshold

        dup_threshold = duplicate_threshold(config)
        return [:duplicate, dupe_count] if dup_threshold.positive? && dupe_count && dupe_count >= dup_threshold

        nil
      end

      # Record this message in the per-(scope, author) flood window and return the
      # count now inside it. nil when flood detection is off or the author has no id.
      def record_flood(scope, message, now, config)
        window = flood_window(config)
        return nil unless flood_threshold(config).positive?

        author = message.author
        return nil if author.nil? || author.native_id.nil?

        key = [scope, "#{message.origin.adapter_name}:#{author.native_id}"]
        @monitor.synchronize do
          times = @flood.delete(key) || []
          times << now
          cutoff = now - window
          times.reject! { |time| time < cutoff }
          # Reinserted at the tail, so insertion order is recency order and the
          # pruner below can stop at the first bucket still inside its window.
          @flood[key] = times
          prune_flood(cutoff)
          times.size
        end
      end

      # Drop (channel, author) buckets that have fully aged out, then evict
      # the least-recently-seen keys down to the cap, under the monitor; the
      # bucket the caller just wrote always survives. Both bounds shift from
      # the front, so this costs what it evicts rather than the size of the
      # whole map on every message.
      def prune_flood(cutoff)
        while (oldest = @flood.first)
          times = oldest.last
          break unless times.empty? || times.last < cutoff

          @flood.shift
        end
        @flood.shift while @flood.size > MAX_TRACKED_FLOOD_KEYS
      end

      # Record this message's normalised text in the per-scope duplicate window and
      # return how many copies now fall inside it. nil when duplicate detection is
      # off or the message is too short.
      def record_duplicate(scope, message, now, config)
        return nil unless duplicate_threshold(config).positive?

        normalised = normalise(message.body.text)
        return nil if normalised.length < duplicate_min_length(config)

        window = duplicate_window(config)
        @monitor.synchronize do
          bucket = (@dupes[scope] ||= {})
          times = bucket.delete(normalised) || []
          times << now
          cutoff = now - window
          times.reject! { |time| time < cutoff }
          bucket[normalised] = times
          prune_duplicates(bucket, cutoff)
          times.size
        end
      end

      # Drop text keys that have fully aged out, then evict the least-recently-seen
      # keys down to the cap, under the monitor. Same front-shift as {#prune_flood},
      # for the same reason.
      def prune_duplicates(bucket, cutoff)
        while (oldest = bucket.first)
          times = oldest.last
          break unless times.empty? || times.last < cutoff

          bucket.shift
        end
        bucket.shift while bucket.size > MAX_TRACKED_DUPLICATES
      end

      # Fold case and collapse whitespace so trivial reformatting of the same
      # payload is still recognised as a duplicate. No fuzzy distance matching.
      def normalise(text)
        text.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      # Spares a known operator when exempt_operators is on.
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

      # Delete removes and halts; flag leaves the message and continues; warn and
      # mute escalate the author and contain the message via the stub action.
      def act(context, reason)
        requested = requested_action(context.config)
        escalate(context, requested, reason)

        effective = effective_action(requested, context.config)
        audit(context, reason, requested, effective)

        case effective
        when "flag"
          Outcome.continue([])
        else # "delete"
          removed = @remover.remove_everywhere(context.message)
          notify(context)
          Outcome.halt(removed)
        end
      end

      def escalate(context, requested, reason)
        return unless @warnings && DEFERRED_ACTIONS.include?(requested)

        author = context.message.author
        return if author.nil? || author.native_id.nil?

        origin = context.message.origin
        if requested == "mute"
          @warnings.sanction(
            community: context.community, subject: author, origin: origin,
            action: :mute, duration: mute_duration(context.config), reason: spam_reason(reason),
            issued_by: "anti-spam"
          )
        else # "warn"
          @warnings.warn(
            community: context.community, subject: author, origin: origin,
            ladder: warnings_ladder(context), max: warnings_max(context),
            expire_after: warnings_expire_after(context), reason: spam_reason(reason), issued_by: "anti-spam"
          )
        end
      rescue StandardError => e
        @logger.warn { "anti_spam: could not escalate #{requested}: #{e.class}: #{e.message}" }
      end

      # The community's own "warnings" feature config, read once so this filter
      # and `/warn` feed one ladder, one maximum and one decay policy. Empty
      # without a control plane (no community to read it from).
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

      def spam_reason(reason)
        mode, count = reason
        "anti-spam: #{mode} (#{count})"
      end

      def effective_action(action, config)
        return action if IMPLEMENTED_ACTIONS.include?(action)

        stub = normalise_stub(config_value(config, :stub_action))
        unless @warnings
          @logger.warn do
            "anti_spam: #{action} escalation needs the warnings service; applying only the #{stub.inspect} containment"
          end
        end
        stub
      end

      def notify(context)
        # Unset falls back to the default, so a removal explains itself out of
        # the box. Explicitly blank still means say nothing.
        text = config_value(context.config, :notice)
        text = DEFAULT_NOTICE if text.nil?
        return if text.to_s.strip.empty?
        return if @ephemeral.nil?

        delay = duration(config_value(context.config, :notice_delete_after), default: DEFAULT_NOTICE_DELETE_AFTER)
        group = @ephemeral.post(
          endpoints: [context.message.origin],
          body: Core::RichText.plain(text.to_s),
          name: NOTICE_NAME,
          delete_after: delay
        )
        @cleanup.after(delay) { group.delete_now } if delay.positive? && @cleanup && group.any?
      rescue StandardError => e
        @logger.warn { "anti_spam: could not post the removal notice: #{e.message}" }
      end

      # A structured, operator-facing record of every action taken: one durable
      # row in the moderation audit log, and the log line beside it.
      def audit(context, reason, requested, effective)
        mode, count = reason
        record_audit(context, mode, count, requested, effective)
        @logger.info do
          fields = {
            event: "anti_spam.#{mode}",
            action: effective,
            requested: requested,
            count: count,
            message: context.message.ref.to_s,
            author: context.message.author&.any_name,
            community: context.community&.slug,
            channel: scope_key(context)
          }
          "anti_spam " + fields.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        end
      end

      # The durable row, written through the shared removal engine so anti-spam
      # lands in the same table and under the same shape as every other filter.
      # Never raises: a lost audit line must not derail containment.
      def record_audit(context, mode, count, requested, effective)
        @remover.notice(
          context: context, action: effective, reason: spam_reason([mode, count]),
          requested: requested == effective ? nil : requested,
          metadata: { mode: mode.to_s, count: count }
        )
      rescue StandardError => e
        @logger.warn { "anti_spam: could not record the audit event: #{e.message}" }
      end

      def scope_id(message) = message.origin.id

      def scope_key(context)
        if context.channel.respond_to?(:endpoint_key)
          context.channel.endpoint_key
        else
          context.message.origin.id
        end
      end

      def requested_action(config)
        candidate = config_value(config, :action).to_s
        ACTIONS.include?(candidate) ? candidate : DEFAULT_ACTION
      end

      def normalise_stub(value)
        candidate = value.to_s
        IMPLEMENTED_ACTIONS.include?(candidate) ? candidate : DEFAULT_STUB_ACTION
      end

      def flood_threshold(config) = integer(config_value(config, :flood_threshold), default: DEFAULT_FLOOD_THRESHOLD)

      def flood_window(config) = duration(config_value(config, :flood_window), default: DEFAULT_FLOOD_WINDOW)

      def duplicate_threshold(config)
        integer(config_value(config, :duplicate_threshold), default: DEFAULT_DUPLICATE_THRESHOLD)
      end

      def duplicate_window(config)
        duration(config_value(config, :duplicate_window), default: DEFAULT_DUPLICATE_WINDOW)
      end

      def duplicate_min_length(config)
        integer(config_value(config, :duplicate_min_length), default: DEFAULT_DUPLICATE_MIN_LENGTH)
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

      def integer(value, default:)
        return default if value.nil?
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)

        default
      end

      def duration(value, default:)
        return default if value.nil?

        seconds = Core::Warnings.duration_seconds(value)
        seconds.nil? ? default : seconds
      end
    end
  end
end
