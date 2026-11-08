# frozen_string_literal: true

require "digest"

module Rubotty
  module Watchdog
    # The cross-channel duplicate watchdog. Each qualifying message records a
    # sighting keyed on (community, author identity, content digest) and gets back
    # how many distinct channels carried that fingerprint inside the window.
    #
    # Only the digest is stored, never the text, and sightings expire on the TTL.
    class Multipost < Base
      # The distinct-channel count at which copies start being removed, counting the
      # first post.
      DEFAULT_CHANNEL_THRESHOLD = 2

      # How long a prior post in another channel still counts, in seconds.
      DEFAULT_WINDOW_SECONDS = 300

      # Ignore messages whose normalised text is shorter than this, so "thanks" in a
      # couple of channels is not a cross-post drop.
      DEFAULT_MIN_LENGTH = 10

      # The reason shown to the author, overridable per scope via `removal_reason`.
      REASON = "Posting the same message across multiple channels is not allowed."

      # @param storage the fingerprint store; the sighting record and the
      #   distinct-channel count are one atomic call
      # @param clock [#call] returns the current Time; injected in tests
      def initialize(storage:, clock: -> { Time.now })
        super()
        @storage = storage
        @clock = clock
      end

      def name = "multipost"

      def evaluate(context)
        threshold = channel_threshold(context.config)
        # A threshold of one cannot tell a cross-post from a single post, so stay
        # inert rather than removing every message.
        return Verdict.pass if threshold <= 1

        message = context.message
        author = author_identity(message)
        return Verdict.pass if author.nil?

        normalised = normalise(message.body&.text)
        return Verdict.pass if normalised.length < min_length(context.config)

        channels = @storage.record_multipost(
          community: community_key(context),
          author: author,
          fingerprint: fingerprint(normalised),
          channel: message.origin.id,
          now: @clock.call,
          window_seconds: window_seconds(context.config)
        )
        return Verdict.pass if channels < threshold

        Verdict.remove(reason_for(context.config), metadata: { channels: channels, threshold: threshold })
      end

      private

      # The author's platform-stable identity, "adapter:native_id", matching the
      # anti-spam engine's per-author key.
      def author_identity(message)
        author = message.author
        return nil if author.nil? || author.native_id.nil?

        "#{message.origin.adapter_name}:#{author.native_id}"
      end

      # Fold case and collapse whitespace so reformatting the same payload is
      # still recognised.
      def normalise(text)
        text.to_s.strip.downcase.gsub(/\s+/, " ")
      end

      # A fixed-width key that never stores the message content itself.
      def fingerprint(normalised)
        Digest::SHA256.hexdigest(normalised)
      end

      # The owning community's slug, or "" without a control plane, never NULL,
      # so the storage key cannot split on distinct-NULL semantics.
      def community_key(context)
        context.community&.slug.to_s
      end

      # The per-scope `removal_reason` override, or {REASON} when it is unset.
      def reason_for(config)
        override = config_value(config, :removal_reason)
        override.nil? || override.to_s.strip.empty? ? REASON : override.to_s
      end

      def channel_threshold(config)
        integer(config_value(config, :channel_threshold), default: DEFAULT_CHANNEL_THRESHOLD)
      end

      def window_seconds(config)
        duration(config_value(config, :window_seconds), default: DEFAULT_WINDOW_SECONDS)
      end

      def min_length(config)
        integer(config_value(config, :min_length), default: DEFAULT_MIN_LENGTH)
      end

      # Read one key from the resolved config, tolerating symbol or string keys.
      def config_value(config, key)
        return nil unless config.is_a?(Hash)

        config.key?(key) ? config[key] : config[key.to_s]
      end

      def integer(value, default:)
        return default if value.nil?
        return value if value.is_a?(Integer)
        return value.to_i if value.is_a?(String) && value.match?(/\A-?\d+\z/)

        default
      end

      def duration(value, default:)
        return default if value.nil?

        seconds = Core::Warnings.duration_seconds(value)
        seconds.nil? ? default : seconds
      end
    end
  end
end
