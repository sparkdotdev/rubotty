# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # Manual, operator-issued mute and unmute, driven from the dashboard
    # rather than a chat command. It writes to the same durable state and
    # schedules on the same job kind as the warnings ladder, so a sanction
    # issued here is indistinguishable once recorded. The dashboard shares
    # only the datastore, never the running bot's adapter connections, so it
    # cannot place a live Discord timeout or Telegram restriction; the expiry
    # job is picked up by whichever bot process is running.
    class ModerationActions
      # Raised for a mute request that cannot be carried out (no platform or user
      # id, or a duration that cannot be read).
      class Invalid < Rubotty::Error; end

      # @param store [Core::WarningsStore::Sequel, Core::WarningsStore::Null]
      # @param scheduler [Core::DurableScheduler] schedules a timed mute's reversal
      # @param audit [Core::AuditLog::Sequel, Core::AuditLog::Null, nil] the durable
      #   moderation history a mute/unmute is recorded to
      # @param logger [#warn, nil]
      # @param clock [#call] returns the current Time; injected in tests
      def initialize(store:, scheduler:, audit: nil, logger: nil, clock: -> { Time.now })
        @store = store
        @scheduler = scheduler
        @audit = audit || Core::AuditLog::Null.new
        @logger = logger
        @clock = clock
      end

      # Every currently active mute in a community, most recently issued first.
      # Bans recorded by the ladder are deliberately excluded.
      #
      # @param community [Models::Community]
      # @return [Array<Core::WarningsStore::Sanction>]
      def active_mutes(community:)
        @store.community_sanctions(community: community.slug, active: true)
              .select { |sanction| sanction.action == "mute" }
      rescue StorageError => e
        @logger&.warn { "moderation: could not list active mutes: #{e.message}" }
        []
      end

      # Mute a subject identified by platform + native id.
      #
      # @param duration [String, Numeric, nil] "1h" / "30m" / "1d" / a plain
      #   number of seconds, or nil/blank for an indefinite mute
      # @return [Core::WarningsStore::Sanction, nil] nil only when the store could
      #   not record the sanction (a transient storage failure, logged and
      #   swallowed rather than raised)
      # @raise [Invalid] missing platform/user id, or an unreadable duration
      def mute(community:, adapter:, native_id:, username: nil, display: nil,
               duration: nil, reason: nil, issued_by: nil)
        adapter = presence(adapter)
        native_id = presence(native_id)
        raise Invalid, "a platform and a user id are required to mute someone." if adapter.nil? || native_id.nil?

        seconds = parse_duration(duration)
        now = @clock.call
        until_at = seconds ? now + seconds : nil

        record = begin
          @store.record_sanction(
            community: community.slug, adapter: adapter, subject_native_id: native_id,
            subject_username: presence(username), action: :mute, until_at: until_at,
            endpoints: [], now: now
          )
        rescue StorageError => e
          @logger&.warn { "moderation: could not record a mute: #{e.message}" }
          nil
        end
        return record if record.nil?

        schedule_expiry(community: community, adapter: adapter, native_id: native_id,
                        record: record, until_at: until_at) if seconds
        audit_action(
          community: community, action: "mute", adapter: adapter, native_id: native_id,
          display: presence(display) || presence(username), reason: reason, issued_by: issued_by,
          outcome: seconds ? "until #{until_at}" : "indefinite", metadata: { duration_seconds: seconds }
        )
        record
      end

      # Lift an active mute early, by its `active_sanctions` row id.
      #
      # @param community [Models::Community] the mute must belong to this community
      # @param id [Integer, String]
      # @return [Core::WarningsStore::Sanction, nil] the lifted row, or nil when no
      #   such sanction exists in this community (a bad id, or another community's)
      def unmute(community:, id:)
        sanction = @store.find_sanction(community: community.slug, id: id)
        return nil if sanction.nil?

        @store.lift_sanction(community: community.slug, id: sanction.id, now: @clock.call)
        cancel_expiry(sanction, community.slug)
        audit_action(
          community: community, action: "unmute", adapter: sanction.adapter,
          native_id: sanction.subject_native_id, display: sanction.subject_username,
          outcome: "lifted manually"
        )
        sanction
      rescue StorageError => e
        @logger&.warn { "moderation: could not unmute ##{id}: #{e.message}" }
        nil
      end

      private

      # A duration string/number to whole seconds, or nil for "no duration given"
      # (an indefinite mute). Reuses {Core::Warnings.duration_seconds} so the form
      # accepts the same "1h" / "30m" / "1d" vocabulary the ladder's config does.
      def parse_duration(duration)
        return nil if blank?(duration)

        seconds = Core::Warnings.duration_seconds(duration)
        raise Invalid, "that duration could not be understood (try \"1h\", \"30m\", or \"1d\")." if seconds.nil?

        seconds
      end

      # Schedule the durable job that reverses a timed mute at `until_at`, in the
      # exact payload shape Core::Warnings::Service#persist_sanction builds. An
      # empty endpoint list means the expiry has only the sanction row to lift.
      def schedule_expiry(community:, adapter:, native_id:, record:, until_at:)
        job_id = @scheduler.schedule(
          kind: Core::Warnings::EXPIRE_KIND, run_at: until_at, community: community.slug,
          payload: {
            sanction_id: record.id, community: community.slug, adapter: adapter,
            native_id: native_id.to_s, action: "mute", endpoints: []
          }
        )
        @store.attach_job(record.id, job_id) if job_id
      rescue StorageError => e
        @logger&.warn { "moderation: could not schedule the mute expiry: #{e.message}" }
      end

      # Cancel a still-pending expiry job so a manual unmute is not overwritten
      # by the scheduled one firing later, mirroring keyword_watches.rb's
      # cancel_expiry for the equivalent case.
      def cancel_expiry(sanction, slug)
        @scheduler.cancel(kind: Core::Warnings::EXPIRE_KIND, community: slug) do |payload|
          payload["sanction_id"] == sanction.id
        end
      end

      def audit_action(community:, action:, adapter:, native_id:, display: nil, reason: nil,
                       issued_by: nil, outcome: nil, metadata: nil)
        @audit.record(
          community: community.slug, source: "dashboard", action: action, adapter: adapter,
          actor: issued_by, subject: display, subject_native_id: native_id,
          reason: presence(reason), outcome: outcome, metadata: metadata
        )
      rescue StorageError => e
        @logger&.warn { "moderation: could not record the audit event: #{e.message}" }
      end

      def blank?(value)
        value.nil? || value.to_s.strip.empty?
      end

      def presence(value)
        return nil if value.nil?

        string = value.to_s.strip
        string.empty? ? nil : string
      end
    end
  end
end
