# frozen_string_literal: true

require "set"

module Rubotty
  module Security
    # Which content types a browser may render in place when the bytes came
    # from outside: the portal shares a hostname with the dashboard, so a
    # declared text/html served inline could run script against the
    # dashboard's origin and cookie. The gate is an allow list of exact
    # types; anything else is served as a download.
    module ServedTypes
      # What an unrecognised or malformed type becomes.
      DEFAULT = "application/octet-stream"

      # Exact types only, all lowercase. image/svg+xml is deliberately
      # absent, since an SVG is a scripting context, and so is
      # application/pdf, which can navigate and submit forms from a viewer
      # the page does not control.
      INLINE = Set.new(
        %w[
          image/apng image/avif image/bmp image/gif image/jpeg image/png image/webp
          audio/aac audio/flac audio/mp4 audio/mpeg audio/ogg audio/wav audio/webm
          video/mp4 video/ogg video/quicktime video/webm
          text/plain
        ]
      ).freeze

      # A type is stored and compared without its parameters, so a charset cannot
      # smuggle one type past a comparison against another.
      GRAMMAR = %r{\A[a-z0-9][a-z0-9!\#$&^_.+-]{0,62}/[a-z0-9][a-z0-9!\#$&^_.+-]{0,62}\z}

      module_function

      # +type+ reduced to a bare lowercase type/subtype, or {DEFAULT} when it is
      # blank, over-long or not a well-formed media type.
      def normalise(type)
        text = type.to_s.split(";").first.to_s.strip.downcase
        return DEFAULT unless text.match?(GRAMMAR)

        text
      end

      # Whether a browser may render +type+ in place.
      def inline?(type) = INLINE.include?(normalise(type))

      # The Content-Disposition disposition for +type+.
      def disposition(type) = inline?(type) ? "inline" : "attachment"

      # +type+ if the allow list carries it, {DEFAULT} otherwise. Both the store
      # and the serve route go through this, so a row written before the allow
      # list existed is still announced as bytes today.
      def allowed(type)
        normalised = normalise(type)
        INLINE.include?(normalised) ? normalised : DEFAULT
      end
    end
  end
end
