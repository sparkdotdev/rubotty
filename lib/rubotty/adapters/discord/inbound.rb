# frozen_string_literal: true

module Rubotty
  module Adapters
    module Discord
      # Converts discordrb events into canonical messages. Kept free of any
      # discordrb require: it works on duck typed objects, so the whole inbound
      # path is unit testable against plain doubles.
      class Inbound
        def initialize(endpoint_for:, logger: nil, resolver: nil, own_webhook: nil, user_handle: nil)
          @endpoint_for = endpoint_for
          @logger = logger
          @resolver = resolver
          @own_webhook = own_webhook
          @user_handle = user_handle
        end

        # MESSAGE_CREATE, and the same builder backfill re-feeds history through.
        # +replaying+ says which of those it is, because an unanswerable
        # ownership check has to fail the other way when we are replaying.
        def message(event, replaying: false)
          endpoint = endpoint_for(event)
          return nil if endpoint.nil?

          payload = event.message
          # Our own webhook posts are not authored by the bot account, so the
          # loop guard recognises them by webhook id instead.
          return nil if own_webhook_message?(payload, replaying: replaying)

          build_chat_message(event, endpoint, payload)
        end

        # Same shape {#message} builds, paired with the ownership answer
        # {#message} acts on instead of returning. Nothing is dropped for
        # being our own copy: a read only report needs to see an echo to
        # count and label it, not have it vanish before it arrives.
        def message_with_ownership(event)
          endpoint = endpoint_for(event)
          return nil if endpoint.nil?

          payload = event.message
          [build_chat_message(event, endpoint, payload), webhook_ownership(payload)]
        end

        # The Discord thread a message lives in, or nil. A thread is a channel in
        # its own right whose +parent_id+ points at the channel it hangs off, but
        # an ordinary channel sitting in a category carries a truthy +parent_id+
        # too (the category's), so only the channel's own type tells the two
        # apart.
        def thread_for(event)
          channel = event.respond_to?(:channel) ? event.channel : nil
          return nil if channel.nil?
          return nil unless thread_channel?(channel)

          Core::ThreadRef.new(native_id: channel.id, name: safe(channel, :name),
                              creator: thread_creator(channel), creator_native_id: safe(channel, :owner_id))
        rescue StandardError
          nil
        end

        # Who started the thread. Discord carries them as the thread channel's
        # owner id, so only a user lookup turns that into a handle worth reading.
        def thread_creator(channel)
          owner = safe(channel, :owner_id)
          return nil if owner.nil? || @user_handle.nil?

          @user_handle.call(owner)
        rescue StandardError
          nil
        end

        # MESSAGE_UPDATE. Discord also emits this for an embed finishing its
        # unfurl, a link preview arriving or a message being pinned, so anything
        # without an edit timestamp is discarded.
        def edit(event)
          endpoint = endpoint_for(event)
          return nil if endpoint.nil?

          payload = event.message
          return nil unless edited?(payload)

          Core::Message.new(
            kind: :edit,
            ref: Core::MessageRef.new(endpoint.id, payload.id),
            origin: endpoint,
            author: author_for(payload),
            body: Markdown.parse(payload.content, resolver: mention_resolver(endpoint)),
            attachments: attachments_for(payload),
            reply_to: reply_ref(payload, endpoint),
            reply_preview: reply_preview(payload, endpoint),
            timestamp: safe_time(payload),
            raw: payload
          )
        end

        # MESSAGE_DELETE. Discord tells us the id and the channel and nothing
        # else, which is enough: the router resolves the copies through the
        # message map.
        def delete(event)
          endpoint = endpoint_for(event)
          return nil if endpoint.nil?

          Core::Message.new(
            kind: :delete,
            ref: Core::MessageRef.new(endpoint.id, event.id),
            origin: endpoint,
            author: Core::Author.new(kind: :system),
            timestamp: Time.now,
            raw: event
          )
        end

        # MESSAGE_REACTION_ADD and MESSAGE_REACTION_REMOVE.
        def reaction(event, kind)
          endpoint = endpoint_for(event)
          return nil if endpoint.nil?

          parsed = reaction_value(event)
          if parsed.nil?
            @logger&.warn do
              "discord: dropped a reaction on #{endpoint.id}:#{message_id_of(event)}, it carries no readable emoji"
            end
            return nil
          end

          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, message_id_of(event)),
            origin: endpoint,
            author: reaction_author(event),
            reaction: parsed,
            timestamp: Time.now,
            raw: event
          )
        end

        # discordrb's ReactionEvent#user resolves the reacting member with a live
        # REST call on every reaction, and a rate limit or other hiccup makes it
        # answer nil rather than raise. #author_from_user would then hand back a
        # bare system author, indistinguishable downstream from an unactionable
        # reaction, so a vote or RSVP silently vanishes. Falling back to the bare
        # id the gateway payload already carried keeps the reaction attributable.
        def reaction_author(event)
          user = event.user
          return author_from_user(user) unless user.nil?

          id = reaction_user_id(event)
          if id.nil?
            @logger&.warn { "discord: dropped a reaction on #{message_id_of(event)}, it names no resolvable user" }
            return Core::Author.new(kind: :system)
          end

          @logger&.warn do
            "discord: could not resolve the member for a reaction on #{message_id_of(event)}, using its bare id"
          end
          Core::Author.new(native_id: id, kind: :user)
        rescue StandardError => e
          @logger&.warn { "discord: could not read the reacting user off #{message_id_of(event)}: #{e.message}" }
          Core::Author.new(kind: :system)
        end

        # discordrb's ReactionEvent carries no public reader for the id it
        # already parsed off the gateway payload before it went looking for a
        # Member; a test double may expose one directly, so that is tried
        # first.
        def reaction_user_id(event)
          if event.respond_to?(:user_id)
            id = event.user_id
            return id.nil? ? nil : id.to_s
          end

          raw = event.instance_variable_get(:@user_id)
          raw && raw.to_s
        end

        # MESSAGE_REACTION_REMOVE_ALL and MESSAGE_REACTION_REMOVE_EMOJI. Discord
        # names no user for either, whether one emoji or the whole message is
        # being cleared, so this never resolves an author. #reaction_value
        # already answers nil for a ReactionRemoveAllEvent, which carries no
        # emoji at all, and that nil is what tells the bridge to clear
        # everything rather than one emoji.
        def reaction_clear(event)
          endpoint = endpoint_for(event)
          return nil if endpoint.nil?

          Core::Message.new(
            kind: :reaction_clear,
            ref: Core::MessageRef.new(endpoint.id, message_id_of(event)),
            origin: endpoint,
            reaction: reaction_value(event),
            timestamp: Time.now,
            raw: event
          )
        end

        # GUILD_MEMBER_ADD or GUILD_MEMBER_REMOVE, already narrowed to one
        # endpoint bridged in the guild the event named; the adapter calls this
        # once per such endpoint, since neither event carries a channel of its
        # own for #endpoint_for to resolve.
        def member(event, kind, endpoint)
          Core::Message.new(
            kind: kind,
            ref: Core::MessageRef.new(endpoint.id, "member-#{safe(event.user, :id)}-#{Time.now.to_i}"),
            origin: endpoint,
            author: author_from_user(event.user),
            timestamp: Time.now,
            raw: event
          )
        end

        # A message posted INSIDE a Discord thread carries the thread's own channel
        # object, and a thread is never itself a mapped endpoint, so it has to route
        # through #parent_id, the channel it hangs off. An ordinary channel in a
        # category also carries a truthy #parent_id (the category's), never mapped
        # either, so trying the channel's own id first and falling back to the
        # parent handles both without needing to know the channel type. Public so a
        # caller holding just a channel, like Adapter#notify_unmapped_command, reuses
        # this exact fallback instead of a second, divergent copy.
        def endpoint_for_channel(channel)
          if channel.nil?
            @logger&.debug { "discord: no channel to resolve, dropping" }
            return nil
          end

          endpoint = @endpoint_for.call(channel.id) || endpoint_for_parent(channel)
          @logger&.debug { "discord: no endpoint bridged to channel #{channel.id}, dropping" } if endpoint.nil?
          endpoint
        end

        private

        # The {Core::Message} shape both {#message} and {#message_with_ownership}
        # produce, factored out so the two differ only in what they do about
        # ownership rather than in how a message gets built.
        def build_chat_message(event, endpoint, payload)
          Core::Message.new(
            kind: :chat,
            ref: Core::MessageRef.new(endpoint.id, payload.id),
            origin: endpoint,
            author: author_for(payload),
            body: Markdown.parse(payload.content, resolver: mention_resolver(endpoint)),
            attachments: attachments_for(payload),
            reply_to: reply_ref(payload, endpoint),
            reply_preview: reply_preview(payload, endpoint),
            thread: thread_for(event),
            timestamp: safe_time(payload),
            raw: payload
          )
        end

        def endpoint_for(event)
          channel = event.respond_to?(:channel) ? event.channel : nil
          endpoint_for_channel(channel)
        end

        def endpoint_for_parent(channel)
          parent_id = safe(channel, :parent_id)
          return nil if parent_id.nil?

          @endpoint_for.call(parent_id)
        end

        # Discord uses #parent_id for two unrelated things (a thread's parent
        # channel, and a categorized channel's category), so only the channel's
        # own type, discordrb's #thread?, tells a thread apart from a channel in
        # a category. A duck-typed double with no #thread? is never a thread.
        def thread_channel?(channel)
          channel.respond_to?(:thread?) && channel.thread?
        end

        def attachments_for(payload)
          return [] unless payload.respond_to?(:attachments)

          Array(payload.attachments).map do |attachment|
            Core::Attachment.new(
              kind: kind_for(attachment),
              url: attachment.url,
              filename: attachment.filename,
              mime_type: safe(attachment, :content_type),
              size: safe(attachment, :size),
              width: safe(attachment, :width),
              height: safe(attachment, :height)
            )
          end
        end

        # Discord reports a MIME type rather than a category, so the category is
        # inferred. Falling back to :document is always safe.
        def kind_for(attachment)
          mime = safe(attachment, :content_type).to_s
          case mime
          when %r{\Aimage/gif} then :animation
          when %r{\Aimage/} then :photo
          when %r{\Avideo/} then :video
          when %r{\Aaudio/} then :audio
          else :document
          end
        end

        def author_for(payload)
          user = payload.respond_to?(:author) ? payload.author : nil
          return Core::Author.new(kind: :system) if user.nil?

          author_from_user(user, webhook: webhook?(payload))
        end

        def author_from_user(user, webhook: false)
          return Core::Author.new(kind: :system) if user.nil?

          Core::Author.new(
            native_id: safe(user, :id),
            username: safe(user, :username) || safe(user, :name),
            # The raw guild nickname, for a template that specifically wants it.
            nickname: guild_nickname(user),
            # The EFFECTIVE display name: guild nickname first, then the global
            # display name, then the username. Author#any_name prefers
            # display_name over nickname, so the global name alone is wrong.
            display_name: effective_display_name(user),
            bot: webhook || safe(user, :bot_account) || false,
            kind: :user,
            # Discord avatar URLs are public CDN links carrying no credential,
            # so they are safe to hand to another platform.
            avatar_url: avatar_for(user)
          )
        end

        # nickname, then global display name, then username. The same order
        # discord.js resolves member.displayName in.
        def effective_display_name(user)
          guild_nickname(user) ||
            safe(user, :global_name) ||
            safe(user, :username) ||
            safe(user, :name)
        end

        # `display_name` on a Member is the nickname if set, otherwise the
        # username. Only useful as a nickname when it actually differs.
        def guild_nickname(user)
          return nil unless user.respond_to?(:nick)

          nick = safe(user, :nick)
          return nick if nick

          shown = safe(user, :display_name)
          username = safe(user, :username) || safe(user, :name)
          shown if shown && shown != username
        end

        # Whether +payload+ is a copy this bridge wrote through a webhook.
        # +replaying+ inverts what an unanswerable case means: live, an
        # unknown is treated as a stranger's, since that costs nothing the
        # other loop guards do not already cover; replaying, an unknown
        # counts as ours, since guessing wrong there would push the same
        # message back down the bridge a second time.
        def own_webhook_message?(payload, replaying: false)
          case webhook_ownership(payload)
          when :ours then true
          when :not_ours then false
          else replaying
          end
        end

        # The raw three way ownership answer for +payload+, with no opinion on
        # what to do about it. {#own_webhook_message?} is that opinion, applied
        # for a live or replayed relay decision; this is the fact underneath it,
        # for a caller (a report) that wants to see rather than act.
        def webhook_ownership(payload)
          return :not_ours if @own_webhook.nil?
          return :not_ours unless payload.respond_to?(:webhook_id)

          @own_webhook.call(payload.webhook_id, channel_of(payload))
        rescue StandardError
          # Same reasoning #own_webhook_message? applies to this: silence is
          # only safe when the caller treats it as "cannot tell", never as "no".
          :unknown
        end

        # The channel a payload sits in, so ownership can be settled against
        # Discord's own webhook list rather than against what this process
        # happens to remember posting.
        def channel_of(payload)
          payload.respond_to?(:channel) ? payload.channel : nil
        rescue StandardError
          nil
        end

        def avatar_for(user)
          return nil unless user.respond_to?(:avatar_url)

          user.avatar_url
        rescue StandardError
          nil
        end

        def webhook?(payload)
          payload.respond_to?(:webhook?) && payload.webhook?
        rescue StandardError
          false
        end

        def reply_ref(payload, endpoint)
          parent = referenced(payload)
          return nil if parent.nil?

          Core::MessageRef.new(endpoint.id, parent.id)
        end

        # Discord includes the parent message inline on a reply, so the excerpt
        # needed for quoting is already in hand. See Core::ReplyPreview. +endpoint+
        # is the REPLY's own endpoint, not the parent's: Discord has no cross
        # channel replies, so the two are always the same channel.
        def reply_preview(payload, endpoint)
          parent = referenced(payload)
          return nil if parent.nil?

          Core::ReplyPreview.new(
            author: author_for(parent),
            body: Markdown.parse(safe(parent, :content), resolver: mention_resolver(endpoint))
          )
        end

        # @resolver bound to this endpoint's channel, so a mention inside the body
        # reads a per-server nickname rather than the bot-wide name (see
        # Adapter#user_name). Falls back to the plain resolver when there is
        # nothing to bind, keeping a nil @resolver's own nil-safety intact.
        def mention_resolver(endpoint)
          return @resolver if @resolver.nil? || endpoint.nil?

          channel_id = endpoint.settings[:channel_id]
          ->(type, id) { @resolver.call(type, id, channel_id: channel_id) }
        end

        def referenced(payload)
          return nil unless payload.respond_to?(:referenced_message)

          payload.referenced_message
        rescue StandardError
          nil
        end

        def reaction_value(event)
          emoji = event.respond_to?(:emoji) ? event.emoji : nil
          return nil if emoji.nil?

          id = safe(emoji, :id)
          return Core::Reaction.new(custom_id: id, custom_name: safe(emoji, :name)) if id

          Core::Reaction.new(emoji: safe(emoji, :name))
        end

        def message_id_of(event)
          return event.message_id if event.respond_to?(:message_id)

          safe(event, :message)&.id
        end

        # Unreadable defaults to "not an edit": the other way turns an embed
        # unfurl or a pin into a fabricated edit on the target platform.
        def edited?(payload)
          return false unless payload.respond_to?(:edited?)

          payload.edited?
        rescue StandardError
          false
        end

        def safe_time(payload)
          return Time.now unless payload.respond_to?(:timestamp)

          payload.timestamp || Time.now
        rescue StandardError
          Time.now
        end

        def safe(object, method)
          return nil unless object.respond_to?(method)

          value = object.public_send(method)
          value.is_a?(String) && value.empty? ? nil : value
        rescue StandardError
          nil
        end
      end
    end
  end
end
