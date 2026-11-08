# frozen_string_literal: true

require "base64"

module Rubotty
  module ControlPlane
    # Stores and serves a guest-uploaded file: the web app writes bytes and a feed
    # row pointing at {#fetch}; the bot's guest adapter drains it into an
    # attachment; bytes never ride the feed. The serve URL carries the UUID the
    # store minted (the AES key derives from it too), so the row keeps only a
    # SHA-256 digest: storing both the blob's location and its key would defeat the
    # sealing. The URL carries no invite token and is unguessable, so the link alone
    # is the whole gate, like a CDN link. {GuestRetention} unlinks the object via
    # {#forget_bytes} before deleting the row, which is why that method is public.
    class GuestUploads
      # The object store namespace these live under, so a guest upload and a
      # rehosted file cannot collide on disk.
      NAMESPACE = "guest-upload"
      ORPHAN_GRACE = 3600

      # A stored upload projected for a reader: the ONE-TIME secret the caller puts
      # in the serve URL, plus the metadata for the feed descriptor. The secret is
      # not recoverable afterwards; the row holds only its digest.
      Stored = Struct.new(:secret, :filename, :content_type, :byte_size, keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param store [Storage::ObjectStore] where the bytes go
      # @param logger [#info, #warn, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, store:, logger: nil, clock: -> { Time.now })
        @models = models
        @store = store
        @logger = logger
        @clock = clock
      end

      attr_reader :store

      # Seal a guest-uploaded file into the object store and record it.
      #
      # @param source [#read] anything answering read(length): Rack's multipart
      #   tempfile, a File, a StringIO. Never held whole.
      # @param limit [Integer, nil] refuse a source larger than this many bytes,
      #   raising {Storage::ObjectStore::TooLarge} mid-stream
      # @return [Stored] the serve secret and the metadata
      def store_file(invite:, source:, filename: nil, content_type: nil, limit: nil)
        sealed = @store.put(namespace: NAMESPACE, scope: invite.community_id, source: source, limit: limit)
        row = @models.guest_upload.create(
          community_id: invite.community_id,
          room_id: invite.room_id,
          token_hash: Storage::ObjectStore.digest(sealed.secret),
          object_key: sealed.key,
          iv: Base64.strict_encode64(sealed.iv),
          auth_tag: Base64.strict_encode64(sealed.auth_tag),
          filename: clean_filename(filename),
          content_type: clean_type(content_type),
          byte_size: sealed.byte_size,
          sealed_bytes: sealed.sealed_bytes,
          created_at: @clock.call
        )
        Stored.new(secret: sealed.secret, filename: row.filename, content_type: row.content_type,
                   byte_size: row.byte_size)
      end

      # The upload row a raw serve secret names, or nil when there is none.
      #
      # @param secret [String, nil] the value out of the serve URL
      # @return [Models::GuestUpload, nil]
      def fetch(secret:)
        digest = Storage::ObjectStore.digest(secret)
        return nil if digest.nil?

        @models.guest_upload.where(token_hash: digest).first
      end

      # Stream a row's plaintext back, in chunks, decompressing as it goes.
      # Raises {Storage::ObjectStore::Unreadable} for a wrong secret, a missing
      # blob or one whose authentication tag does not verify.
      #
      # @yieldparam chunk [String]
      def stream(row, secret:, &block)
        @store.open(
          key: row.object_key, secret: secret,
          iv: Base64.strict_decode64(row.iv.to_s), auth_tag: Base64.strict_decode64(row.auth_tag.to_s),
          &block
        )
      end

      # Whether the row's bytes still authenticate, handing none of them out, so
      # a serve route can answer 200 only when it can keep that promise.
      def intact?(row, secret:)
        @store.intact?(
          key: row.object_key, secret: secret,
          iv: Base64.strict_decode64(row.iv.to_s), auth_tag: Base64.strict_decode64(row.auth_tag.to_s)
        )
      rescue ArgumentError
        false
      end

      # Removes an upload's BYTES, leaving its row to the caller: bytes first and
      # the row second, since a row dropped ahead of its object leaves a blob
      # nothing points at. Never raises, because one unreadable key must not stop
      # the rest of a reclamation.
      #
      # @param missing_ok [Boolean] count confirmed absence as successful cleanup
      # @return [Boolean] whether cleanup succeeded (or removed bytes by default)
      def forget_bytes(row, missing_ok: false)
        return false if row.nil? || row.object_key.to_s.empty?

        @store.delete(row.object_key, missing_ok: missing_ok)
      rescue StandardError => e
        @logger&.warn { "could not remove a guest upload's bytes: #{e.class}: #{e.message}" }
        false
      end

      # Failed metadata writes and older failed cleanup runs can leave blobs
      # with no row. Skip recent writes while their metadata is still landing.
      def sweep_orphans(now: @clock.call)
        referenced = @models.guest_upload.select_map(:object_key).to_h { |key| [key.to_s, true] }
        @store.keys(namespace: NAMESPACE, before: now - ORPHAN_GRACE)
              .count { |key| !referenced.key?(key) && @store.delete(key) }
      rescue StandardError => e
        @logger&.warn { "could not remove orphaned guest uploads: #{e.class}: #{e.message}" }
        0
      end

      private

      # Keep only the basename and a bounded length: a guest supplies the filename,
      # so a path or an oversized name never reaches storage or a serve header.
      def clean_filename(name)
        base = File.basename(name.to_s.strip)
        base = "upload" if base.empty? || base == "." || base == ".."
        base[0, 255]
      end

      # A guest names the type, and the serve route hands it to the browser and the
      # adapters, so anything malformed becomes bytes.
      def clean_type(type) = Security::ServedTypes.allowed(type)
    end
  end
end
