# frozen_string_literal: true

require "time"

module Rubotty
  module Core
    # Scheduled and recurring announcements: post a message at a future time
    # or on a fixed interval, to one or more channels at once, built on the
    # durable scheduler for at-least-once delivery, recurrence, and boot
    # recovery. {#reconcile} clears the community's pending jobs and
    # re-enqueues from the current config, so it is safe to run on every
    # boot: a recurring job anchors to a fixed epoch grid, and a one-shot
    # whose time has passed is skipped. Off by default, like every non-bridge
    # feature.
    class AnnouncementScheduler
      # The durable-scheduler job kind this service registers and enqueues.
      KIND = "announcement"

      # The feature key its config lives under in feature_settings.
      FEATURE = "scheduled_announcements"

      DEFAULT_NAME = "announcement"

      # @param scheduler [Core::DurableScheduler] registers its handler on
      #   construction, before boot recovery runs
      # @param ephemeral [Core::EphemeralMessage] posts the announcement to each
      #   target endpoint as the bot
      # @param topology [Core::Topology] resolves an endpoint id at fire time
      # @param registry [ControlPlane::Registry, nil] nil on the config path
      # @param logger [#info,#warn]
      # @param clock [#call] returns the current Time; injected in tests
      def initialize(scheduler:, ephemeral:, topology:, logger:, registry: nil, clock: -> { Time.now })
        @scheduler = scheduler
        @ephemeral = ephemeral
        @topology = topology
        @registry = registry
        @logger = logger
        @clock = clock
        @scheduler.register(KIND) { |job| deliver(job) }
      end

      # Reconcile one community's configured announcements into durable jobs.
      # Idempotent, so it is safe to call on every boot and on a config change.
      #
      # @param community [String] the community slug
      # @param announcements [Array<Hash>] the config entries
      # @return [Integer] jobs enqueued
      def reconcile(community:, announcements:)
        @scheduler.forget(kind: KIND, community: community)
        now = @clock.call
        Array(announcements).count do |raw|
          entry = Entry.parse(raw, logger: @logger)
          next false if entry.nil?

          schedule(community, entry, now)
        end
      rescue StandardError => e
        @logger&.warn { "scheduled_announcements: could not reconcile #{community}: #{e.class}: #{e.message}" }
        0
      end

      # Reconcile every community in a control-plane snapshot. A community with
      # the feature switched off is visited too, with an empty schedule, so the
      # forget inside {#reconcile} cancels whatever it had pending: skipping it
      # would leave a recurring job rescheduling itself, since nothing
      # downstream of the enqueue consults the feature again.
      #
      # @param snapshot [ControlPlane::Snapshot]
      # @return [Integer] communities with the feature enabled
      def reconcile_snapshot(snapshot)
        return 0 if snapshot.nil?

        Array(snapshot.communities).count do |community|
          enabled = community.feature_enabled?(nil, FEATURE)
          config = enabled ? community.feature_config(nil, FEATURE) : nil
          reconcile(community: community.slug, announcements: enabled ? fetch(config, :announcements) : [])
          enabled
        end
      end

      private

      # Enqueue one entry as a durable job. Returns true when a job was scheduled,
      # false when a past one-shot was skipped.
      def schedule(community, entry, now)
        if entry.recurring?
          run_at = next_slot(entry.interval, now)
          @scheduler.schedule(
            kind: KIND, run_at: run_at, community: community,
            recurrence: entry.interval, payload: entry.payload
          )
          true
        elsif entry.at.nil? || entry.at <= now
          # A one-shot with no time, or one whose moment has passed: nothing to do.
          false
        else
          @scheduler.schedule(kind: KIND, run_at: entry.at, community: community, payload: entry.payload)
          true
        end
      end

      # The next multiple of +interval+ on the fixed Unix-epoch grid, strictly after
      # +now+, so a re-reconcile after a restart recomputes the SAME next slot.
      def next_slot(interval, now)
        base = now.to_i
        Time.at(((base / interval) + 1) * interval)
      end

      # Post one due announcement to its target endpoints as the bot, resolved
      # from the topology at fire time (ones that no longer exist are
      # skipped). Raising marks the durable job a failure, which is retried.
      def deliver(job)
        payload = job.payload || {}
        endpoints = endpoints_for(job, payload)
        if endpoints.empty?
          @logger&.warn { "scheduled_announcements: job #{job.id} names no live endpoint, skipping" }
          return
        end

        body = payload["body"].to_s
        name = presence(payload["name"]) || DEFAULT_NAME
        @ephemeral.post(endpoints: endpoints, body: RichText.plain(body), name: name, delete_after: 0)
        @logger&.info do
          "scheduled_announcements: posted job #{job.id} to #{endpoints.size} endpoint(s) in #{job.community.inspect}"
        end
      end

      # The endpoints a job may post to. The payload's ids resolve against the
      # merged topology, which spans every tenant, so each one is then held
      # against the community the job carries and refused if it belongs to
      # another. Without a registry there is one community and nothing to cross
      # into, which is the config-file path; with one, a slug naming no live
      # community posts nothing rather than posting unscoped.
      def endpoints_for(job, payload)
        resolved = Array(payload["endpoints"]).filter_map { |id| @topology.endpoint(id.to_s) }
        return resolved if @registry.nil?

        community_id = @registry.current.community(job.community.to_s)&.id
        return refuse_whole_job(job) if community_id.nil?

        resolved.select do |endpoint|
          CommunityScope.permit_or_log(endpoint, community_id, logger: @logger,
                                                              doing: "scheduled_announcements: job #{job.id}")
        end
      end

      def refuse_whole_job(job)
        @logger&.error do
          "scheduled_announcements: job #{job.id} names no live community (#{job.community.inspect}), posting nothing"
        end
        []
      end

      def fetch(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def presence(value)
        value = value.to_s.strip
        value.empty? ? nil : value
      end

      # One configured announcement: the text, its target endpoint ids, and either
      # a recurrence interval or a fixed time. Parsed defensively, so a malformed
      # entry is dropped with a log line rather than crashing the reconcile.
      class Entry
        attr_reader :text, :endpoints, :interval, :at, :name

        def self.parse(raw, logger: nil)
          unless raw.is_a?(Hash)
            logger&.warn { "scheduled_announcements: ignoring an entry that is not a mapping: #{raw.inspect}" }
            return nil
          end

          entry = symbolize(raw)
          text = entry[:text].to_s
          if text.strip.empty?
            logger&.warn { "scheduled_announcements: ignoring an entry with no text" }
            return nil
          end

          endpoints = Array(entry[:channels] || entry[:endpoints]).map(&:to_s).reject(&:empty?).uniq
          if endpoints.empty?
            logger&.warn { "scheduled_announcements: ignoring #{text.inspect}, it names no channels" }
            return nil
          end

          interval = Core::Warnings.duration_seconds(entry[:every] || entry[:interval])
          at = parse_time(entry[:at])
          if (interval.nil? || interval <= 0) && at.nil?
            logger&.warn { "scheduled_announcements: ignoring #{text.inspect}, it has neither `every` nor a valid `at`" }
            return nil
          end

          new(
            text: text, endpoints: endpoints, name: entry[:name],
            interval: interval&.positive? ? interval : nil,
            at: interval&.positive? ? nil : at
          )
        end

        def self.parse_time(value)
          return nil if value.nil?
          return Time.at(value) if value.is_a?(Numeric)

          Time.parse(value.to_s)
        rescue ArgumentError
          nil
        end

        def self.symbolize(hash)
          hash.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
        end

        def initialize(text:, endpoints:, interval: nil, at: nil, name: nil)
          @text = text
          @endpoints = endpoints
          @interval = interval
          @at = at
          @name = name
          freeze
        end

        def recurring? = !@interval.nil?

        # The durable-job payload, JSON-serialisable.
        def payload
          { "endpoints" => @endpoints, "body" => @text, "name" => @name&.to_s }
        end
      end
    end
  end
end
