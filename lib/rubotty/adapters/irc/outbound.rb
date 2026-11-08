# frozen_string_literal: true

module Rubotty
  module Adapters
    module Irc
      # Builds the plain text a message becomes on IRC. One connection is one
      # nick, so the sender is written into the text as a prefix and a reply
      # is shown as a quoted line. Where message-tags and msgid were
      # negotiated, a reply to a message originating HERE rides the tag.
      class Outbound
        def initialize(logger: nil)
          @logger = logger
        end

        # @param capabilities [Adapters::Capabilities] this ENDPOINT's resolved
        #   capabilities (see {Adapter#capabilities_for}), so #quote can tell
        #   whether a native +draft/reply+ tag will carry the reply instead.
        #   Defaults to the conservative floor of no native replies.
        # @param short_code [String, nil] this endpoint's hub-mode short code
        #   ({HubRouter#code_for}), shown alongside room_label. nil outside a hub
        #   channel, which renders nothing extra.
        def compose(message, endpoint, capabilities: Capabilities.new, short_code: nil)
          parts = []
          parts << room_label(endpoint, short_code)
          parts << quote(message, endpoint, capabilities)
          parts << sender_prefix(message, endpoint)
          parts << forward_note(message)
          parts << membership_note(message)
          parts << message.body.text
          parts << thread_note(message)
          parts << attachment_links(message)
          parts.compact.reject(&:empty?).join
        end

        # Hub mode mirrors several bridged rooms into one physical IRC channel,
        # so the label tells them apart, with the room's short code alongside it
        # ("[gaming gs] "). A per-room endpoint leaves room_label unset.
        def room_label(endpoint, short_code = nil)
          label = endpoint.settings[:room_label].to_s.strip
          return nil if label.empty?

          short_code ? "[#{label} #{short_code}] " : "[#{label}] "
        end

        # A text quote, the way an IRC user would reply by hand, used when no
        # native tag can carry the relationship: the capability was never
        # negotiated, or the parent did not originate on this endpoint.
        def quote(message, endpoint, capabilities)
          return nil if native_reply?(message, endpoint, capabilities)
          return nil unless message.quotable_reply?

          preview = message.reply_preview
          text = preview.body.text.gsub("\n", " ")
          label = preview.label
          header = label ? "#{label}: " : ""
          "> #{header}#{text}\n"
        end

        # Whether {Adapter#deliver} will attach a client-only +draft/reply+ tag
        # to this send instead: the endpoint's resolved capabilities allow a
        # reply AND the parent lives on this same endpoint.
        def native_reply?(message, endpoint, capabilities)
          capabilities.replies? && !message.reply_to.nil? && message.reply_to.endpoint_id == endpoint.id
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

        # Rendered plain: IRC shows no bold, so both callables are the identity.
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
          membership_verb(message)
        end

        # Who a forwarded message originally came from, shown so the reader here
        # knows it was not typed in this channel.
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

        def attachment_links(message)
          return nil if message.attachments.empty?

          links = message.attachments.map do |attachment|
            Util::SafeUrl.public(attachment.url) || "[#{attachment.label}, could not be relayed]"
          end
          "\n#{links.join("\n")}"
        end

        # Attachments #attachment_links already fell back to a marker for,
        # read by the adapter so it can tell the sender the way
        # {Adapters::Discord::Adapter#note_failed_upload} does for Discord.
        def unrelayed_attachments(message)
          message.attachments.reject { |attachment| Util::SafeUrl.public(attachment.url) }
        end
      end
    end
  end
end
