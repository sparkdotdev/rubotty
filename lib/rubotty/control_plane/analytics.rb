# frozen_string_literal: true

require "sequel"
require "time"

module Rubotty
  module ControlPlane
    # Read-only analytics over data the bot already stores; it never writes and
    # adds no schema of its own. A text column is always compared against a
    # String, since MariaDB coerces a varchar column to a number when the other
    # side is one and would match every non-numeric row. The message map and
    # reaction state are derived and pruned on a ~24h cycle, so those panels are
    # labelled as last-day only.
    class Analytics
      # The selectable windows, in seconds, in the order the UI offers them.
      WINDOWS = {
        "24h" => 24 * 3600,
        "7d" => 7 * 24 * 3600,
        "30d" => 30 * 24 * 3600,
        # The one panel with a real 90 day retention behind it.
        "90d" => 90 * 24 * 3600
      }.freeze

      # The window used when a request names none or an unknown one.
      DEFAULT_WINDOW = "7d"

      # The two ways the "By channel" message panel can group its bars: the raw
      # platform channel, or the metachannel it is bridged into.
      CHANNEL_VIEWS = %w[channel room].freeze

      DEFAULT_CHANNEL_VIEW = "channel"

      # How long the derived message map and reaction state are kept. Volume drawn
      # from those tables can never look back further, whatever window is picked.
      RETENTION_SECONDS = 24 * 3600

      # The audit log's moderation sources, listed in a stable order so a source
      # that has fired nothing still shows a zero.
      KNOWN_SOURCES = %w[moderation word_filter link_filter anti_spam anti_raid].freeze

      # @param db [Sequel::Database] the shared datastore
      # @param models [ControlPlane::Models] the control-plane model classes
      # @param now [#call] a clock, injectable so a test can freeze time
      # @param model_calls [ModelCallStats, nil] the rollup the model-backed
      #   panel reads. Only ever read from here.
      def initialize(db:, models:, now: -> { Time.now }, model_calls: nil)
        @db = db
        @models = models
        @now = now
        @model_calls = model_calls || ModelCallStats.new(models: models)
      end

      # The current instant, through the injected clock.
      def now = @now.call

      # Normalise a requested window key, falling back to the default.
      def self.window_key(value)
        WINDOWS.key?(value.to_s) ? value.to_s : DEFAULT_WINDOW
      end

      # The same, for the "By channel" grouping toggle.
      def self.channel_view_key(value)
        CHANNEL_VIEWS.include?(value.to_s) ? value.to_s : DEFAULT_CHANNEL_VIEW
      end

      # Every panel the detail view renders, as a plain Hash.
      #
      # @param community [#id, #slug] the community row
      # @param window [String] one of {WINDOWS}'s keys
      def overview(community:, window: DEFAULT_WINDOW)
        key = self.class.window_key(window)
        moment = now
        since = moment - WINDOWS.fetch(key)
        {
          window: key,
          since: since,
          now: moment,
          moderation: moderation(community: community, since: since, now: moment, window: key),
          members: members(community: community, since: since),
          messages: messages(community: community, now: moment),
          reactions: reactions(community: community),
          guests: guests(community: community, since: since, now: moment),
          warnings: warnings(community: community, since: since),
          sanctions: sanctions(community: community, now: moment),
          events: events(community: community, since: since, now: moment),
          multiposts: multiposts(community: community, now: moment),
          onboarding: onboarding(community: community, since: since),
          operator_requests: operator_request_latency(community: community, since: since),
          model_calls: model_calls(community: community, since: since, now: moment)
        }
      end

      # One line per community for the landing table, reusing the counts the detail
      # view shows so the two cannot disagree.
      # @param only [Array, nil] the communities (rows or ids) to report on. Nil
      #   is every community, which is a caller who has said so rather than a
      #   caller who forgot to scope.
      def community_rows(window: DEFAULT_WINDOW, only: nil)
        key = self.class.window_key(window)
        moment = now
        since = moment - WINDOWS.fetch(key)
        scoped_communities(only).map do |community|
          {
            community: community,
            active_members: observed(community).where { last_seen_at >= since }.count,
            moderation_actions: audit_scope(community.slug, since).count,
            messages_recent: relay_recent_count(community, moment),
            active_guests: active_guest_scope(community, moment).count,
            operators: @models.operator.where(community_id: community.id).count,
            upcoming_events: events(community: community, since: since, now: moment)[:upcoming],
            pending_spaces: onboarding(community: community, since: since)[:pending],
            operator_request_minutes: operator_request_latency(community: community, since: since)[:average_minutes]
          }
        end
      end

      # Every community, slug order, for the landing table and the picker.
      def communities
        @models.community.order(:slug).all
      end

      private

      # +only+ narrowed to community rows, in the same order {#communities} gives.
      def scoped_communities(only)
        return communities if only.nil?

        ids = Array(only).map { |entry| entry.respond_to?(:id) ? entry.id : entry.to_i }
        communities.select { |community| ids.include?(community.id) }
      end

      def moderation(community:, since:, now:, window:)
        scope = audit_scope(community.slug, since)
        total = scope.count
        {
          total: total,
          by_action: grouped(scope, :action),
          by_source: sources_with_zero(scope),
          by_platform: grouped(scope.exclude(adapter: nil), :adapter),
          by_channel: channels_breakdown(scope, community),
          series: bucketed(scope.select_map(:created_at), since: since, now: now, window: window)
        }
      end

      def audit_scope(slug, since)
        @db[:audit_events].where(community: slug.to_s).where { created_at >= since }
      end

      # The action or platform breakdown: [{ label:, count: }], largest first.
      def grouped(scope, column)
        scope.group_and_count(column).all.map do |row|
          { label: row[column].to_s, count: row[:count].to_i }
        end.reject { |row| row[:label].empty? }.sort_by { |row| -row[:count] }
      end

      # Lists the known sources even at zero, plus any unexpected one the data
      # carries, so the view is stable run to run.
      def sources_with_zero(scope)
        counts = grouped(scope, :source).to_h { |row| [row[:label], row[:count]] }
        ordered = KNOWN_SOURCES + (counts.keys - KNOWN_SOURCES)
        ordered.map { |source| { label: source, count: counts.fetch(source, 0) } }
      end

      # A community-wide action carries no channel and folds into a "(community-wide)"
      # bucket. The stored value is the endpoint key, resolved to a room name when
      # possible and kept as-is otherwise.
      def channels_breakdown(scope, community, limit: 8)
        names = channel_names(community)
        scope.group_and_count(:channel).all.map do |row|
          key = row[:channel].to_s
          label = key.empty? ? "(community-wide)" : names.fetch(key, key)
          { label: label, count: row[:count].to_i }
        end.sort_by { |row| -row[:count] }.first(limit)
      end

      # endpoint key => the friendliest name available: the room it is bridged into,
      # then the channel's own label, then nothing so the caller keeps the key.
      def channel_names(community)
        rows = @db[:channels]
               .left_join(:room_channels, channel_id: :id)
               .left_join(:rooms, id: :room_id)
               .where(Sequel[:channels][:community_id] => community.id)
               .select(Sequel[:channels][:endpoint_key],
                       Sequel[:channels][:label].as(:channel_label),
                       Sequel[:rooms][:label].as(:room_label),
                       Sequel[:rooms][:room_key].as(:room_key))
               .all
        rows.each_with_object({}) do |row, out|
          key = row[:endpoint_key].to_s
          next if key.empty?

          name = presence(row[:room_label]) || presence(row[:room_key]) || presence(row[:channel_label])
          out[key] = name unless name.nil?
        end
      end

      def presence(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def members(community:, since:)
        directory = observed(community)
        active = directory.where { last_seen_at >= since }
        {
          total: directory.count,
          active: active.count,
          new_in_window: directory.where { first_seen_at >= since }.count,
          by_platform: grouped(active, :adapter),
          recently_active: recently_active(active)
        }
      end

      def observed(community)
        @models.observed_identity.where(community_id: community.id)
      end

      # The senders seen most recently, standing in for "top posters": the directory
      # records who was seen and when, never a per-person message count.
      def recently_active(scope, limit: 10)
        scope.order(Sequel.desc(:last_seen_at), Sequel.desc(:id)).limit(limit).all.map do |row|
          {
            adapter: row[:adapter],
            username: row[:username],
            display_name: row[:display_name],
            last_seen_at: row[:last_seen_at]
          }
        end
      end

      def messages(community:, now:)
        scope = relay_new(community)
        return { available: false } if scope.nil?

        endpoints = endpoint_directory(community)
        since = now - RETENTION_SECONDS
        recent = scope.where { claimed_at >= since }
        {
          available: true,
          retention_hours: RETENTION_SECONDS / 3600,
          total: recent.count,
          by_channel: endpoint_breakdown(recent, endpoints, :label),
          by_room: endpoint_breakdown(recent, room_directory(community), :label),
          by_platform: endpoint_breakdown(recent, endpoints, :adapter),
          busiest_hours: hour_breakdown(recent.select_map(:claimed_at)),
          series: bucketed(recent.select_map(:claimed_at), since: since, now: now, window: "24h")
        }
      end

      # Zero when the derived table is absent.
      def relay_recent_count(community, now)
        scope = relay_new(community)
        return 0 if scope.nil?

        since = now - RETENTION_SECONDS
        scope.where { claimed_at >= since }.count
      end

      # The 'new' relay claims, one row per relayed source message; nil when the
      # derived table is absent. The claim's community column carries the
      # community's ROW ID, never its slug, and must be compared as a String or
      # MariaDB coerces the column and matches every row against 0.
      def relay_new(community)
        return nil unless @db.table_exists?(:relay_claims)

        @db[:relay_claims].where(community: claim_community_key(community), operation: "new")
      end

      def claim_community_key(community) = community.id.to_s

      # endpoint_key => { label:, adapter: } per channel, so a relay claim keyed by
      # source endpoint can be named.
      def endpoint_directory(community)
        @models.channel.where(community_id: community.id).all.each_with_object({}) do |channel, map|
          label = channel[:label].to_s.empty? ? channel[:route_key].to_s : channel[:label].to_s
          map[channel[:endpoint_key].to_s] = { label: label, adapter: channel[:adapter].to_s }
        end
      end

      # endpoint_key => { label: } for each channel's room, so the same claims can
      # be rolled up by room. A channel in several rooms keeps only the first, so
      # one message is never counted twice.
      def room_directory(community)
        @models.channel.where(community_id: community.id).all.each_with_object({}) do |channel, map|
          room = channel.rooms.first
          label = if room.nil?
                    "(no room)"
                  else
                    room[:label].to_s.empty? ? room[:room_key].to_s : room[:label].to_s
                  end
          map[channel[:endpoint_key].to_s] = { label: label }
        end
      end

      # Roll relay claims up under a channel attribute. An endpoint with no matching
      # channel folds into "(unknown)".
      def endpoint_breakdown(scope, endpoints, attribute, endpoint_column: :source_endpoint)
        totals = Hash.new(0)
        scope.group_and_count(endpoint_column).each do |row|
          info = endpoints[row[endpoint_column].to_s]
          key = info ? info[attribute] : "(unknown)"
          key = "(unknown)" if key.to_s.empty?
          totals[key] += row[:count].to_i
        end
        totals.map { |label, count| { label: label, count: count } }.sort_by { |row| -row[:count] }
      end

      def reactions(community:)
        return { available: false } unless @db.table_exists?(:reaction_state)

        endpoints = @models.channel.where(community_id: community.id).select_map(:endpoint_key).map(&:to_s)
        return { available: true, total: 0, by_emoji: [] } if endpoints.empty?

        scope = @db[:reaction_state].where(endpoint_id: endpoints)
        {
          available: true,
          retention_hours: RETENTION_SECONDS / 3600,
          total: scope.count,
          by_emoji: grouped(scope.exclude(emoji: nil), :emoji).first(8)
        }
      end

      def guests(community:, since:, now:)
        invites = @models.guest_invite.where(community_id: community.id)
        issued = invites.where { created_at >= since }
        {
          total: invites.count,
          issued_in_window: issued.count,
          redeemed_in_window: invites.where { joined_at >= since }.count,
          redemption_rate: percentage(issued.exclude(joined_at: nil).count, issued.count),
          average_session_minutes: average_guest_session_minutes(invites.exclude(joined_at: nil), now),
          active: active_guest_scope(community, now).count
        }
      end

      # Live invites: the same test GuestInvites#live? applies.
      def active_guest_scope(community, now)
        @models.guest_invite
               .where(community_id: community.id, revoked_at: nil)
               .where { expires_at > now }
      end

      def warnings(community:, since:)
        return unavailable unless @db.table_exists?(:warnings)

        scope = @db[:warnings].where(community: community.slug.to_s)
        recent = scope.where { issued_at >= since }
        {
          available: true,
          total: recent.count,
          active: scope.where(active: true).count,
          repeat_offender_rate: repeat_offender_rate(recent),
          by_platform: grouped(recent, :adapter),
          by_issuer: grouped(recent.exclude(issued_by: nil), :issued_by).first(8)
        }
      end

      # Checks until_at against the clock rather than trusting the active flag
      # alone: the flag only flips once the durable scheduler's expire_sanction
      # job actually runs, so a sanction whose time has already passed can still
      # read as active for a while, longer still after downtime.
      def sanctions(community:, now:)
        return unavailable unless @db.table_exists?(:active_sanctions)

        scope = @db[:active_sanctions].where(community: community.slug.to_s, active: true)
        active = scope.where { until_at > now }
        {
          available: true,
          active: active.count,
          by_action: grouped(active, :action),
          by_platform: grouped(active, :adapter)
        }
      end

      def events(community:, since:, now:)
        return unavailable unless @db.table_exists?(:events)

        scope = @db[:events].where(community_id: community.id)
        recent = scope.where { created_at >= since }
        upcoming = scope.where(status: "scheduled").where { starts_at >= now }
        ids = scope.select_map(:id)
        rsvp_scope = if @db.table_exists?(:event_rsvps) && ids.any?
                       @db[:event_rsvps].where(event_id: ids)
                     end
        {
          available: true,
          created: recent.count,
          upcoming: upcoming.count,
          attendance: positive_rsvp_count(rsvp_scope),
          by_kind: grouped(scope, :kind),
          by_status: grouped(scope, :status),
          rsvps: rsvp_scope ? grouped(rsvp_scope, :response) : []
        }
      end

      def multiposts(community:, now:)
        return unavailable unless @db.table_exists?(:multipost_fingerprints)

        scope = @db[:multipost_fingerprints].where(community: community.slug.to_s)
        recent = scope.where { recorded_at >= now - RETENTION_SECONDS }
        grouped_fingerprints = recent.all.group_by { |row| [row[:author].to_s, row[:fingerprint].to_s] }
        detections = grouped_fingerprints.values.count do |rows|
          rows.map { |row| row[:channel].to_s }.uniq.size > 1
        end
        {
          available: true,
          retention_hours: RETENTION_SECONDS / 3600,
          detections: detections,
          by_channel: endpoint_breakdown(recent, endpoint_directory(community), :label, endpoint_column: :channel)
        }
      end

      def onboarding(community:, since:)
        return unavailable unless @db.table_exists?(:pending_spaces)

        scope = @db[:pending_spaces].where(community_id: community.id)
        decided = scope.where { decided_at >= since }
        decided_count = decided.count
        approved_count = decided.where(state: "approved").count
        {
          available: true,
          pending: scope.where(state: "pending").count,
          approved: approved_count,
          denied: decided.where(state: "denied").count,
          approval_rate: percentage(approved_count, decided_count),
          by_platform: grouped(scope, :adapter)
        }
      end

      def operator_request_latency(community:, since:)
        return unavailable unless @db.table_exists?(:operator_requests)

        decided = @db[:operator_requests]
                  .where(community_id: community.id)
                  .exclude(decided_at: nil)
                  .where { decided_at >= since }
        {
          available: true,
          pending: @db[:operator_requests].where(community_id: community.id, state: "pending").count,
          decided: decided.count,
          average_minutes: average_minutes(decided.all, :requested_at, :decided_at)
        }
      end

      # What the model-backed features cost over the window, plus what is queued
      # for them right now. Depth is read live rather than sampled: the query is
      # a count over one index and cannot drift the way a sample would.
      def model_calls(community:, since:, now:)
        report = @model_calls.report(community: community, since: since)
        return unavailable unless report[:available]

        report.merge(queue: model_call_queue(community, now))
      end

      # Per feature, how much of its work is due and still waiting, and how long
      # the oldest of it has been. Only jobs already due are counted: a summary
      # scheduled for next Tuesday is not a backlog.
      def model_call_queue(community, now)
        return [] unless @db.table_exists?(:scheduled_jobs)

        pending = @db[:scheduled_jobs].where(status: "pending", community: community.slug.to_s)
        ModelCallStats::KINDS.filter_map do |feature, kind|
          due = pending.where(kind: kind.to_s).where { run_at <= now }
          depth = due.count
          next nil if depth.zero?

          { feature: feature, label: ModelCallStats::FEATURES.fetch(feature),
            depth: depth, oldest_seconds: oldest_wait(due, now) }
        end
      end

      # How long the most overdue job in +scope+ has been waiting, in whole
      # seconds, or nil when its run_at will not parse. Read as a row rather
      # than through min(), which comes back as an unconverted string on SQLite
      # and reads an hour out wherever the process is not on UTC.
      def oldest_wait(scope, now)
        row = scope.order(:run_at).first
        at = coerce_time(row && row[:run_at])
        at.nil? ? nil : [(now - at).round, 0].max
      end

      def unavailable = { available: false }

      def repeat_offender_rate(scope)
        subject_counts = scope.all.each_with_object(Hash.new(0)) do |row, counts|
          counts[[row[:adapter].to_s, row[:subject_native_id].to_s]] += 1
        end
        percentage(subject_counts.values.count { |count| count > 1 }, subject_counts.size)
      end

      def positive_rsvp_count(scope)
        return 0 unless scope

        scope.where(response: %w[in yes]).count
      end

      def average_guest_session_minutes(invites, now)
        rows = invites.all.map do |row|
          joined = coerce_time(row[:joined_at])
          next if joined.nil?

          ended = [coerce_time(row[:revoked_at]), coerce_time(row[:expires_at]), now].compact.min
          [ended - joined, 0].max
        end.compact
        return 0 if rows.empty?

        (rows.sum / rows.size / 60).round
      end

      def average_minutes(rows, start_column, end_column)
        durations = rows.map do |row|
          started = coerce_time(row[start_column])
          ended = coerce_time(row[end_column])
          next if started.nil? || ended.nil?

          [ended - started, 0].max
        end.compact
        return 0 if durations.empty?

        (durations.sum / durations.size / 60).round
      end

      def percentage(numerator, denominator)
        return 0 if denominator.to_i.zero?

        ((numerator.to_f / denominator) * 100).round
      end

      def hour_breakdown(times)
        counts = Hash.new(0)
        times.each do |raw|
          moment = coerce_time(raw)
          counts[moment.strftime("%H:00")] += 1 if moment
        end
        counts.map { |label, count| { label: label, count: count } }.sort_by { |row| [-row[:count], row[:label]] }
      end

      # Evenly spaced buckets from +since+ to +now+, so a quiet hour shows as a zero
      # column rather than a gap. 24h buckets hourly, anything longer daily.
      #
      # @return [Array<Hash>] each { at: Time, count: Integer }, oldest first
      def bucketed(times, since:, now:, window:)
        step = window == "24h" ? 3600 : 86_400
        span = now - since
        count = [(span / step).ceil, 1].max
        buckets = Array.new(count, 0)
        times.each do |raw|
          moment = coerce_time(raw)
          next if moment.nil? || moment < since

          index = ((moment - since) / step).floor
          index = count - 1 if index >= count
          buckets[index] += 1 if index >= 0
        end
        buckets.each_index.map do |i|
          { at: since + (i * step), count: buckets[i], step: step }
        end
      end

      # A String is tolerated so this never raises on an unexpected shape.
      def coerce_time(value)
        case value
        when Time then value
        when String then (Time.parse(value) rescue nil)
        else value.respond_to?(:to_time) ? value.to_time : nil
        end
      end
    end
  end
end
