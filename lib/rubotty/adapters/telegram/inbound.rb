# frozen_string_literal: true

module Rubotty
  module Adapters
    module Telegram
      # Converts a raw Bot API update into a {Core::Message}. Kept separate from
      # the adapter so it can be unit tested on fixtures without a client, a
      # transport or a network.
      class Inbound
        # Bot API keys that carry a file, mapped to the canonical attachment
        # kind. Order matters: a `document` can accompany other keys, and the
        # first match wins.
        MEDIA_KEYS = {
          "photo" => :photo,
          "animation" => :animation,
          "video" => :video,
          "video_note" => :video_note,
          "audio" => :audio,
          "voice" => :voice,
          "sticker" => :sticker,
          "document" => :document
        }.freeze

        # @param endpoint_for_reaction [#call, nil] (chat_id, message_id) -> endpoint,
        #   falling back to the bare chat id when nil since reactions carry no thread id
        # @param file_resolver [#call, nil] file_id -> URL; nil lets an operator turn
        #   off file resolution entirely, since a Telegram file URL embeds the bot token
        # @param avatar_resolver [#call, nil] (user_id, chat_id, thread_id) -> URL or
        #   nil, answered from a cache so parsing never waits on a Bot API call
        # @param custom_emoji_resolver [#call, nil] custom emoji ids -> ordinary emoji;
        #   a reaction names a custom emoji by id alone, so without this it stays a number
        def initialize(endpoint_for:, endpoint_for_reaction: nil, file_resolver: nil,
                       avatar_resolver: nil, custom_emoji_resolver: nil, logger: nil,
                       unsend_on_dot: false)
          @endpoint_for = endpoint_for
          @endpoint_for_reaction = endpoint_for_reaction
          @file_resolver = file_resolver
          @avatar_resolver = avatar_resolver
          @custom_emoji = custom_emoji_resolver
          @logger = logger
          @unsend_on_dot = unsend_on_dot
        end

        # The text that means "unsend this". See Adapter#handle_update.
        UNSEND_TEXT = "."

        # Is this edit the unsend gesture? Telegram never tells a bot that a
        # message was deleted, but a message edited to a single full stop DOES
        # arrive as an edited_message, so that stands in for "remove everywhere",
        # and the text must be exactly "." with no entities, so an edit that
        # merely ends in a full stop is untouched.
        def unsend?(payload)
          return false unless @unsend_on_dot

          text = payload["text"] || payload["caption"]
          return false unless text.to_s.strip == UNSEND_TEXT

          entities = payload["entities"] || payload["caption_entities"]
          entities.nil? || entities.empty?
        end

        # @param update [Hash] raw Bot API update
        # @return [Core::Message, nil] nil when the update is not something we
        #   relay, which is the common case for most update types
        def call(update)
          if (message = update["message"])
            from_message(message, kind: :chat)
          elsif (edited = update["edited_message"])
            from_message(edited, kind: unsend?(edited) ? :delete : :edit)
          elsif (channel_post = update["channel_post"])
            from_message(channel_post, kind: :chat)
          elsif (edited_post = update["edited_channel_post"])
            from_message(edited_post, kind: unsend?(edited_post) ? :delete : :edit)
          elsif (reaction = update["message_reaction"])
            from_reaction(reaction)
          elsif (counts = update["message_reaction_count"])
            from_reaction_count(counts)
          elsif (press = update["callback_query"])
            from_button_press(press)
          end
        end

        # A CallbackQuery is a tap on an inline keyboard button we placed. It
        # names the presser, the message the keyboard is on and the token the
        # button carries, which the feature that offered it reads back.
        def from_button_press(payload)
          carrier = payload["message"]
          token = payload["data"].to_s
          user = payload["from"]
          return nil unless carrier.is_a?(Hash) && !token.empty? && user.is_a?(Hash)

          endpoint = press_endpoint(carrier)
          if endpoint.nil?
            @logger&.debug { unresolved_press((carrier["chat"] || {})["id"], carrier["message_id"]) }
            return nil
          end

          Core::Message.new(
            kind: :button_press,
            ref: Core::MessageRef.new(endpoint.id, carrier["message_id"]),
            origin: endpoint,
            author: author_from_user(user),
            button: token,
            timestamp: Time.now,
            raw: payload
          )
        end

        # A MessageReactionUpdated carries the reacting user's OLD and NEW
        # reaction lists, so the difference between them is what changed. One
        # update can produce both a removal and an addition, hence the array.
        def from_reaction(payload)
          chat = payload["chat"] || {}
          endpoint = reaction_endpoint(chat["id"], payload["message_id"])
          if endpoint.nil?
            @logger&.debug { unresolved_reaction(:reaction, chat["id"], payload["message_id"]) }
            return nil
          end

          user = payload["user"]
          if user.nil?
            # One chat id can stand for several anonymous admins, so there is no
            # holder here to add to or take away from.
            @logger&.warn do
              "dropped an anonymous Telegram reaction on #{endpoint.id}:#{payload["message_id"]}, " \
                "it names no holder to count"
            end
            return nil
          end

          # Both lists in one lookup: an update that swaps one custom emoji for
          # another names two, and neither is worth its own Bot API call.
          bases = custom_bases(
            custom_ids(payload["old_reaction"]) + custom_ids(payload["new_reaction"])
          )
          old_set = reaction_list(payload["old_reaction"], bases)
          new_set = reaction_list(payload["new_reaction"], bases)
          author = author_from_user(user)
          ref = Core::MessageRef.new(endpoint.id, payload["message_id"])
          at = payload["date"] ? Time.at(payload["date"]) : Time.now

          added = (new_set - old_set).map { |r| reaction_event(:reaction_add, r, ref, endpoint, author, at, payload) }
          removed = (old_set - new_set).map do |r|
            reaction_event(:reaction_remove, r, ref, endpoint, author, at, payload)
          end
          added + removed
        end

        # A MessageReactionCountUpdated states every reaction currently on the
        # message and names nobody holding any of them. Telegram sends it in
        # place of message_reaction wherever a chat's reactions are anonymous,
        # which covers channels and groups past a size threshold, so without it
        # such a chat produces no reaction event at all.
        def from_reaction_count(payload)
          chat = payload["chat"] || {}
          endpoint = reaction_endpoint(chat["id"], payload["message_id"])
          if endpoint.nil?
            @logger&.debug { unresolved_reaction(:reaction_count, chat["id"], payload["message_id"]) }
            return nil
          end

          Core::Message.new(
            kind: :reaction_sync,
            ref: Core::MessageRef.new(endpoint.id, payload["message_id"]),
            origin: endpoint,
            reaction_set: reaction_counts(payload["reactions"]),
            timestamp: payload["date"] ? Time.at(payload["date"]) : Time.now,
            raw: payload
          )
        end

        # Telegram has no delete update: a bot is never told that a user deleted
        # a message. Deletes propagate FROM platforms that report them (Discord
        # does) TO Telegram, but not the other way.
        def supports_delete_events? = false

        private

        # The endpoint a reaction is on. A reaction update names its chat and
        # its message but never its topic, so the adapter's resolver recovers
        # the topic; without one wired, the chat id alone is all there is.
        def reaction_endpoint(chat_id, message_id)
          return @endpoint_for.call(chat_id, nil) if @endpoint_for_reaction.nil?

          @endpoint_for_reaction.call(chat_id, message_id)
        end

        # The endpoint a press is on. Unlike a reaction update, a callback query
        # carries the whole message the keyboard sits on, topic included, and
        # the reaction resolver covers the General topic and a chat bridged whole.
        def press_endpoint(carrier)
          chat = carrier["chat"] || {}
          thread_id = chat["is_forum"] ? carrier["message_thread_id"] : nil
          found = thread_id.nil? ? nil : @endpoint_for.call(chat["id"], thread_id)
          found || reaction_endpoint(chat["id"], carrier["message_id"])
        end

        def unresolved_press(chat_id, message_id)
          "dropped a Telegram button press on #{chat_id}:#{message_id}, no endpoint answered"
        end

        # Says what the lookup actually tried, since a topic endpoint is bridged
        # under "<chat_id>/<topic>" and no reaction update names a topic.
        def unresolved_reaction(kind, chat_id, message_id)
          "dropped a Telegram #{kind} on #{chat_id}:#{message_id}, no endpoint answered: the update names " \
            "no topic, so the lookup had only the message map and the bare chat id #{chat_id} to go on, " \
            "and an endpoint bridged as #{chat_id}/<topic> answers to neither"
        end

        # Keyed by chat id and thread id, so a forum topic that resolved to
        # nothing reads differently from a whole chat nobody has mapped.
        def unresolved_message(chat_id, thread_id)
          return "dropped a Telegram message in chat #{chat_id}, no endpoint is bridged to it" if thread_id.nil?

          "dropped a Telegram message in chat #{chat_id}/#{thread_id}, no endpoint is bridged to it"
        end

        def reaction_list(raw, bases = {})
          Array(raw).filter_map { |entry| reaction_from(entry, bases) }
        end

        # The emoji named by a ReactionCount list, dropping any that nobody holds.
        def reaction_counts(raw)
          held = Array(raw).filter_map { |entry| entry["type"] || {} if entry["total_count"].to_i.positive? }
          bases = custom_bases(custom_ids(held))
          held.filter_map { |entry| reaction_from(entry, bases) }
        end

        def reaction_from(entry, bases = {})
          case entry["type"]
          when "emoji" then Core::Reaction.new(emoji: entry["emoji"])
          when "custom_emoji"
            id = entry["custom_emoji_id"]
            Core::Reaction.new(custom_id: id, emoji: bases[id.to_s])
          end
        end

        # The custom emoji ids named by a list of ReactionType entries.
        def custom_ids(entries)
          Array(entries).filter_map { |entry| entry["custom_emoji_id"] if entry["type"] == "custom_emoji" }
        end

        # The ordinary emoji each of +ids+ is drawn from. Empty without a
        # resolver wired, which leaves a custom reaction exactly as it arrived.
        def custom_bases(ids)
          return {} if @custom_emoji.nil? || ids.empty?

          @custom_emoji.call(ids) || {}
        rescue StandardError => e
          @logger&.warn { "could not resolve a Telegram custom emoji: #{e.class}: #{e.message}" }
          {}
        end

        def reaction_event(kind, reaction, ref, endpoint, author, at, payload)
          Core::Message.new(
            kind: kind, ref: ref, origin: endpoint, author: author,
            reaction: reaction, timestamp: at, raw: payload
          )
        end

        def from_message(payload, kind:)
          chat = payload["chat"] || {}
          thread_id = chat["is_forum"] ? payload["message_thread_id"] : nil
          endpoint = @endpoint_for.call(chat["id"], thread_id)
          if endpoint.nil?
            @logger&.debug { unresolved_message(chat["id"], thread_id) }
            return nil
          end

          return membership(payload, endpoint, chat) if membership?(payload)

          body, attachments = content(payload)
          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, payload["message_id"]),
            origin: endpoint,
            author: author_for(payload, chat, avatar: true),
            body: body,
            attachments: attachments,
            reply_to: reply_ref(payload, endpoint),
            reply_preview: reply_preview(payload),
            forwarded_from: forwarded_author(payload),
            forwarded_target: forwarded_target(payload),
            thread: thread_for(payload),
            timestamp: payload["date"] ? Time.at(payload["date"]) : Time.now,
            raw: payload
          )
        end

        # The forum topic a message lives in, or nil. Telegram does not repeat the
        # topic's NAME on each message, so the name is left unknown here and
        # Adapter#name_thread fills it in from the service messages that carry it.
        # Only a forum carries real topics. Telegram overloads the same field for
        # reply chain grouping in an ordinary group, which every other reader of
        # it here already guards against, so reading it bare made an ordinary
        # reply look like a message in a thread.
        def thread_for(payload)
          chat = payload["chat"] || {}
          thread_id = chat["is_forum"] ? payload["message_thread_id"] : nil
          return nil if thread_id.nil?

          Core::ThreadRef.new(native_id: thread_id)
        end

        def content(payload)
          text = payload["text"]
          if text
            return [Entities.to_rich_text(text, payload["entities"]), []]
          end

          place = place_text(payload)
          return [Core::RichText.plain(place), []] if place

          caption = payload["caption"]
          body = Entities.to_rich_text(caption, payload["caption_entities"])
          [body, attachments(payload)]
        end

        # A location or a venue as a maps link. Without this the message has no
        # text and no attachment, so the router discards it as empty and the
        # location never arrives.
        def place_text(payload)
          venue = payload["venue"]
          location = venue ? venue["location"] : payload["location"]
          return nil unless location.is_a?(Hash)

          latitude = location["latitude"]
          longitude = location["longitude"]
          return nil if latitude.nil? || longitude.nil?

          link = "https://www.google.com/maps/search/?api=1&query=#{latitude},#{longitude}"
          return "#{venue["title"]}\n#{venue["address"]}\n#{link}".strip if venue

          link
        end

        def attachments(payload)
          MEDIA_KEYS.each do |key, kind|
            raw = payload[key]
            next if raw.nil?

            return [build_attachment(kind, raw, payload)]
          end
          []
        end

        def build_attachment(kind, raw, payload)
          # `photo` is an array of sizes, smallest first. The last entry is the
          # largest Telegram will serve.
          raw = raw.last if raw.is_a?(Array)
          file_id = relayable_file_id(kind, raw)

          Core::Attachment.new(
            kind: kind,
            native_ref: file_id,
            url: resolve_file(file_id),
            filename: sticker_filename(kind, raw) || raw["file_name"],
            mime_type: raw["mime_type"],
            size: raw["file_size"],
            width: raw["width"],
            height: raw["height"],
            duration: raw["duration"],
            emoji: raw["emoji"],
            animated: !!raw["is_animated"],
            caption: payload["caption"]
          )
        end

        # Which file to actually relay: an ANIMATED sticker is a .tgs
        # (gzipped Lottie JSON) that nothing outside a Telegram client
        # renders, so its static thumbnail crosses instead, while a VIDEO
        # sticker is a .webm, which Discord renders inline, so the real
        # sticker file crosses. is_video takes precedence, since Telegram
        # sometimes sets both flags and the one that renders wins.
        def relayable_file_id(kind, raw)
          if kind == :sticker && raw["is_animated"] && !raw["is_video"]
            thumbnail = raw["thumbnail"] || raw["thumb"]
            return thumbnail["file_id"] if thumbnail.is_a?(Hash) && thumbnail["file_id"]
          end

          raw["file_id"]
        end

        # Telegram never names a sticker file, but Discord decides whether it can
        # play one from the extension, so a video sticker is given a .webm name.
        def sticker_filename(kind, raw)
          return nil unless kind == :sticker && raw["is_video"]

          "sticker.webm"
        end

        def resolve_file(file_id)
          return nil if @file_resolver.nil? || file_id.nil?

          @file_resolver.call(file_id)
        rescue StandardError => e
          @logger&.warn { "could not resolve Telegram file #{file_id}: #{e.message}" }
          nil
        end

        # +avatar+ is set only for the author of the message itself, the one a
        # target platform puppets. A reply preview's author is rendered as text,
        # so looking a picture up for it would be Bot API traffic nobody sees.
        def author_for(payload, chat, avatar: false)
          from = payload["from"]
          # A channel post has no `from`: the channel itself is the author, so it
          # becomes a :channel author with only a display name and the template
          # system picks a sensible fallback.
          return channel_author(chat) if from.nil?

          Core::Author.new(
            native_id: from["id"],
            username: from["username"],
            first_name: from["first_name"],
            last_name: from["last_name"],
            bot: from["is_bot"],
            kind: :user,
            avatar_url: avatar ? avatar_for(from, payload, chat) : nil
          )
        end

        # The sender's rehosted profile photo, or nil. Never a raw Telegram file
        # URL: those carry the bot token, which is why the picture is copied
        # somewhere public first.
        def avatar_for(from, payload, chat)
          return nil if @avatar_resolver.nil?

          @avatar_resolver.call(from["id"], chat["id"], payload["message_thread_id"])
        rescue StandardError => e
          @logger&.warn { "could not resolve a Telegram avatar: #{e.class}: #{e.message}" }
          nil
        end

        def channel_author(chat)
          Core::Author.new(
            native_id: chat["id"],
            username: chat["username"],
            display_name: chat["title"],
            kind: :channel
          )
        end

        # The two forward readers are public: the DM report route reads a
        # forwarded message outside the endpoint-bound parse below, since a
        # private chat has no endpoint for that parse to resolve against.
        public

        # Which message a forward came from, where Telegram says. Only a channel
        # forward carries one: MessageOriginChannel names the chat and the
        # message id, while a forward from a user or a private group names
        # neither, so those arrive as the words alone with nothing to point at.
        # Answered as a {Core::Permalink::Target}, matched against endpoints by
        # their settings, since a chat id is not an endpoint id.
        def forwarded_target(payload)
          origin = payload["forward_origin"]
          return nil unless origin.is_a?(Hash) && origin["type"] == "channel"

          chat_id = origin.dig("chat", "id")
          message_id = origin["message_id"]
          return nil if chat_id.nil? || message_id.nil?

          Core::Permalink::Target.new(adapter: :telegram, settings: { chat_id: chat_id.to_s },
                                      native_id: message_id.to_s)
        end

        def forwarded_author(payload)
          # Bot API 7.0 replaced the flat forward_* fields with forward_origin.
          # Both are handled because a self hosted Bot API server may lag.
          origin = payload["forward_origin"]
          if origin
            case origin["type"]
            when "user" then return author_from_user(origin["sender_user"])
            when "hidden_user" then return Core::Author.new(display_name: origin["sender_user_name"])
            when "chat" then return channel_author(origin["sender_chat"] || {})
            when "channel" then return channel_author(origin["chat"] || {})
            end
          end

          return author_from_user(payload["forward_from"]) if payload["forward_from"]
          return channel_author(payload["forward_from_chat"]) if payload["forward_from_chat"]
          return Core::Author.new(display_name: payload["forward_sender_name"]) if payload["forward_sender_name"]

          nil
        end

        private

        def author_from_user(user)
          return nil if user.nil?

          Core::Author.new(
            native_id: user["id"],
            username: user["username"],
            first_name: user["first_name"],
            last_name: user["last_name"],
            bot: user["is_bot"]
          )
        end

        def reply_ref(payload, endpoint)
          replied = payload["reply_to_message"]
          return nil if replied.nil?

          # In a forum, Telegram reports the topic's opening message as the reply
          # target of every message in that topic. Relaying it would make every
          # message look like a reply to the topic name.
          return nil if payload["message_thread_id"] &&
                        replied["message_id"] == payload["message_thread_id"]

          Core::MessageRef.new(endpoint.id, replied["message_id"])
        end

        # Telegram includes the ENTIRE parent message inline as
        # `reply_to_message`, so the excerpt needed for quoting elsewhere is
        # already in hand and costs nothing to capture at parse time.
        def reply_preview(payload)
          parent = payload["reply_to_message"]
          return nil if parent.nil?
          return nil if payload["message_thread_id"] &&
                        parent["message_id"] == payload["message_thread_id"]

          text = parent["text"] || parent["caption"]
          entities = parent["text"] ? parent["entities"] : parent["caption_entities"]
          body = Entities.to_rich_text(text, entities)
          # A parent with no text at all (a bare photo) still identifies who is
          # being replied to.
          author = author_for(parent, parent["chat"] || {})
          return nil if body.blank? && author.nil?

          Core::ReplyPreview.new(
            author: author,
            body: body,
            ref: Core::MessageRef.new("", parent["message_id"])
          )
        end

        def membership?(payload)
          payload.key?("new_chat_members") || payload.key?("left_chat_member")
        end

        def membership(payload, endpoint, chat)
          joined = payload["new_chat_members"]
          kind = joined ? :join : :leave
          subject = joined ? joined.first : payload["left_chat_member"]

          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, payload["message_id"]),
            origin: endpoint,
            author: author_from_user(subject) || author_for(payload, chat),
            body: Core::RichText.new,
            timestamp: payload["date"] ? Time.at(payload["date"]) : Time.now,
            raw: payload
          )
        end
      end
    end
  end
end
