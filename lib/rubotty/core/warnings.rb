# frozen_string_literal: true

require "zlib"

module Rubotty
  module Core
    # Warnings with memory: an operator issues one, {Service} persists it,
    # counts the subject's active strikes, DMs them their new level against
    # a configured maximum, and applies the mapped {Ladder} penalty (a
    # temp/permanent mute, temp/permanent ban, or removal) when a strike
    # crosses a threshold, previewing the next rung's penalty too. A warning
    # decays on its own configured expiry, dropping the level and DMing the
    # decrease. Both {Features::Warnings} (`/warn`) and the word filter feed
    # one {Service}, so both share a ladder and this DM machinery.
    module Warnings
      # The durable-scheduler handler kind that reverses an expired sanction. The
      # runtime registers {Service#expire} under it before the boot recovery runs.
      EXPIRE_KIND = "expire_sanction"

      # The durable-scheduler handler kind that decays a warning on its own
      # configured expiry. Registered against {Service#decay} the same way.
      DECAY_KIND = "expire_warning"

      # The actions the ladder and the word filter can apply, and how each is
      # reversed when its sanction expires. A kick has no reverse: removal from
      # the community is a one-shot action, never scheduled or lifted.
      REVERSE = { mute: :unmute, ban: :unban }.freeze
      SANCTION_ACTIONS = (REVERSE.keys + [:kick]).freeze

      # The in-room notice a muted author gets when no DM could reach them.
      # Short-lived, since it is for one person and the room does not need a
      # standing record of somebody's mute, and rate limited per author.
      DROP_NOTICE_NAME = "warnings"
      DROP_NOTICE_TTL = 60
      DROP_NOTICE_COOLDOWN = 60

      # Time units for a ladder duration written as "1h" / "30m" / "1d". A bare
      # number is seconds.
      DURATION_UNITS = {
        "s" => 1, "sec" => 1, "secs" => 1, "second" => 1, "seconds" => 1,
        "m" => 60, "min" => 60, "mins" => 60, "minute" => 60, "minutes" => 60,
        "h" => 3600, "hr" => 3600, "hrs" => 3600, "hour" => 3600, "hours" => 3600,
        "d" => 86_400, "day" => 86_400, "days" => 86_400,
        "w" => 604_800, "week" => 604_800, "weeks" => 604_800
      }.freeze

      # The mute argument a permanent mute (nil duration) is applied with: long
      # enough that an adapter with its own cap (Discord/Fluxer clamp to 28
      # days) reaches for its own maximum instead of a short built-in default.
      PERMANENT_MUTE_ARGUMENT_SECONDS = 100 * 365 * 86_400

      module_function

      # Whole seconds from a number or a "1h" / "2 days" string, nil if unreadable.
      def duration_seconds(value)
        return nil if value.nil?
        return value.to_i if value.is_a?(Numeric)

        match = value.to_s.strip.downcase.match(/\A(\d+)\s*([a-z]*)\z/)
        return nil if match.nil?

        amount = match[1].to_i
        unit = match[2]
        return amount if unit.empty?

        multiplier = DURATION_UNITS[unit]
        multiplier && amount * multiplier
      end

      # The named app lock that serializes one subject's strikes, hashed rather
      # than spelled out: MySQL rejects a GET_LOCK name past 64 characters, and a
      # community, platform and native id spelled out together run well past it.
      def subject_lock_name(community, adapter, native_id)
        "warnings_#{Zlib.crc32([community, adapter, native_id].map(&:to_s).join(":"))}"
      end

      # The compact form a duration reads back in: "45s" / "30m" / "2h" / "3d".
      def human_duration(seconds)
        seconds = seconds.to_i
        return "#{seconds}s" if seconds < 60
        return "#{seconds / 60}m" if seconds < 3600
        return "#{seconds / 3600}h" if seconds < 86_400

        "#{seconds / 86_400}d"
      end

      # How a penalty reads to a person. Module level because the DM and the
      # in-room notice both say it, about the same sanction, and two copies of
      # this would be two wordings for one event.
      def penalty_phrase(action, duration)
        case action
        when :kick then "removed from the community"
        when :ban then duration ? "banned for #{human_duration(duration)}" : "banned permanently"
        else duration ? "muted for #{human_duration(duration)}" : "muted permanently"
        end
      end

      # The escalation ladder: warning-count threshold to action, parsed per call
      # from the resolved "warnings" config. Each rule is `{ threshold:, action:
      # "mute"|"ban"|"kick", duration: }`; a kick takes no duration, and an
      # absent duration on a mute/ban is a PERMANENT sanction. Unreadable rules
      # drop.
      class Ladder
        Rule = Struct.new(:threshold, :action, :duration, keyword_init: true)

        def self.empty = new([])

        def self.parse(config, logger: nil)
          config = {} unless config.is_a?(Hash)
          raw = fetch(config, :ladder)
          rules = Array(raw).filter_map { |entry| build_rule(entry, logger) }
          new(rules)
        end

        def self.build_rule(entry, logger)
          entry = symbolize(entry)
          return log_drop(logger, entry, "not a mapping") unless entry

          threshold = entry[:threshold].to_i
          return log_drop(logger, entry, "threshold must be a positive integer") unless threshold.positive?

          action = entry[:action].to_s.downcase.to_sym
          unless SANCTION_ACTIONS.include?(action)
            return log_drop(logger, entry, "unknown action #{entry[:action].inspect}")
          end

          duration = rule_duration(action, entry[:duration])
          return log_drop(logger, entry, "duration must be a positive time span") if duration == :invalid

          Rule.new(threshold: threshold, action: action, duration: duration)
        end

        # A kick never carries a duration; mute/ban read one when given, or stay
        # nil (permanent) when it is absent. :invalid marks a duration that was
        # given but could not be read.
        def self.rule_duration(action, raw)
          return nil if action == :kick || raw.nil?

          duration = Warnings.duration_seconds(raw)
          duration&.positive? ? duration : :invalid
        end

        def self.log_drop(logger, entry, why)
          logger&.warn { "warnings: ignoring a ladder rule (#{why}): #{entry.inspect}" }
          nil
        end

        def self.symbolize(entry)
          return nil unless entry.is_a?(Hash)

          entry.each_with_object({}) { |(k, v), out| out[k.to_s.to_sym] = v }
        end

        def self.fetch(config, key)
          config.key?(key) ? config[key] : config[key.to_s]
        end

        def initialize(rules)
          # Sorted by threshold so a lookup is deterministic.
          @rules = rules.sort_by(&:threshold).freeze
          freeze
        end

        attr_reader :rules

        def empty? = @rules.empty?

        # The most severe rule whose threshold sits in (+previous_count+,
        # +new_count+]. nil when no threshold was crossed.
        def crossed(previous_count, new_count)
          candidates = @rules.select { |rule| rule.threshold > previous_count && rule.threshold <= new_count }
          return nil if candidates.empty?

          candidates.max_by { |rule| [severity(rule.action), rule.threshold] }
        end

        # The rule the warning that brought the total to +count+ crossed.
        def for_count(count) = crossed(count - 1, count)

        private

        # Removal outranks a ban outranks a mute, for the rare case where two
        # thresholds are crossed by the same warning.
        def severity(action)
          case action
          when :kick then 2
          when :ban then 1
          else 0
          end
        end
      end

      # The coordinator: issue / list / clear warnings, run the ladder, apply and
      # reverse sanctions, and DM the subject throughout.
      class Service
        # Stands in for the community id an expiry is held against when there
        # is no registry to resolve one, the single-community config-file path.
        UNSCOPED = :unscoped

        # The persisted strike, the running active count, the configured
        # maximum (nil when unset), the sanction the ladder applied (or nil),
        # and whether the level DM was actually delivered.
        Outcome = Struct.new(:warning, :count, :max, :sanction, :dm_sent, :text, keyword_init: true) do
          def escalated? = !sanction.nil?
        end

        # The action, its duration in seconds (nil for permanent), the moment it
        # lifts (nil for permanent), the endpoint ids it actually landed on
        # (empty is a graceful skip), and whether its own DM was sent.
        Sanction = Struct.new(:action, :duration, :until_at, :endpoints, :record, :dm_sent, keyword_init: true) do
          def applied? = !endpoints.empty?
        end

        # Shared warning storage, durable scheduling, topology and adapters. The
        # registry turns the slug an expiry job carries into the community that
        # has to own every endpoint the reversal touches; without one there is a
        # single community and nothing to cross into, the config-file path.
        def initialize(store:, scheduler:, topology:, adapters:, storage: nil, audit: nil, logger: nil,
                       registry: nil, undelivered: nil, ephemeral: nil, clock: -> { Time.now })
          @store = store
          @undelivered = undelivered
          @ephemeral = ephemeral
          @drop_notices = {}
          @scheduler = scheduler
          @topology = topology
          @registry = registry
          @adapters = adapters
          @audit = audit || AuditLog::Null.new
          @logger = logger
          @clock = clock
          @removal = storage && Watchdog::Removal.new(
            topology: topology, adapters: adapters, storage: storage,
            logger: logger || Log.null, source: "warnings"
          )
        end

        # Record a warning, apply its ladder sanction, notify the subject and
        # schedule optional decay.
        def warn(community:, subject:, origin:, ladder: Ladder.empty, max: nil, expire_after: nil,
                 reason: nil, issued_by: nil)
          slug = slug_of(community)
          native_id = subject&.native_id
          return nil if slug.nil? || native_id.nil?

          adapter = origin.adapter_name
          record = nil
          count = nil
          @store.with_advisory_lock(Warnings.subject_lock_name(slug, adapter, native_id)) do
            record = @store.record_warning(
              community: slug, adapter: adapter, subject_native_id: native_id,
              subject_username: subject.username, subject_display: display_of(subject),
              reason: reason, issued_by: issued_by, account: origin.account, now: @clock.call
            )
            count = @store.active_count(community: slug, adapter: adapter, subject_native_id: native_id)
          end
          audit_warning(slug, adapter, subject, count, reason, issued_by)
          schedule_decay(slug, adapter, subject, origin, record, max, expire_after) if expire_after&.positive?

          rule = ladder.for_count(count)
          sanction = rule && sanction(
            community: community, subject: subject, origin: origin,
            action: rule.action, duration: rule.duration, reason: reason,
            issued_by: "warnings ladder (#{count} strikes)", notify: false
          )
          told = warn_dm_text(slug, count, max, reason, sanction, ladder, expire_after)
          dm_sent = deliver_dm(
            community: slug, adapter_name: adapter, account: origin.account, native_id: native_id,
            display: display_of(subject), text: told,
            event: "a warning", expires_at: warning_expiry(record, expire_after)
          )
          Outcome.new(warning: record, count: count, max: max, sanction: sanction,
                      dm_sent: dm_sent, text: told)
        rescue StorageError => e
          @logger&.warn { "warnings: could not record a warning: #{e.message}" }
          nil
        end

        # A subject's active strikes on +adapter+ (their platform), oldest first.
        def list(community:, subject:, adapter:)
          slug = slug_of(community)
          native_id = subject&.native_id
          return [] if slug.nil? || native_id.nil?

          @store.active_warnings(community: slug, adapter: adapter, subject_native_id: native_id)
        rescue StorageError => e
          @logger&.warn { "warnings: could not list warnings: #{e.message}" }
          []
        end

        # Deactivate a subject's warnings: +scope: :latest+ removes the most recent
        # one, +scope: :all+ clears every active strike. Returns the count.
        def clear(community:, subject:, adapter:, scope: :latest)
          slug = slug_of(community)
          native_id = subject&.native_id
          return 0 if slug.nil? || native_id.nil?

          @store.deactivate_warnings(
            community: slug, adapter: adapter, subject_native_id: native_id,
            scope: scope, now: @clock.call
          )
        rescue StorageError => e
          @logger&.warn { "warnings: could not clear warnings: #{e.message}" }
          0
        end

        # Apply and persist a mute, ban or kick, with optional reversal and DM.
        def sanction(community:, subject:, origin:, action:, duration: nil, reason: nil, issued_by: nil,
                     notify: true)
          slug = slug_of(community)
          native_id = subject&.native_id
          action = action.to_sym
          until_at = duration&.positive? ? @clock.call + duration.to_i : nil

          # Refuse sanctions that cannot be persisted or scheduled safely.
          if slug.nil? || native_id.nil?
            @logger&.warn { "warnings: cannot apply #{action} without a community and subject; skipping" }
            return Sanction.new(action: action, duration: duration&.to_i, until_at: until_at,
                                endpoints: [], record: nil, dm_sent: nil)
          end

          targets = sanction_targets(origin, action)
          applied = targets.select { |endpoint| apply(endpoint, action, native_id, duration, issued_by) }
          endpoint_ids = applied.map(&:id)
          record = persist_sanction(slug, origin.adapter_name, subject, action, until_at, endpoint_ids)
          audit_sanction(slug, origin.adapter_name, subject, action, duration, endpoint_ids, issued_by)

          dm_sent = notify ? deliver_dm(
            community: slug, adapter_name: origin.adapter_name, account: origin.account, native_id: native_id,
            display: display_of(subject), text: sanction_dm_text(slug, action, duration, reason),
            event: "a #{action}"
          ) : nil
          Sanction.new(action: action, duration: duration&.to_i, until_at: until_at,
                      endpoints: endpoint_ids, record: record, dm_sent: dm_sent)
        end

        # The durable-scheduler handler: reverse a sanction whose time has come.
        # Reads everything from the job payload, so it is idempotent.
        def expire(job)
          payload = job.payload || {}
          reverse = REVERSE[payload.fetch("action", "").to_sym]
          return if reverse.nil?

          slug = expiry_slug(job, payload)
          community_id = expiry_community_id(slug)
          return refuse_expiry(job, slug) if community_id.nil?

          reverse_expiry(job, payload, reverse, community_id)
          # Held to the same community the reversal was. Refusing to unban
          # anybody and lifting the row regardless would read as served.
          @store.lift_sanction(community: slug, id: payload["sanction_id"]) if payload["sanction_id"]
          audit_expiry(payload, reverse)
        end

        # The community an expiry belongs to: the payload's own slug, with the
        # job's as the fallback for a row written before it carried one.
        def expiry_slug(job, payload)
          slug = payload["community"].to_s.strip
          slug.empty? ? job.community.to_s : slug
        end

        # nil for a slug naming no live community, which refuses the whole
        # expiry. UNSCOPED without a registry, since there is then nothing to
        # hold the slug against and the ladder has to keep working.
        def expiry_community_id(slug)
          return UNSCOPED if @registry.nil?

          @registry.current.community(slug)&.id
        end

        def reverse_expiry(job, payload, reverse, community_id)
          native_id = payload["native_id"]
          expiry_endpoints(job, payload, community_id).each do |endpoint|
            next unless supports?(endpoint, reverse)

            apply(endpoint, reverse, native_id, nil, "warnings ladder (expiry)")
          end
        end

        # The endpoints an expiry may reverse a sanction on. The payload's ids
        # resolve against the merged topology, which spans every tenant, so each
        # one is held against the community the job carries and refused if it
        # belongs to another: an unban or unmute landing in the wrong community
        # is worse than a stray post.
        def expiry_endpoints(job, payload, community_id)
          resolved = Array(payload["endpoints"]).filter_map { |id| @topology.endpoint(id.to_s) }
          return resolved if community_id == UNSCOPED

          resolved.select do |endpoint|
            CommunityScope.permit_or_log(endpoint, community_id, logger: @logger,
                                                                 doing: "warnings expiry: job #{job.id}")
          end
        end

        def refuse_expiry(job, slug)
          @logger&.error do
            "warnings expiry: job #{job.id} names no live community (#{slug.inspect}), " \
              "reversing nothing and lifting nothing"
          end
          nil
        end

        # Deactivate an expiring warning, recompute its level and notify. The
        # store makes repeated jobs harmless.
        def decay(job)
          payload = job.payload || {}
          warning_id = payload["warning_id"]
          return if warning_id.nil?
          return unless @store.deactivate_warning(community: payload["community"], id: warning_id,
                                                  now: @clock.call)

          count = @store.active_count(
            community: payload["community"], adapter: payload["adapter"], subject_native_id: payload["native_id"]
          )
          deliver_dm(
            community: payload["community"], adapter_name: payload["adapter"], account: payload["account"],
            native_id: payload["native_id"], display: payload["subject_display"],
            text: decay_dm_text(payload["community"], count, payload["max"]), event: "a warning decreasing"
          )
          audit_decay(payload, count)
        end

        # Suppress an actively muted author's message, delete copies and notify
        # them privately.
        def suppress?(message:, community:)
          slug = slug_of(community)
          author = message.author
          return false if slug.nil? || author.nil? || author.native_id.nil?

          adapter_name = message.origin.adapter_name
          mute = active_mute(community: slug, adapter: adapter_name, subject_native_id: author.native_id)
          return false if mute.nil?

          @removal&.remove_everywhere(message)
          sent = deliver_dm(
            community: slug, adapter_name: adapter_name, account: message.origin.account,
            native_id: author.native_id, display: display_of(author),
            text: mute_drop_dm_text(slug, mute), event: "a dropped message",
            expires_at: mute.until_at
          )
          # A mute enforced by dropping messages is invisible to the person it
          # is enforced against: their words simply stop appearing. The DM is
          # how they find out, and the people who most need it are exactly the
          # ones a bot cannot DM, so say it in the room instead.
          announce_drop(message, slug, mute) unless sent
          true
        rescue StorageError => e
          @logger&.warn { "warnings: could not check #{author&.native_id}'s mute status: #{e.message}" }
          false
        end

        private

        # Tell a muted author in the room that their message went nowhere, when
        # no DM could reach them. Self-deleting, and at most one per author per
        # {DROP_NOTICE_COOLDOWN}: somebody muted mid-argument can send a dozen
        # messages a minute, and a notice for each would be the room shouting
        # rather than the room informing.
        def announce_drop(message, slug, mute)
          return if @ephemeral.nil?

          key = [slug, message.origin.adapter_name, message.author.native_id]
          now = @clock.call
          return if @drop_notices[key] && @drop_notices[key] > now - DROP_NOTICE_COOLDOWN

          @drop_notices[key] = now
          @ephemeral.post(
            endpoints: [message.origin], name: DROP_NOTICE_NAME,
            delete_after: DROP_NOTICE_TTL, body: drop_notice_body(message, mute)
          )
        rescue StandardError => e
          @logger&.warn { "warnings: could not post the dropped-message notice: #{e.message}" }
        end

        # Mentions them where the platform can, so it reaches the one person it
        # is for rather than reading as an announcement about them.
        def drop_notice_body(message, mute)
          author = message.author
          name = display_of(author).to_s
          name = "someone" if name.strip.empty?
          remaining = mute.until_at && Warnings.human_duration(mute.until_at - @clock.call)
          lifts = remaining ? "it lifts in #{remaining}" : "the mute is permanent"
          text = "#{name}, your message was removed because you are muted, and #{lifts}."
          native_id = author&.native_id
          return RichText.plain(text) if native_id.nil?

          key = :"#{message.origin.adapter_name}_id_for_target"
          span = Span.new(kind: :mention, begin_index: 0, end_index: name.length, attributes: { key => native_id })
          RichText.new(text, [span])
        end

        # Return the latest unexpired mute, checking time independently of jobs.
        def active_mute(community:, adapter:, subject_native_id:)
          now = @clock.call
          @store.active_sanctions(community: community, adapter: adapter, subject_native_id: subject_native_id)
                .select { |s| s.action == "mute" && (s.until_at.nil? || s.until_at > now) }
                .max_by(&:id)
        end

        # The endpoints a sanction lands on: those in rooms reachable from the
        # origin that are on the SUBJECT's platform (so the native id is valid),
        # can send, and whose adapter declares the action.
        def sanction_targets(origin, action)
          @topology.rooms_for(origin.id)
                   .flat_map(&:endpoints)
                   .select { |endpoint| endpoint.adapter_name == origin.adapter_name && endpoint.sends? }
                   .uniq(&:id)
                   .select { |endpoint| supports?(endpoint, action) }
        end

        def supports?(endpoint, action)
          adapter = adapter_for(endpoint)
          return false if adapter.nil?

          adapter.capabilities_for(endpoint).moderates?(action)
        end

        # Carry out one moderation action on one endpoint, returning whether the
        # adapter reported success, so the caller records only the endpoints a
        # sanction landed on. Never raises.
        def apply(endpoint, action, native_id, duration, issuer)
          adapter = adapter_for(endpoint)
          return false if adapter.nil?

          command = Moderation::Command.new(
            action: action, issuer: issuer, origin: endpoint,
            target_user_id: native_id, arguments: mute_arguments(action, duration)
          )
          result = adapter.moderate(command, endpoint, nil)
          result.respond_to?(:ok?) ? result.ok? : true
        rescue StandardError => e
          @logger&.warn { "warnings: #{action} on #{endpoint.id} failed: #{e.class}: #{e.message}" }
          false
        end

        # Convert mute durations to whole minutes; permanent mutes use adapter
        # maximums.
        def mute_arguments(action, duration)
          return [] unless action == :mute

          seconds = duration || PERMANENT_MUTE_ARGUMENT_SECONDS
          minutes = (seconds.to_f / 60).ceil
          minutes.positive? ? [minutes.to_s] : []
        end

        # Persist mute or ban sanctions and schedule reversal only when timed.
        def persist_sanction(slug, adapter, subject, action, until_at, endpoint_ids)
          return nil unless REVERSE.key?(action)

          record = @store.record_sanction(
            community: slug, adapter: adapter, subject_native_id: subject.native_id,
            subject_username: subject.username, action: action, until_at: until_at,
            endpoints: endpoint_ids, now: @clock.call
          )
          schedule_expiry(slug, adapter, subject, action, until_at, endpoint_ids, record) if until_at
          record
        end

        def schedule_expiry(slug, adapter, subject, action, until_at, endpoint_ids, record)
          job_id = @scheduler.schedule(
            kind: EXPIRE_KIND, run_at: until_at, community: slug,
            payload: {
              sanction_id: record&.id, community: slug, adapter: adapter,
              native_id: subject.native_id.to_s, action: action.to_s, endpoints: endpoint_ids
            }
          )
          @store.attach_job(record.id, job_id) if record && job_id
        end

        # Schedule decay with the durable payload needed after source objects end.
        def schedule_decay(slug, adapter, subject, origin, record, max, expire_after)
          return if record.nil?

          @scheduler.schedule(
            kind: DECAY_KIND, run_at: record.issued_at + expire_after, community: slug,
            payload: {
              warning_id: record.id, community: slug, adapter: adapter, account: origin.account,
              native_id: subject.native_id.to_s, subject_display: display_of(subject), max: max
            }
          )
        end

        # Send a best-effort platform DM, and keep what could not be sent. A bot
        # cannot open a conversation on Telegram, so a member who has never
        # written in is unreachable until they do; the text waits for that
        # rather than being lost with only an audit line to say it existed.
        def deliver_dm(community:, adapter_name:, account:, native_id:, display:, text:, event:, expires_at: nil)
          # Durable JSON returns adapter names as strings; the map uses symbols.
          adapter = @adapters[[adapter_name.to_s.to_sym, account]]
          sent = !!(adapter&.supports_admin_dm? && adapter.send_admin_dm(native_id, text))
          unless sent
            audit_dm_failure(community, adapter_name, native_id, display, event)
            keep_undelivered(community, adapter_name, account, native_id, display, text, event, expires_at)
          end
          sent
        rescue StandardError => e
          @logger&.warn { "warnings: #{event} DM to #{native_id} failed: #{e.class}: #{e.message}" }
          audit_dm_failure(community, adapter_name, native_id, display, event)
          keep_undelivered(community, adapter_name, account, native_id, display, text, event, expires_at)
          false
        end

        # What a warned member is told: why, where they now stand, what it cost
        # if anything, what the next one costs where that is more than a warning,
        # and how long this one is held against them. Never who warned them: the
        # invocation is taken away at once so the room cannot work out who called
        # it, and naming them here would hand it straight back (#1912).
        def warn_dm_text(community, count, max, reason, sanction, ladder, expire_after = nil)
          level = "You are now at warning level #{count}#{level_suffix(max)} in #{community}."
          parts = [reason_sentence(reason), level]
          parts << "You have been #{penalty_phrase(sanction.action, sanction.duration)}." if sanction
          forward = ladder.for_count(count + 1)
          if forward
            parts << "If you are warned again, you will be #{penalty_phrase(forward.action, forward.duration)}."
          end
          parts << record_sentence(expire_after)
          parts.compact.join(" ")
        end

        # How long this warning is held against them. Spelled out rather than in
        # the compact form a penalty uses, since this is the one sentence they
        # are meant to remember a date from.
        def record_sentence(expire_after)
          seconds = expire_after.to_i
          return nil unless seconds.positive?

          days = seconds / 86_400
          span = days.positive? ? "#{days} day#{"s" unless days == 1}" : Warnings.human_duration(seconds)
          "This warning stays on your record for #{span}, then it expires on its own."
        end

        def sanction_dm_text(community, action, duration, reason)
          text = if action == :kick
                   "You have been removed from #{community}."
                 else
                   "You have been #{penalty_phrase(action, duration)} in #{community}."
                 end
          reason.nil? || reason.to_s.strip.empty? ? text : "#{text} Reason: #{reason}."
        end

        def decay_dm_text(community, count, max)
          "One of your warnings in #{community} has expired. You are now at warning level " \
            "#{count}#{level_suffix(max)}."
        end

        def mute_drop_dm_text(community, mute)
          remaining = mute.until_at && Warnings.human_duration(mute.until_at - @clock.call)
          lifts = remaining ? "It lifts in #{remaining}." : "This mute is permanent."
          "Your message in #{community} was not delivered because you are muted. #{lifts}"
        end

        def level_suffix(max)
          max&.positive? ? " of #{max}" : ""
        end

        def penalty_phrase(action, duration) = Warnings.penalty_phrase(action, duration)

        def reason_sentence(reason)
          return nil if reason.nil? || reason.to_s.strip.empty?

          "Reason: #{reason}."
        end

        def adapter_for(endpoint)
          @adapters[[endpoint.adapter_name, endpoint.account]]
        end

        def slug_of(community)
          return nil if community.nil?

          community.respond_to?(:slug) ? community.slug : community.to_s
        end

        def display_of(subject)
          subject.respond_to?(:any_name) ? subject.any_name : nil
        end

        def audit_warning(slug, adapter, subject, count, reason, issued_by)
          @logger&.info do
            fields = {
              event: "warnings.warn", community: slug, adapter: adapter,
              subject: subject.native_id, handle: subject.username, count: count,
              reason: reason, issued_by: issued_by
            }
            audit_line(fields)
          end
          record_audit(
            community: slug, action: "warn", adapter: adapter, actor: issued_by,
            subject: subject, reason: reason, outcome: "#{count} active"
          )
        end

        def audit_sanction(slug, adapter, subject, action, duration, endpoints, issued_by)
          @logger&.info do
            fields = {
              event: "warnings.sanction", community: slug, adapter: adapter,
              subject: subject.native_id, action: action, duration: duration,
              endpoints: endpoints, applied: !endpoints.empty?
            }
            audit_line(fields)
          end
          record_audit(
            community: slug, action: action.to_s, adapter: adapter, actor: issued_by, subject: subject,
            outcome: endpoints.empty? ? "no endpoint could carry it out" : "applied to #{endpoints.join(', ')}",
            metadata: { duration_seconds: duration&.to_i, endpoints: endpoints }
          )
        end

        def audit_expiry(payload, reverse)
          @logger&.info do
            fields = {
              event: "warnings.expire", community: payload["community"],
              adapter: payload["adapter"], subject: payload["native_id"],
              reversed_with: reverse, endpoints: payload["endpoints"]
            }
            audit_line(fields)
          end
          @audit.record(
            community: payload["community"].to_s, source: "warnings", action: reverse.to_s,
            adapter: payload["adapter"], actor: "warnings ladder (expiry)",
            subject_native_id: payload["native_id"], outcome: "sanction expired",
            metadata: { endpoints: payload["endpoints"] }
          )
        rescue StorageError => e
          @logger&.warn { "warnings: could not record the expiry audit event: #{e.message}" }
        end

        def audit_decay(payload, count)
          @logger&.info do
            fields = {
              event: "warnings.decay", community: payload["community"],
              adapter: payload["adapter"], subject: payload["native_id"], count: count
            }
            audit_line(fields)
          end
          @audit.record(
            community: payload["community"].to_s, source: "warnings", action: "decay",
            adapter: payload["adapter"], actor: "warnings decay",
            subject_native_id: payload["native_id"], outcome: "#{count} active"
          )
        rescue StorageError => e
          @logger&.warn { "warnings: could not record the decay audit event: #{e.message}" }
        end

        # When the strike this DM is about lapses, which is how long the DM is
        # worth keeping. Nil where nothing decays, and nothing is kept then:
        # a notice with no expiry has no honest retention to promise.
        def warning_expiry(record, expire_after)
          return nil if record.nil? || !expire_after.to_i.positive?

          record.issued_at + expire_after
        end

        # The community row a kept DM hangs off, resolved through the snapshot
        # since everything down here works in slugs.
        def community_id_for(slug)
          @registry&.current&.community(slug.to_s)&.id
        end

        # Keep an unsent DM for the next time this member writes to the bot.
        # Best effort on top of a send that has already failed: a store that
        # cannot take it must not turn one lost notice into a raised warning.
        def keep_undelivered(community, adapter_name, account, native_id, display, text, event, expires_at)
          return if @undelivered.nil? || expires_at.nil?

          @undelivered.retain(
            community_id: community_id_for(community), adapter: adapter_name, account: account,
            native_id: native_id, display: display, body: text, event: event, expires_at: expires_at
          )
        rescue StandardError => e
          @logger&.warn { "warnings: could not keep the undelivered #{event} DM: #{e.message}" }
        end

        # Record failed DMs durably so operators can diagnose delivery gaps.
        def audit_dm_failure(community, adapter, native_id, display, event)
          @audit.record(
            community: community.to_s, source: "warnings", action: "dm_failed", adapter: adapter&.to_s,
            subject: display, subject_native_id: native_id, outcome: "could not DM about #{event}"
          )
        rescue StorageError => e
          @logger&.warn { "warnings: could not record the DM-failure audit event: #{e.message}" }
        end

        def audit_line(fields)
          "warnings " + fields.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")
        end

        # Write warnings audit records for dashboard visibility without risking
        # the process path.
        def record_audit(community:, action:, adapter:, actor:, subject:, reason: nil, outcome: nil, metadata: nil)
          @audit.record(
            community: community, source: "warnings", action: action, adapter: adapter,
            actor: actor, subject: display_of(subject), subject_native_id: subject.native_id,
            reason: reason, outcome: outcome, metadata: metadata
          )
        rescue StorageError => e
          @logger&.warn { "warnings: could not record the audit event: #{e.message}" }
        end
      end
    end
  end
end
