# frozen_string_literal: true

module Rubotty
  module Adapters
    module Xmpp
      # Builds the plain text body sent to an XMPP MUC from a canonical message.
      # Formatting is flattened, and a MUC occupant has one fixed nick, so the
      # sender is written into the text as a prefix.
      class Outbound
        def initialize(logger: nil)
          @logger = logger
        end

        def compose(message, endpoint, uploaded: {})
          parts = []
          parts << quote(message, endpoint)
          parts << sender_prefix(message, endpoint)
          parts << forward_note(message)
          parts << membership_note(message)
          parts << message.body.text
          parts << thread_note(message)
          parts << attachment_links(message, uploaded: uploaded)
          parts.compact.reject(&:empty?).join
        end

        # XMPP has no native reply, so the parent is quoted with the ">" a MUC user
        # would type by hand.
        def quote(message, endpoint)
          return nil unless message.quotable_reply?

          preview = message.reply_preview
          text = preview.body.text.gsub("\n", "\n> ")
          label = preview.label
          header = label ? "#{label}: " : ""
          "> #{header}#{text}\n"
        end

        def sender_prefix(message, endpoint)
          return nil if message.system_notice?
          return nil unless endpoint.settings.fetch(:sender_prefix, true)

          label = message.sender_label
          return nil if label.nil?

          rendered = render_label(label)
          return nil if rendered.empty?

          separator = endpoint.settings[:sender_separator] || ":"
          membership_verb(message) ? "#{rendered} " : "#{rendered}#{separator} "
        end

        # XMPP shows no bold, so both callables are the identity.
        def render_label(label)
          return label.to_s unless label.is_a?(Core::SenderLabel)

          label.render(escape: ->(text) { text }, bold: ->(text) { text })
        end

        def membership_verb(message)
          case message.kind
          when :join then "joined the chat"
          when :leave then "left the chat"
          end
        end

        def membership_note(message)
          verb = membership_verb(message)
          verb && verb
        end

        # Who a forwarded message originally came from, shown so the reader here
        # knows it was not typed in this room.
        def forward_note(message)
          notice = message.forwarded_notice
          return nil if notice.nil?

          "#{notice}\n"
        end

        # The thread degradation line, when the bridge asked for one, sitting under
        # the body to reconstruct context the reader lost. The bridge builds the
        # whole sentence; this only renders it.
        def thread_note(message)
          notice = message.thread_notice
          return nil if notice.nil? || notice.empty?

          "\n#{notice}"
        end

        # A public link surfaces the media in clients that preview URLs; a
        # credentialed URL (a Telegram file URL embeds the token) is never
        # posted. +uploaded+ is the adapter's own XEP-0363 result per
        # attachment, keyed by the attachment itself: a credentialed source
        # that got a real hosted url is shown at that url instead of the
        # could-not-relay marker.
        def attachment_links(message, uploaded: {})
          return nil if message.attachments.empty?

          links = message.attachments.map { |attachment| attachment_link(attachment, uploaded) }
          "\n#{links.join("\n")}"
        end

        def attachment_link(attachment, uploaded)
          Util::SafeUrl.public(attachment.url) || uploaded[attachment] || "[#{attachment.label}, could not be relayed]"
        end

        # Attachments #attachment_links still fell back to a marker for even
        # after +uploaded+ was consulted, read by the adapter so it can tell
        # the sender the way {Adapters::Discord::Adapter#note_failed_upload}
        # does for Discord.
        def unrelayed_attachments(message, uploaded: {})
          message.attachments.reject { |attachment| Util::SafeUrl.public(attachment.url) || uploaded[attachment] }
        end
      end
    end
  end
end
