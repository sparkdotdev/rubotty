# frozen_string_literal: true

require "json"
require "securerandom"

module Rubotty
  module ControlPlane
    # Post a finished /upload back into the room it was asked for, as one
    # message carrying every stored file as a real attachment, so each
    # target's own outbound logic decides album versus separate posts the
    # way it would for any other multi-attachment message. The web process
    # has no adapters, so posting goes through a one-shot durable job when a
    # scheduler is available, delivering directly otherwise. The decryption
    # keys live on the ticket's own pending_files and pending_failed columns
    # rather than the job payload, since a completed job is marked done.
    class UploadAnnouncer
      DEFAULT_NAME = "rubotty"

      # The durable-scheduler job kind this registers when given a scheduler.
      KIND = "rehosted_upload_posted"

      # @param registry [ControlPlane::Registry, nil] source of the live Snapshot
      #   the room is resolved from. Required for delivery; nil is fine for a
      #   process that only ever enqueues.
      # @param scheduler [Core::DurableScheduler, nil] when given, delivery goes
      #   through a durable job; the handler is registered here, at construction,
      #   before boot recovery runs.
      def initialize(models:, registry: nil, adapters: {}, scheduler: nil, logger: nil, name: DEFAULT_NAME,
                     env: ENV)
        @models = models
        @registry = registry
        @adapters = adapters
        @scheduler = scheduler
        @logger = logger
        @name = name
        @env = env
        @scheduler&.register(KIND) { |job| deliver(ticket_from(job)) }
      end

      # A batch of files has just been uploaded against +ticket+. Record the
      # hand-off and ask for it to be posted.
      #
      # @param ticket [Models::RehostedUploadTicket]
      # @param files [Array<ControlPlane::RehostedFiles::Stored>] in selection order
      # @param failed [Array<String>] filenames from the same batch that could
      #   not be stored, named in the room notice rather than silently dropped
      def announce(ticket:, files:, failed: [])
        return if ticket.nil? || Array(files).empty?

        pending = files.map { |stored| { "secret" => stored.secret.to_s, "file_id" => stored.file.id } }
        ticket.update(pending_files: JSON.generate(pending), pending_failed: JSON.generate(Array(failed).map(&:to_s)))
        if @scheduler
          @scheduler.schedule(kind: KIND, run_at: Time.now, payload: { "ticket_id" => ticket.id })
        else
          deliver(ticket)
        end
      end

      # Post the batch into its room and clear the hand-off. Never raises: a
      # lost notice must not fail the job into a retry loop that would keep
      # the secrets alive longer than the post they were for.
      def deliver(ticket)
        return if ticket.nil?

        pairs = resolved_pairs(ticket)
        return if pairs.empty?

        text = message_text(ticket, pairs.map(&:first), failed_for(ticket))
        attachments = pairs.map { |file, secret| attachment_for(file, secret) }
        room = resolve_room(ticket)
        post_all(room, text, attachments) if room
      rescue StandardError => e
        @logger&.warn { "upload announcer: could not post the upload: #{e.class}: #{e.message}" }
      ensure
        # Cleared whatever happened: keeping the keys around for a second
        # attempt would be keeping them for no benefit.
        ticket&.update(pending_files: "[]", pending_failed: "[]")
      end

      private

      def ticket_from(job)
        id = (job.payload || {})["ticket_id"]
        id && @models.rehosted_upload_ticket[id.to_i]
      end

      # The ticket's pending files, each resolved against its still-live row.
      # A file the daily sweep has since reclaimed is dropped rather than
      # crashing the whole post over one stale entry.
      def resolved_pairs(ticket)
        decode(ticket.pending_files).filter_map do |entry|
          file = entry["file_id"] && @models.rehosted_file[entry["file_id"].to_i]
          file && [file, entry["secret"]]
        end
      end

      def failed_for(ticket)
        decode(ticket.pending_failed).map(&:to_s)
      end

      def decode(raw)
        parsed = raw.to_s.strip.empty? ? [] : JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : []
      rescue JSON::ParserError
        []
      end

      def message_text(ticket, files, failed)
        who = ticket.requested_by_label.to_s
        who = "Somebody" if who.empty?
        lead = if files.size == 1
                 "#{who} uploaded #{files.first.filename} (#{human_size(files.first.byte_size)})."
               else
                 "#{who} uploaded #{files.size} files (#{human_size(files.sum { |f| f.byte_size.to_i })} total)."
               end
        return lead if failed.empty?

        "#{lead} #{failed.size} more could not be stored and #{failed.size == 1 ? "was" : "were"} " \
          "left out: #{failed.join(", ")}."
      end

      # One real attachment per stored file, in the same order the pending
      # list carries, so the target's own album logic sees them the way it
      # would any other multi-attachment message.
      def attachment_for(file, secret)
        Core::Attachment.new(
          kind: attachment_kind_for(file.content_type),
          url: link(file, secret),
          filename: file.filename,
          mime_type: file.content_type,
          size: file.byte_size
        )
      end

      # The broad attachment category for a MIME type, the same split
      # GuestPortal::App uses for a guest's own inline upload.
      def attachment_kind_for(mime)
        case mime.to_s.split("/").first
        when "image" then :photo
        when "video" then :video
        when "audio" then :audio
        else :document
        end
      end

      # The download URL, built off RUBOTTY_FILE_STORAGE_URL, ending in the
      # file's own extension the way {Core::AttachmentRehoster#download_url}
      # does.
      def link(file, secret)
        base = @env["RUBOTTY_FILE_STORAGE_URL"].to_s.sub(%r{/+\z}, "")
        ext = Util::FileExtension.for(filename: file.filename, content_type: file.content_type)
        "#{base}/#{Core::AttachmentRehoster::PATH}/#{secret}.#{ext}"
      end

      # The room the ticket named, resolved through one of its channels' endpoint
      # keys rather than by matching the room_key string against the global
      # topology: room_key is unique only WITHIN a community.
      def resolve_room(ticket)
        return nil if @registry.nil?

        key = ticket.endpoint_key.to_s
        room = @registry.current.topology.rooms.find { |candidate| candidate.include?(key) }
        @logger&.warn { "upload announcer: no live room for #{key}, dropping the notice" } if room.nil?
        room
      end

      # Every endpoint the room fans a notice out to, with no origin to exclude,
      # since the bot is authoring this rather than relaying it.
      def post_all(room, text, attachments)
        room.targets_for(nil).each do |endpoint|
          adapter = @adapters[[endpoint.adapter_name, endpoint.account]]
          next if adapter.nil?

          adapter.deliver(build_message(endpoint, text, attachments), endpoint)
        rescue AdapterError => e
          @logger&.warn { "upload announcer: could not post to #{endpoint.id}: #{e.message}" }
        end
      end

      def build_message(endpoint, text, attachments)
        Core::Message.new(
          kind: :system,
          ref: Core::MessageRef.new(endpoint.id, "upload-notice-#{SecureRandom.hex(4)}"),
          origin: endpoint,
          author: Core::Author.new(display_name: @name, kind: :system),
          body: Core::RichText.plain(text),
          attachments: attachments,
          sender_label: @name
        )
      end

      def human_size(bytes)
        size = bytes.to_i
        return "#{size} B" if size < 1024
        return "#{(size / 1024.0).round(1)} KB" if size < 1024 * 1024
        return "#{(size / (1024.0 * 1024)).round(1)} MB" if size < 1024 * 1024 * 1024

        "#{(size / (1024.0 * 1024 * 1024)).round(1)} GB"
      end
    end
  end
end
