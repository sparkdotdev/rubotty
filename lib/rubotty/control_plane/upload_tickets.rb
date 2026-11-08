# frozen_string_literal: true

require "securerandom"

module Rubotty
  module ControlPlane
    # One-time, short-lived permission to put a file into a room from a
    # browser: /upload DMs a link, and the file picked there lands in the
    # room the command was typed in. The link itself carries the authority,
    # the same shape as a guest invite: a high-entropy token, only its
    # SHA-256 digest stored, spent the moment a file is accepted and
    # expiring in {DEFAULT_TTL_SECONDS} either way. endpoint_key is captured
    # when the command is typed, so nothing the browser posts can redirect
    # the result to a different room.
    class UploadTickets
      # Bytes of entropy in a raw ticket token, the same as a guest invite's.
      TOKEN_BYTES = 32

      # How long a ticket stays usable. Long enough to switch to a browser and
      # find the file, short enough that a link left in a DM is not a way in.
      DEFAULT_TTL_SECONDS = 30 * 60

      # A newly issued ticket plus the ONE-TIME raw token, which is not
      # recoverable afterwards.
      Issued = Struct.new(:ticket, :token, keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, logger: nil, clock: -> { Time.now })
        @models = models
        @logger = logger
        @clock = clock
      end

      # Mint a ticket for one person, in one room.
      #
      # @param endpoint_key [String] where the command was typed, and where the
      #   finished file is posted back
      # @return [Issued]
      def issue(community_id:, endpoint_key:, adapter:, native_id:, room_key: nil, label: nil,
                ttl_seconds: DEFAULT_TTL_SECONDS)
        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        now = @clock.call
        ticket = @models.rehosted_upload_ticket.create(
          community_id: community_id,
          room_key: room_key&.to_s,
          token_hash: Storage::ObjectStore.digest(token),
          endpoint_key: endpoint_key.to_s,
          requested_by_adapter: adapter.to_s,
          requested_by_native_id: native_id.to_s,
          requested_by_label: label&.to_s&.slice(0, 200),
          created_at: now,
          expires_at: now + [ttl_seconds.to_i, 60].max
        )
        @logger&.info { "upload ticket issued: community=#{community_id} room=#{room_key}" }
        Issued.new(ticket: ticket, token: token)
      end

      # The live ticket a raw token names, or nil for one that is unknown,
      # expired or already spent. Read-only: use {#claim} to actually spend it.
      def authenticate(token:)
        digest = Storage::ObjectStore.digest(token)
        return nil if digest.nil?

        now = @clock.call
        @models.rehosted_upload_ticket
               .where(token_hash: digest, used_at: nil)
               .where { expires_at > now }
               .first
      end

      # Spends a ticket, returning it, or nil when it was not live: the
      # used_at stamp is written by an UPDATE whose WHERE still carries the
      # liveness conditions, so exactly one of two concurrent posts can win
      # it. Reading the row and then writing it would let both see it unused.
      def claim(token:)
        digest = Storage::ObjectStore.digest(token)
        return nil if digest.nil?

        now = @clock.call
        claimed = @models.rehosted_upload_ticket
                         .where(token_hash: digest, used_at: nil)
                         .where { expires_at > now }
                         .update(used_at: now)
        return nil unless claimed.to_i.positive?

        @models.rehosted_upload_ticket.where(token_hash: digest).first
      end

      # Drop tickets that are past their expiry, spent or not. Rides the same
      # daily sweep the files do.
      #
      # @return [Integer] rows removed
      def expire(now: @clock.call)
        @models.rehosted_upload_ticket.where { expires_at <= now }.delete.to_i
      rescue StandardError => e
        @logger&.warn { "upload ticket expiry failed: #{e.class}: #{e.message}" }
        0
      end
    end
  end
end
