# frozen_string_literal: true

module Rubotty
  module Util
    # Picks the extension a rehosted file's download url ends in, and splits
    # that url's own token back apart on the way in. The extension exists
    # only so a human or a chat client's link preview has something to
    # glance at; it is never trusted for a serving decision, since the guest
    # portal route recomputes it from what {ControlPlane::RehostedFiles}
    # actually has and 404s a url whose extension disagrees.
    module FileExtension
      # A filename's own extension is kept only when it looks like one: short
      # and alphanumeric, nothing a path or a query string could hide inside.
      SAFE = /\A\.[a-zA-Z0-9]{1,10}\z/

      # What a type nothing below recognises, or no filename at all, becomes.
      # Matches {Security::ServedTypes::DEFAULT}'s own fallback.
      FALLBACK = "bin"

      # Common types a rehosted file arrives as. Not exhaustive: an unlisted
      # type still gets a url, it just ends in {FALLBACK} instead of something
      # more specific.
      BY_CONTENT_TYPE = {
        "image/jpeg" => "jpg", "image/pjpeg" => "jpg", "image/png" => "png",
        "image/gif" => "gif", "image/webp" => "webp", "image/bmp" => "bmp",
        "image/svg+xml" => "svg", "image/heic" => "heic", "image/heif" => "heif",
        "image/avif" => "avif", "image/apng" => "apng", "image/tiff" => "tiff",
        "image/x-icon" => "ico",
        "audio/mpeg" => "mp3", "audio/mp4" => "m4a", "audio/aac" => "aac",
        "audio/ogg" => "ogg", "audio/wav" => "wav", "audio/x-wav" => "wav",
        "audio/webm" => "weba", "audio/flac" => "flac",
        "video/mp4" => "mp4", "video/webm" => "webm", "video/quicktime" => "mov",
        "video/x-matroska" => "mkv", "video/mpeg" => "mpg", "video/x-msvideo" => "avi",
        "video/3gpp" => "3gp", "video/ogg" => "ogv",
        "application/pdf" => "pdf", "application/zip" => "zip",
        "application/x-7z-compressed" => "7z", "application/vnd.rar" => "rar",
        "application/gzip" => "gz", "application/json" => "json",
        "text/plain" => "txt", "text/csv" => "csv",
        "application/msword" => "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => "docx",
        "application/vnd.ms-excel" => "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" => "xlsx",
        "application/vnd.ms-powerpoint" => "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation" => "pptx"
      }.freeze

      module_function

      # The extension a download url for this file should end in, with no
      # leading dot. The filename's own extension wins when it looks safe to
      # reuse; otherwise the content type names one, and {FALLBACK} covers
      # whatever neither does.
      def for(filename: nil, content_type: nil)
        from_name = File.extname(filename.to_s)
        return from_name.delete_prefix(".").downcase if SAFE.match?(from_name)

        normalised = content_type.to_s.split(";").first.to_s.strip.downcase
        BY_CONTENT_TYPE[normalised] || FALLBACK
      end

      # Splits "<secret>.<ext>" into its two halves, +ext+ downcased and
      # carrying no leading dot. Either half is nil when the token has no dot
      # to split on, or the dot leaves one side empty.
      def split(token)
        text = token.to_s
        dot = text.rindex(".")
        return [nil, nil] if dot.nil? || dot.zero? || dot == text.length - 1

        [text[0...dot], text[(dot + 1)..].downcase]
      end
    end
  end
end
