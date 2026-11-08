# frozen_string_literal: true

module Rubotty
  module Util
    # Works out what bitrate and resolution a video has to be encoded at to
    # land under a byte ceiling, or says it cannot be. ffmpeg has no "make
    # this N MB" flag (+-fs+ just stops writing mid-file), so instead:
    #
    #   video_bitrate = (target_bytes * 8 * SAFETY) / duration - audio_bitrate
    #
    # The frame steps down the {HEIGHTS} ladder until the bitrate clears its
    # floor, answering nil (link instead) when even the smallest fails.
    class VideoSizeTarget
      # Container overhead and the overshoot a rate controller allows itself.
      # 0.93 is inside the 0.92 to 0.95 that leaves room for both without
      # throwing away quality that could have been spent.
      SAFETY = 0.93

      # Frame heights to try, tallest first. Width follows the source's aspect
      # ratio, so only the height is decided here.
      HEIGHTS = [1080, 720, 480, 360].freeze

      # Bits per pixel per second below which x264 on a fast preset stops
      # producing something worth watching: under this the frame steps down
      # instead, since a smaller sharp picture beats a larger smeared one.
      # Works out at roughly 1.2 Mbps for 1080p, 550 kbps for 720p and
      # 250 kbps for 480p.
      FLOOR_BITS_PER_PIXEL = 0.6

      # Never encode video below this whatever the arithmetic says.
      MIN_VIDEO_BITRATE = 120_000

      # What a speech-and-general-video AAC track costs. Taken off the top
      # because audio that breaks up is worse than a slightly softer picture.
      DEFAULT_AUDIO_BITRATE = 96_000

      # A video with no audio stream pays nothing for one.
      SILENT_AUDIO_BITRATE = 0

      # Assumed when the source does not say how tall it is, so the ladder still
      # has somewhere to start.
      DEFAULT_HEIGHT = 1080

      # 16:9, for turning a height into a pixel count when the source did not say
      # how wide it is.
      DEFAULT_ASPECT = 16.0 / 9

      # What to encode at. Nil is never one of these: {.for} answers nil instead.
      Plan = Struct.new(:video_bitrate, :audio_bitrate, :height, keyword_init: true) do
        # The total the two streams are aiming at, which is what the output
        # should come in near.
        def total_bitrate = video_bitrate + audio_bitrate
      end

      class << self
        # @param duration [Numeric] seconds. A video whose duration is unknown
        #   cannot be planned for, since the whole sum divides by it.
        # @param width [Integer, nil] the source's frame width, for the pixel
        #   count the quality floor is measured against
        # @return [Plan, nil] nil when no height on the ladder can be encoded
        #   above the floor, which means this file should be linked
        def for(target_bytes:, duration:, height: nil, width: nil, audio: true)
          budget = usable_bits(target_bytes)
          seconds = duration.to_f
          return nil if budget < 1 || seconds <= 0

          audio_bitrate = audio ? DEFAULT_AUDIO_BITRATE : SILENT_AUDIO_BITRATE
          available = (budget / seconds).floor - audio_bitrate
          return nil if available < MIN_VIDEO_BITRATE

          plan_for(available, audio_bitrate, height, width)
        end

        # The bits a file of +target_bytes+ may spend, after the margin.
        def usable_bits(target_bytes) = (target_bytes.to_i * 8 * SAFETY).floor

        # The lowest bitrate worth encoding a +height+ tall frame at.
        def floor_for(height, aspect = DEFAULT_ASPECT)
          pixels = height * (height * aspect)
          [(pixels * FLOOR_BITS_PER_PIXEL).round, MIN_VIDEO_BITRATE].max
        end

        private

        # Step down the ladder until the bitrate on offer clears that frame's
        # floor. Nothing above the source's own height is ever tried: upscaling
        # spends bits inventing detail that was never there.
        def plan_for(available, audio_bitrate, height, width)
          aspect = aspect_of(height, width)
          chosen = heights_for(height).find { |candidate| available >= floor_for(candidate, aspect) }
          return nil if chosen.nil?

          Plan.new(video_bitrate: available, audio_bitrate: audio_bitrate, height: chosen)
        end

        # Never taller than the source, since upscaling spends bits inventing
        # detail that was never there, and never taller than the top rung. A 900
        # tall clip is tried at 900 before it is tried at 720.
        def heights_for(height)
          source = height.to_i.positive? ? height.to_i : DEFAULT_HEIGHT
          capped = [source, HEIGHTS.first].min
          ([capped] + HEIGHTS.select { |candidate| candidate < capped }).uniq
        end

        def aspect_of(height, width)
          return DEFAULT_ASPECT unless height.to_i.positive? && width.to_i.positive?

          width.to_f / height
        end
      end
    end
  end
end
