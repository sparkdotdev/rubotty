# frozen_string_literal: true

module Rubotty
  module Adapters
    module Telegram
      # Turns a canonical message into Bot API calls. Split out from the adapter
      # for the same reason as {Inbound}: the fiddly decisions live here and
      # deserve tests that do not need a transport.
      class Outbound
        # Telegram limits a text message to 4096 characters and a media caption
        # to 1024, both counted in UTF-16 code units, so the limit check cannot
        # use String#length.
        TEXT_LIMIT = 4096
        CAPTION_LIMIT = 1024

        # What Telegram will carry as one button's callback data, in bytes.
        CALLBACK_DATA_LIMIT = 64

        SEND_METHODS = {
          photo: ["sendPhoto", :photo],
          video: ["sendVideo", :video],
          animation: ["sendAnimation", :animation],
          audio: ["sendAudio", :audio],
          voice: ["sendVoice", :voice],
          video_note: ["sendVideoNote", :video_note],
          sticker: ["sendSticker", :sticker],
          document: ["sendDocument", :document]
        }.freeze

        def initialize(renderer: Rendering::TelegramHtml.new, logger: nil)
          @renderer = renderer
          @logger = logger
        end

        # Build the parameters for the initial send.
        #
        # @param message [Core::Message]
        # @param endpoint [Core::Endpoint]
        # @return [Array(String, Hash)] method name and parameters
        # Kinds Telegram will accept inside a media group. Stickers, voice notes
        # and video notes cannot be grouped at all.
        ALBUM_KINDS = %i[photo video].freeze
        MAX_ALBUM = 10

        # Every attachment goes out, never just the first: one call for a groupable
        # album (chunked past Telegram's per group maximum), otherwise one call per
        # attachment. The first call alone carries the caption and the reply pointer;
        # the rest are bare, since Telegram would repeat a caption under every chunk
        # or message it appears on.
        #
        # @return [Array<Array(String, Hash)>] one (method name, parameters) pair
        #   per call, empty when there is nothing to send at all
        def send_calls(message, endpoint)
          attachments = message.attachments
          return text_calls(message, endpoint) if attachments.empty?
          return album_calls(message, endpoint, attachments) if album?(attachments)

          media_calls(message, endpoint, attachments)
        end

        # No attachments, so one sendMessage, or none at all when the composed
        # body is empty: Telegram rejects an empty text, and the adapter would
        # then report a routine decline as a failed send.
        def text_calls(message, endpoint)
          call = text_call(message, endpoint)
          call[1][:text].to_s.strip.empty? ? [] : [call]
        end

        # Several files go as one media group when Telegram will take one, since
        # separate messages lose the fact that they were posted together.
        def album?(attachments)
          attachments.size > 1 &&
            attachments.all? { |a| ALBUM_KINDS.include?(a.kind) && a.resolvable? }
        end

        # Telegram caps a single media group at MAX_ALBUM items, so an album
        # past that size becomes more than one sendMediaGroup call rather than
        # dropping the overflow.
        def album_calls(message, endpoint, attachments)
          attachments.each_slice(MAX_ALBUM).with_index.map do |chunk, index|
            lead = index.zero?
            # A media group needs at least two items; a lone leftover chunk
            # goes as one ordinary send instead.
            next media_call(message, endpoint, chunk.first, lead: lead) if chunk.size == 1

            album_group_call(message, endpoint, chunk, lead: lead)
          end
        end

        def album_group_call(message, endpoint, chunk, lead:)
          media = chunk.each_with_index.map do |attachment, index|
            item = { type: attachment.kind.to_s, media: attachment.url }
            # Telegram shows the caption of the FIRST item as the album's
            # caption. Putting it on every item repeats it under each photo.
            if lead && index.zero?
              caption = clamp(compose(message, endpoint), CAPTION_LIMIT)
              unless caption.empty?
                item[:caption] = caption
                item[:parse_mode] = "HTML"
              end
            end
            item
          end

          params = base_params(endpoint).merge(media: media)
          if lead
            params[:reply_to_message_id] = reply_id(message, endpoint)
            params[:allow_sending_without_reply] = true
          end
          ["sendMediaGroup", params]
        end

        # Mixed kinds, a lone attachment, or anything #album? rejected: one
        # ordinary send per file rather than losing everything past the first.
        def media_calls(message, endpoint, attachments)
          attachments.each_with_index.map do |attachment, index|
            media_call(message, endpoint, attachment, lead: index.zero?)
          end
        end

        # An edit that names no reply_markup takes the keyboard off the message,
        # so a card's buttons have to be restated on every edit or the first
        # refreshed tally would leave the room with nothing to press.
        def edit_call(message, endpoint, native_id)
          body = compose(message, endpoint)
          if message.attachments.any?
            # Editing a caption and editing text are different Bot API methods,
            # and calling the wrong one fails. An attachment on the NEW content
            # is the best signal available.
            ["editMessageCaption", base_params(endpoint).merge(
              message_id: native_id.to_i,
              caption: clamp(body, CAPTION_LIMIT),
              parse_mode: "HTML",
              reply_markup: keyboard(message)
            )]
          else
            ["editMessageText", base_params(endpoint).merge(
              message_id: native_id.to_i,
              text: clamp(body, TEXT_LIMIT),
              parse_mode: "HTML",
              link_preview_options: { is_disabled: false },
              reply_markup: keyboard(message)
            )]
          end
        end

        # The inline keyboard for a message that carries buttons, or nil, which
        # {ApiClient#compact} strips. One button per row, since an option label
        # is a sentence rather than a word.
        def keyboard(message)
          rows = message.buttons.filter_map do |button|
            next skipped_button(button) if button.token.bytesize > CALLBACK_DATA_LIMIT

            [{ text: button.label, callback_data: button.token }]
          end
          rows.empty? ? nil : { inline_keyboard: rows }
        end

        def delete_call(endpoint, native_id)
          ["deleteMessage", { chat_id: endpoint.settings[:chat_id], message_id: native_id.to_i }]
        end

        # The rendered message body including the sender prefix. Telegram bots
        # cannot post under an arbitrary name, so the sender becomes part of the
        # text, bold so it reads as a header rather than as content.
        def compose(message, endpoint)
          parts = []
          parts << quote(message, endpoint)
          parts << sender_prefix(message, endpoint)
          parts << forward_note(message)
          parts << @renderer.render(message.body)
          parts << thread_note(message)
          parts << membership_note(message)
          parts.compact.reject(&:empty?).join
        end

        # Telegram has a native blockquote, so a parent we cannot reply to
        # natively is shown the way a Telegram user would show it by hand.
        def quote(message, endpoint)
          return nil unless message.quotable_reply?
          # A native reply already shows Telegram's own preview of the parent.
          return nil if reply_id(message, endpoint)

          preview = message.reply_preview
          inner = @renderer.render(preview.body)
          label = preview.label
          header = label ? "<b>#{Rendering::TelegramHtml.escape(label)}</b>: " : ""
          "<blockquote>#{header}#{inner}</blockquote>\n"
        end

        private

        # Telegram rejects the whole send over an oversized callback_data, so a
        # button nobody could carry is left out and said out loud.
        def skipped_button(button)
          @logger&.warn { "telegram: left out the #{button.label.inspect} button, its token is too long" }
          nil
        end

        def text_call(message, endpoint)
          ["sendMessage", base_params(endpoint).merge(
            text: clamp(compose(message, endpoint), TEXT_LIMIT),
            parse_mode: "HTML",
            reply_to_message_id: reply_id(message, endpoint),
            allow_sending_without_reply: true,
            reply_markup: keyboard(message)
          )]
        end

        # @param lead [Boolean] whether this is the first call for the message,
        #   which alone carries the caption and the reply pointer
        #
        # Always hands Telegram a URL to fetch itself rather than uploading bytes,
        # so the file still has to clear Telegram's own tighter URL-fetch ceiling
        # (Adapter::URL_RELAY_BYTES), not just its 50 MB upload ceiling; Bridge is
        # what keeps a file that only clears the bigger one from reaching here.
        def media_call(message, endpoint, attachment, lead: true)
          method, key = SEND_METHODS.fetch(attachment.kind, SEND_METHODS[:document])
          # A blank url is not resolvable, matching #resolvable? elsewhere; a bare
          # "" would otherwise pass this as a source and Telegram would 400 on it.
          source = attachment.resolvable? ? attachment.url : attachment.native_ref
          return unresolved_call(message, endpoint, attachment, lead: lead) if source.to_s.strip.empty?

          params = base_params(endpoint).merge(key => source)
          if lead
            params[:reply_to_message_id] = reply_id(message, endpoint)
            params[:allow_sending_without_reply] = true
          end
          # Stickers and video notes take no caption. Sending one is an API error.
          if lead && !%i[sticker video_note].include?(attachment.kind)
            params[:caption] = clamp(compose(message, endpoint), CAPTION_LIMIT)
            params[:parse_mode] = "HTML"
          end
          [method, params]
        end

        # A source Telegram cannot fetch falls back to a note rather than being
        # dropped. The lead slot carries the full composed caption already; a
        # bare slot only needs the reference, since the lead call's text or
        # caption already crossed once.
        def unresolved_call(message, endpoint, attachment, lead:)
          return text_call(message, endpoint) if lead

          ["sendMessage", base_params(endpoint).merge(
            text: clamp(attachment_reference(attachment), TEXT_LIMIT),
            parse_mode: "HTML"
          )]
        end

        # A link when the source carries no secret, otherwise a bare marker. A
        # Telegram file URL embeds the bot token, which is why this checks at
        # all, but the attachment came FROM elsewhere here, so this is mostly
        # future proofing against a source that turns out to be one.
        def attachment_reference(attachment)
          Util::SafeUrl.public(attachment.url) ||
            "[#{attachment.filename || attachment.kind}, could not be relayed]"
        end

        def base_params(endpoint)
          params = { chat_id: endpoint.settings[:chat_id] }
          thread = endpoint.settings[:thread_id]
          params[:message_thread_id] = thread if thread
          params
        end

        # A native reply is only possible when the router managed to translate
        # the parent into THIS endpoint's id space. Sending an untranslated id to
        # Telegram would attach the reply to an unrelated message.
        def reply_id(message, endpoint)
          return nil if message.reply_to.nil?
          return nil unless message.reply_to.endpoint_id == endpoint.id

          message.reply_to.native_id.to_i
        end

        def sender_prefix(message, endpoint)
          # A notice the bridge itself is saying needs no sender label, and a
          # prefix would corrupt the startup banner's format.
          return nil if message.system_notice?
          return nil unless endpoint.settings.fetch(:sender_prefix, true)

          rendered = render_sender_label(message.sender_label)
          return nil if rendered.nil? || rendered.empty?

          separator = endpoint.settings[:sender_separator] || ":"
          return "#{rendered} " if membership_verb(message)

          "#{rendered}#{Rendering::TelegramHtml.escape(separator)}\n"
        end

        # Render the sender label as Telegram HTML. A structured
        # {Core::SenderLabel} bolds ONLY the username; a bare string keeps the
        # whole label bold.
        def render_sender_label(label)
          return nil if label.nil?

          if label.is_a?(Core::SenderLabel)
            label.render(escape: Rendering::TelegramHtml.method(:escape),
                         bold: ->(text) { "<b>#{text}</b>" })
          else
            text = label.to_s
            text.empty? ? nil : "<b>#{Rendering::TelegramHtml.escape(text)}</b>"
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

          "<i>#{verb}</i>"
        end

        def forward_note(message)
          notice = message.forwarded_notice
          return nil if notice.nil?

          "<i>#{Rendering::TelegramHtml.escape(notice)}</i>\n"
        end

        # The thread degradation line, when the bridge asked for one, sitting under
        # the body to reconstruct context the reader lost. The bridge builds the
        # sentence; this only renders it as italic HTML.
        def thread_note(message)
          notice = message.thread_notice
          return nil if notice.nil? || notice.empty?

          "\n<i>#{Rendering::TelegramHtml.escape(notice)}</i>"
        end

        # Truncate on a UTF-16 budget, since that is the unit Telegram counts.
        # Cutting inside an HTML tag would make the whole message unparseable.
        def clamp(html, limit)
          return html if Util::Utf16.length(html) <= limit

          budget = limit - 1
          # Build the boundary table once and binary search it. Re-encoding the
          # prefix at every step is O(n^2) and stalls a room's worker thread for
          # about a second on a 20KB message.
          table = Util::Utf16.boundaries(html)
          cut = Util::Utf16.char_index(budget, table)
          truncated = html[0, cut].to_s

          # Never end inside a tag.
          last_open = truncated.rindex("<")
          last_close = truncated.rindex(">")
          truncated = truncated[0, last_open].to_s if last_open && (last_close.nil? || last_open > last_close)

          close_dangling(truncated) + "…"
        end

        # Close any tags left open by truncation, innermost first, so Telegram's
        # parser accepts the result.
        def close_dangling(html)
          open = []
          html.scan(%r{<(/?)([a-z-]+)[^>]*>}) do |slash, tag|
            if slash.empty?
              open << tag
            elsif open.last == tag
              open.pop
            end
          end
          html + open.reverse.map { |tag| "</#{tag}>" }.join
        end
      end
    end
  end
end
