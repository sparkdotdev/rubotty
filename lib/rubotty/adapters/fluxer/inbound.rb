# frozen_string_literal: true

module Rubotty
  module Adapters
    module Fluxer
      # Converts Fluxer gateway dispatch payloads into canonical messages.
      # The payloads mirror Discord's, so the Discord Markdown parser is
      # reused. Works on the plain JSON Hashes the gateway parses plus
      # injected callables, with no network dependency.
      class Inbound
        # @param resolver [#call, nil] (:user|:channel|:role, id) -> String or nil
        # @param user_for [#call, nil] user id -> full user Hash or nil, for an
        #   event (a reaction) that names only an id and carries no user object
        # @param own_webhook [#call, nil] (webhook id, channel id) -> :ours,
        #   :not_ours or :unknown, so a message we posted through a webhook is
        #   not relayed back before the message map is populated; a nil channel
        #   asks only what this process already remembers posting through
        def initialize(endpoint_for:, resolver: nil, user_for: nil, own_webhook: nil, logger: nil)
          @endpoint_for = endpoint_for
          @resolver = resolver
          @user_for = user_for
          @own_webhook = own_webhook
          @logger = logger
        end

        def message(payload)
          endpoint = endpoint_for(payload)
          return nil if endpoint.nil?

          id = payload["id"]
          return nil if id.nil?
          return nil if own_webhook_message?(payload)

          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, id),
            origin: endpoint,
            author: author_for(payload["author"], webhook: webhook_author?(payload)),
            body: parse_markdown(payload["content"], payload["guild_id"]),
            attachments: attachments_for(payload["attachments"]),
            reply_to: reply_ref(payload, endpoint),
            reply_preview: reply_preview(payload),
            timestamp: Time.now,
            raw: payload
          )
        end

        def edit(payload)
          endpoint = endpoint_for(payload)
          return nil if endpoint.nil?

          id = payload["id"]
          return nil if id.nil?
          # An update event that carries no content (an embed unfurl, a pin) is
          # not an edit worth relaying.
          return nil unless payload.key?("content")
          return nil if own_webhook_message?(payload)

          Core::Message.new(
            kind: :edit,
            ref: Core::MessageRef.new(endpoint.id, id),
            origin: endpoint,
            author: author_for(payload["author"], webhook: webhook_author?(payload)),
            body: parse_markdown(payload["content"], payload["guild_id"]),
            attachments: attachments_for(payload["attachments"]),
            reply_to: reply_ref(payload, endpoint),
            reply_preview: reply_preview(payload),
            timestamp: Time.now,
            raw: payload
          )
        end

        def delete(payload)
          endpoint = endpoint_for(payload)
          return nil if endpoint.nil?

          id = payload["id"]
          return nil if id.nil?

          Core::Message.new(
            kind: :delete,
            ref: Core::MessageRef.new(endpoint.id, id),
            origin: endpoint,
            author: Core::Author.new(kind: :system),
            timestamp: Time.now,
            raw: payload
          )
        end

        def reaction(payload, kind)
          endpoint = endpoint_for(payload)
          if endpoint.nil?
            @logger&.debug do
              "dropped a Fluxer reaction in channel #{payload["channel_id"]}, no endpoint is bridged to it"
            end
            return nil
          end

          message_id = payload["message_id"]
          if message_id.nil?
            @logger&.debug { "dropped a Fluxer reaction on #{endpoint.id}, no message id" }
            return nil
          end

          parsed = reaction_value(payload["emoji"])
          if parsed.nil?
            @logger&.debug { "dropped a Fluxer reaction on #{endpoint.id}:#{message_id}, no emoji named" }
            return nil
          end

          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, message_id),
            origin: endpoint,
            author: author_from_id(payload["user_id"]),
            reaction: parsed,
            timestamp: Time.now,
            raw: payload
          )
        end

        # GUILD_MEMBER_ADD or GUILD_MEMBER_REMOVE, already narrowed to one
        # endpoint bridged in that guild; the adapter calls this once per such
        # endpoint, since a guild carries no channel_id of its own to resolve.
        def member(payload, kind, endpoint)
          user = payload["user"]
          return nil if user.nil?

          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, "member-#{user["id"]}-#{Time.now.to_i}"),
            origin: endpoint,
            author: author_for(user),
            timestamp: Time.now,
            raw: payload
          )
        end

        # MESSAGE_REACTION_REMOVE_ALL and MESSAGE_REACTION_REMOVE_EMOJI: Fluxer
        # clears one emoji or the whole message and names no user for either,
        # so this never resolves an author. The "emoji" key tells the two
        # apart: present for one emoji, absent for the whole message.
        def reaction_clear(payload)
          endpoint = endpoint_for(payload)
          if endpoint.nil?
            @logger&.debug do
              "dropped a Fluxer reaction clear in channel #{payload["channel_id"]}, no endpoint is bridged to it"
            end
            return nil
          end

          message_id = payload["message_id"]
          if message_id.nil?
            @logger&.debug { "dropped a Fluxer reaction clear on #{endpoint.id}, no message id" }
            return nil
          end

          reaction = payload.key?("emoji") ? reaction_value(payload["emoji"]) : nil
          if payload.key?("emoji") && reaction.nil?
            @logger&.debug { "dropped a Fluxer reaction clear on #{endpoint.id}:#{message_id}, no emoji named" }
            return nil
          end

          Core::Message.new(
            kind: :reaction_clear,
            ref: Core::MessageRef.new(endpoint.id, message_id),
            origin: endpoint,
            reaction: reaction,
            timestamp: Time.now,
            raw: payload
          )
        end

        private

        def endpoint_for(payload)
          channel_id = payload["channel_id"]
          return nil if channel_id.nil?

          @endpoint_for.call(channel_id)
        end

        # +guild_id+, when known, is what lets {Adapter#resolve_mention} read a
        # per-guild member's nickname rather than the bot-wide user's global
        # name. See #mention_resolver.
        def parse_markdown(content, guild_id = nil)
          return Core::RichText.new if content.nil? || content.to_s.empty?

          Discord::Markdown.parse(content.to_s, resolver: mention_resolver(guild_id))
        end

        # @resolver bound to this message's guild, so a mention inside the body
        # reads the per-guild nickname rather than the bot-wide name (see
        # Adapter#member_handle). Falls back to the plain resolver when there is
        # nothing to bind, keeping a nil @resolver's own nil-safety intact.
        def mention_resolver(guild_id)
          return @resolver if @resolver.nil? || guild_id.nil?

          ->(type, id) { @resolver.call(type, id, guild_id: guild_id) }
        end

        def author_for(user, webhook: false)
          return Core::Author.new(kind: :system) if user.nil?

          Core::Author.new(
            native_id: user["id"],
            username: user["username"] || user["name"],
            display_name: user["global_name"] || user["display_name"],
            bot: webhook || !user["bot"].nil? && user["bot"] != false,
            kind: :user,
            avatar_url: avatar_url(user)
          )
        end

        # A reaction event names only a user id, never the full user object a
        # message or member event carries, so the caller's cache (or a REST
        # lookup behind it, keyed the same way @mention resolution already
        # is) is asked before falling back to a bare id with no name to show.
        def author_from_id(id)
          return Core::Author.new(kind: :system) if id.nil?

          user = lookup_user(id)
          # The id is already known for certain, the one thing being resolved
          # is the name attached to it, so it is asserted here rather than
          # trusted to come back unchanged on the object the lookup returns.
          return author_for(user.merge("id" => id)) if user.is_a?(Hash)

          Core::Author.new(native_id: id, kind: :user)
        end

        # A lookup failure degrades to the bare id {#author_from_id} already
        # falls back to, rather than losing the whole reaction event over it.
        def lookup_user(id)
          @user_for&.call(id)
        rescue StandardError
          nil
        end

        # Only take an avatar that is already a fetchable URL, never a bare hash
        # we would have to guess a CDN path for.
        def avatar_url(user)
          value = user["avatar_url"] || user["avatar"]
          return nil unless value.is_a?(String) && value.start_with?("http")

          value
        end

        # Whether the author is a webhook at all, not only when Fluxer bothers
        # to populate webhook_id. A webhook message names the webhook as its
        # author too, so whenever the field is missing, the same recognition
        # {#own_webhook_message?} uses to catch our own echo answers this as
        # well: the id is ours or it is not, webhook_id or no webhook_id.
        def webhook_author?(payload)
          return true unless payload["webhook_id"].nil?

          own_webhook_message?(payload)
        end

        # Whether +payload+ is a copy this bridge wrote through a webhook. An
        # :unknown answer relays, since the message map and the delivery ledger
        # still stand behind it and refusing everything unrecognised would
        # silence other people's webhooks.
        def own_webhook_message?(payload) = webhook_ownership(payload) == :ours

        # The raw three-way ownership answer. A webhook message names the
        # webhook as its author as well, so the id is still there to recognise
        # when the payload carries no webhook_id of its own; that spelling is
        # checked against what this process remembers posting through rather
        # than against a channel listing, so an ordinary message costs nothing.
        def webhook_ownership(payload)
          return :not_ours if @own_webhook.nil?

          id = payload["webhook_id"]
          return @own_webhook.call(author_id(payload), nil) if id.nil?

          @own_webhook.call(id, payload["channel_id"])
        rescue StandardError
          # Silence is only safe read as "cannot tell", never as "no".
          :unknown
        end

        def author_id(payload)
          author = payload["author"]
          author.is_a?(Hash) ? author["id"] : nil
        end

        def attachments_for(files)
          Array(files).filter_map do |file|
            next nil unless file.is_a?(Hash)

            Core::Attachment.new(
              kind: kind_for(file),
              url: file["url"],
              filename: file["filename"],
              mime_type: file["content_type"],
              size: file["size"],
              width: file["width"],
              height: file["height"]
            )
          end
        end

        def kind_for(file)
          mime = file["content_type"].to_s
          case mime
          when %r{\Aimage/gif} then :animation
          when %r{\Aimage/} then :photo
          when %r{\Avideo/} then :video
          when %r{\Aaudio/} then :audio
          else :document
          end
        end

        def reply_ref(payload, endpoint)
          reference = payload["message_reference"]
          parent_id = reference.is_a?(Hash) ? reference["message_id"] : nil
          parent_id ||= payload.dig("referenced_message", "id")
          return nil if parent_id.nil?

          Core::MessageRef.new(endpoint.id, parent_id)
        end

        # Fluxer includes the parent inline on a reply, so the excerpt needed for
        # quoting elsewhere is already in hand. +payload+'s own guild_id is used,
        # not the parent's: Fluxer has no cross guild replies, so the two are
        # always the same guild.
        def reply_preview(payload)
          parent = payload["referenced_message"]
          return nil unless parent.is_a?(Hash)

          Core::ReplyPreview.new(
            author: author_for(parent["author"]),
            body: parse_markdown(parent["content"], payload["guild_id"])
          )
        end

        def reaction_value(emoji)
          return nil unless emoji.is_a?(Hash)

          id = emoji["id"]
          return Core::Reaction.new(custom_id: id, custom_name: emoji["name"]) if id

          name = emoji["name"]
          return nil if name.nil? || name.to_s.empty?

          Core::Reaction.new(emoji: name)
        end
      end
    end
  end
end
