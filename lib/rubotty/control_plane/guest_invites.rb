# frozen_string_literal: true

require "securerandom"
require "digest"

module Rubotty
  module ControlPlane
    # Issue, authenticate and revoke guest-portal invites. Room-scoped: a
    # session grants access to the whole bridged room, so {#issue} takes
    # +room:+ and every downstream read scopes by room_id. A token is a
    # bearer capability stored hashed: {#issue} returns the raw token once
    # and the database keeps only its SHA-256 digest, so a dump cannot
    # reconstruct a working link. An invite authenticates only while live
    # (issued, short of expires_at, never revoked); either bound makes
    # {#authenticate} return nil, which ends a session.
    class GuestInvites
      # Raised for a request that cannot be carried out. Carries a human message.
      class Invalid < Rubotty::Error; end

      # Bytes of entropy in a raw token. 32 bytes is 256 bits.
      TOKEN_BYTES = 32

      # A newly issued invite plus the one-time raw token, which is never
      # recoverable afterwards.
      Issued = Struct.new(:invite, :token, keyword_init: true)

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param logger [#info, nil]
      # @param clock [#call] injectable time source, for deterministic tests
      # @param retention [GuestRetention, nil] schedules reclamation at expiry and
      #   reclaims on revoke. Nil on a read-only surface.
      # @param announcer [GuestAnnouncer, nil] posts the arrival notice when
      #   {#record_join} first pins the feed cursor.
      def initialize(models:, logger: nil, clock: -> { Time.now }, retention: nil, announcer: nil)
        @models = models
        @logger = logger
        @clock = clock
        @retention = retention
        @announcer = announcer
      end

      # Mint a room-scoped, expiring invite for a guest. Two gates: the room must
      # have its "guest_portal" feature enabled, and the issuer must satisfy
      # `who_can_invite` ("operators" by default, or "everyone").
      #
      # @param room [Models::Room] the room the guest joins, meaning every platform
      #   endpoint bridged into it
      # @return [Issued] the row and the one-time raw token
      def issue(community:, room:, nickname:, ttl_seconds:, created_by: nil, as: :operator)
        name = nickname.to_s.strip
        raise Invalid, "a guest invite needs a nickname." if name.empty?

        ttl = ttl_seconds.to_i
        raise Invalid, "a guest invite needs a positive lifetime." unless ttl.positive?

        unless room && room.community_id == community.id
          raise Invalid, "that room does not belong to this community."
        end

        policy = room_policy(community: community, room: room)
        raise Invalid, "guests are not allowed in that room." unless policy[:allowed]
        unless permitted?(policy[:who_can_invite], as)
          raise Invalid, "only operators may invite guests to that room."
        end

        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)
        now = @clock.call
        # Reclaim whatever a previous session left in this room, so a fresh guest
        # never inherits it. Must run BEFORE the create: a moment later the room
        # has a live invite and this would decline.
        @retention&.reclaim_room(room.id, now: now)
        invite = @models.guest_invite.create(
          community_id: community.id,
          room_id: room.id,
          nickname: name[0, 80],
          token_hash: self.class.hash_token(token),
          created_by: created_by&.to_s,
          expires_at: now + ttl,
          created_at: now,
          updated_at: now
        )
        # Durable, so it survives this process: the dashboard runs no scheduler
        # worker, so a bot process claims the job.
        @retention&.schedule_for(invite)
        @logger&.info do
          "guest invite issued: community=#{community.slug} room=#{room.room_key} " \
            "nickname=#{name.inspect} expires_at=#{invite.expires_at}"
        end
        Issued.new(invite: invite, token: token)
      end

      # Move an invite's hard time bound to +ttl_seconds+ from now, and move its
      # retention job with it: leaving the original job in place would reclaim the
      # feed out from under a guest still reading it. Refuses a revoked invite.
      #
      # @param invite [Models::GuestInvite]
      # @param ttl_seconds [Integer] the new lifetime from now; must be positive
      # @return [Models::GuestInvite]
      def extend_lifetime(invite:, ttl_seconds:)
        ttl = ttl_seconds.to_i
        raise Invalid, "a guest invite needs a positive lifetime." unless ttl.positive?
        raise Invalid, "that guest invite has been revoked." unless invite.revoked_at.nil?

        now = @clock.call
        invite.update(expires_at: now + ttl, updated_at: now)
        @retention&.schedule_for(invite)
        @logger&.info { "guest invite extended: invite=#{invite.id} expires_at=#{invite.expires_at}" }
        invite
      end

      # The live invite a raw token names, or nil. Unknown, expired and revoked are
      # indistinguishable, so a dead link never reveals whether it was ever valid.
      #
      # @param token [String, nil]
      # @return [Models::GuestInvite, nil]
      def authenticate(token:)
        digest = self.class.hash_token(token)
        return nil if digest.nil?

        # The liveness bound is applied in SQL: a naive timestamp read back in a
        # different zone would compare wrong, and this is the security gate.
        now = @clock.call
        @models.guest_invite
               .where(token_hash: digest, revoked_at: nil)
               .where { expires_at > now }
               .first
      end

      # The invite a raw token names regardless of liveness, so the web surface can
      # render an ended page for a once-valid link rather than a bare 404.
      def find_by_token(token:)
        digest = self.class.hash_token(token)
        return nil if digest.nil?

        @models.guest_invite.where(token_hash: digest).first
      end

      # Record a guest's first open, pinning the feed cursor so no history before
      # join is ever shown. Idempotent: a re-load never moves the cursor and so
      # never re-reveals the backlog. The write is conditional at the DB layer
      # (WHERE joined_at IS NULL), not just guarded in Ruby, so two requests
      # racing on the same unjoined invite cannot both win and both announce.
      #
      # @return [Models::GuestInvite] the (possibly updated) invite
      def record_join(invite:, cursor:)
        return invite unless invite.joined_at.nil?

        now = @clock.call
        updated = @models.guest_invite
                          .where(id: invite.id, joined_at: nil)
                          .update(joined_at: now, join_cursor: cursor.to_i, updated_at: now)
        invite = invite.refresh
        return invite if updated.zero?

        @logger&.info { "guest joined: invite=#{invite.id} cursor=#{cursor}" }
        # The arrival notice, so members know an outsider is now reading. The
        # conditional update above keeps it to once per invite even under a race.
        @announcer&.announce_join(invite)
        invite
      end

      # Revoke an invite early. Idempotent: revoking an already-revoked or expired
      # invite is a harmless no-op that leaves the original revoked_at in place.
      #
      # @param invite [Models::GuestInvite]
      # @return [Models::GuestInvite]
      def revoke(invite:)
        return invite unless invite.revoked_at.nil?

        invite.update(revoked_at: @clock.call, updated_at: @clock.call)
        # Revoking ends the session now, so the content goes now. Also cancels the
        # expiry job, which would otherwise sit pending forever.
        @retention&.reclaim_for(invite, reason: "invite revoked")
        @logger&.info { "guest invite revoked: invite=#{invite.id}" }
        invite
      end

      # Revoke by id within a community, or nil when there is no such invite. The
      # community scoping stops a caller revoking another community's invite by id.
      def revoke_by_id(community:, id:)
        invite = @models.guest_invite.where(community_id: community.id, id: id).first
        invite && revoke(invite: invite)
      end

      # Every invite for a community, newest first, for the operator list view.
      def list(community:)
        @models.guest_invite.where(community_id: community.id).reverse(:id).all
      end

      # The community row for an id, so the /guest chat command needs no Models
      # handle of its own.
      def community_by_id(id)
        @models.community[id]
      end

      # The room a channel named by endpoint_key is bridged into, or nil. Public
      # because the /guest command has only a Snapshot::Channel, which carries an
      # endpoint_key.
      def room_for_endpoint_key(community:, endpoint_key:)
        channel = @models.channel.where(community_id: community.id, endpoint_key: endpoint_key.to_s).first
        return nil if channel.nil?

        room_for_channel(channel)
      end

      # Whether a room has any live guest: the guest adapter asks before writing a
      # relayed message, so a guest-enabled room with no visitor writes nothing.
      # Gated in SQL, the same as {#authenticate}.
      def live_on_room?(room_id:)
        now = @clock.call
        @models.guest_invite
               .where(room_id: room_id, revoked_at: nil)
               .where { expires_at > now }
               .count
               .positive?
      end

      # A channel's guest-access policy, from the "guest_portal" feature: whether
      # guests are allowed (room row over community default) and who may invite.
      #
      # @return [Hash] { allowed: Boolean, who_can_invite: String }
      def guest_policy(community:, channel:)
        room_policy(community: community, room: room_for_channel(channel))
      end

      # The same policy resolved directly for a room, which is what the dashboard's
      # room-scoped access table reads and writes.
      #
      # @param room [Models::Room, nil] nil resolves the community default alone
      # @return [Hash] { allowed: Boolean, who_can_invite: String }
      def room_policy(community:, room:)
        rows = @models.feature_setting
                      .where(community_id: community.id, feature: Features::GuestPortal.feature_name).all
        room_row = room && rows.find { |row| row.room_id == room.id }
        community_row = rows.find { |row| row.room_id.nil? }
        enabled = if room_row then to_bool(room_row.enabled)
                  elsif community_row then to_bool(community_row.enabled)
                  else false
                  end
        config = (community_row&.json_value(:config) || {}).merge(room_row&.json_value(:config) || {})
        who = config["who_can_invite"].to_s
        who = Features::GuestPortal::WHO_OPERATORS unless Features::GuestPortal::WHO_CAN_INVITE.include?(who)
        { allowed: enabled, who_can_invite: who }
      end

      # Whether an invite is currently live: not revoked and not past expiry.
      def live?(invite)
        return false unless invite.revoked_at.nil?

        !expired?(invite)
      end

      # Whether an invite is past its hard time bound.
      def expired?(invite)
        @clock.call >= to_time(invite.expires_at)
      end

      # The state word the UI shows for an invite: revoked, expired, or live.
      def state_of(invite)
        return "revoked" unless invite.revoked_at.nil?
        return "expired" if expired?(invite)

        "live"
      end

      # SHA-256 hex digest of a raw token, or nil for a blank one. What the row
      # stores and what authentication matches.
      def self.hash_token(token)
        string = token.to_s
        return nil if string.empty?

        Digest::SHA256.hexdigest(string)
      end

      private

      # The room a channel is bridged into, or nil, in which case {#guest_policy}
      # degrades to the community default rather than raising.
      def room_for_channel(channel)
        return nil if channel.nil?

        join = @models.room_channel.where(channel_id: channel.id).first
        join && @models.room[join.room_id]
      end

      # An operator always may; a member only where the channel is "everyone".
      def permitted?(who_can_invite, as)
        return true if as.to_sym == :operator

        who_can_invite.to_s == Features::GuestPortal::WHO_EVERYONE
      end

      # SQLite returns booleans as 0/1 through some Sequel paths, so normalise
      # rather than trusting the raw value (0 is truthy in Ruby).
      def to_bool(value)
        return value if value == true || value == false

        [1, "1", "t", "true"].include?(value)
      end

      # Sequel returns DateTime or Time depending on the backend; normalise so the
      # comparison is backend-independent.
      def to_time(value)
        return value if value.is_a?(Time)

        value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
      end
    end
  end
end
