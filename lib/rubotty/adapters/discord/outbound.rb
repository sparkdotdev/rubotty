# frozen_string_literal: true

module Rubotty
  module Adapters
    module Discord
      # Builds what gets sent to Discord from a canonical message.
      class Outbound
        # Discord's hard limit on message content.
        TEXT_LIMIT = 2000

        # An embed description holds far more, which is how a Telegram message
        # (limit 4096) crosses intact.
        EMBED_LIMIT = 4096

        # Colour used for the embed, so a long relayed message does not read as
        # an alert.
        EMBED_COLOUR = 0x5865F2

        # Discord's limit on an embed author name.
        EMBED_AUTHOR_LIMIT = 256

        def initialize(renderer: Rendering::DiscordMarkdown.new, logger: nil)
          @renderer = renderer
          @logger = logger
        end

        # The full message body, sender prefix and quoted reply included.
        #
        # @param message [Core::Message]
        # @param endpoint [Core::Endpoint]
        # @param webhook [Boolean] when posting through a webhook the sender is
        #   carried by the webhook's username, so no text prefix is added
        def compose(message, endpoint, webhook: false)
          parts = []
          parts << quote(message, endpoint, webhook: webhook)
          parts << sender_prefix(message, endpoint) unless webhook
          parts << forward_note(message)
          parts << @renderer.render(message.body)
          parts << thread_note(message)
          parts << membership_note(message)
          parts << attachment_note(message)
          body = parts.compact.reject(&:empty?).join
          # Clamped to the EMBED limit: the send path decides which of the two
          # applies, and clamping to 2000 here would throw content away first.
          clamp(body, EMBED_LIMIT)
        end

        # Discord has no native way to quote a message that is not a real reply,
        # so a blockquote is used.
        def quote(message, endpoint, webhook: false)
          return nil unless message.quotable_reply?
          # A native reply already shows Discord's own preview of the parent. A
          # WEBHOOK message cannot make a native reply, so on that path the quote
          # is the only way the reply relationship survives.
          return nil if !webhook && reply_id(message, endpoint)

          preview = message.reply_preview
          text = @renderer.render(preview.body).gsub("\n", "\n> ")
          label = preview.label
          header = label ? "**#{escape(label)}**: " : ""
          "> #{header}#{text}\n"
        end

        def sender_prefix(message, endpoint)
          # A notice the bridge itself is saying needs no sender label, and a
          # prefix would corrupt the startup banner's format.
          return nil if message.system_notice?
          return nil unless endpoint.settings.fetch(:sender_prefix, true)

          label = message.sender_label
          return nil if label.nil? || label.empty?

          separator = endpoint.settings[:sender_separator] || ":"

          # A structured label bolds ONLY the username and keeps "@platform
          # [display name]" plain, with the separator outside the bold.
          if label.is_a?(Core::SenderLabel)
            rendered = render_sender_label(label)
            return nil if rendered.empty?
            return "#{rendered} " if membership_verb(message)

            return "#{rendered}#{escape(separator)}\n"
          end

          # A bare string (a configured display name template, or a bridge
          # notice) keeps the whole label bold, separator included.
          return "**#{escape(label)}** " if membership_verb(message)

          "**#{escape(label)}#{escape(separator)}**\n"
        end

        # Render a structured {Core::SenderLabel} as Discord markdown, bolding
        # only the username span.
        def render_sender_label(label)
          label.render(escape: method(:escape), bold: ->(text) { "**#{text}**" })
        end

        def membership_verb(message)
          case message.kind
          when :join then "joined the chat"
          when :leave then "left the chat"
          end
        end

        def membership_note(message)
          verb = membership_verb(message)
          verb && "*#{verb}*"
        end

        def forward_note(message)
          notice = message.forwarded_notice
          return nil if notice.nil?

          "*#{escape(notice)}*\n"
        end

        # The thread degradation line, when the bridge asked for one, sitting under
        # the body to reconstruct context the reader lost. The bridge builds the
        # whole sentence; this only renders it.
        def thread_note(message)
          notice = message.thread_notice
          return nil if notice.nil? || notice.empty?

          "\n*#{escape(notice)}*"
        end

        # Attachments that could not be uploaded are listed as links, so the
        # reader at least knows something was attached and can follow it.
        def attachment_note(message)
          links = message.attachments.reject(&:resolvable?)
          return nil if links.empty?

          "\n" + links.map { |a| "[#{escape(a.label)}]" }.join(" ")
        end

        # The reply id usable on this endpoint, or nil.
        def reply_id(message, endpoint)
          return nil if message.reply_to.nil?
          return nil unless message.reply_to.endpoint_id == endpoint.id

          message.reply_to.native_id
        end

        # Which mentions Discord is permitted to actually resolve in relayed
        # content, as a whitelist of ids the bridge itself resolved a mention to.
        # `parse: []` is the crux: `parse: [users, roles]` would resolve every
        # `<@id>` token in the text, and markdown escaping does not neutralise
        # `<`, `@` or `&`, so a token typed by hand elsewhere would ping for real;
        # `allow_mass_mentions` returns nil instead, letting Discord parse everything.
        def allowed_mentions(message, endpoint)
          return nil if endpoint.settings[:allow_mass_mentions]

          ids = resolved_mention_ids(message)
          { parse: [], users: ids[:users], roles: ids[:roles] }
        end

        # The Discord ids the router resolved a cross platform mention to, read
        # from the body's mention spans, which the router annotated with
        # `:discord_id_for_target` and the renderer turns into `<@id>`.
        def resolved_mention_ids(message)
          users = []
          roles = []
          message.body.spans.each do |span|
            next unless span.kind == :mention

            user_id = span.attributes[:discord_id_for_target]
            users << user_id.to_s if user_id
            role_id = span.attributes[:discord_role_id_for_target]
            roles << role_id.to_s if role_id
          end
          { users: users.uniq, roles: roles.uniq }
        end

        def clamp(text, limit = TEXT_LIMIT)
          return text if text.length <= limit

          "#{text[0, limit - 1]}…"
        end

        # Does this message need an embed to cross without losing content?
        # Anything over Discord's 2000 character limit goes into an embed, whose
        # description holds 4096, rather than being cut with an ellipsis.
        def embed?(content, endpoint)
          mode = endpoint.settings[:use_embeds] || :auto
          return false if mode == :never
          return true if mode == :always

          content.to_s.length > TEXT_LIMIT
        end

        # The embed payload for an over long message, a plain Hash so this class
        # stays free of discordrb. The sender goes in the AUTHOR field, which keeps
        # the description free for a full 4096 character body.
        def embed_for(content, author_name: nil)
          payload = { description: clamp(content, EMBED_LIMIT), color: EMBED_COLOUR }
          # The author field carries the sender out of band, so it wants the
          # PLAIN text of the label rather than any markup.
          payload[:author] = { name: clamp(author_name.to_s, EMBED_AUTHOR_LIMIT) } if author_name
          payload
        end

        # Body without the sender prefix, for use as an embed description.
        def embed_body(message, endpoint)
          compose(message, endpoint, webhook: true)
        end

        private

        def escape(text) = text.to_s.gsub(/([\\*_~`|])/) { "\\#{Regexp.last_match(1)}" }
      end
    end
  end
end
