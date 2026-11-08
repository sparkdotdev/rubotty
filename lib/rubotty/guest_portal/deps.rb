# frozen_string_literal: true

require "sequel"

module Rubotty
  module GuestPortal
    # The bundle of control-plane operations the guest portal drives, built once
    # over one Sequel connection and shared by every request, mirroring
    # {Dashboard::Deps}.
    class Deps
      attr_reader :db, :models, :invites, :feed, :uploads, :rate_limiter, :logger, :retention_grace,
                  :rehosted_files, :upload_tickets, :upload_announcer

      # @param db [Sequel::Database] the already-migrated control-plane connection
      # @param retention_grace [Integer] seconds a guest's captured messages stay
      #   in the database after their access expires. Read only; the bot process
      #   does the reclaiming.
      # @param file_store_path [String, nil] where the sealed object store keeps
      #   bulk bytes. A store that cannot be made ready leaves the file services
      #   nil and their routes answering 404 or 503.
      def initialize(db:, logger: nil, rate_max: RateLimiter::DEFAULT_MAX,
                     rate_window: RateLimiter::DEFAULT_WINDOW_SECONDS,
                     retention_grace: ControlPlane::GuestRetention::DEFAULT_GRACE,
                     file_store_path: nil)
        @db = db
        @logger = logger
        @retention_grace = retention_grace
        @models = ControlPlane.models(db)
        build_file_services(file_store_path)
        # This process only enqueues the arrival notice on a never-started,
        # write-only scheduler. The running bot process delivers it.
        scheduler_store = Core::DurableSchedulerStore::Sequel.new(db: db, logger: logger)
        scheduler = Core::DurableScheduler.new(store: scheduler_store, session_id: "guest-portal", logger: logger)
        announcer = ControlPlane::GuestAnnouncer.new(models: @models, scheduler: scheduler, logger: logger)
        # The finished-upload notice, on the same write-only scheduler.
        @upload_announcer = ControlPlane::UploadAnnouncer.new(
          models: @models, scheduler: scheduler, logger: logger
        )
        @invites = ControlPlane::GuestInvites.new(models: @models, logger: logger, announcer: announcer)
        @feed = ControlPlane::GuestFeed.new(models: @models)
        @rate_limiter = RateLimiter.new(feed: @feed, max: rate_max, window_seconds: rate_window)
      end

      private

      # The services that need the object store, or nil when it is not usable. A
      # mount that did not come up makes downloads 404 without stopping guest sessions.
      def build_file_services(configured)
        store = Storage::ObjectStore.new(root: Storage::ObjectStore.path_from(configured), logger: @logger)
        store.ready!
        @rehosted_files = ControlPlane::RehostedFiles.new(models: @models, store: store, logger: @logger)
        @upload_tickets = ControlPlane::UploadTickets.new(models: @models, logger: @logger)
        @uploads = ControlPlane::GuestUploads.new(models: @models, store: store, logger: @logger)
      rescue Storage::ObjectStore::Unavailable => e
        @logger&.warn do
          "file store unavailable, so rehosted downloads, /upload and guest uploads are off: #{e.message}"
        end
        @rehosted_files = nil
        @upload_tickets = nil
        @uploads = nil
      end
    end
  end
end
