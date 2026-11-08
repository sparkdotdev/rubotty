# frozen_string_literal: true

module Rubotty
  module Util
    # Recognises URLs that carry a credential, so they are never logged, relayed or
    # handed to a third party to fetch. Telegram's file API embeds the bot token in
    # the path, making such a URL a working credential for the whole bot.
    module SafeUrl
      # Telegram bot tokens are `<numeric id>:<secret>` and the file endpoint spells
      # them `/bot<token>/`. Matching the numeric id and colon keeps a Discord CDN
      # attachment named `bot.png` relayable.
      TELEGRAM_FILE = %r{/bot\d+:[\w-]+}i

      # Defence in depth, in case the shape of a token ever changes.
      TELEGRAM_FILE_HOST = %r{\Ahttps?://[^/]*api\.telegram\.org/file/}i

      REDACTED = "<redacted>"

      module_function

      # Does this URL embed a secret?
      #
      # @param url [String, nil]
      # @return [Boolean]
      def credentialed?(url)
        return false if url.nil?

        text = url.to_s
        TELEGRAM_FILE.match?(text) || TELEGRAM_FILE_HOST.match?(text)
      end

      # The URL if it is safe to show a third party, otherwise nil: nil
      # rather than a redacted string, so the caller says something
      # meaningful instead. A blank or whitespace only URL is treated the
      # same as nil, so a caller's `public(url) || fallback` pattern falls
      # back for that case too.
      #
      # @return [String, nil]
      def public(url)
        return nil if url.nil? || url.to_s.strip.empty? || credentialed?(url)

        url
      end

      # A form safe to write to a log, keeping enough shape to debug with.
      def redact(url)
        return url if url.nil?

        url.to_s
           .gsub(TELEGRAM_FILE) { "/bot#{REDACTED}" }
           .sub(%r{(api\.telegram\.org/file/)(?!bot#{Regexp.escape(REDACTED)})[^\s]*}i) { "#{Regexp.last_match(1)}#{REDACTED}" }
      end
    end
  end
end
