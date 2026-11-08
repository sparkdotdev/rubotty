# frozen_string_literal: true

require "sequel"

module Rubotty
  module Core
    # Durable backing for keyword watches: the `keyword_watches` table.
    #
    # {Sequel} persists to it; {Null} is a no-op used by the memory and pstore
    # backends, which have no database, so there /watch simply records nothing.
    module KeywordWatchStore
      # One subscription, as the service reads it back.
      Watch = Struct.new(
        :id, :community, :subscriber_adapter, :subscriber_account, :subscriber_native_id,
        :subscriber_username, :subscriber_display, :keyword, :notify_via, :created_at, :expires_at,
        :cancelled_at, :last_notified_at, :job_id, keyword_init: true
      ) do
        def active?(now = Time.now) = cancelled_at.nil? && expires_at && expires_at > now
      end

      module_function

      # The right store for a storage backend: {Sequel} when it exposes a
      # Sequel::Database, {Null} otherwise.
      def for(storage, logger: nil)
        db = storage.respond_to?(:db) ? storage.db : nil
        db.is_a?(::Sequel::Database) ? Sequel.new(db: db, logger: logger) : Null.new
      end

      # No-op store for backends without a database.
      class Null
        def durable? = false

        def create(**) = nil

        def attach_job(*) = nil

        def find(_id) = nil

        def active_for_subscriber(**) = []

        def active_count(**) = 0

        def active_for_community(**) = []

        def find_active_by_keyword(**) = nil

        def cancel(*) = false

        def touch_notified(*) = nil
      end

      # Persistent store over the `keyword_watches` table.
      class Sequel
        TABLE = :keyword_watches

        def initialize(db:, logger: nil)
          @db = db
          @logger = logger
        end

        def durable? = true

        # Persist a new subscription and return it as a {Watch}.
        def create(community:, subscriber_adapter:, subscriber_account:, subscriber_native_id:, keyword:,
                   expires_at:, subscriber_username: nil, subscriber_display: nil, notify_via: "mention",
                   now: Time.now)
          id = watches.insert(
            community: community.to_s, subscriber_adapter: subscriber_adapter.to_s,
            subscriber_account: subscriber_account.to_s, subscriber_native_id: subscriber_native_id.to_s,
            subscriber_username: subscriber_username, subscriber_display: subscriber_display,
            keyword: keyword.to_s, notify_via: notify_via.to_s, created_at: now, expires_at: expires_at
          )
          find(id)
        rescue ::Sequel::Error => e
          raise StorageError, "could not record a keyword watch: #{e.message}"
        end

        # Attach the durable-scheduler job id that drives this watch's expiry. Separate
        # from the insert so a store that could not schedule still records the watch.
        def attach_job(id, job_id)
          watches.where(id: id).update(job_id: job_id&.to_s)
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not attach the expiry job: #{e.message}"
        end

        # One watch by id, or nil.
        def find(id)
          row = watches.where(id: id).first
          row && to_watch(row)
        rescue ::Sequel::Error => e
          raise StorageError, "could not read a keyword watch: #{e.message}"
        end

        # A subscriber's still-active watches (not cancelled, not yet
        # expired), oldest first: what /watch list shows, and the cap count.
        def active_for_subscriber(community:, subscriber_adapter:, subscriber_native_id:, now: Time.now)
          active_subject_scope(subscriber_scope(watches, community, subscriber_adapter, subscriber_native_id), now)
            .order(:id).map { |row| to_watch(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not list keyword watches: #{e.message}"
        end

        # How many active watches a subscriber has, the per-user cap check.
        def active_count(community:, subscriber_adapter:, subscriber_native_id:, now: Time.now)
          active_subject_scope(subscriber_scope(watches, community, subscriber_adapter, subscriber_native_id), now)
            .count
        rescue ::Sequel::Error => e
          raise StorageError, "could not count keyword watches: #{e.message}"
        end

        # Every still-active watch in a community, across every subscriber: the source
        # compiled into a matcher set once per community, rebuilt on subscription change.
        def active_for_community(community:, now: Time.now)
          active_subject_scope(watches.where(community: community.to_s), now)
            .order(:id).map { |row| to_watch(row) }
        rescue ::Sequel::Error => e
          raise StorageError, "could not list a community's keyword watches: #{e.message}"
        end

        # A subscriber's active watch on an exact keyword (case-insensitive),
        # or nil: /watch stop's target, and the duplicate-subscription check.
        def find_active_by_keyword(community:, subscriber_adapter:, subscriber_native_id:, keyword:, now: Time.now)
          needle = keyword.to_s.strip.downcase
          return nil if needle.empty?

          # An equality rather than a LIKE, which is what "exact" above always
          # meant: a keyword is typed by whoever runs /watch, and one holding a
          # percent or an underscore would otherwise stop somebody else's watch.
          row = active_subject_scope(subscriber_scope(watches, community, subscriber_adapter, subscriber_native_id),
                                      now)
                .where(::Sequel.function(:lower, :keyword) => needle)
                .order(:id).first
          row && to_watch(row)
        rescue ::Sequel::Error => e
          raise StorageError, "could not look up a keyword watch: #{e.message}"
        end

        # End a watch (a /watch stop, or the scheduler's expiry firing) by deactivating
        # the row so a subscriber's history survives. Returns true when one was ended.
        def cancel(id, now: Time.now)
          watches.where(id: id, cancelled_at: nil).update(cancelled_at: now).positive?
        rescue ::Sequel::Error => e
          raise StorageError, "could not cancel a keyword watch: #{e.message}"
        end

        # Record that a watch just notified its subscriber, the cooldown clock.
        def touch_notified(id, now: Time.now)
          watches.where(id: id).update(last_notified_at: now)
          nil
        rescue ::Sequel::Error => e
          raise StorageError, "could not update a keyword watch's cooldown: #{e.message}"
        end

        private

        def watches = @db[TABLE]

        def subscriber_scope(dataset, community, adapter, native_id)
          dataset.where(
            community: community.to_s, subscriber_adapter: adapter.to_s,
            subscriber_native_id: native_id.to_s
          )
        end

        def active_subject_scope(dataset, now)
          dataset.where(cancelled_at: nil).where { expires_at > now }
        end

        def to_watch(row)
          Watch.new(
            id: row[:id], community: row[:community], subscriber_adapter: row[:subscriber_adapter],
            subscriber_account: row[:subscriber_account], subscriber_native_id: row[:subscriber_native_id],
            subscriber_username: row[:subscriber_username], subscriber_display: row[:subscriber_display],
            keyword: row[:keyword], notify_via: row[:notify_via], created_at: row[:created_at],
            expires_at: row[:expires_at], cancelled_at: row[:cancelled_at],
            last_notified_at: row[:last_notified_at], job_id: row[:job_id]
          )
        end
      end
    end
  end
end
