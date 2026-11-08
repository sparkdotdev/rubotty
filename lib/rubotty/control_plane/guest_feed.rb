# frozen_string_literal: true

require "json"

module Rubotty
  module ControlPlane
    # The guest-portal message feed: one table the guest web app and the
    # running bot share, each direction written by one side, read by the
    # other. OUT rows are guest sends the web app appends with relayed_at
    # NULL; the bot's relay drains, fans out, and stamps relayed_at. IN
    # rows are messages the bot saw while a guest was live; only rows
    # above the guest's join cursor are ever returned, holding "no
    # history before join." Append-only and keyed by id, so the guest UI
    # polls "everything after id N"; channel_id is informational only.
    class GuestFeed
      OUT = "out"
      IN = "in"

      # Feed row kinds beyond the platform-neutral Core::Message kinds. These three
      # are the rich-inbound events the guest view applies to a bubble it already
      # rendered, each carrying a ref_id to that earlier row.
      EDIT = "edit"
      DELETE = "delete"
      REACTION = "reaction"

      # How long a guest send may sit unrelayed before it is given up on, matching
      # {ApiMessages::MAX_WAIT_SECONDS}. A send waits while its room has no guest
      # endpoint in the bot's snapshot, which is permanent once an operator turns
      # guest access back off, so without a bound the relay retries it forever.
      MAX_WAIT_SECONDS = 3600

      # A feed row projected for a reader, decoupled from the Sequel model. ref_id
      # is set only on a rich-inbound event and names the row it acts on.
      Entry = Struct.new(:id, :invite_id, :direction, :author_label, :body, :attachments, :kind,
                         :ref_id, :created_at, keyword_init: true) do
        def out? = direction == OUT

        def incoming? = direction == IN
      end

      # @param models [ControlPlane::Models] bound to the control-plane database
      # @param clock [#call] injectable time source, for deterministic tests
      def initialize(models:, clock: -> { Time.now })
        @models = models
        @clock = clock
      end

      # Append a guest send (OUT), awaiting relay: written by the web app
      # when a guest hits send, and drained by the relay. Scoped to the
      # invite's room, so channel_id is left unset.
      #
      # @param body [String] plain text; a guest can only send plain text
      # @param attachments [Array<Hash>] descriptors for a guest-uploaded file,
      #   each a plain hash the adapter turns back into a Core::Attachment
      # @return [Models::GuestMessage]
      def record_out(invite:, body:, attachments: [])
        @models.guest_message.create(
          community_id: invite.community_id,
          room_id: invite.room_id,
          invite_id: invite.id,
          direction: OUT,
          author_label: "#{invite.nickname}@#{Core::SenderLabel::GUEST_DOMAIN}",
          body: body.to_s,
          attachments: Models.dump_json(Array(attachments)),
          kind: "chat",
          relayed_at: nil,
          created_at: @clock.call
        )
      end

      # Append an incoming message (IN) for the guests of a room to read,
      # written by the bot's feed recorder for a message seen on any
      # endpoint of the room while a guest is live. channel_id is an
      # informational marker only.
      #
      # @return [Models::GuestMessage]
      def record_in(community_id:, room_id:, author_label:, body:, kind: "chat", attachments: [], channel_id: nil)
        @models.guest_message.create(
          community_id: community_id,
          room_id: room_id,
          channel_id: channel_id,
          invite_id: nil,
          direction: IN,
          author_label: author_label.to_s[0, 200],
          body: body.to_s,
          attachments: Models.dump_json(Array(attachments)),
          kind: kind.to_s[0, 16],
          created_at: @clock.call
        )
      end

      # Append a rich-inbound event: an edit, delete or reaction on an earlier
      # feed row, ref_id naming the row acted on and body carrying the new text
      # (edit), the reaction summary (reaction), or nothing (delete). Appended
      # rather than updated in place, since a mutated row below the guest's
      # poll cursor is never re-served.
      #
      # @param kind [String] one of EDIT, DELETE, REACTION
      # @return [Models::GuestMessage]
      def record_event(community_id:, room_id:, ref_id:, kind:, body: "")
        @models.guest_message.create(
          community_id: community_id,
          room_id: room_id,
          invite_id: nil,
          direction: IN,
          author_label: nil,
          body: body.to_s,
          attachments: "[]",
          kind: kind.to_s[0, 16],
          ref_id: ref_id.to_i,
          created_at: @clock.call
        )
      end

      # The highest feed id currently in a room, or 0 when the room has no rows
      # yet. This is the join cursor pinned at first access, so the guest sees
      # only what lands afterwards.
      def latest_id(room_id:)
        @models.guest_message.where(room_id: room_id).max(:id).to_i
      end

      # The feed a guest may read: every row in THEIR room with id strictly above
      # both the polling cursor and their pinned join cursor, oldest first. A
      # guest who has not joined yet (join_cursor still nil) has pinned nothing,
      # so nothing is visible, rather than a nil floor collapsing to 0 and
      # handing back the room's whole history.
      #
      # @return [Array<Entry>]
      def for_guest(invite:, since: 0, limit: 200)
        return [] if invite.join_cursor.nil?

        floor = [since.to_i, invite.join_cursor.to_i].max
        rows = @models.guest_message
                      .where(room_id: invite.room_id)
                      .where { id > floor }
                      .order(:id)
                      .limit(limit)
                      .all
        rows.map { |row| entry_for(row) }
      end

      # The pending guest sends across the whole instance (OUT, relayed_at NULL),
      # oldest first, capped. The relay drains these.
      def pending_out(limit: 200)
        @models.guest_message
               .where(direction: OUT, relayed_at: nil)
               .order(:id)
               .limit(limit)
               .all
      end

      # Stamp an out row relayed, so the relay never sends it twice. Also how an
      # undeliverable send is retired, since a guest reads their own rows back.
      def mark_relayed(message)
        message.update(relayed_at: @clock.call)
      end

      # Whether a queued out row has waited past {MAX_WAIT_SECONDS}. Read off the
      # row the relay already loaded, so bounding the wait costs no extra query.
      def expired?(row, now: @clock.call)
        now - to_time(row.created_at) > MAX_WAIT_SECONDS
      end

      # One feed row by id, or nil. The guest adapter uses this to apply a relayed
      # edit or delete to the guest's copy, and to remove a screened guest send.
      def message(id)
        @models.guest_message[id.to_i]
      end

      # How many guest sends this invite has made since +since+. The rate limiter
      # uses this to bound a session's send rate, durably and per invite.
      def out_count_since(invite:, since:)
        @models.guest_message
               .where(invite_id: invite.id, direction: OUT)
               .where { created_at >= since }
               .count
      end

      private

      # Sequel returns DateTime or Time for a timestamp column depending on the
      # backend; normalise so the arithmetic is backend-independent.
      def to_time(value)
        return value if value.is_a?(Time)

        value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
      end

      def entry_for(row)
        Entry.new(
          id: row.id, invite_id: row.invite_id, direction: row.direction,
          author_label: row.author_label, body: row.body.to_s,
          attachments: sanitize_attachments(decode(row.attachments)), kind: row.kind, ref_id: row.ref_id,
          created_at: row.created_at
        )
      end

      def decode(raw)
        value = JSON.parse(raw.to_s)
        value.is_a?(Array) ? value : []
      rescue JSON::ParserError
        []
      end

      # A row written before the adapter filtered on write (0.5.78) may still
      # carry a credentialed source URL verbatim, so every read is filtered too.
      # Dropping the key rather than nulling it matches how a fresh write shapes
      # the hash, and lets the guest UI's existing no-url-key rendering apply.
      def sanitize_attachments(attachments)
        attachments.map do |attachment|
          next attachment unless attachment.is_a?(Hash) && attachment.key?("url")

          attachment.merge("url" => Util::SafeUrl.public(attachment["url"])).compact
        end
      end
    end
  end
end
