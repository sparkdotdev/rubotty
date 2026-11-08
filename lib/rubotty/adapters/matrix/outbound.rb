# frozen_string_literal: true

module Rubotty
  module Adapters
    module Matrix
      # Builds the event content sent to Matrix from a canonical message. A
      # Matrix message carries a plain `body` and, when formatted, an HTML
      # `formatted_body`, both produced from the same canonical message so a
      # client that renders no HTML still reads a faithful plain text.
      class Outbound
        FORMAT = "org.matrix.custom.html"

        # msgtype for a real upload, the write-side mirror of Inbound's own
        # read-side MEDIA_MSGTYPES.
        MEDIA_MSGTYPES = {
          photo: "m.image", animation: "m.image", sticker: "m.image",
          video: "m.video", video_note: "m.video",
          audio: "m.audio", voice: "m.audio",
          document: "m.file"
        }.freeze

        def initialize(renderer: Html.new, logger: nil)
          @renderer = renderer
          @logger = logger
        end

        # The content for an m.room.message event carrying one uploaded
        # attachment: msgtype picked from its kind, +mxc_uri+ (what
        # Adapter#fetch_and_upload got back from the content repository) as
        # the url a client resolves and renders inline.
        def media_content(attachment, mxc_uri)
          {
            "msgtype" => MEDIA_MSGTYPES.fetch(attachment.kind, "m.file"),
            "body" => attachment.filename || attachment.label,
            "url" => mxc_uri,
            "info" => media_info(attachment)
          }
        end

        def media_info(attachment)
          { "mimetype" => attachment.mime_type, "size" => attachment.size,
            "w" => attachment.width, "h" => attachment.height }.compact
        end

        # Content for a fresh send.
        def send_content(message, endpoint)
          plain, html = compose(message, endpoint)
          content = base_content(plain, html, message)
          reply = reply_relation(message, endpoint)
          content["m.relates_to"] = reply if reply
          content
        end

        # Content for an edit: the new content is nested under `m.new_content`,
        # the visible fallback is the new body with the "* " marker Matrix
        # clients use, and the relation replaces the target event. `m.mentions`
        # is what a push rule actually reads, so it goes on the outer content
        # too, not only inside `m.new_content`; it is the edit's current
        # mention set, not diffed against the original, so a mention kept
        # across an edit rings again rather than staying silent.
        def edit_content(message, endpoint, target_event_id)
          plain, html = compose(message, endpoint, editing: true)
          new_content = base_content(plain, html, message)
          fallback = base_content("* #{plain}", "* #{html}", message)
          fallback.merge(
            "m.new_content" => new_content,
            "m.relates_to" => { "rel_type" => "m.replace", "event_id" => target_event_id }
          )
        end

        def compose(message, endpoint, editing: false)
          plain = []
          html = []
          unless editing
            quote = quote(message, endpoint)
            append(plain, html, quote)
          end
          append(plain, html, sender_prefix(message, endpoint))
          append(plain, html, forward_note(message))
          append(plain, html, membership_note(message))
          plain << message.body.text
          html << @renderer.render(message.body)
          append(plain, html, thread_note(message))
          append(plain, html, attachment_links(message))
          [join(plain), join(html)]
        end

        # The native reply relation when the parent is on this endpoint. A
        # foreign reply cannot point at a local event, so it degrades to the
        # quote the compose path adds instead.
        def reply_relation(message, endpoint)
          id = reply_id(message, endpoint)
          return nil if id.nil?

          { "m.in_reply_to" => { "event_id" => id } }
        end

        def reply_id(message, endpoint)
          return nil if message.reply_to.nil?
          return nil unless message.reply_to.endpoint_id == endpoint.id

          message.reply_to.native_id
        end

        # A quoted parent for a reply we cannot represent natively.
        def quote(message, endpoint)
          return nil unless message.quotable_reply?
          return nil if reply_id(message, endpoint)

          preview = message.reply_preview
          body = preview.body.text
          label = preview.label
          plain_lines = body.split("\n").map { |line| "> #{line}" }.join("\n")
          plain = label ? "> #{label}: #{body}\n" : "#{plain_lines}\n"
          inner = @renderer.render(preview.body)
          header = label ? "<b>#{esc(label)}</b>: " : ""
          html = "<blockquote>#{header}#{inner}</blockquote>"
          [plain, html]
        end

        def sender_prefix(message, endpoint)
          return nil if message.system_notice?
          return nil unless endpoint.settings.fetch(:sender_prefix, true)

          label = message.sender_label
          return nil if label.nil?

          separator = endpoint.settings[:sender_separator] || ":"
          plain, html = render_label(label)
          return nil if plain.empty?

          if membership_verb(message)
            ["#{plain} ", "#{html} "]
          else
            ["#{plain}#{separator}\n", "#{html}#{esc(separator)}<br/>"]
          end
        end

        # Render the label once to plain and once to HTML.
        def render_label(label)
          if label.is_a?(Core::SenderLabel)
            plain = label.render(escape: ->(text) { text }, bold: ->(text) { text })
            html = label.render(escape: method(:esc), bold: ->(text) { "<b>#{text}</b>" })
            [plain, html]
          else
            text = label.to_s
            [text, "<b>#{esc(text)}</b>"]
          end
        end

        def membership_verb(message)
          case message.kind
          when :join then "joined the chat"
          when :leave then "left the chat"
          end
        end

        def membership_note(message)
          verb = membership_verb(message)
          return nil if verb.nil?

          ["*#{verb}*", "<i>#{esc(verb)}</i>"]
        end

        # Who a forwarded message originally came from, shown so the reader here
        # knows it was not typed in this room.
        def forward_note(message)
          notice = message.forwarded_notice
          return nil if notice.nil?

          ["*#{notice}*\n", "<i>#{esc(notice)}</i><br/>"]
        end

        # The thread degradation line, when the bridge asked for one, sitting under
        # the body to reconstruct context the reader lost. The bridge builds the
        # whole sentence; this only renders it.
        def thread_note(message)
          notice = message.thread_notice
          return nil if notice.nil? || notice.empty?

          ["\n*#{notice}*", "<br/><i>#{esc(notice)}</i>"]
        end

        # Matrix renders a bare media URL as a link, so a public source link
        # surfaces the media with no re upload. A credentialed source URL (a
        # Telegram file URL embeds the token) is never posted.
        def attachment_links(message)
          return nil if message.attachments.empty?

          plain = []
          html = []
          message.attachments.each do |attachment|
            safe = Util::SafeUrl.public(attachment.url)
            if safe
              plain << safe
              html << %(<a href="#{esc(safe)}">#{esc(attachment.label)}</a>)
            else
              marker = "[#{attachment.label}, could not be relayed]"
              plain << marker
              html << esc(marker)
            end
          end
          ["\n#{plain.join("\n")}", "<br/>#{html.join("<br/>")}"]
        end

        # Attachments #attachment_links already fell back to a marker for,
        # read by the adapter so it can tell the sender the way
        # {Adapters::Discord::Adapter#note_failed_upload} does for Discord.
        def unrelayed_attachments(message)
          message.attachments.reject { |attachment| Util::SafeUrl.public(attachment.url) }
        end

        private

        def base_content(plain, html, message)
          content = {
            "msgtype" => "m.text",
            "body" => plain,
            "format" => FORMAT,
            "formatted_body" => html
          }
          ids = mentioned_user_ids(message)
          content["m.mentions"] = { "user_ids" => ids } unless ids.empty?
          content
        end

        # The Matrix user ids a resolved mention span in the body carries,
        # for `m.mentions`, the field Matrix's push rules key a real
        # notification off rather than scanning the rendered text. `@room` is
        # never included: a mass mention does not cross platforms.
        def mentioned_user_ids(message)
          message.body.spans.filter_map do |span|
            span.attributes[:matrix_id_for_target] if span.kind == :mention
          end.uniq
        end

        # Append a [plain, html] pair (or skip a nil) to the two accumulators.
        def append(plain, html, pair)
          return if pair.nil?

          plain << pair[0]
          html << pair[1]
        end

        def join(parts) = parts.compact.reject { |part| part.to_s.empty? }.join

        def esc(text) = Html.escape(text)
      end
    end
  end
end
