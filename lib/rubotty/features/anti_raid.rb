# frozen_string_literal: true

require "monitor"
require "json"
require "securerandom"

module Rubotty
  module Features
    # Anti-raid / mass-join protection with a temporary lockdown mode. Detection
    # is a sliding window kept in memory per channel; the lockdown is durable and
    # stamped with an `until` time, so a restart cannot leave a community locked.
    #
    #   announce  (default) no action, operators act by hand
    #   kick/ban  remove or ban each joiner for the lockdown duration
    #
    # Kick and ban skip operators and bots, and halt the pipeline.
    class AntiRaid < Base
      include AdapterLookup

      # The joiner responses, in ascending severity.
      ACTIONS = %w[announce kick ban].freeze

      DEFAULT_ACTION = "announce"
      # Five joins inside thirty seconds is past organic growth for most channels.
      DEFAULT_JOIN_THRESHOLD = 5
      DEFAULT_WINDOW = 30
      # Long enough to outlast a burst, short enough to clear without an operator.
      DEFAULT_LOCKDOWN_DURATION = 300

      DEFAULT_NOTICE =
        "Raid protection triggered: a burst of new joins was detected, so this channel is in temporary lockdown."

      # The sender label the lockdown notices are posted under.
      DEFAULT_NAME = "anti-raid"

      # Caps how many channel scopes' join windows are kept in memory, mirroring
      # anti_spam's own flood-key cap: a long-running bridge across many channels,
      # or one whose rooms get created and abandoned, must not accumulate one
      # @windows entry forever for every channel that has ever seen a single join.
      MAX_TRACKED_WINDOWS = 4096

      # Key prefix for the durable lockdown record in the shared key-value state.
      STATE_PREFIX = "anti_raid:lockdown:"

      # The audit `source` key, matching the feature name the way every other
      # filter's does.
      SOURCE = "anti_raid"

      def self.feature_name = "anti_raid"

      def self.description = "Detects a burst of joins and trips a temporary lockdown."

      # A fresh community locks nothing down until an operator turns this on.
      def self.default_enabled? = false

      def self.observes = %i[join]

      # The per-scope config shape, for the dashboard and the loader to validate.
      def self.config_schema
        Config::Schema.define do
          field :join_threshold, :integer, default: DEFAULT_JOIN_THRESHOLD,
                desc: "joins within the window that trip a lockdown"
          field :window, :duration, default: DEFAULT_WINDOW,
                desc: "the sliding detection window, in seconds"
          field :lockdown_duration, :duration, default: DEFAULT_LOCKDOWN_DURATION,
                desc: "how long a tripped lockdown lasts before it self-clears"
          field :action, :string, default: DEFAULT_ACTION, one_of: ACTIONS,
                desc: "what to do to a member who joins during lockdown"
          field :notice, :string, default: DEFAULT_NOTICE, desc: "message posted when a lockdown trips"
          field :lift_notice, :string, desc: "optional message posted when a lockdown lifts"
          field :exempt_operators, :boolean, default: true
          field :name, :string, default: DEFAULT_NAME, desc: "sender label the lockdown notices use"
        end
      end

      # @param topology [Core::Topology] only used to build the default ephemeral sender
      # @param adapters [Hash{[Symbol,String]=>Adapters::Base}] the shared map
      # @param storage the message map, which also backs the durable key-value
      #   state the lockdown record lives in
      # @param ephemeral [Core::EphemeralMessage, nil] posts the lockdown notices
      # @param cleanup [Core::Scheduler, nil] fires the optional lift notice;
      #   without one only the notice is skipped
      def initialize(topology:, adapters:, storage:, logger:,
                     ephemeral: nil, cleanup: nil,
                     audit: nil, clock: -> { Time.now })
        super()
        @topology = topology
        @adapters = adapters
        @storage = storage
        @logger = logger
        @cleanup = cleanup
        # A no-op Null sink by default; the runtime injects the real store.
        @audit = audit || Core::AuditLog::Null.new
        @clock = clock
        @monitor = Monitor.new
        # scope id => Array<Float> of recent join times, the in-memory window.
        @windows = {}
        @ephemeral = ephemeral || Core::EphemeralMessage.new(
          adapters: adapters, topology: topology, session_id: SecureRandom.uuid, logger: logger
        )
      end

      attr_reader :logger

      def call(context)
        scope = scope_id(context)
        now = @clock.call.to_f

        count = record_join(scope, now, window_seconds(context.config))
        locked = lockdown_active?(scope, now)

        unless locked
          threshold = join_threshold(context.config)
          if threshold.positive? && count >= threshold
            trip_lockdown(context, scope, now)
            locked = true
          end
        end

        # Contain the joiner only while locked, and halt only when actually removed.
        return Outcome.halt([]) if locked && enforce(context)

        Outcome.continue([])
      end

      private

      # Record this join in the scope's sliding window and return how many joins
      # now fall inside it. Entries older than +window+ seconds are dropped.
      def record_join(scope, now, window)
        @monitor.synchronize do
          times = @windows.delete(scope) || []
          times << now
          cutoff = now - window
          times.reject! { |time| time < cutoff }
          # Reinserted at the tail, so insertion order is recency order and the
          # pruner below can stop at the first scope still inside its window.
          @windows[scope] = times
          prune_windows(cutoff)
          times.size
        end
      end

      # Drop scopes whose window has fully aged out, then evict the
      # least-recently-seen ones down to the cap, under the monitor. Same
      # front-shift as anti_spam's own prune_flood, for the same reason.
      def prune_windows(cutoff)
        while (oldest = @windows.first)
          times = oldest.last
          break unless times.empty? || times.last < cutoff

          @windows.shift
        end
        @windows.shift while @windows.size > MAX_TRACKED_WINDOWS
      end

      # Whether +scope+ is under lockdown: the durable record is present and its
      # `until` horizon is still in the future, judged against this feature's
      # own clock rather than the backend's row-expiry timing.
      def lockdown_active?(scope, now)
        raw = @storage.get_state(state_key(scope))
        return false if raw.nil?

        data = JSON.parse(raw)
        now < data["until"].to_f
      rescue JSON::ParserError, StorageError => e
        @logger.warn { "anti_raid: could not read the lockdown state: #{e.message}" }
        false
      end

      # Enter lockdown: write the durable record, alert the channel, schedule the
      # optional lift notice. Never raises, so a failure here cannot stop the
      # containment that follows.
      def trip_lockdown(context, scope, now)
        duration = lockdown_duration(context.config)
        until_at = now + duration
        persist_lockdown(scope, since: now, until_at: until_at)
        announce_lockdown(context)
        schedule_lift_notice(context, duration)
        audit(context, event: "tripped", detail: "lockdown for #{duration}s")
      rescue StandardError => e
        @logger.warn { "anti_raid: could not trip lockdown: #{e.class}: #{e.message}" }
      end

      def persist_lockdown(scope, since:, until_at:)
        @storage.put_state(
          state_key(scope),
          JSON.generate("since" => since, "until" => until_at),
          expires_at: Time.at(until_at)
        )
      rescue StorageError => e
        # Losing the record means this trip does not stick; it must not crash the
        # pipeline.
        @logger.warn { "anti_raid: could not persist the lockdown record: #{e.message}" }
      end

      # Apply the configured response to a joiner during lockdown. True only when
      # a kick or ban was actually issued, which is what lets the caller halt.
      def enforce(context)
        action = action_for(context.config)
        return false if action == "announce"
        return false if exempt?(context)

        remove_joiner(context, action.to_sym)
      end

      # Spares the bot itself always, and a known operator when exempt_operators
      # is on, so an operator rejoining mid-raid is not caught in the net.
      def exempt?(context)
        author = context.message.author
        return true if author.nil? || author.native_id.nil? || author.bot?
        return false unless truthy(config_value(context.config, :exempt_operators), default: true)

        # This community's own directory and nothing else. A room key is unique
        # only within one, so an unresolved community denies rather than widening
        # to the merged deployment-wide view. Empty is still not short-circuited:
        # the deployment-configured owner floor is invisible to Directory#empty?.
        directory = context.operators
        return false if directory.nil?

        !directory.resolve(context.message.origin.adapter_name, author.native_id,
                           username: author.username).nil?
      end

      # Issue a kick or ban against the joiner on the platform they joined, returning
      # true only if it went through. Never raises.
      def remove_joiner(context, action)
        endpoint = context.message.origin
        adapter = adapter_for(endpoint)
        return false if adapter.nil? || !adapter.capabilities_for(endpoint).moderates?(action)

        author = context.message.author
        command = Core::Moderation::Command.new(
          action: action, issuer: nil, origin: endpoint, target_user_id: author.native_id
        )
        adapter.moderate(command, endpoint, nil)
        audit(context, event: action.to_s, detail: "removed joiner #{author.native_id}")
        true
      rescue StandardError => e
        @logger.warn { "anti_raid: could not #{action} joiner on #{endpoint.id}: #{e.class}: #{e.message}" }
        false
      end

      # Post the lockdown notice to the channel as the bot. Persistent, so it
      # stays visible while the lockdown holds.
      def announce_lockdown(context)
        text = notice_for(context.config)
        return if text.nil? || text.to_s.strip.empty?

        @ephemeral.post(
          endpoints: [context.message.origin],
          body: Core::RichText.plain(text.to_s),
          name: name_for(context.config),
          delete_after: 0
        )
      rescue StandardError => e
        @logger.warn { "anti_raid: could not post the lockdown notice: #{e.message}" }
      end

      # Schedule the optional "lockdown lifted" notice. A restart loses the
      # notice; the lockdown itself still lifts on its own.
      def schedule_lift_notice(context, duration)
        text = config_value(context.config, :lift_notice)
        return if text.nil? || text.to_s.strip.empty?
        return if @cleanup.nil? || duration <= 0

        origin = context.message.origin
        name = name_for(context.config)
        @cleanup.after(duration) do
          @ephemeral.post(endpoints: [origin], body: Core::RichText.plain(text.to_s), name: name, delete_after: 0)
        end
      rescue StandardError => e
        @logger.warn { "anti_raid: could not schedule the lift notice: #{e.message}" }
      end

      # A structured, operator-facing record of every lockdown action: one
      # durable row in the moderation audit log, and the log line beside it.
      def audit(context, event:, detail: nil)
        record_audit(context, event, detail)
        @logger.info do
          fields = {
            event: "anti_raid.#{event}",
            detail: detail,
            member: context.message.author&.any_name,
            community: context.community&.slug,
            channel: scope_id(context)
          }
          "anti_raid " + fields.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        end
      end

      # Never raises: a lost audit line must not derail a lockdown.
      def record_audit(context, event, detail)
        message = context.message
        author = message&.author
        @audit.record(
          community: context.community&.slug,
          source: SOURCE,
          action: event.to_s,
          adapter: message&.origin&.adapter_name,
          channel: scope_id(context),
          actor: SOURCE,
          subject: author&.any_name,
          subject_native_id: author&.native_id,
          target_ref: message&.ref&.to_s,
          reason: detail,
          outcome: event.to_s,
          metadata: { detail: detail }
        )
      rescue StandardError => e
        @logger.warn { "anti_raid: could not record the audit event: #{e.message}" }
      end

      # The endpoint the join arrived on, so one channel's lockdown does not spill
      # onto another.
      def scope_id(context) = context.message.origin.id

      def state_key(scope) = "#{STATE_PREFIX}#{scope}"

      def join_threshold(config)
        integer(config_value(config, :join_threshold), default: DEFAULT_JOIN_THRESHOLD)
      end

      def window_seconds(config)
        duration(config_value(config, :window), default: DEFAULT_WINDOW)
      end

      def lockdown_duration(config)
        duration(config_value(config, :lockdown_duration), default: DEFAULT_LOCKDOWN_DURATION)
      end

      def action_for(config)
        candidate = config_value(config, :action).to_s
        ACTIONS.include?(candidate) ? candidate : DEFAULT_ACTION
      end

      def notice_for(config)
        return DEFAULT_NOTICE unless config.is_a?(Hash) && (config.key?(:notice) || config.key?("notice"))

        config_value(config, :notice)
      end

      def name_for(config)
        value = config_value(config, :name)
        value.nil? || value.to_s.strip.empty? ? DEFAULT_NAME : value.to_s
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

      # Accepts an Integer, a "30s" style string, or a bare numeric string.
      def duration(value, default:)
        return default if value.nil?

        seconds = Core::Warnings.duration_seconds(value)
        seconds.nil? ? default : seconds
      end
    end
  end
end
