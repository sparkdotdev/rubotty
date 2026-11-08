# frozen_string_literal: true

module Rubotty
  module Core
    # A file travelling with a message.
    #
    # An attachment carries either a resolvable +url+ or a +native_ref+ that only
    # means something on the originating platform (a Telegram file_id). Adapters
    # prefer +url+ when relaying to a different platform.
    class Attachment
      # Broad categories every platform can map onto. The renderer picks a send
      # method from this, falling back to :document.
      KINDS = %i[photo video audio voice document sticker animation video_note].freeze

      attr_reader :kind, :url, :native_ref, :filename, :mime_type, :size, :caption,
                  :width, :height, :duration, :emoji, :animated

      def initialize(kind:, url: nil, native_ref: nil, filename: nil, mime_type: nil, size: nil,
                     caption: nil, width: nil, height: nil, duration: nil, emoji: nil, animated: false)
        @kind = kind.to_sym
        @url = url
        @native_ref = native_ref
        @filename = filename
        @mime_type = mime_type
        @size = size
        @caption = caption
        @width = width
        @height = height
        @duration = duration
        @emoji = emoji
        @animated = !!animated
        freeze
      end

      def animated? = @animated

      # False for nil, and also for an empty or whitespace only string: that is
      # what {Util::MediaFetcher#fetch} already treats as unusable, and the two
      # have to agree or an attachment passes this filter and dies silently in
      # the fetcher instead of taking the reference path.
      def resolvable? = !url.to_s.strip.empty?

      # Human readable label for when a target platform cannot carry the file.
      def label
        filename || emoji || kind.to_s
      end

      # A copy with some fields replaced. Frozen, so every change is a new one.
      def with(**changes) = self.class.new(**to_h, **changes)

      def with_url(new_url) = with(url: new_url)

      def to_h
        {
          kind: kind, url: url, native_ref: native_ref, filename: filename, mime_type: mime_type,
          size: size, caption: caption, width: width, height: height, duration: duration,
          emoji: emoji, animated: animated
        }
      end

      def ==(other) = other.is_a?(Attachment) && other.to_h == to_h
      alias eql? ==

      def hash = to_h.hash
    end
  end
end
