# frozen_string_literal: true

module Rubotty
  module Core
    # Turns a file the target platform will not accept into a link it will:
    # downloads through the hardened fetcher, stores via
    # {ControlPlane::RehostedFiles}, and returns a download URL. Every failure
    # path returns nil and logs, and nothing here ever raises, so the bridge
    # just relays as before. Bytes are pulled, not linked, because platform
    # URLs aren't safe substitutes: a Telegram URL embeds the bot token and a
    # Discord CDN link is signed, both expiring, so reposting would leak a
    # credential. The +memo+ hash dedupes storage across one message's fan-out.
    class AttachmentRehoster
      # The path a download url is served under, on the same public base the
      # guest portal's own upload URLs use. The url itself ends in a real
      # extension, e.g. ".../filestorage/<uuid>.jpg", for a human or a link
      # preview reading it; {LEGACY_PATH} is the bare-uuid shape this used
      # before.
      PATH = "filestorage"

      # Where a download url used to be served, with no extension on the
      # uuid. Kept working rather than removed: a rehosted file can sit on
      # disk for up to a year, so a link already posted into a real room may
      # still be live, and this route costs nothing to leave standing.
      LEGACY_PATH = "f"

      # What every notice says rubotty did, whatever the reason was. Always in
      # italics: it is system commentary standing next to the url, not
      # something a room member wrote. Says the link is limited rather than
      # how many times are left, which an operator reads off the file
      # instead; see ControlPlane::RehostedFiles#serves_remaining.
      REHOST_ASIDE = "File re-hosted automatically by Rubotty to avoid platform limitations; " \
                     "the link works a limited number of times."

      # What each of {Features::FileRehosting::STRATEGIES} is willing to do.
      # Named here rather than read from the feature because this is the half
      # that acts on them; a spec holds the two lists to each other.
      SHRINKING = %i[shrink shrink_then_link].freeze
      LINKING = %i[link shrink_then_link].freeze

      # What became of one attachment that needed rehosting: +:shrunk+ carries a
      # re encoded replacement, +:relayed+ carries the same file handed across
      # untouched (rehosting only to strip a credential), and +:linked+ carries
      # the URL that replaces the file in the body. +:video+ is set only on a
      # +:linked+ placement, for a background improvement via
      # {Core::VideoRehostRelay}; see {#schedule_video_followup}.
      Placement = Struct.new(:kind, :attachment, :url, :video, keyword_init: true) do
        def shrunk? = kind == :shrunk

        def relayed? = kind == :relayed

        def linked? = kind == :linked
      end

      # Configure durable file storage, byte-limited fetching and optional image
      # or video shrinking.
      def initialize(files:, fetcher_for: nil, shrinker: nil, video: nil, logger: nil, env: ENV)
        @files = files
        @fetcher_for = fetcher_for || ->(limit) { Util::MediaFetcher.new(limit: limit, logger: logger) }
        @shrinker = shrinker
        @video = video
        @logger = logger
        @env = env
      end

      # Whether shrinking is possible at all in this deployment.
      def shrinks? = !@shrinker.nil?

      # Whether a video can be linked now and shrunk in the background at all.
      def shrinks_video? = !@video.nil? && @video.available?

      # Choose a target-specific attachment placement under the community's
      # strategy and byte ceiling.
      def place(attachment:, community_id:, ceiling:, strategy: :link, room_key: nil,
                retention_days: nil, max_bytes: nil, created_by: nil, memo: nil, verbatim: false)
        return nil if attachment.nil? || community_id.nil?
        return nil unless attachment.resolvable?

        if verbatim
          placement = relay_verbatim(attachment: attachment, community_id: community_id, room_key: room_key,
                                     retention_days: retention_days, max_bytes: max_bytes,
                                     created_by: created_by, memo: memo)
          return placement if placement
        end

        if SHRINKING.include?(strategy)
          placement = if video_candidate?(attachment)
                        link_with_pending_shrink(attachment, community_id, room_key, ceiling,
                                                 retention_days, max_bytes, created_by, memo)
                      else
                        shrink(attachment, community_id, room_key, ceiling, retention_days, max_bytes,
                              created_by, memo)
                      end
          return placement if placement
        end
        return nil unless LINKING.include?(strategy)

        url = rehost(attachment: attachment, community_id: community_id, room_key: room_key,
                     retention_days: retention_days, max_bytes: max_bytes,
                     created_by: created_by, memo: memo)
        url && Placement.new(kind: :linked, url: url)
      end

      # Queue a delivered link for optional background video replacement.
      def schedule_video_followup(video, **delivered)
        return if video.nil? || @video.nil?

        @video.enqueue(**video, **delivered)
      end

      # Rehost one resolvable attachment and return its public download URL.
      def rehost(attachment:, community_id:, room_key: nil, retention_days: nil, max_bytes: nil,
                 created_by: nil, memo: nil)
        return nil if attachment.nil? || community_id.nil?
        # A native-only ref has no URL through which to fetch bytes.
        return nil unless attachment.resolvable?

        # All targets can reuse a stored original regardless of their ceilings.
        key = memo_key(attachment, room_key)
        return memo[key] if memo&.key?(key)

        url = store(attachment, community_id, room_key, retention_days, max_bytes, created_by)
        # Cache failures to avoid repeating a failed download per target.
        memo[key] = url if memo
        url
      end

      # Store an original attachment unchanged when only its source URL is unsafe.
      def relay_verbatim(attachment:, community_id:, room_key: nil, retention_days: nil, max_bytes: nil,
                         created_by: nil, memo: nil)
        url = rehost(attachment: attachment, community_id: community_id, room_key: room_key,
                     retention_days: retention_days, max_bytes: max_bytes,
                     created_by: created_by, memo: memo)
        url && Placement.new(kind: :relayed, attachment: attachment.with(url: url))
      end

      # The line that goes into the body in place of the file: the download
      # url, and this italicised aside.
      def notice(url:)
        parenthetical_aside(url, REHOST_ASIDE)
      end

      # Explain when a source platform refuses a file too large to download.
      def unfetchable_notice(attachment:, target_label:, origin_label:, ceiling:)
        size = human_size(attachment.size)
        fact = "#{label(attachment)}#{size ? " (#{size})" : ""} could not reach #{target_label}: " \
               "#{origin_label} will not let a bot download a file over #{human_size(ceiling)}."
        parenthetical_aside(fact, "Rubotty could not re-host it either, since it was never downloaded.")
      end

      private

      # Return a RichText aside so each target renderer controls emphasis syntax.
      def parenthetical_aside(lead, note)
        prefix = "#{lead} ("
        span = Span.new(kind: :italic, begin_index: prefix.length, end_index: prefix.length + note.length)
        RichText.new("#{prefix}#{note})", [span])
      end

      def label(attachment)
        name = attachment.filename.to_s
        name.empty? ? attachment.kind.to_s : name
      end

      def video_candidate?(attachment)
        shrinks_video? && Util::VideoTranscoder.transcodable?(mime_type: attachment.mime_type,
                                                               filename: attachment.filename)
      end

      # Link a video first, then carry the information for optional background
      # replacement.
      def link_with_pending_shrink(attachment, community_id, room_key, ceiling, retention_days,
                                   max_bytes, created_by, memo)
        url = rehost(attachment: attachment, community_id: community_id, room_key: room_key,
                     retention_days: retention_days, max_bytes: max_bytes,
                     created_by: created_by, memo: memo)
        return nil if url.nil?

        Placement.new(kind: :linked, url: url, video: {
          attachment: attachment, community_id: community_id, room_key: room_key, ceiling: ceiling,
          retention_days: retention_days, max_bytes: max_bytes, created_by: created_by
        })
      end

      # Re-encode an image to its target ceiling, caching by room and ceiling.
      def shrink(attachment, community_id, room_key, ceiling, retention_days, max_bytes,
                 created_by, memo)
        return nil if @shrinker.nil? || ceiling.to_i < 1

        key = memo_key(attachment, room_key, ceiling)
        return memo[key] if memo&.key?(key)

        placement = build_shrunk(attachment, community_id, room_key, ceiling, retention_days,
                                 max_bytes, created_by)
        memo[key] = placement if memo
        placement
      end

      def build_shrunk(attachment, community_id, room_key, ceiling, retention_days, max_bytes,
                       created_by)
        return nil unless Util::ImageShrinker.shrinkable?(mime_type: attachment.mime_type,
                                                          filename: attachment.filename)
        # Skip encoding when no public base can serve the result.
        return nil if no_public_base!

        limit = cap(max_bytes)
        return nil if attachment.size.to_i.positive? && attachment.size.to_i > limit

        stored, bytes = fetch_and_shrink(attachment, community_id, room_key, ceiling,
                                         retention_days, limit, created_by)
        return nil if stored.nil?

        Placement.new(kind: :shrunk, attachment: shrunk_attachment(attachment, stored, bytes))
      end

      def fetch_and_shrink(attachment, community_id, room_key, ceiling, retention_days, limit,
                           created_by)
        @fetcher_for.call(limit).with(attachment.url, filename: attachment.filename) do |file|
          @shrinker.shrink(file, ceiling: ceiling, filename: attachment.filename) do |smaller|
            bytes = smaller.size
            [@files.store_file(
              community_id: community_id, room_key: room_key, source: smaller,
              filename: shrunk_filename(attachment),
              content_type: Util::ImageShrinker::OUTPUT_MIME,
              ttl_days: retention_days || ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS,
              limit: limit, origin: "relay", created_by: created_by
            ), bytes]
          end
        end || [nil, nil]
      rescue StandardError => e
        # Keep shrink failures out of the relay fan-out.
        @logger&.warn { "could not shrink a file: #{e.class}: #{e.message}" }
        [nil, nil]
      end

      # Clear changed image dimensions from the shrunk replacement.
      def shrunk_attachment(attachment, stored, bytes)
        attachment.with(
          url: download_url(stored.secret, filename: stored.file.filename, content_type: stored.file.content_type),
          size: bytes, mime_type: Util::ImageShrinker::OUTPUT_MIME, filename: shrunk_filename(attachment),
          width: nil, height: nil
        )
      end

      def shrunk_filename(attachment)
        name = attachment.filename.to_s
        name = attachment.kind.to_s if name.empty?
        "#{File.basename(name, File.extname(name))}#{Util::ImageShrinker::OUTPUT_EXTENSION}"
      end

      def cap(max_bytes)
        limit = max_bytes.to_i
        limit.positive? ? limit : ControlPlane::RehostedFiles::DEFAULT_MAX_BYTES
      end

      def store(attachment, community_id, room_key, retention_days, max_bytes, created_by)
        return nil if no_public_base!

        limit = cap(max_bytes)
        # Refuse known oversize files before fetching.
        if attachment.size.to_i.positive? && attachment.size.to_i > limit
          @logger&.info { "not rehosting a #{attachment.size} byte file: over the #{limit} byte cap" }
          return nil
        end

        stored = @fetcher_for.call(limit).with(attachment.url, filename: attachment.filename) do |file|
          @files.store_file(
            community_id: community_id, room_key: room_key, source: file,
            filename: attachment.filename || file.original_filename,
            content_type: attachment.mime_type,
            ttl_days: retention_days || ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS,
            limit: limit, origin: "relay", created_by: created_by
          )
        end
        return nil if stored.nil?

        download_url(stored.secret, filename: stored.file.filename, content_type: stored.file.content_type)
      rescue Storage::ObjectStore::TooLarge
        @logger&.info { "not rehosting a file: it exceeded the #{limit} byte cap while downloading" }
        nil
      rescue StandardError => e
        # Keep rehost failures out of the relay fan-out.
        @logger&.warn { "could not rehost a file: #{e.class}: #{e.message}" }
        nil
      end

      # Return a validated public download base, or nil without one.
      def public_base
        base = @env["RUBOTTY_FILE_STORAGE_URL"].to_s.sub(%r{/+\z}, "")
        base.match?(%r{\Ahttps?://\S+\z}) ? base : nil
      end

      # Warn and refuse storage when no public base can serve a download link.
      def no_public_base!
        return false unless public_base.nil?

        @logger&.warn do
          "not rehosting a file: RUBOTTY_FILE_STORAGE_URL is not set to an http(s) base, so " \
            "no download link could be built"
        end
        true
      end

      # Build link extensions from the stored file the download route validates.
      def download_url(secret, filename:, content_type:)
        base = public_base
        return nil if base.nil?

        ext = Util::FileExtension.for(filename: filename, content_type: content_type)
        "#{base}/#{PATH}/#{secret}.#{ext}"
      end

      # Memoise by source URL, room retention scope and optional target ceiling.
      def memo_key(attachment, room_key, ceiling = nil)
        [room_key, attachment.url || attachment.object_id, ceiling]
      end

      def human_size(bytes)
        size = bytes.to_i
        return nil unless size.positive?
        return "#{size} B" if size < 1024
        return "#{(size / 1024.0).round(1)} KB" if size < 1024 * 1024
        return "#{(size / (1024.0 * 1024)).round(1)} MB" if size < 1024 * 1024 * 1024

        "#{(size / (1024.0 * 1024 * 1024)).round(1)} GB"
      end
    end
  end
end
