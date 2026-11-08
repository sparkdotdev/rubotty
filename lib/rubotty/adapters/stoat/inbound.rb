# frozen_string_literal: true

module Rubotty
  module Adapters
    module Stoat
      # Converts Stoat gateway events into canonical messages, working on
      # the plain JSON Hashes the gateway parses plus injected callables,
      # with no network dependency. Stoat markup is Markdown, so the Discord
      # Markdown parser is reused, mention resolution included: see
      # #parse_markdown.
      class Inbound
        # Stoat/Revolt ids are ULIDs: 26 characters in Crockford base32. A reaction
        # emoji matching this is a custom server emoji; anything else is unicode.
        ULID = /\A[0-9A-HJKMNP-TV-Z]{26}\z/

        # @param endpoint_for [#call] channel id -> Core::Endpoint or nil
        # @param user_resolver [#call, nil] user id -> user Hash or nil
        # @param member_resolver [#call, nil] (channel id, user id) -> member Hash or nil
        # @param mention_resolver [#call, nil] (type, id, channel_id:) -> display
        #   string or nil, the same shape Discord::Inbound's own resolver takes
        # @param logger [#warn, nil]
        def initialize(endpoint_for:, user_resolver: nil, member_resolver: nil, mention_resolver: nil,
                       file_url: nil, logger: nil)
          @endpoint_for = endpoint_for
          @user_resolver = user_resolver
          @member_resolver = member_resolver
          @mention_resolver = mention_resolver
          @file_url = file_url
          @logger = logger
        end

        # A "Message" event. The event IS the message object with a type tag.
        def message(event)
          endpoint = endpoint_for(event["channel"])
          return nil if endpoint.nil?

          native_id = event["_id"]
          return nil if native_id.nil?

          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, native_id),
            origin: endpoint,
            author: author_for(event["author"], event["masquerade"], member_for(event, event["author"])),
            body: parse_markdown(event["content"], channel_id: event["channel"]),
            attachments: attachments_for(event["attachments"]),
            reply_to: reply_ref(event["replies"], endpoint),
            timestamp: Time.now,
            raw: event
          )
        end

        # A "MessageUpdate" event carries only the changed fields under `data`.
        # Stoat does not resend the author on an edit, so the author is left as a
        # system author; the router resolves the copies through the message map.
        def edit(event)
          endpoint = endpoint_for(event["channel"])
          return nil if endpoint.nil?

          native_id = event["id"]
          data = event["data"] || {}
          return nil if native_id.nil?
          # An update that changes no content is not an edit worth relaying.
          return nil unless data.key?("content")

          Core::Message.new(
            kind: :edit,
            ref: Core::MessageRef.new(endpoint.id, native_id),
            origin: endpoint,
            author: Core::Author.new(kind: :system),
            body: parse_markdown(data["content"], channel_id: event["channel"]),
            timestamp: Time.now,
            raw: event
          )
        end

        # A "MessageDelete" event: id and channel, all the router needs to fan the
        # removal out through the message map.
        def delete(event)
          endpoint = endpoint_for(event["channel"])
          return nil if endpoint.nil?

          native_id = event["id"]
          return nil if native_id.nil?

          Core::Message.new(
            kind: :delete,
            ref: Core::MessageRef.new(endpoint.id, native_id),
            origin: endpoint,
            author: Core::Author.new(kind: :system),
            timestamp: Time.now,
            raw: event
          )
        end

        # "MessageReact" and "MessageUnreact". The message reacted TO is the
        # subject, who reacted is the author, and the emoji is the payload, so loop
        # prevention and the message map apply with no second code path.
        def reaction(event, kind)
          channel_id = event["channel_id"] || event["channel"]
          endpoint = endpoint_for(channel_id)
          if endpoint.nil?
            @logger&.debug { "dropped a Stoat reaction in channel #{channel_id}, no endpoint is bridged to it" }
            return nil
          end

          message_id = event["id"]
          if message_id.nil?
            @logger&.debug { "dropped a Stoat reaction on #{endpoint.id}, no message id" }
            return nil
          end

          parsed = reaction_value(event["emoji_id"])
          if parsed.nil?
            @logger&.debug { "dropped a Stoat reaction on #{endpoint.id}:#{message_id}, no emoji named" }
            return nil
          end

          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, message_id),
            origin: endpoint,
            author: author_for(event["user_id"], nil, member_for(event, event["user_id"])),
            reaction: parsed,
            timestamp: Time.now,
            raw: event
          )
        end

        # "MessageRemoveReaction". Bonfire fires this when an author or
        # moderator clears every instance of one emoji, and it carries no
        # user_id, so nobody in particular can be blamed for it.
        def reaction_clear(event)
          channel_id = event["channel_id"] || event["channel"]
          endpoint = endpoint_for(channel_id)
          if endpoint.nil?
            @logger&.debug do
              "dropped a Stoat reaction clear in channel #{channel_id}, no endpoint is bridged to it"
            end
            return nil
          end

          message_id = event["id"]
          if message_id.nil?
            @logger&.debug { "dropped a Stoat reaction clear on #{endpoint.id}, no message id" }
            return nil
          end

          parsed = reaction_value(event["emoji_id"])
          if parsed.nil?
            @logger&.debug { "dropped a Stoat reaction clear on #{endpoint.id}:#{message_id}, no emoji named" }
            return nil
          end

          Core::Message.new(
            kind: :reaction_clear,
            ref: Core::MessageRef.new(endpoint.id, message_id),
            origin: endpoint,
            reaction: parsed,
            timestamp: Time.now,
            raw: event
          )
        end

        private

        def endpoint_for(channel_id)
          return nil if channel_id.nil?

          @endpoint_for.call(channel_id)
        end

        # +channel_id+ is what lets #mention_resolver bind a mention lookup to
        # the server this channel belongs to, the same per channel scoping
        # Discord::Inbound#mention_resolver applies.
        def parse_markdown(content, channel_id: nil)
          return Core::RichText.new if content.nil? || content.to_s.empty?

          Discord::Markdown.parse(content.to_s, resolver: mention_resolver(channel_id))
        end

        # @mention_resolver bound to +channel_id+, so a mention inside the body
        # reads the server member this channel belongs to rather than nothing at
        # all (issue #905). Falls back to a bare nil resolver when none was
        # injected, keeping Markdown.parse's own nil safety intact.
        def mention_resolver(channel_id)
          return nil if @mention_resolver.nil?

          ->(type, id) { @mention_resolver.call(type, id, channel_id: channel_id) }
        end

        # Build an author from a user id, resolving a name through the injected
        # resolvers. A masquerade name is preferred as the display name, matching
        # what a reader on Stoat actually saw.
        def author_for(user_id, masquerade, member = nil)
          return Core::Author.new(kind: :system) if user_id.nil?

          user = resolve_user(user_id)
          masq_name = masquerade.is_a?(Hash) ? presence(masquerade["name"]) : nil

          Core::Author.new(
            native_id: user_id,
            username: user && (user["username"] || user["name"]),
            nickname: nickname_of(member),
            display_name: masq_name || effective_display_name(user, member),
            bot: bot_flag(user),
            kind: :user,
            avatar_url: masquerade_avatar(masquerade) || user_avatar(user)
          )
        end

        # The member object for this event's author, which is where a per server
        # nickname lives. A server channel's Message event carries it inline; the
        # rest is a lookup.
        def member_for(event, user_id)
          inline = event["member"]
          return inline if inline.is_a?(Hash)

          resolve_member(event["channel"] || event["channel_id"], user_id)
        end

        def resolve_user(id)
          return nil if @user_resolver.nil?

          @user_resolver.call(id)
        rescue StandardError
          nil
        end

        def resolve_member(channel_id, user_id)
          return nil if @member_resolver.nil? || channel_id.nil? || user_id.nil?

          @member_resolver.call(channel_id, user_id)
        rescue StandardError
          nil
        end

        # The name Stoat itself shows for this member: the nickname they chose
        # inside this server, then the account display name. Author#any_name
        # prefers display_name over nickname, so the account name alone is wrong.
        def effective_display_name(user, member)
          nickname_of(member) || display_name_of(user)
        end

        # Stoat keeps a per server nickname on the Member object, under "nickname".
        def nickname_of(member)
          return nil unless member.is_a?(Hash)

          presence(member["nickname"])
        end

        # The account level display name, which a member may never have set.
        def display_name_of(user)
          return nil unless user.is_a?(Hash)

          presence(user["display_name"])
        end

        def bot_flag(user)
          return false unless user.is_a?(Hash)

          !user["bot"].nil?
        end

        # Stoat avatars are served from the CDN and carry no credential.
        def user_avatar(user)
          return nil unless user.is_a?(Hash)

          avatar = user["avatar"]
          return nil unless avatar.is_a?(Hash)
          return nil if @file_url.nil?

          @file_url.call(avatar)
        end

        def masquerade_avatar(masquerade)
          return nil unless masquerade.is_a?(Hash)

          presence(masquerade["avatar"])
        end

        def attachments_for(files)
          Array(files).filter_map do |file|
            next nil unless file.is_a?(Hash)

            url = @file_url&.call(file)
            Core::Attachment.new(
              kind: kind_for(file),
              url: url,
              filename: file["filename"],
              mime_type: file["content_type"],
              size: file["size"]
            )
          end
        end

        # Stoat tags a file's media type inside `metadata.type`; fall back to the
        # content type, and to :document.
        def kind_for(file)
          type = file.dig("metadata", "type").to_s
          case type
          when "Image" then :photo
          when "Video" then :video
          when "Audio" then :audio
          else
            mime = file["content_type"].to_s
            case mime
            when %r{\Aimage/gif} then :animation
            when %r{\Aimage/} then :photo
            when %r{\Avideo/} then :video
            when %r{\Aaudio/} then :audio
            else :document
            end
          end
        end

        # Stoat carries replies as a list of parent message ids on the same channel
        # and does not embed the parent, so there is no inline preview to quote
        # from. The first parent is the one a reader replied to.
        def reply_ref(replies, endpoint)
          parent = Array(replies).first
          return nil if parent.nil?

          Core::MessageRef.new(endpoint.id, parent)
        end

        def reaction_value(emoji_id)
          value = presence(emoji_id)
          return nil if value.nil?

          return Core::Reaction.new(custom_id: value) if value.match?(ULID)

          Core::Reaction.new(emoji: value)
        end

        def presence(value)
          return nil if value.nil?

          string = value.to_s
          string.empty? ? nil : string
        end
      end
    end
  end
end
