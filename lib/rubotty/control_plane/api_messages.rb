# frozen_string_literal: true

module Rubotty
  module ControlPlane
    # The queue behind `POST /communities/:slug/rooms/:room_key/messages`: the
    # API process appends a row here, and {Adapters::Api::Adapter}'s receive loop
    # in the bot drains and DELETES it, which is also the drain's at-most-once
    # claim. An API post carries no connected adapter of its own, so it is
    # emitted as an ordinary inbound {Core::Message} and every guard in
    # {Features::Pipeline} still applies to it.
    class ApiMessages
      # The longest body accepted, matching {GuestPortal::App::MAX_BODY}: it bounds
      # one post and sits under every bridged platform's own message ceiling.
      MAX_BODY = 4_000

      # The author class stamped on every row this writes, stored rather than
      # inferred so a queued API row can never be read as a queued guest row.
      AUTHOR_KIND = "api"

      # How long a post may sit unrouted before it is dropped unsent: a post waits
      # when the room has no endpoint in the bot's current snapshot, which is
      # permanent once a room has lost its last channel. Without a bound the row
      # would hold somebody's words in the database forever.
      MAX_WAIT_SECONDS = 3600

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, clock: -> { Time.now })
        @models = models
        @clock = clock
      end

      # Append a post, awaiting relay; the bot's relay drains it. The row is
      # the last place +room+ can still be compared against the community
      # beside it, so the pair is asserted here rather than trusted upstream.
      #
      # @param key [Models::ApiKey, nil] the credential that posted
      # @raise [ArgumentError] when +room+ belongs to another community
      # @return [Models::ApiPendingMessage]
      def enqueue(community:, room:, body:, key: nil)
        ApiRoomScope.assert_pair!(community, room)
        @models.api_pending_message.create(
          community_id: community.id,
          room_id: room.id,
          api_key_id: key&.id,
          author_label: author_label(key),
          author_kind: AUTHOR_KIND,
          body: body.to_s,
          created_at: @clock.call
        )
      end

      # The queue across the whole instance, oldest first, capped. Every row
      # present is still waiting: the relay deletes what it emits.
      def pending(limit: 200)
        @models.api_pending_message.order(:id).limit(limit).all
      end

      # Drop a row: both how a post is claimed on its way out and how an
      # undeliverable one is given up on. Taking the row makes the drain
      # at-most-once, and it takes the body with it.
      def retire(row)
        row.delete
      end

      # Whether a queued post has waited past {MAX_WAIT_SECONDS}. Read off the row
      # the drain has already loaded, so bounding the wait costs no extra query.
      def expired?(row, now: @clock.call)
        now - row.created_at > MAX_WAIT_SECONDS
      end

      # The rendered sender label a room will see: the key's operator-set label,
      # falling back to its public id. {Core::SenderLabel.api} pins the fixed
      # @api-client domain, so a key labelled "ada@discord" cannot pass as a member.
      def author_label(key)
        name = key&.label.to_s.strip
        name = key&.public_id.to_s if name.empty?
        name = "api" if name.empty?
        Core::SenderLabel.api(label: name).to_s[0, 200]
      end
    end
  end
end
