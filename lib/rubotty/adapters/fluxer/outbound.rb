# frozen_string_literal: true

module Rubotty
  module Adapters
    module Fluxer
      # Builds what gets sent to Fluxer from a canonical message. Content is
      # Discord flavoured Markdown, so the shared DiscordMarkdown renderer
      # produces it. Only the ids the bridge itself resolved are allowed to
      # ping, so an injected `@everyone` stays inert.
      class Outbound
        # Fluxer's message content limit, matching Discord's.
        TEXT_LIMIT = 2000

        def initialize(renderer: Rendering::DiscordMarkdown.new(mention_key: :fluxer_id_for_target), logger: nil)
          @renderer = renderer
          @logger = logger
        end

        # The REST body for a bot send: content, an optional native reply, a
        # resolved mention whitelist, and a nonce for idempotency.
        def send_body(message, endpoint)
          body = { content: compose(message, endpoint), allowed_mentions: allowed_mentions(message, endpoint) }
          reference = reply_reference(message, endpoint)
          body[:message_reference] = reference if reference
          body[:nonce] = message.correlation_id
          body
        end

        def edit_body(message, endpoint)
          { content: compose(message, endpoint, editing: true),
            allowed_mentions: allowed_mentions(message, endpoint) }
        end

        # The sender is carried by the webhook username, so no text prefix.
        def webhook_body(message, endpoint, username:, avatar_url: nil)
          body = {
            content: compose(message, endpoint, webhook: true),
            username: username,
            allowed_mentions: allowed_mentions(message, endpoint)
          }
          body[:avatar_url] = avatar_url if avatar_url
          body
        end

        # The full message text, quote and (bot path) sender prefix included.
        def compose(message, endpoint, webhook: false, editing: false)
          parts = []
          parts << quote(message, endpoint) unless editing
          parts << sender_prefix(message, endpoint) unless webhook
          parts << forward_note(message)
          parts << membership_note(message)
          parts << @renderer.render(message.body)
          parts << thread_note(message)
          parts << attachment_note(message)
          body = parts.compact.reject(&:empty?).join
          clamp(body)
        end

        def quote(message, endpoint)
          return nil unless message.quotable_reply?
          return nil if reply_id(message, endpoint)

          preview = message.reply_preview
          text = @renderer.render(preview.body).gsub("\n", "\n> ")
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

        # An attachment with no resolvable url never reaches the adapter's
        # upload path, so it gets a bare label here; one that does is sent as a
        # real file and needs nothing said about it in the text.
        def attachment_note(message)
          links = message.attachments.reject(&:resolvable?)
          return nil if links.empty?

          "\n#{links.map { |a| "[#{escape(a.label)}]" }.join(" ")}"
        end

        # A whitelist of the concrete ids the bridge itself resolved. `parse: []`
        # keeps every raw token a federated user typed inert, so a relayed
        # `@everyone` does not ping.
        def allowed_mentions(message, endpoint)
          return nil if endpoint.settings[:allow_mass_mentions]

          ids = resolved_mention_ids(message)
          { parse: [], users: ids[:users], roles: ids[:roles] }
        end

        # Fluxer is its own identity space (see {Rendering::DiscordMarkdown}), so
        # a mention the router resolved for THIS target carries
        # `fluxer_id_for_target`, never Discord's own key.
        def resolved_mention_ids(message)
          users = []
          roles = []
          message.body.spans.each do |span|
            next unless span.kind == :mention

            user_id = span.attributes[:fluxer_id_for_target]
            users << user_id.to_s if user_id
            role_id = span.attributes[:fluxer_role_id_for_target]
            roles << role_id.to_s if role_id
          end
          { users: users.uniq, roles: roles.uniq }
        end

        def reply_reference(message, endpoint)
          id = reply_id(message, endpoint)
          return nil if id.nil?

          { message_id: id, fail_if_not_exists: false }
        end

        def reply_id(message, endpoint)
          return nil if message.reply_to.nil?
          return nil unless message.reply_to.endpoint_id == endpoint.id

          message.reply_to.native_id
        end

        def clamp(text, limit = TEXT_LIMIT)
          return text if text.length <= limit

          "#{text[0, limit - 1]}…"
        end

        private

        def escape(text) = text.to_s.gsub(/([\\*_~`|])/) { "\\#{Regexp.last_match(1)}" }
      end
    end
  end
end
