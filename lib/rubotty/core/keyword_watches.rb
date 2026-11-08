# frozen_string_literal: true

module Rubotty
  module Core
    # "Summon me when someone says X, for the next N hours": a per-person
    # keyword subscription, notified across the bridged platforms for a
    # bounded window. This module is the coordinator (subscribe/list/stop,
    # anti-annoyance, delivery); matching itself belongs to
    # {Features::KeywordWatch}. {#subscribe} schedules its own expiry
    # reversal on {Core::DurableScheduler}, so a lapse during downtime is
    # still honoured on the next boot. It refuses a keyword colliding with a
    # known identity, a check {#notify} repeats since a collision can start later.
    module KeywordWatches
      # The durable-scheduler handler kind that ends an expired watch. The runtime
      # registers {Service#expire} under it before the scheduler's boot recovery.
      EXPIRE_KIND = "expire_keyword_watch"

      # Hard cap of ACTIVE watches per subscriber; the 11th is refused rather than
      # silently dropping an old one, so a runaway subscriber cannot grow the
      # per-message matching cost without bound. A cancelled watch frees a slot.
      MAX_ACTIVE_PER_SUBSCRIBER = 10

      MIN_KEYWORD_LENGTH = 2
      MAX_KEYWORD_LENGTH = 100

      # Duration bounds: never unbounded, never so short it is pointless.
      DEFAULT_DURATION = 4 * 3600
      MIN_DURATION = 60
      MAX_DURATION = 30 * 24 * 3600

      # How long after notifying about one watch the same watch stays quiet, so a
      # burst of the same keyword pings once.
      COOLDOWN_SECONDS = 300

      NOTIFY_MODES = %w[mention dm].freeze
      DEFAULT_NOTIFY_VIA = "mention"

      # The sender label a notification is posted under.
      NOTICE_NAME = "rubotty"

      module_function

      # Reuses {Warnings.duration_seconds}'s "1h" / "30m" / seconds vocabulary.
      def duration_seconds(value) = Warnings.duration_seconds(value)

      # What {Service#subscribe} or {Service#stop} did.
      Result = Struct.new(:ok, :watch, :error, :active, keyword_init: true) do
        def ok? = !!ok
      end

      class Service
        # @param store [KeywordWatchStore::Sequel, KeywordWatchStore::Null]
        # @param scheduler [Core::DurableScheduler, nil] schedules and reverses a
        #   watch's bounded expiry; the CALLER registers {#expire} under
        #   {EXPIRE_KIND} on it before boot recovery runs.
        # @param identity_directory [ControlPlane::IdentityDirectory, nil] read by
        #   the anti-stalking check and mention resolution; nil leaves the
        #   collision check permissive and mention delivery falls back to a DM.
        def initialize(store:, scheduler: nil, adapters: {}, ephemeral: nil, identity_directory: nil, logger: nil,
                       clock: -> { Time.now })
          @store = store
          @scheduler = scheduler
          @adapters = adapters
          @ephemeral = ephemeral
          @identity_directory = identity_directory
          @logger = logger
          @clock = clock
          # A cheap in-memory "has anything changed" counter per community, read
          # by {Features::KeywordWatch} on every message (one Hash lookup, no
          # database) to decide whether its own matcher cache is still current.
          # Bumped on every subscribe, stop and expiry.
          @versions = Hash.new(0)
          @versions_mutex = Mutex.new
        end

        attr_reader :store

        # The current version of +community+'s active-watch set. Two calls
        # returning the same value mean nothing changed between them.
        def cache_version(community)
          slug = slug_of(community)
          return 0 if slug.nil?

          @versions_mutex.synchronize { @versions[slug] }
        end

        # subscribe / list / stop

        # Register a new watch for +subscriber+ (a Core::Author, on +origin+'s
        # platform), enforcing a valid keyword, a known notify mode, the
        # anti-stalking check, no duplicate and the per-user cap, in that order.
        # A refusal always carries a human-readable +error+.
        def subscribe(community:, subscriber:, origin:, keyword:, duration: nil, notify_via: DEFAULT_NOTIFY_VIA)
          slug = slug_of(community)
          native_id = subscriber&.native_id
          return Result.new(ok: false, error: "watches aren't available here.") if slug.nil? || native_id.nil?

          term = normalize_keyword(keyword)
          length_error = keyword_length_error(term)
          return Result.new(ok: false, error: length_error) if length_error

          mode = normalize_notify_via(notify_via)
          return Result.new(ok: false, error: %(notify mode must be "mention" or "dm".)) if mode.nil?

          if name_collision?(community, term)
            return Result.new(ok: false, error: collision_error(term))
          end

          now = @clock.call
          existing = @store.find_active_by_keyword(
            community: slug, subscriber_adapter: origin.adapter_name, subscriber_native_id: native_id,
            keyword: term, now: now
          )
          if existing
            return Result.new(
              ok: false, watch: existing,
              error: %(you're already watching "#{existing.keyword}"; /watch stop #{existing.keyword} first if you want to change it.)
            )
          end

          active = @store.active_for_subscriber(
            community: slug, subscriber_adapter: origin.adapter_name, subscriber_native_id: native_id, now: now
          )
          if active.size >= MAX_ACTIVE_PER_SUBSCRIBER
            return Result.new(ok: false, active: active, error: cap_error(active))
          end

          expires_at = now + resolve_duration(duration)
          record = @store.create(
            community: slug, subscriber_adapter: origin.adapter_name, subscriber_account: origin.account,
            subscriber_native_id: native_id, subscriber_username: subscriber.username,
            subscriber_display: display_of(subscriber), keyword: term, notify_via: mode,
            expires_at: expires_at, now: now
          )
          schedule_expiry(record, slug)
          bump_version(slug)
          Result.new(ok: true, watch: record)
        rescue StorageError => e
          @logger&.warn { "keyword_watches: could not subscribe: #{e.message}" }
          Result.new(ok: false, error: "something went wrong recording that watch; try again in a moment.")
        end

        # A subscriber's active watches, oldest first. [] without a community
        # or an identifiable subscriber (no control plane).
        def list(community:, subscriber:, adapter:)
          slug = slug_of(community)
          native_id = subscriber&.native_id
          return [] if slug.nil? || native_id.nil?

          @store.active_for_subscriber(
            community: slug, subscriber_adapter: adapter, subscriber_native_id: native_id, now: @clock.call
          )
        rescue StorageError => e
          @logger&.warn { "keyword_watches: could not list watches: #{e.message}" }
          []
        end

        # End a subscriber's active watch on +keyword+ early. Returns true when
        # a still-active watch was actually found and ended.
        def stop(community:, subscriber:, adapter:, keyword:)
          slug = slug_of(community)
          native_id = subscriber&.native_id
          return false if slug.nil? || native_id.nil?

          watch = @store.find_active_by_keyword(
            community: slug, subscriber_adapter: adapter, subscriber_native_id: native_id,
            keyword: keyword, now: @clock.call
          )
          return false if watch.nil?

          cancelled = @store.cancel(watch.id, now: @clock.call)
          if cancelled
            cancel_expiry(watch, slug)
            bump_version(slug)
          end
          cancelled
        rescue StorageError => e
          @logger&.warn { "keyword_watches: could not stop a watch: #{e.message}" }
          false
        end

        # The durable-scheduler handler: end a watch whose window has come.
        # Idempotent, so racing a manual /watch stop is a harmless no-op.
        def expire(job)
          payload = job.payload || {}
          watch_id = payload["watch_id"]
          return if watch_id.nil?

          cancelled = @store.cancel(watch_id, now: @clock.call)
          bump_version(payload["community"]) if cancelled
        rescue StorageError => e
          @logger&.warn { "keyword_watches: could not expire watch #{watch_id.inspect}: #{e.message}" }
        end

        # matching + notification

        # Every still-active watch in +community+, which {Features::KeywordWatch}
        # compiles into its per-community matcher cache.
        def active_for_community(community)
          slug = slug_of(community)
          return [] if slug.nil?

          @store.active_for_community(community: slug, now: @clock.call)
        rescue StorageError => e
          @logger&.warn { "keyword_watches: could not list a community's watches: #{e.message}" }
          []
        end

        # Notifies the subscriber behind +watch+ that their keyword was said in
        # +message+, returning false without sending when the watch is no
        # longer active, the subscriber said it themselves, this watch already
        # notified within {COOLDOWN_SECONDS}, or the keyword now collides with
        # a known identity. +watch+ is refetched from the store first since
        # the caller's copy may be stale, leaving last_notified_at nil forever
        # and cooldown never engaging.
        # @return [Boolean] whether a notification was actually sent
        def notify(watch, message:, origin:, community:)
          current = @store.find(watch.id)
          return false if current.nil? || !current.active?(@clock.call)
          return false if self_notify?(current, message)
          return false if cooling_down?(current)
          return false if name_collision?(community, current.keyword)

          sent = deliver(current, message: message, origin: origin, community: community)
          @store.touch_notified(current.id, now: @clock.call) if sent
          sent
        end

        private

        # ---- subscribe helpers ----

        def normalize_keyword(keyword) = keyword.to_s.strip

        def keyword_length_error(term)
          return "tell me what to watch for, e.g. /watch aoe3 4h." if term.empty?
          return "keep the keyword under #{MAX_KEYWORD_LENGTH} characters." if term.length > MAX_KEYWORD_LENGTH
          return "a keyword needs at least #{MIN_KEYWORD_LENGTH} characters." if term.length < MIN_KEYWORD_LENGTH

          nil
        end

        def normalize_notify_via(value)
          mode = value.to_s.strip.downcase
          mode = DEFAULT_NOTIFY_VIA if mode.empty?
          NOTIFY_MODES.include?(mode) ? mode : nil
        end

        # The anti-stalking rule's enforcement point, at registration and at the
        # recheck in {#notify}. Permissive without a directory or a community id,
        # since there is nothing to check a name against.
        def name_collision?(community, term)
          return false if @identity_directory.nil?

          community_id = community_id_of(community)
          return false if community_id.nil?

          @identity_directory.handle_collision?(community_id: community_id, keyword: term)
        rescue StandardError => e
          @logger&.warn { "keyword_watches: collision check failed, allowing: #{e.message}" }
          false
        end

        def collision_error(term)
          %("#{term}" looks like a name or handle rather than a keyword, so watching it isn't allowed ) +
            "(this guards against using /watch to track a specific person)."
        end

        def cap_error(active)
          "you already have #{MAX_ACTIVE_PER_SUBSCRIBER} active watches, the most allowed: " \
            "#{active.map(&:keyword).join(", ")}. /watch stop one first."
        end

        def resolve_duration(duration)
          # Qualified: module_function makes .duration_seconds a module method, so
          # an unqualified call from a nested class raises NoMethodError.
          seconds = duration.nil? ? DEFAULT_DURATION : KeywordWatches.duration_seconds(duration)
          seconds = DEFAULT_DURATION if seconds.nil? || !seconds.positive?
          seconds.clamp(MIN_DURATION, MAX_DURATION)
        end

        def schedule_expiry(record, slug)
          return if @scheduler.nil? || record.nil?

          job_id = @scheduler.schedule(
            kind: EXPIRE_KIND, run_at: record.expires_at, community: slug,
            payload: { "watch_id" => record.id, "community" => slug }
          )
          @store.attach_job(record.id, job_id) if job_id
        end

        def cancel_expiry(watch, slug)
          return if @scheduler.nil?

          # A config-file deployment has no slug to name and one community to
          # sweep, the only case where the whole deployment IS the scope. Under
          # the control plane the slug is always there.
          scope = slug.nil? ? { every_community: true } : { community: slug }
          @scheduler.cancel(kind: EXPIRE_KIND, **scope) { |payload| payload["watch_id"] == watch.id }
        end

        def bump_version(slug)
          return if slug.nil?

          @versions_mutex.synchronize { @versions[slug.to_s] += 1 }
        end

        # notify helpers

        # A subscriber is never notified because THEY typed their own watched
        # keyword. Matched on identity, so it holds cross-platform too.
        def self_notify?(watch, message)
          author = message&.author
          return false if author.nil?

          watch.subscriber_adapter.to_s == message.origin.adapter_name.to_s &&
            watch.subscriber_native_id.to_s == author.native_id.to_s
        end

        def cooling_down?(watch)
          last = watch.last_notified_at
          return false if last.nil?

          (@clock.call - to_time(last)) < COOLDOWN_SECONDS
        end

        def deliver(watch, message:, origin:, community:)
          if watch.notify_via == "dm"
            deliver_dm(watch, plain_notification_text(watch))
          else
            deliver_mention(watch, message: message, origin: origin, community: community)
          end
        end

        # Ping the subscriber IN the room the keyword was said in, resolved
        # against the identity directory the same way cross-platform @mentions
        # are; only an UNAMBIGUOUS resolution becomes a real ping. Falls back to a
        # DM when the subscriber has no resolvable identity here.
        def deliver_mention(watch, message:, origin:, community:)
          id = resolve_here(watch, origin, community)
          return deliver_dm(watch, plain_notification_text(watch)) if id.nil?

          rich = mention_rich_text(watch, watch.subscriber_username, origin.adapter_name, id)
          group = ephemeral&.post(endpoints: [origin], body: rich, name: NOTICE_NAME)
          !group.nil? && group.any?
        end

        def resolve_here(watch, origin, community)
          return nil if @identity_directory.nil?

          handle = presence(watch.subscriber_username)
          community_id = community_id_of(community)
          return nil if handle.nil? || community_id.nil?

          @identity_directory.resolve_unique(community_id: community_id, adapter: origin.adapter_name, handle: handle)
        rescue StandardError => e
          @logger&.warn { "keyword_watches: mention resolution failed, falling back to DM: #{e.message}" }
          nil
        end

        def mention_rich_text(watch, handle, adapter_name, native_id)
          token = "@#{handle}"
          text = "Hey #{token}, you're watching \"#{watch.keyword}\" and it was just mentioned here."
          key = :"#{adapter_name}_id_for_target"
          span = Span.new(
            kind: :mention, begin_index: 4, end_index: 4 + token.length, attributes: { key => native_id.to_s }
          )
          RichText.new(text, [span])
        end

        def deliver_dm(watch, text)
          adapter = @adapters[[watch.subscriber_adapter.to_sym, watch.subscriber_account]]
          return false if adapter.nil? || !adapter.supports_admin_dm?

          !!adapter.send_admin_dm(watch.subscriber_native_id, text)
        rescue StandardError => e
          @logger&.warn { "keyword_watches: dm notify failed: #{e.class}: #{e.message}" }
          false
        end

        def plain_notification_text(watch)
          %(You're watching "#{watch.keyword}" and it was just mentioned.)
        end

        # A minimal standalone poster so the Service works with only an adapters
        # map when the runtime's shared primitive was not injected. Cached.
        def ephemeral
          @ephemeral ||= EphemeralMessage.new(adapters: @adapters, session_id: "keyword-watches", logger: @logger)
        end

        def slug_of(community)
          return nil if community.nil?

          community.respond_to?(:slug) ? community.slug : community.to_s
        end

        def community_id_of(community)
          return nil if community.nil?

          community.respond_to?(:id) ? community.id : nil
        end

        def display_of(subscriber)
          subscriber.respond_to?(:any_name) ? subscriber.any_name : nil
        end

        def presence(value)
          return nil if value.nil?

          string = value.to_s.strip
          string.empty? ? nil : string
        end

        def to_time(value)
          return value if value.is_a?(Time)

          value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        end
      end
    end
  end
end
