# frozen_string_literal: true

require "securerandom"

module Rubotty
  module Core
    # The off-worker half of shrinking an oversized video: a room's own
    # worker links the file at once through {AttachmentRehoster}, since a
    # transcode cannot finish before the message has to cross, and this
    # tries for something smaller afterwards on {DurableScheduler}'s own
    # worker. Nothing about the room waits on it: success delivers a
    # separate message with the link's line edited out, and failure leaves
    # the link as is. The delivered copy joins the message map, and the loop
    # guard learns of it at delivery, before anything could echo it back.
    class VideoRehostRelay
      KIND = "video_shrink"

      # The short marker a notice becomes when stripping its own line leaves
      # nothing else in the message.
      NO_CAPTION = "crossed as a video below."

      # @param scheduler [Core::DurableScheduler, nil] where a transcode runs; nil
      #   makes {#enqueue} a no-op and {#available?} false.
      # @param transcoder [Util::VideoTranscoder, nil] nil where ffmpeg is not on
      #   PATH, decided once at boot.
      # @param topology [Core::Topology] resolves the target endpoint at fire
      #   time, which may be long after the message that queued this.
      # @param ttl [Integer, nil] seconds the delivered copy's map entry lives
      #   for; nil never expires it.
      def initialize(scheduler:, transcoder:, files:, storage:, topology:, adapters:,
                     loop_guard: nil, fetcher_for: nil, logger: nil, env: ENV, ttl: nil,
                     clock: -> { Time.now })
        @scheduler = scheduler
        @transcoder = transcoder
        @files = files
        @storage = storage
        @topology = topology
        @adapters = adapters
        @loop_guard = loop_guard
        @fetcher_for = fetcher_for || ->(limit) { Util::MediaFetcher.new(limit: limit, logger: logger) }
        @logger = logger
        @env = env
        @ttl = ttl
        @clock = clock
        @scheduler&.register(KIND) { |job| run(job) }
      end

      # Whether a video can be linked now and improved on later at all. No
      # scheduler and no ffmpeg both leave the link standing forever, the same
      # "not installed yet" answer {AttachmentRehoster#shrinks?} gives for a
      # missing image binary.
      def available? = !@scheduler.nil? && !@transcoder.nil?

      # Ask for a background transcode of an attachment already linked, to try
      # to replace that link with the video itself. Called once the message
      # carrying the link has actually gone out, since only then is there a
      # real ref to improve on.
      #
      # @return [Object, nil] the scheduled job's id, or nil with nothing to
      #   schedule against
      def enqueue(attachment:, community_id:, room_key:, ceiling:, source_ref:, target_endpoint_id:,
                  notice_native_id:, notice_line:, body_text:, retention_days: nil, max_bytes: nil,
                  created_by: nil)
        return nil if @scheduler.nil?

        @scheduler.schedule(kind: KIND, run_at: @clock.call, community: community_id&.to_s, payload: {
          "attachment" => attachment.to_h,
          "community_id" => community_id,
          "room_key" => room_key,
          "ceiling" => ceiling,
          "source_endpoint_id" => source_ref.endpoint_id,
          "source_native_id" => source_ref.native_id,
          "target_endpoint_id" => target_endpoint_id,
          "notice_native_id" => notice_native_id,
          "notice_line" => notice_line,
          "body_text" => body_text,
          "retention_days" => retention_days,
          "max_bytes" => max_bytes,
          "created_by" => created_by
        })
      end

      # The durable scheduler's own handler. Public for the same reason
      # {Translation::Relay#run} is: a spec can drive one job without a
      # scheduler behind it. Takes the JOB rather than its payload, so the
      # community that queued the work is in reach of the code below that
      # picks where the video lands.
      def run(job)
        raise ArgumentError, "video_shrink needs the durable job, not a bare payload" unless job?(job)

        payload = job.payload || {}
        target = target_for(job, payload)
        return if target.nil?

        adapter = @adapters[[target.adapter_name, target.account]]
        return if adapter.nil?

        attachment = attachment_of(payload)
        stored = shrink(attachment, payload)
        return if stored.nil?

        deliver_and_edit(adapter, target, attachment, stored, payload)
      end

      private

      def job?(job) = job.respond_to?(:payload) && job.respond_to?(:community)

      # The endpoint this job may deliver a video to. The payload's id resolves
      # against the merged topology, which spans every tenant, so the answer is
      # held against the community that queued the job before anything is
      # posted. An endpoint with no community of its own is the config-file
      # path, which has no other tenant to reach.
      def target_for(job, payload)
        target = @topology.endpoint(payload["target_endpoint_id"])
        return nil if target.nil? || !agrees?(job, payload)

        community_id = payload["community_id"]
        return target if community_id.nil?

        permitted = CommunityScope.permit_or_log(target, community_id, logger: @logger, doing: "video_shrink")
        permitted ? target : nil
      end

      # The payload names the community outright and the job repeats it as
      # text. A disagreement means one of the two was written for a different
      # tenant, and nothing here can tell which, so the video is not delivered.
      def agrees?(job, payload)
        return true if job.community.nil? || payload["community_id"].nil?
        return true if job.community.to_s == payload["community_id"].to_s

        @logger&.error do
          "video_shrink REFUSED: job community #{job.community.inspect} does not match its payload's " \
            "community #{payload["community_id"].inspect}"
        end
        false
      end

      # Fetch the ORIGINAL bytes again, separately from the copy the link
      # already stored: reading that copy back out would cost the same
      # decrypt-and-stream this fetch costs, for a file the transcoder needs
      # to read whole regardless. Deliberately broad, the same way
      # {AttachmentRehoster#build_shrunk} is: a fault here costs the upgrade,
      # never the link already delivered.
      def shrink(attachment, payload)
        # The delivered copy's own url is what the target adapter fetches to
        # pick the transcoded bytes back up, so without a usable base there is
        # nothing to hand it; skip the transcode rather than deliver an
        # attachment no adapter could ever download.
        if public_base.nil?
          @logger&.warn { "not shrinking a video: RUBOTTY_FILE_STORAGE_URL is not set to an http(s) base" }
          return nil
        end

        limit = cap(payload["max_bytes"])
        return nil if attachment.size.to_i.positive? && attachment.size.to_i > limit

        @fetcher_for.call(limit).with(attachment.url, filename: attachment.filename) do |file|
          @transcoder.transcode(file, ceiling: payload["ceiling"].to_i, filename: attachment.filename) do |smaller|
            store(attachment, smaller, payload, limit)
          end
        end
      rescue StandardError => e
        @logger&.warn { "could not shrink a video in the background: #{e.class}: #{e.message}" }
        nil
      end

      def store(attachment, smaller, payload, limit)
        stored = @files.store_file(
          community_id: payload["community_id"], room_key: payload["room_key"], source: smaller,
          filename: shrunk_filename(attachment), content_type: Util::VideoTranscoder::OUTPUT_MIME,
          ttl_days: payload["retention_days"] || ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS,
          limit: limit, origin: "relay", created_by: payload["created_by"]
        )
        attachment.with(
          url: download_url(stored.secret, filename: stored.file.filename, content_type: stored.file.content_type),
          size: smaller.size, mime_type: Util::VideoTranscoder::OUTPUT_MIME,
          filename: shrunk_filename(attachment), width: nil, height: nil
        )
      end

      # Deliver the shrunk copy as its own message and, once that is on the
      # target, edit the link's own line out of the original notice. Wrapped
      # whole: a fault past this point must never retry the job, which would
      # deliver the video a second time.
      def deliver_and_edit(adapter, target, attachment, stored, payload)
        receipt = adapter.deliver(video_message(target, stored), target)
        return if receipt.nil? || receipt.equal?(Core::DeliveryReceipt::NOT_APPLICABLE)

        @storage.record(source: source_ref(payload), destination: receipt.ref,
                        room_id: payload["room_key"], expires_at: @ttl ? @clock.call + @ttl : nil)
        @loop_guard&.note_delivery(target.id, receipt.native_id)
        edit_notice_away(adapter, target, attachment, payload)
      rescue StandardError => e
        @logger&.warn { "could not deliver a shrunk video to #{target.id}: #{e.class}: #{e.message}" }
      end

      def video_message(target, stored)
        Core::Message.new(
          kind: :chat, ref: Core::MessageRef.new(target.id, "video-shrink-#{SecureRandom.hex(4)}"),
          origin: target, body: Core::RichText.plain(""), attachments: [stored], trace: [target.id]
        )
      end

      # Drop the notice's own line from the message that carried it, now that
      # the video has a copy of its own. Left alone on a target that cannot
      # edit at all: the room ends up with both the link and the video, which
      # is a duplicate rather than a break.
      def edit_notice_away(adapter, target, attachment, payload)
        return unless adapter.capabilities_for(target).edits?

        text = without_notice_line(payload["body_text"], payload["notice_line"], attachment.label)
        message = Core::Message.new(
          kind: :chat, ref: Core::MessageRef.new(target.id, payload["notice_native_id"]), origin: target,
          body: Core::RichText.plain(text)
        )
        adapter.edit(message, target, payload["notice_native_id"])
      end

      # Notices join and get appended one whole line at a time (see
      # {Features::Bridge#append_lines}), so the line this attachment earned is
      # removed exactly, whatever else the caption or another notice left
      # standing. Only a body that had nothing else becomes the short marker.
      def without_notice_line(text, line, label)
        lines = text.to_s.split("\n")
        lines.delete(line.to_s)
        lines.empty? ? "[#{label} #{NO_CAPTION}]" : lines.join("\n")
      end

      def cap(max_bytes)
        limit = max_bytes.to_i
        limit.positive? ? limit : ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES
      end

      def shrunk_filename(attachment)
        name = attachment.filename.to_s
        name = attachment.kind.to_s if name.empty?
        "#{File.basename(name, File.extname(name))}#{Util::VideoTranscoder::OUTPUT_EXTENSION}"
      end

      # The same http(s)-or-nil validation {AttachmentRehoster#public_base}
      # applies, so a delivered copy's url is never built on an empty or
      # malformed RUBOTTY_FILE_STORAGE_URL. {#shrink} already refuses to
      # transcode at all once this is nil, so by the time {#download_url}
      # runs it is not.
      def public_base
        base = @env["RUBOTTY_FILE_STORAGE_URL"].to_s.sub(%r{/+\z}, "")
        base.match?(%r{\Ahttps?://\S+\z}) ? base : nil
      end

      def download_url(secret, filename:, content_type:)
        base = public_base
        return nil if base.nil?

        ext = Util::FileExtension.for(filename: filename, content_type: content_type)
        "#{base}/#{AttachmentRehoster::PATH}/#{secret}.#{ext}"
      end

      def source_ref(payload) = Core::MessageRef.new(payload["source_endpoint_id"], payload["source_native_id"])

      def attachment_of(payload) = Core::Attachment.new(**symbolize(payload["attachment"]))

      def symbolize(hash)
        return {} unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(key, value), out| out[key.to_s.to_sym] = value }
      end
    end
  end
end
