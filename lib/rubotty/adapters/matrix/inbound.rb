# frozen_string_literal: true

require "set"

module Rubotty
  module Adapters
    module Matrix
      # Converts Matrix client-server events into canonical messages, working
      # on the plain event Hashes `/sync` returns plus three injected
      # callables (endpoint lookup, a display name resolver, an mxc to URL
      # resolver). Matrix message bodies carry a plain `body` and an optional
      # HTML `formatted_body`; RichTextParser reads the HTML back into spans
      # when it can, falling back to the plain body otherwise.
      class Inbound
        MEDIA_MSGTYPES = {
          "m.image" => :photo, "m.video" => :video, "m.audio" => :audio, "m.file" => :document
        }.freeze

        # How many m.reaction event ids #redaction can still recognise as a
        # reaction being taken back rather than a message delete. Bounded the
        # same way Adapter's own reaction cache is: oldest inserted goes first,
        # no full scan to pick a victim, and entries also leave on a hit, so
        # this only bounds the ones nobody ever takes back.
        MAX_TRACKED_ANNOTATIONS = 4096

        # @param own_account_id [#call, nil] no args -> this bot's own user id; a
        #   callable rather than a plain value because it is nil until Adapter#start
        #   populates it
        # @param on_encrypted [#call, nil] room id -> called once, the first time an
        #   m.room.encrypted event is seen in that room, so a caller outside this
        #   read-only class can learn a room is encrypted too
        def initialize(endpoint_for:, displayname: nil, media_url: nil, own_account_id: nil, on_encrypted: nil,
                       logger: nil)
          @endpoint_for = endpoint_for
          @displayname = displayname
          @media_url = media_url
          @own_account_id = own_account_id
          @on_encrypted = on_encrypted
          @logger = logger
          # event_id of the m.reaction -> {target:, key:}. Read and written
          # only from the inbound sync thread, so this needs no lock.
          @annotations = {}
          # Rooms already warned about being encrypted, so the log says it once.
          @encrypted_rooms_warned = Set.new
          # room_id => Set of user ids this bridge has already relayed a join
          # for. #membership's fallback for a homeserver that does not bother
          # sending unsigned.prev_content, so a routine displayname or avatar
          # change on an already-known member does not misread as a fresh join.
          @known_members = Hash.new { |hash, key| hash[key] = Set.new }
        end

        # Dispatch one timeline event. Returns a Core::Message or nil.
        def call(room_id, event)
          endpoint = @endpoint_for.call(room_id)
          return nil if endpoint.nil?

          case event["type"]
          when "m.room.message" then message(endpoint, event)
          when "m.reaction" then reaction(endpoint, event)
          when "m.room.redaction" then redaction(endpoint, event)
          when "m.room.member" then membership(endpoint, event)
          when "m.room.encrypted" then encrypted(endpoint, room_id)
          else
            @logger&.debug { "matrix: unhandled event type #{event["type"].inspect} in #{endpoint.label}" }
            nil
          end
        end

        # Same builder #message uses for a live m.room.message, run directly
        # over one history row a backfill sweep read from Client#messages.
        # Drops a copy this bridge posted itself, the same rule
        # {Core::LoopGuard} applies to live traffic: without it here, the
        # sweep's own relay count would be inflated by an echo it was always
        # going to drop downstream, and its reconcile pass would then log that
        # echo as abandoned rather than as the ordinary skip it is.
        def backfill_message(room_id, event)
          built, ownership = backfill_message_with_ownership(room_id, event)
          return nil if built.nil?

          ownership == :not_ours ? built : nil
        end

        # Same walk {#backfill_message} does, but nothing is dropped for being
        # our own copy: paired with the ownership answer instead, for
        # {Core::GapReport}. See Discord's Inbound#message_with_ownership for
        # the shape this mirrors; ownership here is simpler, a direct sender
        # comparison rather than a webhook lookup, because Matrix posts every
        # relayed copy under the bot's own account with no impersonation.
        def backfill_message_with_ownership(room_id, event)
          return nil unless chat_event?(event)

          endpoint = @endpoint_for.call(room_id)
          return nil if endpoint.nil?

          content = event["content"] || {}
          [build_chat_message(endpoint, event, content), ownership_of(event["sender"])]
        end

        # One reaction-relation event Client#relations returned, run through
        # the very builder #call uses for a live m.reaction, so a replayed
        # reaction dedups exactly like a live one through the same react claim.
        def backfill_reaction(room_id, event)
          endpoint = @endpoint_for.call(room_id)
          return nil if endpoint.nil?

          reaction(endpoint, event)
        end

        private

        def message(endpoint, event)
          content = event["content"] || {}
          relation = content["m.relates_to"]

          if replacement?(relation)
            return edit(endpoint, event, content, relation)
          end

          build_chat_message(endpoint, event, content)
        end

        # The {Core::Message} shape #message, #backfill_message and
        # #backfill_message_with_ownership all build for an ordinary
        # m.room.message, factored out so a backfilled row is built exactly
        # the way a live one is.
        def build_chat_message(endpoint, event, content)
          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, event["event_id"]),
            origin: endpoint,
            author: author_for(event["sender"]),
            body: body_text(content),
            attachments: attachments_for(content),
            reply_to: reply_ref(content, endpoint),
            thread: thread_ref(content),
            timestamp: timestamp(event),
            raw: event
          )
        end

        # A plain chat message worth building into a backfill candidate: an
        # m.room.message that is not itself an m.replace edit. Matrix's
        # /messages walk hands back an edited message's original and every
        # edit as separate rows, and the original's body already reads as
        # whatever the edit produced by the time it was sent, so there is
        # nothing for a replayed edit on its own to attach to; the same scope
        # Discord's history endpoint has, since it folds an edit into the
        # current message state rather than exposing it as its own row.
        def chat_event?(event)
          return false unless event["type"] == "m.room.message"

          !replacement?((event["content"] || {})["m.relates_to"])
        end

        # Whether +sender+ is this bot's own account. :unknown when the id is
        # not yet known (Adapter#start has not run), which #backfill_message
        # treats the same cautious way #own_webhook_message? does on Discord:
        # unable to tell means it counts as ours and is dropped, since
        # guessing wrong there is what put a week of our own copies back down
        # the bridge once already.
        def ownership_of(sender)
          own = @own_account_id&.call
          return :unknown if own.to_s.empty?

          sender.to_s == own.to_s ? :ours : :not_ours
        end

        def edit(endpoint, event, content, relation)
          replacement = content["m.new_content"] || content
          target = relation["event_id"]
          return nil if target.nil?

          Core::Message.new(
            kind: :edit,
            ref: Core::MessageRef.new(endpoint.id, target),
            origin: endpoint,
            author: author_for(event["sender"]),
            body: body_text(replacement),
            timestamp: timestamp(event),
            raw: event
          )
        end

        # An encrypted room is never decrypted here, so its whole timeline
        # arrives as m.room.encrypted. Logged once per room so the silence
        # reads as "this room is encrypted" rather than as a mystery, and
        # #on_encrypted is told every time regardless, so the send path can
        # remember it past this one instance too.
        def encrypted(endpoint, room_id)
          @on_encrypted&.call(room_id)
          return nil if @encrypted_rooms_warned.include?(endpoint.id)

          @encrypted_rooms_warned << endpoint.id
          @logger&.warn { "matrix: #{endpoint.label} is encrypted, this bridge cannot decrypt it" }
          nil
        end

        # A reaction is an annotation relation carrying the emoji as its key.
        # Matrix has no "unreact" event of its own: taking a reaction back
        # redacts this very event, so its id is remembered against the message
        # it landed on for #redaction to recognise later.
        def reaction(endpoint, event)
          relation = (event["content"] || {})["m.relates_to"] || {}
          return nil unless relation["rel_type"] == "m.annotation"

          target = relation["event_id"]
          key = relation["key"]
          return nil if target.nil? || key.nil? || key.to_s.empty?

          remember_annotation(event["event_id"], target: target, key: key, sender: event["sender"])

          Core::Message.new(
            kind: :reaction_add,
            ref: Core::MessageRef.new(endpoint.id, target),
            origin: endpoint,
            author: author_for(event["sender"]),
            reaction: Core::Reaction.new(emoji: key),
            timestamp: timestamp(event),
            raw: event
          )
        end

        # A redaction removes an event. Matrix uses it for both a message delete
        # and a reaction removal, and the two need different canonical kinds: a
        # redacted m.reaction has to come out as reaction_remove, since its own
        # event id lives in no message map and a plain :delete would find
        # nothing to remove on any mirror. #reaction remembers the annotation for
        # exactly this lookup; a miss (the redacted event was never one we saw,
        # or was an ordinary message) falls through to the delete the router
        # resolves through the message map instead.
        def redaction(endpoint, event)
          target = event["redacts"] || (event["content"] || {})["redacts"]
          return nil if target.nil?

          annotation = forget_annotation(target)
          return reaction_removal(endpoint, event, annotation) if annotation

          Core::Message.new(
            kind: :delete,
            ref: Core::MessageRef.new(endpoint.id, target),
            origin: endpoint,
            author: Core::Author.new(kind: :system),
            timestamp: timestamp(event),
            raw: event
          )
        end

        # event here is the redaction, and Matrix lets a moderator redact
        # another member's m.reaction, so its sender is the moderator. The
        # remembered annotation carries who actually added the reaction.
        def reaction_removal(endpoint, event, annotation)
          Core::Message.new(
            kind: :reaction_remove,
            ref: Core::MessageRef.new(endpoint.id, annotation[:target]),
            origin: endpoint,
            author: author_for(annotation[:sender]),
            reaction: Core::Reaction.new(emoji: annotation[:key]),
            timestamp: timestamp(event),
            raw: event
          )
        end

        def remember_annotation(event_id, target:, key:, sender:)
          return if event_id.nil?

          @annotations.shift while @annotations.size >= MAX_TRACKED_ANNOTATIONS
          @annotations[event_id] = { target: target, key: key, sender: sender }
        end

        def forget_annotation(event_id) = @annotations.delete(event_id)

        # Only relay a genuine join or leave, not a profile change (which Matrix
        # also delivers as an m.room.member event with unchanged membership).
        def membership(endpoint, event)
          content = event["content"] || {}
          membership = content["membership"]
          previous = event.dig("unsigned", "prev_content", "membership")
          who = event["state_key"] || event["sender"]
          return nil if same_membership?(membership, previous, endpoint.id, who)

          kind = case membership
                 when "join" then :join
                 when "leave", "ban" then :leave
                 end
          return nil if kind.nil?

          track_membership(endpoint.id, who, kind)
          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, "member-#{who}-#{event["event_id"]}"),
            origin: endpoint,
            author: author_for(who),
            timestamp: timestamp(event),
            raw: event
          )
        end

        # unsigned.prev_content is not guaranteed present on every homeserver
        # (it is genuinely optional per the spec); when it is missing, the
        # fallback is whether this bridge already relayed a join for +who+ in
        # this room, rather than assuming a "join" reading is always fresh,
        # which is what let a routine displayname or avatar change misread as
        # one.
        def same_membership?(membership, previous, room_id, who)
          return membership == previous unless previous.nil?
          return false if who.nil?

          membership == "join" && @known_members[room_id].include?(who)
        end

        def track_membership(room_id, who, kind)
          return if who.nil?

          kind == :join ? @known_members[room_id] << who : @known_members[room_id].delete(who)
        end

        def replacement?(relation)
          relation.is_a?(Hash) && relation["rel_type"] == "m.replace"
        end

        # The formatted_body read back into spans when there is one and
        # RichTextParser can make sense of it; otherwise the plain body, with a
        # rich reply's quoted fallback stripped. Matrix prepends the quoted
        # parent as "> ..." lines followed by a blank line, which would double
        # the quote the router already reconstructs.
        def body_text(content)
          parsed = formatted_body(content)
          return parsed unless parsed.nil?

          text = content["body"].to_s
          if content.dig("m.relates_to", "m.in_reply_to")
            text = strip_reply_fallback(text)
          end
          Core::RichText.plain(text)
        end

        def formatted_body(content)
          return nil unless content["format"] == "org.matrix.custom.html"

          html = content["formatted_body"]
          return nil if html.to_s.strip.empty?

          RichTextParser.parse(html)
        end

        def strip_reply_fallback(text)
          lines = text.split("\n", -1)
          return text unless lines.first.to_s.start_with?("> ")

          rest = lines.drop_while { |line| line.start_with?("> ") }
          rest = rest.drop(1) while rest.first == "" && rest.length.positive?
          rest.join("\n")
        end

        def author_for(user_id)
          return Core::Author.new(kind: :system) if user_id.nil?

          Core::Author.new(
            native_id: user_id,
            username: localpart(user_id),
            display_name: resolve_displayname(user_id),
            kind: :user
          )
        end

        # "@ada:example.org" -> "ada", without the homeserver, which the sender
        # label carries separately as the platform token. Under the matrix::
        # qualifier this composes into "matrix::ada@example.org".
        def localpart(user_id)
          match = user_id.to_s.match(/\A@([^:]+):/)
          match ? match[1] : user_id.to_s.delete_prefix("@")
        end

        def resolve_displayname(user_id)
          return nil if @displayname.nil?

          @displayname.call(user_id)
        rescue StandardError
          nil
        end

        def attachments_for(content)
          kind = MEDIA_MSGTYPES[content["msgtype"]]
          return [] if kind.nil?

          url = @media_url&.call(content["url"])
          info = content["info"] || {}
          [Core::Attachment.new(
            kind: kind,
            url: url,
            filename: content["body"],
            mime_type: info["mimetype"],
            size: info["size"],
            width: info["w"],
            height: info["h"]
          )]
        end

        def reply_ref(content, endpoint)
          parent = content.dig("m.relates_to", "m.in_reply_to", "event_id")
          return nil if parent.nil?

          Core::MessageRef.new(endpoint.id, parent)
        end

        # The thread this message belongs to, from an m.thread relation. A
        # threaded reply can carry m.in_reply_to alongside it (read separately,
        # above); the two are independent relations on the same event.
        def thread_ref(content)
          relation = content["m.relates_to"]
          return nil unless relation.is_a?(Hash) && relation["rel_type"] == "m.thread"

          root = relation["event_id"]
          return nil if root.nil?

          Core::ThreadRef.new(native_id: root)
        end

        def timestamp(event)
          ms = event["origin_server_ts"]
          ms ? Time.at(ms / 1000.0) : Time.now
        rescue StandardError
          Time.now
        end
      end
    end
  end
end
