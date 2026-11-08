# frozen_string_literal: true

require "json"
require "tmpdir"

module Rubotty
  module Util
    # Re encodes a video so it fits a platform's upload ceiling, under
    # limits that stop a thin box being taken down by somebody posting a
    # film. Wired in via {Core::VideoRehostRelay}, which registers with the
    # durable scheduler and runs an oversized attachment's transcode off the
    # room worker thread the bridge relays on. Everything that can go wrong
    # (no ffmpeg, no duration, an unreachable bitrate, a busy slot, a
    # timeout, an encoder failure) answers nil, so the caller links the
    # file instead.
    class VideoTranscoder
      FFMPEG = "ffmpeg"
      FFPROBE = "ffprobe"
      BINARIES = [FFMPEG, FFPROBE].freeze

      MIME_PREFIX = "video/"
      MIME_TYPES = %w[video/mp4 video/quicktime video/webm video/x-matroska video/mpeg
                      video/x-msvideo video/3gpp application/mp4].freeze
      EXTENSIONS = %w[.mp4 .mov .webm .mkv .m4v .avi .3gp .mpg .mpeg].freeze

      # These are local attachments, never playlists or manifests that can
      # reference the network or another file. A renamed XML manifest must
      # not reach an XML parser merely because its claimed MIME is video.
      INPUT_CODECS = %w[
        h264 hevc av1 libdav1d libaom-av1 vp8 vp9 libvpx libvpx-vp9
        mpeg1video mpeg2video mpeg4 mjpeg aac aac_fixed aac_latm
        mp3 mp3float mp2 mp2float opus libopus vorbis libvorbis flac alac
        ac3 ac3_fixed eac3 dca pcm_u8 pcm_s16le pcm_s16be pcm_s24le pcm_s24be
        pcm_s32le pcm_s32be pcm_f32le pcm_f32be pcm_f64le pcm_f64be
      ].freeze
      INPUT_OPTIONS = [
        "-codec_whitelist", INPUT_CODECS.join(","),
        "-protocol_whitelist", "file,pipe",
        "-format_whitelist", "mov,matroska,avi,mpeg,mpegts,mpegvideo"
      ].freeze

      # Five at once across the deployment. Enough that a busy evening generally
      # works, few enough that the box survives it.
      DEFAULT_CONCURRENCY = 5

      # Five minutes of wall clock per job, then killed.
      DEFAULT_TIMEOUT = 300

      # Probing is a header read, so it gets a fraction of the budget.
      PROBE_TIMEOUT = 15

      # Bound each decoder, filter pipeline and encoder pool. Defaults based on
      # every host CPU can exhaust the address space ceiling even for a small input.
      THREADS = 2

      # How far below the relay to run. 15 is well down without being starved.
      NICE = 15

      OUTPUT_MIME = "video/mp4"
      OUTPUT_EXTENSION = ".mp4"

      # x264 has no business needing more than this for a bounded frame size.
      MEMORY_BYTES = 1024 * 1024 * 1024

      # A single global gate, because the point is a deployment-wide ceiling and
      # a per instance one would be no ceiling at all.
      SLOTS = Queue.new
      DEFAULT_CONCURRENCY.times { SLOTS << :slot }

      class << self
        def binary(name)
          @binaries ||= {}
          @binaries[name] = executable(name) unless @binaries.key?(name)
          @binaries[name]
        end

        def available? = BINARIES.all? { |name| !binary(name).nil? }

        def missing = BINARIES.reject { |name| binary(name) }

        def reset_binaries! = (@binaries = nil)

        def transcodable?(mime_type: nil, filename: nil)
          type = mime_type.to_s.downcase.split(";").first.to_s.strip
          return MIME_TYPES.include?(type) || type.start_with?(MIME_PREFIX) unless type.empty?

          EXTENSIONS.include?(File.extname(filename.to_s).downcase)
        end

        def executable(name)
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject(&:empty?).find do |dir|
            break File.join(dir, name) if File.executable?(File.join(dir, name))
          end
        end

        # Take one of the deployment's slots, or answer false at once. Never
        # waits: a caller that cannot have a slot now has a link it can use now.
        def claim
          SLOTS.pop(true)
          true
        rescue ThreadError
          false
        end

        def release = SLOTS << :slot

        # How many jobs could start this instant.
        def free_slots = SLOTS.size
      end

      def initialize(ffmpeg: nil, ffprobe: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
        @ffmpeg = ffmpeg || self.class.binary(FFMPEG)
        @ffprobe = ffprobe || self.class.binary(FFPROBE)
        @timeout = timeout
        @logger = logger
      end

      # Re encode +source+ until it fits +ceiling+ bytes, and yield the result.
      #
      # @param source [#read] the original video, positioned at its start
      # @param ceiling [Integer] the target platform's own limit, in bytes
      # @yieldparam [File] the re encoded video, open for reading
      # @return [Object, nil] whatever the block returns, or nil for any of the
      #   reasons in the class note
      def transcode(source, ceiling:, filename: nil)
        return nil if @ffmpeg.nil? || @ffprobe.nil? || ceiling.to_i < 1
        unless self.class.claim
          @logger&.info { "every transcode slot is busy, so a video is being linked instead" }
          return nil
        end

        begin
          run(source, ceiling.to_i, filename) { |file| yield file }
        ensure
          self.class.release
        end
      rescue StandardError => e
        # Deliberately broad: a failure here costs a link, never the message.
        @logger&.warn { "could not shrink a video: #{e.class}: #{e.message}" }
        nil
      end

      private

      def run(source, ceiling, filename)
        Dir.mktmpdir("rubotty-transcode") do |dir|
          input = write_input(dir, source, filename)
          plan = plan_for(input, ceiling)
          next nil if plan.nil?

          output = encode(input, dir, plan)
          next nil if output.nil?
          next nil unless fits?(output, ceiling)

          File.open(output, "rb") { |file| yield file }
        end
      end

      def write_input(dir, source, filename)
        extension = File.extname(filename.to_s)
        extension = OUTPUT_EXTENSION unless EXTENSIONS.include?(extension.downcase)
        path = File.join(dir, "source#{extension}")
        File.open(path, "wb") { |file| IO.copy_stream(source, file) }
        path
      end

      # What to encode at, or nil when this video cannot reach the ceiling at a
      # bitrate worth watching.
      def plan_for(input, ceiling)
        probed = probe(input)
        return nil if probed.nil?

        plan = VideoSizeTarget.for(target_bytes: ceiling, duration: probed[:duration],
                                   height: probed[:height], width: probed[:width],
                                   audio: probed[:audio])
        if plan.nil?
          @logger&.info do
            "a #{probed[:duration].round} second video cannot reach #{ceiling} bytes " \
              "at a watchable bitrate, so it is being linked instead"
          end
        end
        plan
      end

      # Duration, frame size and whether there is any audio to pay for.
      def probe(input)
        argv = [@ffprobe, "-v", "error", "-print_format", "json",
                "-show_entries", "format=duration:stream=codec_type,width,height", *INPUT_OPTIONS, input]
        result = BoundedCommand.new(timeout: PROBE_TIMEOUT, nice: NICE, logger: @logger).run(argv)
        return nil unless result.ok?

        read_probe(result.stdout)
      end

      def read_probe(json)
        parsed = JSON.parse(json.to_s)
        streams = Array(parsed["streams"])
        video = streams.find { |stream| stream["codec_type"] == "video" } || {}
        duration = parsed.dig("format", "duration").to_f
        return nil unless duration.positive?

        { duration: duration, width: video["width"], height: video["height"],
          audio: streams.any? { |stream| stream["codec_type"] == "audio" } }
      rescue JSON::ParserError
        nil
      end

      # Two passes, because a rate controller cannot hit a target size in one:
      # the first pass measures the video and the second spends the budget where
      # the first said it was needed. Both share the one deadline.
      def encode(input, dir, plan)
        output = File.join(dir, "shrunk#{OUTPUT_EXTENSION}")
        log = File.join(dir, "passlog")
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        return nil unless pass(1, input, File::NULL, log, plan, remaining(started))
        return nil unless pass(2, input, output, log, plan, remaining(started))

        File.exist?(output) && File.size(output).positive? ? output : nil
      end

      def remaining(started)
        @timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      end

      def pass(number, input, output, log, plan, budget)
        return false if budget <= 0

        command = BoundedCommand.new(timeout: budget, memory_bytes: MEMORY_BYTES,
                                     nice: NICE, logger: @logger)
        result = command.run(argv(number, input, output, log, plan))
        return true if result.ok?

        @logger&.info { "ffmpeg pass #{number} did not finish: #{result.stderr}" } unless result.timed_out?
        false
      end

      def argv(number, input, output, log, plan)
        common = [
          @ffmpeg, "-y", "-nostdin",
          "-filter_threads", THREADS.to_s, "-filter_complex_threads", THREADS.to_s,
          *INPUT_OPTIONS, "-threads", THREADS.to_s, "-i", input,
          "-threads", THREADS.to_s,
          "-c:v", "libx264", "-preset", "veryfast",
          "-b:v", plan.video_bitrate.to_s,
          "-vf", "scale=-2:#{plan.height}",
          "-pass", number.to_s, "-passlogfile", log
        ]
        return common + ["-an", "-f", "mp4", output] if number == 1

        common + audio_args(plan) + ["-movflags", "+faststart", "-f", "mp4", output]
      end

      def audio_args(plan)
        return ["-an"] if plan.audio_bitrate.zero?

        ["-c:a", "aac", "-b:a", plan.audio_bitrate.to_s]
      end

      # The rate controller aims and sometimes overshoots, so the file is
      # measured rather than assumed. An output over the ceiling gets linked,
      # which is cheaper than watching the platform refuse it.
      def fits?(output, ceiling)
        size = File.size(output)
        return true if size <= ceiling

        @logger&.info do
          "a transcode came out at #{size} bytes against a #{ceiling} byte ceiling, " \
            "so it is being linked instead"
        end
        false
      end
    end
  end
end
