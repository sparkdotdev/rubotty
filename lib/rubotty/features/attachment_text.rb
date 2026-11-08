# frozen_string_literal: true

module Rubotty
  module Features
    # The text hidden inside a message's photo attachments: whatever a QR code
    # decodes to, and, only when asked for, whatever OCR reads off the image
    # itself. One instance is built per inbound message in {Pipeline#handle} and
    # threaded through every feature's {Context}, so a photo is downloaded,
    # decoded and OCR'd at most once no matter how many filters ask: each pass
    # memoises, and {LinkFilter}/{WordFilter} read through {#text} rather than
    # fetching anything themselves. Every failure degrades to an empty string
    # rather than raising, exactly as a message with no attachments does.
    class AttachmentText
      # However many photo attachments one message's worth of scanning
      # covers, so an album of a dozen photos cannot turn one message into a
      # dozen downloads and OCR passes.
      MAX_ATTACHMENTS = 4

      def initialize(message, logger: nil, fetcher: nil, qr_decoder: nil, ocr_reader: nil)
        @message = message
        @logger = logger
        @fetcher = fetcher || Util::MediaFetcher.new(logger: logger)
        @qr_decoder = qr_decoder || Util::QrDecoder.new(logger: logger)
        @ocr_reader = ocr_reader || Util::OcrReader.new(logger: logger)
        @bytes = {}
      end

      # QR/barcode text decoded from every photo attachment. Always
      # attempted when asked for: cheap next to OCR, and a decoded invite
      # link is exactly what {LinkFilter} exists to catch.
      #
      # @return [String]
      def qr_text
        @qr_text ||= photo_attachments.flat_map do |attachment|
          @qr_decoder.decode(bytes_for(attachment), filename: attachment.filename)
        end.join("\n")
      end

      # OCR'd text from every photo attachment, computed only the first time
      # something actually asks for it: a room with every filter's `ocr`
      # field off never pays for this.
      #
      # @return [String]
      def ocr_text
        @ocr_text ||= photo_attachments.map do |attachment|
          @ocr_reader.read(bytes_for(attachment), filename: attachment.filename)
        end.reject(&:empty?).join("\n")
      end

      # @param ocr [Boolean] whether to include the slower, noisier OCR pass
      #   on top of the QR decode every caller gets
      # @return [String]
      def text(ocr: false)
        return qr_text unless ocr

        [qr_text, ocr_text].reject(&:empty?).join("\n")
      end

      private

      def photo_attachments
        @photo_attachments ||= Array(@message.attachments)
                                .select { |attachment| attachment.kind == :photo && attachment.resolvable? }
                                .first(MAX_ATTACHMENTS)
      end

      # +attachment+'s bytes, downloaded once and reused by both the QR and
      # the OCR pass: {Core::Attachment} is a frozen value object with
      # content equality, so the same photo hashes to the same key even if
      # it somehow appeared twice in {#photo_attachments}.
      #
      # @return [String] the bytes, or "" when the download refused (too
      #   large, unreachable, not public) or raised; {Util::MediaFetcher}
      #   already logs a refusal, so only a raise is logged again here.
      def bytes_for(attachment)
        return @bytes[attachment] if @bytes.key?(attachment)

        @bytes[attachment] = fetch(attachment)
      end

      def fetch(attachment)
        result = ""
        @fetcher.with(attachment.url, filename: attachment.filename) { |file| result = file.read }
        result
      rescue StandardError => e
        @logger&.warn { "attachment_text: could not read a #{attachment.kind} attachment: #{e.class}: #{e.message}" }
        ""
      end
    end
  end
end
