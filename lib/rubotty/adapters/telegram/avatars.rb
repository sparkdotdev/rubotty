# frozen_string_literal: true

require "monitor"

module Rubotty
  module Adapters
    module Telegram
      # A Telegram sender's profile photo, copied somewhere a third party may fetch
      # it. Telegram serves a profile photo from a URL with the bot token in its
      # path, so it can never be handed to Discord, Fluxer or Stoat directly; the
      # picture is pulled through {Core::AttachmentRehoster} instead and the public
      # download link is what the bridge puppets with. A photo is cached per person
      # per community since it changes rarely (refreshed on a background thread),
      # and an inbound message is answered out of that cache or not at all: it never
      # waits on a fetch, so the first message from somebody nobody has seen yet relays without a picture.
      class Avatars
        # How long an entry is trusted before Telegram is asked again.
        CHECK_AFTER = 7 * 24 * 60 * 60

        # The same, for a person Telegram gave no photo for. Shorter, because
        # that answer changes the moment they set one.
        RECHECK_MISS_AFTER = 6 * 60 * 60

        # The largest profile photo worth pulling. Telegram caps one at 640x640,
        # so this is a backstop rather than a limit anybody meets.
        MAX_BYTES = 8 * 1024 * 1024

        # What the copy is called and what it is. Telegram serves profile photos
        # as JPEG.
        FILENAME = "avatar.jpg"
        MIME_TYPE = "image/jpeg"

        # The cache ceiling, so a busy deployment cannot grow it without bound.
        MAX_ENTRIES = 2000

        # How many refreshes may be waiting at once. Past this a miss is answered
        # as "no avatar" and tried again on the next message.
        MAX_PENDING = 200

        # Seconds to wait for the worker to finish what it is holding, on stop.
        STOP_TIMEOUT = 5

        # One person's picture. +url+ is nil for somebody with no reachable
        # photo. +stored_at+ and +expires_at+ bracket the life of the copy on
        # disk; +checked_at+ is when Telegram last answered about it.
        Entry = Struct.new(:file_id, :url, :stored_at, :checked_at, :expires_at)

        # @param photos [#call] given a user id, answers getUserProfilePhotos
        # @param file_url [#call] given a file_id, answers a downloadable URL
        # @param rehoster [Core::AttachmentRehoster] where the bytes go
        # @param worker [Boolean] false leaves refreshes for a caller to {#drain},
        #   which is how the specs run them on one thread
        def initialize(photos:, file_url:, rehoster:, logger: nil, clock: -> { Time.now }, worker: true)
          @photos = photos
          @file_url = file_url
          @rehoster = rehoster
          @logger = logger
          @clock = clock
          @worker = worker
          @cache = {}
          @pending = {}
          @queue = Queue.new
          @monitor = Monitor.new
          @thread = nil
        end

        # The link a third party may fetch this person's picture from, or nil.
        # Queues a refresh when there is nothing cached or the entry is due, and
        # answers immediately either way.
        #
        # @param user_id [Integer, String, nil]
        # @param community_id [Integer, nil] whose disk keeps the copy
        # @param retention_days [Integer] how long that community keeps it
        # @return [String, nil]
        def url_for(user_id, community_id, retention_days: ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS)
          return nil if user_id.nil? || community_id.nil?

          key = [community_id, user_id.to_s]
          now = @clock.call
          entry = @monitor.synchronize { @cache[key] }
          enqueue(key, retention_days) if entry.nil? || due?(entry, now)
          return nil if entry.nil? || entry.url.nil? || entry.expires_at <= now

          entry.url
        end

        # Run every queued refresh on the calling thread and answer how many ran.
        # The worker thread is one caller; a spec is the other, so a refresh can
        # be driven without waiting on a thread.
        def drain
          ran = 0
          while (item = next_pending)
            refresh(*item)
            ran += 1
          end
          ran
        end

        def stop
          thread = @monitor.synchronize do
            @queue.close
            @thread.tap { @thread = nil }
          end
          thread&.join(STOP_TIMEOUT)
          self
        end

        private

        def enqueue(key, retention_days)
          @monitor.synchronize do
            return if @pending.key?(key)
            return if @pending.size >= MAX_PENDING

            @pending[key] = true
          end
          @queue << [key, retention_days]
          start_worker if @worker
        rescue ClosedQueueError
          @monitor.synchronize { @pending.delete(key) }
        end

        def start_worker
          @monitor.synchronize do
            return if @thread&.alive?

            @thread = Thread.new { work }
          end
        end

        # #pop answers nil once the queue is closed, which is how {#stop} ends
        # this loop.
        def work
          while (item = @queue.pop)
            refresh(*item)
          end
        rescue StandardError => e
          @logger&.warn { "the Telegram avatar worker stopped: #{e.class}: #{safe(e.message)}" }
        end

        def next_pending
          @queue.pop(true)
        rescue ThreadError
          nil
        end

        # One person's photo, asked about and copied if it needs copying. Never
        # raises: a failure is written down as "no avatar", so the next message
        # is answered from the cache instead of trying again straight away.
        def refresh(key, retention_days)
          community_id, user_id = key
          now = @clock.call
          file_id = current_file_id(user_id)
          return remember(key, Entry.new(nil, nil, nil, now, nil)) if file_id.nil?

          existing = @monitor.synchronize { @cache[key] }
          if reusable?(existing, file_id, now)
            existing.checked_at = now
            return remember(key, existing)
          end

          url = copy(file_id, community_id, user_id, retention_days)
          remember(key, Entry.new(file_id, url, now, now, expiry_for(url, now, retention_days)))
        rescue StandardError => e
          @logger&.warn { "could not refresh a Telegram avatar: #{e.class}: #{safe(e.message)}" }
          remember(key, Entry.new(nil, nil, nil, @clock.call, nil))
        ensure
          @monitor.synchronize { @pending.delete(key) }
        end

        # The file_id of this person's current profile photo, or nil when they
        # have none, when Telegram will not say, or when the answer is not the
        # shape the Bot API documents. The last size is the largest Telegram
        # offers, which for a profile photo is at most 640x640.
        def current_file_id(user_id)
          answer = @photos.call(user_id)
          sizes = answer.is_a?(Hash) ? Array(answer["photos"]).first : nil
          largest = Array(sizes).last
          largest.is_a?(Hash) ? largest["file_id"] : nil
        rescue StandardError => e
          @logger&.warn { "could not read a Telegram profile photo: #{e.class}: #{safe(e.message)}" }
          nil
        end

        # Pull the photo through the rehoster and answer the link a third party
        # may fetch, or nil when any step of that did not work.
        def copy(file_id, community_id, user_id, retention_days)
          source = @file_url.call(file_id)
          return nil if source.nil?

          publishable(
            @rehoster.rehost(
              attachment: Core::Attachment.new(kind: :photo, url: source, filename: FILENAME,
                                               mime_type: MIME_TYPE),
              community_id: community_id, retention_days: retention_days,
              max_bytes: MAX_BYTES, created_by: "telegram:#{user_id}"
            )
          )
        end

        # Only an absolute link with no credential in it is ever cached. A
        # relative one means RUBOTTY_FILE_STORAGE_URL is unset and no platform
        # could fetch it, and a credentialed one would be the very leak the
        # copy exists to avoid.
        def publishable(url)
          return nil if url.nil?
          return nil unless url.to_s.start_with?("https://", "http://")

          Util::SafeUrl.public(url)
        end

        def expiry_for(url, now, retention_days)
          return nil if url.nil?

          now + (clamped(retention_days) * 86_400)
        end

        # Time to ask Telegram again: either the entry has aged out of its check
        # window, or the copy on disk is past half its life and wants remaking
        # while the link it replaces still works.
        def due?(entry, now)
          return now - entry.checked_at >= RECHECK_MISS_AFTER if entry.url.nil?

          now - entry.checked_at >= CHECK_AFTER || now >= renew_at(entry)
        end

        # Halfway through the copy's retention.
        def renew_at(entry) = entry.stored_at + ((entry.expires_at - entry.stored_at) / 2)

        # Nothing to copy: the photo is the one already held and its bytes have
        # plenty of life left, so only the moment of the check moves.
        def reusable?(entry, file_id, now)
          !entry.nil? && !entry.url.nil? && entry.file_id == file_id && now < renew_at(entry)
        end

        def remember(key, entry)
          @monitor.synchronize do
            # Deleted first so the key takes a new place in insertion order, which
            # is what makes the oldest entry the one written longest ago.
            @cache.delete(key)
            @cache[key] = entry
            @cache.delete(@cache.each_key.first) if @cache.size > MAX_ENTRIES
          end
          entry.url
        end

        # The same clamp {ControlPlane::RehostedFiles} applies when it writes the
        # row, so the cache and the disk agree on when the bytes go.
        def clamped(days)
          value = days.to_i
          return ControlPlane::RehostedFiles::DEFAULT_AVATAR_TTL_DAYS unless value.positive?

          [value, ControlPlane::RehostedFiles::MAX_TTL_DAYS].min
        end

        # An exception's own message can quote the URL it failed on, and a
        # Telegram file URL carries the bot token.
        def safe(message) = Util::SafeUrl.redact(message)
      end
    end
  end
end
