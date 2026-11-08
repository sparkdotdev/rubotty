# frozen_string_literal: true

require "base64"

module Rubotty
  module ControlPlane
    # Files too large to relay directly go into the object store, with a
    # download link handed to the target instead. The link's UUID is also the
    # encryption key's input, so the row stores only its SHA-256 digest, never
    # the UUID itself; {#fetch} hashes what it is given and looks up by
    # digest. Download lookups cannot be scoped by community, since the
    # fetcher presents only a token, but the object key is prefixed with the
    # owning community's id, so a row can never name bytes outside its own
    # subtree.
    class RehostedFiles
      # Raised with a message a caller prints as-is.
      class Invalid < Rubotty::Error; end

      # A file that would fit under max_bytes on its own but would push this
      # community's total stored bytes over quota_bytes. A distinct class from
      # the bare {Invalid} it descends from, so the refusal names which limit
      # was hit rather than reading like an ordinary per-file rejection.
      class QuotaExceeded < Invalid; end

      # The store's free space would drop below {MIN_FREE_BYTES} if this write
      # went ahead. Distinct from {QuotaExceeded}: this is about the disk, not
      # about any one community's allowance.
      class InsufficientSpace < Invalid; end

      # The durable-scheduler job kind the daily expiry sweep runs under.
      EXPIRY_KIND = "rehosted_file_expiry"

      # Seconds between sweeps. Retention is measured in days, so daily is enough.
      EXPIRY_INTERVAL = 24 * 60 * 60

      # Retention in days when a community has not said otherwise. A rehosted
      # file stands in for a file somebody posted into a room, and a link that
      # dies while the conversation is still being read is the common complaint,
      # so the default sits at the ceiling.
      DEFAULT_TTL_DAYS = 365

      # A copied profile photo keeps the shorter default, since it is a face
      # rather than something the person chose to post, and a copy is remade
      # long before it lapses anyway.
      DEFAULT_AVATAR_TTL_DAYS = 30

      # The ceiling on a community's configured retention. Rehosted files are
      # member content on rubotty's disk, so no community may keep one forever.
      MAX_TTL_DAYS = 365

      # The largest file rehosted by default. /upload exists precisely for the
      # file no platform will carry at all, a whole video rather than something
      # a little over a Discord limit, so this is sized for that rather than for
      # "a little above the tightest platform ceiling". Safe to raise this far
      # only because {DEFAULT_QUOTA_BYTES} bounds what accumulates behind it.
      DEFAULT_MAX_BYTES = 4 * 1024 * 1024 * 1024

      # The most one community may hold in rehosted files at once, by default.
      # A year of retention (see {DEFAULT_TTL_DAYS}) times every community on a
      # deployment is how a shared disk fills quietly with no quota at all; this
      # is comfortable for occasional large files while still being a real
      # ceiling, and {InsufficientSpace} backstops it against a disk that turns
      # out smaller than this default assumed.
      DEFAULT_QUOTA_BYTES = 50 * 1024 * 1024 * 1024

      # The free space {Storage::ObjectStore#free_bytes} must clear, after
      # accounting for the file being accepted, before a write is allowed to
      # start. A quota tuned for one disk stops being the right number the
      # moment the disk changes size; this is the floor under every community's
      # quota rather than a replacement for one.
      MIN_FREE_BYTES = 5 * 1024 * 1024 * 1024

      # A link's serve ceiling with no live membership to size it by, and the
      # cap on a ceiling computed from one: the lesser of a community's
      # summed membership or this. Chosen as a bound generous enough for a
      # real conversation to keep sharing a link, small enough that a leak
      # cannot travel forever.
      SERVE_LIMIT_FLAT = 100

      # The least a computed ceiling may come out to. Without it a very small
      # community's own membership sum would undercut the flat ceiling and
      # mint a two or three serve link, which the platforms' own preview
      # fetches (see PREVIEW_GRACE_SECONDS) could exhaust before a member
      # ever saw the file. Twenty stays a real bound while leaving room for
      # a handful of members, a rotation, and ordinary re-reading.
      SERVE_LIMIT_FLOOR = 20

      # How long after a row is created a serve is free: this is the window
      # the platforms themselves use to fetch a freshly posted link and build
      # its inline preview, confirmed live (a link posted through /upload
      # rendered inline in Telegram, which only happens by fetching it). A
      # serve landing inside the window does not spend the link's budget; see
      # #preview_window?.
      PREVIEW_GRACE_SECONDS = 60

      # The most files one /upload batch carries by default: the largest group
      # Telegram, Discord and Fluxer will each still send as one native album
      # rather than splitting further, so a bigger batch buys nothing but more
      # groups.
      DEFAULT_MAX_BATCH_FILES = 10

      # A community that has not set its own batch ceiling gets this many times
      # its per file cap as the whole batch's ceiling. Less than
      # DEFAULT_MAX_BATCH_FILES, deliberately: a single file at the per file
      # cap must always fit, but a full batch of files all sitting at that cap
      # is a lot of disk for one ticket, and the point of a separate total is
      # to catch exactly that.
      DEFAULT_BATCH_BYTES_MULTIPLIER = 3

      # The object store namespace, so {GuestUploads} cannot collide on disk.
      NAMESPACE = "rehosted"

      # How old a blob has to be before the orphan sweep will consider it. Long
      # enough that a large upload still writing its row is never mistaken for
      # something nothing points at.
      ORPHAN_GRACE = 60 * 60

      # A stored file plus the one-time secret. The caller puts +secret+ in the
      # download URL and keeps nothing; the row holds only its digest.
      Stored = Struct.new(:file, :secret, keyword_init: true)

      # Turns the store's chunk-yielding read side into the +read(length)+ source
      # its write side wants, so {#rotate} can move an object's bytes between
      # sealed copies without either being whole in memory. The enumerator's fiber
      # only runs when +read+ asks for more, so back pressure comes for free.
      class ChunkReader
        # @yieldparam sink [#<<] hand each plaintext chunk to this
        def initialize(&block)
          @chunks = Enumerator.new { |sink| block.call(sink) }
          # Binary from the start: an empty UTF-8 buffer would take the encoding of
          # the first chunk and then refuse the next one that disagreed.
          @buffer = String.new(encoding: Encoding::BINARY)
        end

        # @return [String, nil] up to +length+ bytes, or nil at the end
        def read(length)
          while @buffer.bytesize < length
            begin
              @buffer << @chunks.next
            rescue StopIteration
              break
            end
          end
          return nil if @buffer.empty?

          @buffer.slice!(0, length)
        end
      end

      # @param store [Storage::ObjectStore] where the bytes go
      # @param clock [#call] injectable time source, for deterministic tests
      # @param adapters [Hash, nil] the runtime's live adapter map, so a new
      #   file's serve ceiling can be sized from real membership; nil in any
      #   process with no adapters (the API, the guest portal, standalone
      #   file storage), which always gets {SERVE_LIMIT_FLAT}
      def initialize(models:, store:, logger: nil, clock: -> { Time.now }, adapters: nil)
        @models = models
        @store = store
        @logger = logger
        @clock = clock
        @adapters = adapters
      end

      attr_reader :store

      # Seal +source+ into the object store and record it.
      # @param source [#read] anything answering read(length). Never held whole.
      # @param ttl_days [Integer] retention, clamped to {MAX_TTL_DAYS}
      # @param limit [Integer, nil] refuse a source larger than this
      # @param origin [String] "relay" or "upload"
      # @param created_by [String, nil] "<adapter>:<handle>", a label only
      # @param serve_limit [Integer, nil] override {#ceiling_for}'s own answer
      # @return [Stored]
      def store_file(community_id:, source:, room_key: nil, filename: nil, content_type: nil,
                     ttl_days: DEFAULT_TTL_DAYS, limit: nil, origin: "relay", created_by: nil,
                     serve_limit: nil)
        raise Invalid, "a rehosted file needs a community." if community_id.nil?

        check_capacity!(community_id: community_id, room_key: room_key, limit: limit)

        sealed = @store.put(namespace: NAMESPACE, scope: community_id, source: source, limit: limit)
        now = @clock.call
        row = @models.rehosted_file.create(
          community_id: community_id,
          room_key: room_key&.to_s,
          token_hash: Storage::ObjectStore.digest(sealed.secret),
          object_key: sealed.key,
          iv: Base64.strict_encode64(sealed.iv),
          auth_tag: Base64.strict_encode64(sealed.auth_tag),
          filename: clean_filename(filename),
          content_type: clean_type(content_type),
          byte_size: sealed.byte_size,
          sealed_bytes: sealed.sealed_bytes,
          source: origin.to_s == "upload" ? "upload" : "relay",
          created_by: created_by&.to_s&.slice(0, 200),
          created_at: now,
          expires_at: now + (clamp_ttl(ttl_days) * 86_400),
          served_count: 0,
          serve_limit: serve_limit || ceiling_for(community_id)
        )
        @logger&.info do
          "rehosted a #{sealed.byte_size} byte file as #{sealed.sealed_bytes} sealed bytes " \
            "(community=#{community_id} room=#{room_key} expires_at=#{row.expires_at})"
        end
        Stored.new(file: row, secret: sealed.secret)
      # TooLarge is an ObjectStore::Error but has to reach the caller as itself: a
      # file over the cap is an ordinary refusal, and the store is fine.
      rescue Storage::ObjectStore::TooLarge
        raise
      rescue Storage::ObjectStore::Error => e
        raise Invalid, "the file store is not usable: #{e.message}"
      end

      # The live file a raw secret names, or nil. An unknown secret and an expired
      # one are indistinguishable, so a dead link never reveals whether the file
      # ever existed.
      #
      # @param secret [String, nil] the UUID from the download URL
      # @param community_id [Integer, nil] baked into the query when the caller
      #   has one; the public download route has none
      def fetch(secret:, community_id: nil)
        digest = Storage::ObjectStore.digest(secret)
        return nil if digest.nil?

        now = @clock.call
        scope = @models.rehosted_file.where(token_hash: digest)
        scope = scope.where(community_id: community_id) if community_id
        scope.where { expires_at > now }.first
      end

      # Stream a row's plaintext back in chunks, decompressing as it goes. Raises
      # {Storage::ObjectStore::Unreadable} for a wrong secret, a missing blob or a
      # failed authentication tag.
      #
      # @yieldparam chunk [String]
      def stream(file, secret:, &block)
        @store.open(
          key: file.object_key, secret: secret,
          iv: Base64.strict_decode64(file.iv.to_s), auth_tag: Base64.strict_decode64(file.auth_tag.to_s),
          &block
        )
      end

      # Whether the row's bytes still authenticate, handing none of them out, so
      # a serve route can answer 200 only when it can keep that promise.
      def intact?(file, secret:)
        @store.intact?(
          key: file.object_key, secret: secret,
          iv: Base64.strict_decode64(file.iv.to_s), auth_tag: Base64.strict_decode64(file.auth_tag.to_s)
        )
      rescue ArgumentError
        false
      end

      # Whether this row has already spent every serve its ceiling allows.
      # {FileStorage::App} checks this before doing anything else, so an
      # exhausted link refuses exactly the way an unknown secret does.
      def exhausted?(file)
        file.served_count.to_i >= file.serve_limit.to_i
      end

      # Whether +file+ is still inside the window right after it was
      # created where a serve is treated as one of the platforms' own
      # link-preview fetches rather than a member's download, and so does
      # not spend the link's budget. See {PREVIEW_GRACE_SECONDS}.
      def preview_window?(file, now: @clock.call)
        (now.to_time - file.created_at.to_time) < PREVIEW_GRACE_SECONDS
      end

      # Atomically spend one serve: the increment and the ceiling check are a
      # single UPDATE, so two requests racing near the ceiling cannot both
      # read "one slot left" and both take it. Never call this for a request
      # that will not deliver the complete file (a HEAD, or one inside
      # {#preview_window?}); those do not spend a serve at all.
      #
      # @return [Boolean] false means the row was already at its ceiling and
      #   nothing was written
      def record_serve(file)
        @models.rehosted_file
               .where(id: file.id)
               .where { served_count < serve_limit }
               .update(served_count: Sequel[:served_count] + 1)
               .positive?
      end

      # How many serves +file+ has left, floored at zero, for an operator's
      # own read of the row (the dashboard and the admin API both show this).
      def serves_remaining(file)
        [file.serve_limit.to_i - file.served_count.to_i, 0].max
      end

      # This community's live membership summed across its platforms, or
      # {SERVE_LIMIT_FLAT} the moment any platform cannot answer, floored at
      # {SERVE_LIMIT_FLOOR} so a small community is never issued a two or
      # three serve link. See {ControlPlane::CommunityMembers}.
      def ceiling_for(community_id)
        return SERVE_LIMIT_FLAT if @adapters.nil?

        sum = CommunityMembers.aggregate(community_id: community_id, models: @models,
                                         adapters: @adapters, logger: @logger)
        return SERVE_LIMIT_FLAT if sum.nil?

        [[sum, SERVE_LIMIT_FLAT].min, SERVE_LIMIT_FLOOR].max
      rescue StandardError => e
        @logger&.warn { "could not compute a serve ceiling for community #{community_id}: #{e.class}: #{e.message}" }
        SERVE_LIMIT_FLAT
      end

      # Re-seals a file under a fresh secret the caller must already hold, since
      # the row stores only a digest. The old link dies the moment the row
      # repoints; expiry is left untouched so rotating a link never extends
      # retention.
      #
      # @param community_id [Integer, nil] baked into the lookup when the caller
      #   has one, so another tenant's file is not found rather than refused
      # @return [Stored, nil] nil when the secret names no live file
      def rotate(secret:, community_id: nil)
        row = fetch(secret: secret, community_id: community_id)
        return nil if row.nil?

        previous_key = row.object_key
        reader = ChunkReader.new { |sink| stream(row, secret: secret) { |chunk| sink << chunk } }
        sealed = @store.put(namespace: NAMESPACE, scope: row.community_id, source: reader)
        # The row is repointed BEFORE the old object goes. A failure between the
        # two leaves an unreferenced blob, which {#sweep_orphans} collects; the
        # other order leaves a row naming bytes that are already gone, which is
        # a broken download.
        row.update(
          token_hash: Storage::ObjectStore.digest(sealed.secret), object_key: sealed.key,
          iv: Base64.strict_encode64(sealed.iv), auth_tag: Base64.strict_encode64(sealed.auth_tag),
          sealed_bytes: sealed.sealed_bytes
        )
        @store.delete(previous_key)
        @logger&.info { "rotated the link for rehosted file #{row.id} (community=#{row.community_id})" }
        Stored.new(file: row.refresh, secret: sealed.secret)
      rescue Storage::ObjectStore::Error => e
        raise Invalid, "that file could not be sealed again: #{e.message}"
      end

      # Brings a file's expiry forward so the next sweep deletes it, leaving
      # the bytes for {#expire} so only one place has to get the
      # unlink-before-row order right. The link stops working at once, since
      # {#fetch} only returns rows whose expiry is still ahead.
      #
      # @return [Object, nil] the row, or nil when the secret names no live file
      def mark_expired(secret:, community_id: nil)
        row = fetch(secret: secret, community_id: community_id)
        return nil if row.nil?

        row.update(expires_at: @clock.call)
        row.refresh
      end

      # The same thing addressed by row id, which is safe because expiry writes a
      # column and never opens the object. An already-expired row is left alone, so
      # a second call cannot push a lapsed file's deletion further out.
      #
      # @return [Object, nil] the row, or nil when the id names nothing here
      def expire_by_id(community_id:, id:)
        row = find(community_id: community_id, id: id)
        return nil if row.nil?

        now = @clock.call
        row.update(expires_at: now) if row.expires_at.nil? || row.expires_at > now
        row.refresh
      end

      # One of a community's files by row id, for an administrative read.
      def find(community_id:, id:)
        @models.rehosted_file.where(community_id: community_id, id: id.to_i).first
      end

      # A community's or a room's file-rehosting policy, read straight from
      # feature_settings, because the web process serves an upload with no topology
      # loaded and still has to honour the same settings. Room row, then community
      # default, then code default.
      #
      # @return [Hash] { enabled:, retention_days:, max_bytes:, quota_bytes:, max_batch_files:,
      #   max_batch_bytes: }
      def policy_for(community_id:, room_key: nil)
        rows = @models.feature_setting
                      .where(community_id: community_id, feature: Features::FileRehosting.feature_name).all
        room_id = room_id_for(community_id, room_key)
        room_row = room_id && rows.find { |row| row.room_id == room_id }
        community_row = rows.find { |row| row.room_id.nil? }
        config = (community_row&.json_value(:config) || {}).merge(room_row&.json_value(:config) || {})
        {
          enabled: to_bool((room_row || community_row)&.enabled),
          retention_days: Features::FileRehosting.retention_days(config),
          max_bytes: Features::FileRehosting.max_bytes(config),
          quota_bytes: Features::FileRehosting.quota_bytes(config),
          max_batch_files: Features::FileRehosting.max_batch_files(config),
          max_batch_bytes: Features::FileRehosting.max_batch_bytes(config)
        }
      end

      def list(community_id:)
        @models.rehosted_file.where(community_id: community_id).reverse(:id).all
      end

      # What a community currently has on disk, in sealed bytes.
      def sealed_bytes_for(community_id:)
        @models.rehosted_file.where(community_id: community_id).sum(:sealed_bytes).to_i
      end

      # Deletes every file past its expiry, BYTES first then the row, since
      # dropping the row first and failing on the unlink would strand a blob
      # nothing points at. Never raises, so one unreadable path cannot stop
      # the sweep.
      #
      # @return [Integer] files removed
      def expire(now: @clock.call)
        removed = 0
        @models.rehosted_file.where { expires_at <= now }.each do |row|
          removed += 1 if forget(row)
        end
        @logger&.info { "rehosted files: removed #{removed} past their retention" } if removed.positive?
        removed
      rescue StandardError => e
        @logger&.warn { "rehosted file expiry failed: #{e.class}: #{e.message}" }
        removed.to_i
      end

      # Delete blobs no row points at: {#rotate} repoints a row before
      # unlinking the old object, so a process that dies between the two
      # leaves an orphan here for this to collect. Only blobs older than
      # {ORPHAN_GRACE} are considered, and this never raises.
      #
      # @return [Integer] blobs removed
      def sweep_orphans(now: @clock.call)
        candidates = @store.keys(namespace: NAMESPACE, before: now - ORPHAN_GRACE)
        return 0 if candidates.empty?

        referenced = @models.rehosted_file.select_map(:object_key)
                            .each_with_object({}) { |key, seen| seen[key.to_s] = true }
        removed = candidates.count { |key| !referenced.key?(key) && @store.delete(key) }
        @logger&.info { "rehosted files: removed #{removed} orphaned blob(s)" } if removed.positive?
        removed
      rescue StandardError => e
        @logger&.warn { "rehosted file orphan sweep failed: #{e.class}: #{e.message}" }
        0
      end

      def forget_community(community_id:)
        @models.rehosted_file.where(community_id: community_id).all.count { |row| forget(row) }
      end

      # Remove one row and the bytes behind it. Public because /upload discards a
      # file whose ticket turned out to be spent.
      def forget(row)
        return false if row.nil?

        @store.delete(row.object_key)
        row.delete
        true
      rescue StandardError => e
        @logger&.warn { "could not remove a rehosted file: #{e.class}: #{e.message}" }
        false
      end

      # Retention in days, clamped to {MAX_TTL_DAYS}. A nonsensical value falls
      # back to the default.
      def clamp_ttl(days)
        value = days.to_i
        return DEFAULT_TTL_DAYS unless value.positive?

        [value, MAX_TTL_DAYS].min
      end

      private

      # Refuses a write before a byte moves, named distinctly from a per-file
      # {Storage::ObjectStore::TooLarge}: a community already full, or a disk
      # too close to full, is a different fact than one file being too big.
      # +limit+ is the caller's own per-file cap, the worst case this write can
      # reach, since neither check can know the real size before it is read.
      def check_capacity!(community_id:, room_key:, limit:)
        incoming = limit.to_i
        quota = policy_for(community_id: community_id, room_key: room_key)[:quota_bytes]
        if quota&.positive? && sealed_bytes_for(community_id: community_id) + incoming > quota
          raise QuotaExceeded, "this community's rehosting quota is full: #{quota} bytes " \
                               "(quota_bytes); delete something on the Files page or raise the " \
                               "quota before storing more."
        end

        free = @store.respond_to?(:free_bytes) ? @store.free_bytes : nil
        return if free.nil? || free - incoming >= MIN_FREE_BYTES

        raise InsufficientSpace, "the object store is too close to full to accept this file " \
                                 "(#{free} bytes free, #{MIN_FREE_BYTES} bytes reserved)."
      end

      def room_id_for(community_id, room_key)
        return nil if room_key.to_s.empty?

        @models.room.where(community_id: community_id, room_key: room_key.to_s).first&.id
      end

      # SQLite returns booleans as 0/1 through some Sequel paths, and 0 is truthy
      # in Ruby, so normalise instead of trusting the raw value.
      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end

      # Keep only the basename and a bounded length, so a path or an oversized name
      # from a platform payload never reaches storage or a serve header.
      def clean_filename(name)
        base = File.basename(name.to_s.strip)
        base = "file" if base.empty? || base == "." || base == ".."
        base[0, 255]
      end

      def clean_type(type)
        text = type.to_s.strip
        return "application/octet-stream" if text.empty? || text.length > 128

        text
      end
    end
  end
end
