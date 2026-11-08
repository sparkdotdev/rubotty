# frozen_string_literal: true

require "securerandom"
require "json"

module Rubotty
  module Adapters
    # The guest-portal platform adapter, room scoped: an admitting room gets
    # one guest endpoint synthesised into it, served like any platform
    # adapter's own so fan-out, loop guard, message map, sender label and
    # moderation all apply. Inbound, the web process writes a guest's send
    # into guest_messages as an "out" row for the receive loop to emit; outbound,
    # {#deliver} writes an "in" row (nothing when no guest is live). The out row
    # is stamped relayed as it is read, and the send is authored by the guest
    # rather than this adapter's own id, so the pipeline does not drop it as self-authored.
    module Guest
      # The fixed adapter name and the single account every guest endpoint shares.
      NAME = :guest
      ACCOUNT = "guest"

      # The native id this adapter reports as "signed in as", for the loop guard.
      # A guest send is authored by the guest, so this only has to be stable and
      # distinct from any real user id.
      OWN_ID = "rubotty-guest"

      # Built from the room's database id, never its room_key string: room_key is
      # unique only within a community, while the global routing {Topology} spans
      # every community, so a room_key based key leaked sends across tenants.
      def self.endpoint_key_for(room_id)
        "guest:#{room_id}"
      end

      # Whether an endpoint key names a guest endpoint.
      def self.guest_key?(endpoint_key)
        endpoint_key.to_s.start_with?("guest:")
      end

      class Adapter < Adapters::Base
        # Seconds between receive-loop passes, so a guest send reaches the room
        # within about this long.
        POLL_INTERVAL = 1

        # How long #stop waits for the poll thread to notice @running went
        # false and exit on its own, before killing it. A kill can land
        # between relay_out's claim and its emit and drop a send for good, so
        # a graceful join is the only safe way to stop this thread.
        JOIN_TIMEOUT = 5

        # How long the per-room "is a guest live here" answer is cached, so a busy
        # room does not query per relayed message.
        LIVE_CACHE_SECONDS = 5

        class << self
          def adapter_name = NAME

          # A guest account carries no credentials; the schema only satisfies the
          # contract.
          def account_schema = Config::Schema.define {}

          def endpoint_schema
            Config::Schema.define do
              field :room_key, :string, desc: "the room this guest endpoint fronts"
              field :room_id, :integer, desc: "the control-plane room id"
              field :channel_endpoint_key, :string,
                    desc: "a real channel bridged into the room, used to resolve moderation scope"
              field :community_id, :integer, desc: "the owning community id"
            end
          end
        end

        CAPABILITIES = Capabilities.new(
          # A relayed edit, delete or reaction is surfaced so the guest view
          # reflects channel state. Reactions are display-only, so custom emoji
          # render as their shortcode.
          edits: true, deletes: true, reactions: true,
          # moderation is delete alone: the automatic filters clean the feed through
          # deletes?, while an operator's /delete gates on moderates?, so both need
          # to agree on the same removal. A guest holds a session, not an account,
          # so there is nobody to ban, kick or mute, and the feed has no pinning.
          moderation: %i[delete]
        ).freeze

        # Constructed directly by the bot, so it takes services instead of settings.
        #
        # @param feed [ControlPlane::GuestFeed] the shared guest_messages store
        # @param invites [ControlPlane::GuestInvites] liveness and nickname lookup
        # @param models [ControlPlane::Models] channel resolution
        # @param registry [ControlPlane::Registry] resolves a pending send's channel
        #   to its guest endpoint in the current topology
        # @param clock [#call] injectable time source
        def initialize(dispatcher:, feed:, invites:, models:, registry:, logger:,
                       clock: -> { Time.now })
          super(account: ACCOUNT, settings: {}, dispatcher: dispatcher, logger: logger)
          @feed = feed
          @invites = invites
          @models = models
          @registry = registry
          @clock = clock
          @running = false
          @thread = nil
          # room_id => [answer, asked_at], aged out on the same window it is
          # served from so a room nobody asks about keeps no entry.
          @live_cache = {}
          @cache_mutex = Mutex.new
        end

        def origin_label(_endpoint = nil) = Core::SenderLabel::GUEST_DOMAIN

        def own_account_id = OWN_ID

        def capabilities = CAPABILITIES

        # Drain any sends already queued once, then poll. Returns promptly.
        def start
          return self if @running

          @running = true
          receive_pending
          @thread = Thread.new do
            Thread.current.name = "guest-adapter"
            while @running
              sleep(POLL_INTERVAL)
              receive_pending
            end
          end
          self
        end

        # Emit every pending guest send once. Never raises: a bad row must not take
        # the receive loop down.
        def receive_pending
          @feed.pending_out.each { |row| relay_out(row) }
        rescue StandardError => e
          logger.warn { "guest adapter receive pass failed: #{e.class}: #{e.message}" }
        end

        def stop
          @running = false
          @thread&.join(JOIN_TIMEOUT)
          @thread&.kill
          @thread = nil
          self
        end

        def running? = @running

        # Write an "in" row for the room's live guests to read, or
        # NOT_APPLICABLE when no guest is live: routine, and not a loss, since
        # there was never a copy to be missing. The receipt's native id is the
        # feed row id, so a later relayed edit or delete can find and update it.
        def deliver(message, endpoint)
          room_id = endpoint.settings[:room_id]
          return Core::DeliveryReceipt::NOT_APPLICABLE if room_id.nil?
          return Core::DeliveryReceipt::NOT_APPLICABLE unless live_guest?(room_id)

          row = @feed.record_in(
            community_id: endpoint.settings[:community_id],
            room_id: room_id,
            channel_id: origin_channel_id(message, endpoint),
            author_label: label_of(message),
            body: message.body.text.to_s,
            kind: message.kind.to_s,
            attachments: attachment_descriptors(message)
          )
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: row.id.to_s)
        rescue StandardError => e
          raise AdapterError, "guest feed write failed: #{e.message}"
        end

        # Apply a relayed edit to the guest's copy. Two writes, because a guest
        # reads the feed forward only: the in row is rewritten, and an "edit" event
        # is appended for a guest who already rendered the old bubble.
        def edit(message, endpoint, native_id)
          return nil if native_id.nil?

          new_body = message.body.text.to_s
          @feed.message(native_id)&.update(body: new_body)
          append_event(endpoint, native_id, ControlPlane::GuestFeed::EDIT, body: new_body)
          Core::DeliveryReceipt.new(endpoint_id: endpoint.id, native_id: native_id)
        rescue StandardError => e
          raise AdapterError, "guest feed edit failed: #{e.message}"
        end

        # Remove a guest feed row by id, both when a relayed message is deleted and
        # when the word filter screens a guest's own send, appending a "delete" event
        # for a guest who already rendered the bubble. A removal that did not happen
        # has to say so: every caller reads anything that did not raise as a confirmed
        # delete, so swallowing the failure here reports a message as gone while a guest still sees it.
        def delete(endpoint, native_id)
          return if native_id.nil?

          @feed.message(native_id)&.delete
          append_event(endpoint, native_id, ControlPlane::GuestFeed::DELETE)
        rescue StandardError => e
          raise AdapterError, "guest feed delete failed: #{e.message}"
        end

        # An operator's moderation command, as far as a read-only feed can carry
        # one out. Only delete, which is the same write the filters already make.
        def moderate(command, endpoint, native_id)
          unless command.action == :delete
            return Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :unsupported)
          end

          delete(endpoint, native_id)
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :done)
        rescue AdapterError => e
          Core::Moderation::Result.new(endpoint_id: endpoint.id, status: :failed, detail: e.message)
        end

        # Reflect a relayed message's reaction state to the guest: the whole
        # desired set is appended as a "reaction" event carrying the rendered
        # summary. Display only, so +previous+ is unused.
        def sync_reactions(endpoint, native_id, desired:, previous: [])
          return if native_id.nil?

          append_event(endpoint, native_id, ControlPlane::GuestFeed::REACTION,
                       body: reaction_summary(desired))
        rescue StandardError => e
          raise AdapterError, "guest feed reaction write failed: #{e.message}"
        end

        private

        # Append a rich-inbound event for a live guest to apply, or nothing when
        # the endpoint carries no room or no guest is live.
        def append_event(endpoint, native_id, kind, body: "")
          room_id = endpoint.settings[:room_id]
          return if room_id.nil?
          return unless live_guest?(room_id)

          @feed.record_event(
            community_id: endpoint.settings[:community_id], room_id: room_id,
            ref_id: native_id, kind: kind, body: body
          )
        end

        # The real platform channel a relayed message arrived on, for the "in"
        # row's informational channel_id. nil when the origin is not a known
        # channel of this endpoint's community.
        def origin_channel_id(message, endpoint)
          community_id = endpoint.settings[:community_id]
          @models.channel.where(community_id: community_id, endpoint_key: message.origin.id).first&.id
        end

        # The reactions to show under a bubble, oldest first. An empty set renders
        # as "", which clears the bubble's footer.
        def reaction_summary(desired)
          Array(desired).map(&:to_s).join(" ")
        end

        # Emit one queued guest send, stamped relayed so it is never emitted twice.
        # The stamp goes on only once the send is deliverable: stamping on the way
        # in dropped rows for good when the room's endpoint was missing. Three
        # bounded things end a send's life unsent: it waited past
        # GuestFeed::MAX_WAIT_SECONDS, its session ended, or the pipeline screened it.
        def relay_out(row)
          if @feed.expired?(row)
            logger.warn { "guest send #{row.id} waited too long to be routed and was dropped unsent" }
            @feed.mark_relayed(row)
            return
          end

          invite = @models.guest_invite[row.invite_id]
          if invite.nil? || !@invites.live?(invite)
            # Nothing later can make a dead session's send relayable.
            @feed.mark_relayed(row)
            return
          end

          endpoint = guest_endpoint_for(invite.room_id)
          if endpoint.nil?
            logger.warn do
              "guest send #{row.id} is waiting: room #{invite.room_id} has no guest endpoint in the " \
                "current snapshot (guest access off, or the snapshot has not reloaded since it was turned on)"
            end
            return
          end

          @feed.mark_relayed(row)
          emit(guest_message(endpoint, invite, row))
        rescue StandardError => e
          logger.warn { "guest send #{row.id} could not be relayed: #{e.class}: #{e.message}" }
        end

        # The guest endpoint for a room from the current snapshot, or nil when
        # the room is not guest-enabled or the community is suspended.
        def guest_endpoint_for(room_id)
          return nil if @models.room[room_id].nil?

          @registry.current.topology.endpoint(Guest.endpoint_key_for(room_id))
        end

        # A guest's send as a canonical message, authored by the guest. Its ref
        # native id is the out row id, so a screening delete finds the row.
        def guest_message(endpoint, invite, row)
          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, row.id.to_s),
            origin: endpoint,
            author: Core::Author.new(
              native_id: "guest-#{invite.id}", display_name: invite.nickname, kind: :user
            ),
            body: Core::RichText.plain(row.body.to_s),
            attachments: attachments_of(row),
            sender_label: Core::SenderLabel.guest(nickname: invite.nickname)
          )
        end

        # Attachments rebuilt from the descriptors the web app stored on the out
        # row. Each names a public URL the guest portal serves the bytes at.
        def attachments_of(row)
          decode_attachments(row.attachments).filter_map do |descriptor|
            url = descriptor["url"].to_s
            next nil if url.empty?

            Core::Attachment.new(
              kind: attachment_kind(descriptor["kind"]), url: url,
              filename: descriptor["filename"], mime_type: descriptor["mime_type"],
              caption: descriptor["caption"]
            )
          end
        end

        # Defaults to :document so an unexpected stored kind still relays.
        def attachment_kind(raw)
          kind = raw.to_s.to_sym
          Core::Attachment::KINDS.include?(kind) ? kind : :document
        end

        def decode_attachments(raw)
          value = JSON.parse(raw.to_s)
          value.is_a?(Array) ? value : []
        rescue JSON::ParserError
          []
        end

        # The bridge has already set the sender label for this target, so reuse it.
        def label_of(message)
          label = message.sender_label
          return label.to_s if label

          message.author&.any_name.to_s
        end

        # The attachments a member sent, as plain hashes the guest UI can
        # render; a platform-only native ref means nothing to a browser, so
        # only fetchable URLs are carried. A URL carrying a credential is
        # named without being linked, since a guest is an outsider holding
        # one room of one community and a Telegram file URL embeds the bot
        # token, reaching every chat the bot serves anywhere.
        def attachment_descriptors(message)
          message.attachments.filter_map do |attachment|
            next nil unless attachment.resolvable?

            {
              "kind" => attachment.kind.to_s, "url" => Util::SafeUrl.public(attachment.url),
              "filename" => attachment.filename, "mime_type" => attachment.mime_type,
              "caption" => attachment.caption
            }.compact
          end
        end

        def live_guest?(room_id)
          now = @clock.call
          @cache_mutex.synchronize do
            answer, asked_at = @live_cache[room_id]
            return answer if asked_at && (now - asked_at) < LIVE_CACHE_SECONDS

            @live_cache.reject! { |_, (_, at)| (now - at) >= LIVE_CACHE_SECONDS }
            live = @invites.live_on_room?(room_id: room_id)
            @live_cache[room_id] = [live, now]
            live
          end
        end
      end
    end
  end
end
