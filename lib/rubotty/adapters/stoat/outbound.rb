# frozen_string_literal: true

module Rubotty
  module Adapters
    module Stoat
      # Builds the REST body sent to Stoat from a canonical message. Content is
      # Markdown, so the shared DiscordMarkdown renderer produces it, and per
      # sender identity is carried by Stoat's masquerade field.
      class Outbound
        # Stoat's hard limit on message content, matching Revolt's 2000.
        TEXT_LIMIT = 2000

        # Stoat rejects a longer masquerade name, and a rejected name fails the
        # whole send, so it is clamped.
        MASQUERADE_NAME_LIMIT = 32

        # What Stoat's own parser reads as a ping straight out of raw content,
        # with no `allowed_mentions` style field on the send endpoint to fall
        # back on the way Discord and Fluxer have.
        USER_MENTION_TOKEN = /<@([0-9A-HJKMNP-TV-Z]{26})>/
        ROLE_MENTION_TOKEN = /<%[0-9A-HJKMNP-TV-Z]{26}>/
        MASS_MENTION_TOKEN = /@(?:everyone|online)/

        def initialize(renderer: Rendering::DiscordMarkdown.new(mention_key: :stoat_id_for_target), logger: nil)
          @renderer = renderer
          @logger = logger
        end

        # The full body for a send: content, an optional native reply, an
        # optional masquerade, and a nonce for idempotency. +masquerade:
        # false+ builds the plain body a channel that refuses the masquerade
        # permission gets, sender prefix and all; +uploaded+ names
        # attachments already carried up as real Stoat files, so {#compose}
        # renders a text link only for the ones that are not.
        def send_body(message, endpoint, masquerade: true, uploaded: [])
          body = { content: compose(message, endpoint, masquerade: masquerade, uploaded: uploaded) }
          replies = reply_list(message, endpoint)
          body[:replies] = replies unless replies.empty?
          chosen = masquerade ? masquerade_for(message, endpoint) : nil
          body[:masquerade] = chosen if chosen
          # The nonce lets Stoat de duplicate a resend.
          body[:nonce] = message.correlation_id
          body
        end

        # The body for an edit is just the new content: a masquerade cannot be
        # changed on edit, and a native reply is fixed at creation.
        def edit_body(message, endpoint)
          { content: compose(message, endpoint, editing: true) }
        end

        # The full message text. When the endpoint carries a masquerade the sender
        # is shown by the masquerade name, so no text prefix is added.
        def compose(message, endpoint, editing: false, masquerade: true, uploaded: [])
          prefixed = !masquerade || masquerade_for(message, endpoint).nil?
          parts = []
          parts << quote(message, endpoint) unless editing
          parts << sender_prefix(message, endpoint) if prefixed
          parts << forward_note(message)
          parts << membership_note(message)
          parts << render_safely(message.body)
          parts << thread_note(message)
          parts << attachment_links(message, uploaded: uploaded)
          body = parts.compact.reject(&:empty?).join
          clamp(body)
        end

        # The masquerade Stoat should show, or nil to post as the bot. A notice the
        # bridge itself is saying always posts as the bot, since giving it a per
        # sender identity would misattribute it.
        def masquerade_for(message, endpoint)
          return nil if message.system_notice?
          return nil if endpoint.settings[:masquerade] == :off

          name = masquerade_name(message)
          return nil if name.nil?

          masquerade = { name: name }
          avatar = Util::SafeUrl.public(message.author&.avatar_url)
          masquerade[:avatar] = avatar if avatar
          masquerade
        end

        # Stoat wants a plain (unmarked) name, which is what SenderLabel#to_s
        # renders ("display [handle@platform]"). Shortening eats into the display
        # name and keeps the bracketed handle whole, rather than letting Stoat cut
        # the tail off wherever the limit happens to land.
        def masquerade_name(message)
          text = message.sender_label.to_s.tr("\r\n", " ").strip
          return nil if text.empty?

          Core::SenderLabel.shorten(text, MASQUERADE_NAME_LIMIT)
        end

        # The native reply list, or empty when the parent is not on this endpoint.
        def reply_list(message, endpoint)
          id = reply_id(message, endpoint)
          return [] if id.nil?

          # `mention: false` keeps a relayed reply from pinging the parent's author.
          [{ id: id, mention: false }]
        end

        def reply_id(message, endpoint)
          return nil if message.reply_to.nil?
          return nil unless message.reply_to.endpoint_id == endpoint.id

          message.reply_to.native_id
        end

        # Stoat has no native quote for a message that is not a real reply, so a
        # Markdown blockquote is used. Suppressed when a native reply is available,
        # to avoid showing the parent twice.
        def quote(message, endpoint)
          return nil unless message.quotable_reply?
          return nil if reply_id(message, endpoint)

          preview = message.reply_preview
          text = render_safely(preview.body).gsub("\n", "\n> ")
          label = preview.label
          header = label ? "**#{escape(label)}**: " : ""
          "> #{header}#{text}\n"
        end

        def sender_prefix(message, endpoint)
          return nil if message.system_notice?
          return nil unless endpoint.settings.fetch(:sender_prefix, true)

          label = message.sender_label
          return nil if label.nil?

          separator = endpoint.settings[:sender_separator] || ":"

          if label.is_a?(Core::SenderLabel)
            rendered = render_sender_label(label)
            return nil if rendered.empty?
            return "#{rendered} " if membership_verb(message)

            "#{rendered}#{escape(separator)}\n"
          else
            text = label.to_s
            return nil if text.empty?
            return "**#{escape(text)}** " if membership_verb(message)

            "**#{escape(text)}#{escape(separator)}**\n"
          end
        end

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

        # Who a forwarded message originally came from, shown so the reader here
        # knows it was not typed in this room.
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

        # A text fallback for whichever attachments the adapter did not carry up
        # as real Stoat files: a link when the source URL carries no credential
        # (a Telegram file URL embeds the bot token), otherwise a bare marker.
        def attachment_links(message, uploaded: [])
          links = (message.attachments - uploaded).map { |attachment| attachment_reference(attachment) }
          return nil if links.empty?

          "\n#{links.join("\n")}"
        end

        def attachment_reference(attachment)
          Util::SafeUrl.public(attachment.url) || "[#{attachment.label}, could not be relayed]"
        end

        def clamp(text, limit = TEXT_LIMIT)
          return text if text.length <= limit

          "#{text[0, limit - 1]}…"
        end

        # Renders +rich+ and defuses every ping shaped token it did not itself
        # resolve. Stoat parses `<@id>` straight out of raw content server side
        # with no allowlist, so a token a member typed by hand, or that arrived
        # in a quoted message from elsewhere, would otherwise ping for real.
        def render_safely(rich)
          defuse(@renderer.render(rich), resolved_ids(rich))
        end

        # The Stoat ids +rich+'s own mention spans actually resolved to, read
        # fresh per call so a quoted message is judged only by what IT
        # resolved, never by what the message quoting it did.
        def resolved_ids(rich)
          rich.spans.filter_map do |span|
            next nil unless span.kind == :mention

            span.attributes[:stoat_id_for_target]&.to_s
          end
        end

        # Breaks every mention shaped token in +text+ that Stoat's parser would
        # honour, other than a `<@id>` whose id is in +trusted_ids+. A role
        # mention and a mass mention are never something this bridge resolves,
        # so both are always broken.
        def defuse(text, trusted_ids)
          text = text.gsub(USER_MENTION_TOKEN) do
            trusted_ids.include?(Regexp.last_match(1)) ? Regexp.last_match(0) : defuse_token(Regexp.last_match(0))
          end
          text = text.gsub(ROLE_MENTION_TOKEN) { |token| defuse_token(token) }
          text.gsub(MASS_MENTION_TOKEN) { |token| defuse_token(token) }
        end

        # A zero width space after the token's first character keeps it readable
        # to a person while breaking the literal adjacency (`<@`, `<%`, `@e`,
        # `@o`) Stoat's own parser requires, whichever of the three shapes it is.
        ZERO_WIDTH_SPACE = "\u200B"
        private_constant :ZERO_WIDTH_SPACE

        def defuse_token(token) = "#{token[0]}#{ZERO_WIDTH_SPACE}#{token[1..]}"

        private

        # Discord flavoured markdown escaping, which Stoat shares.
        def escape(text) = text.to_s.gsub(/([\\*_~`|])/) { "\\#{Regexp.last_match(1)}" }
      end
    end
  end
end
