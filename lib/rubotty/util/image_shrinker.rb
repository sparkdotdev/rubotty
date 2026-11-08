# frozen_string_literal: true

require "tmpdir"

module Rubotty
  module Util
    # Re encodes an image so it fits a platform's upload ceiling, by handing
    # it to ImageMagick in a child process with a deadline. Output is always
    # JPEG, the one format every platform renders and whose encoder can be
    # aimed at a byte size; +-strip+ removes every profile and EXIF tag, a
    # privacy guarantee documented in PRIVACY.md. Nothing here raises at its
    # caller: a missing binary, an unsupported format, a picture that will
    # not come down far enough, or an overrun deadline all answer nil, and
    # the caller links the file instead.
    class ImageShrinker
      # ImageMagick 7 installs "magick"; 6 installs "convert". Either will do.
      BINARIES = %w[magick convert].freeze

      # Still raster formats only. Animation is absent on purpose: flattening a
      # GIF to one frame loses the thing that made it worth sending, so an
      # animated file falls through to being linked.
      MIME_TYPES = %w[
        image/jpeg image/pjpeg image/png image/webp image/heic image/heif
        image/avif image/bmp image/tiff image/x-tiff
      ].freeze

      EXTENSIONS = %w[.jpg .jpeg .png .webp .heic .heif .avif .bmp .tif .tiff].freeze

      # Longest edge in pixels, then JPEG quality, walked in this order until
      # something comes in under the ceiling. Dimensions first because losing
      # pixels a phone screen was never going to show costs less than smearing
      # the ones that are left, and the output is measured after every rung
      # rather than the encoder being trusted to have hit a target.
      LADDER = [
        [2048, 85], [2048, 70], [1600, 70], [1280, 65], [1024, 60], [800, 55]
      ].freeze

      # Wall clock for one invocation. Generous for a resize of a phone photo and
      # short enough that a room worker never notices it went away.
      DEFAULT_TIMEOUT = 20

      # Address space for the child. A decoder handed a deliberately enormous
      # canvas is the thing this stops.
      MEMORY_BYTES = 512 * 1024 * 1024

      OUTPUT_MIME = "image/jpeg"
      OUTPUT_EXTENSION = ".jpg"

      # JPEG's start of image, start of scan and end of image.
      SOI = "\xFF\xD8"
      SOS = 0xDA
      EOI = 0xD9

      class << self
        # @return [String, nil] the binary to run, or nil when neither is here
        def binary
          @binary = BINARIES.find { |name| executable?(name) } unless defined?(@binary)
          @binary
        end

        def available? = !binary.nil?

        # Forget the cached answer, including a cached absence. Only tests need
        # this: the cache keeps a PATH walk out of every relayed photo.
        def reset_binary!
          remove_instance_variable(:@binary) if defined?(@binary)
        end

        # Whether this is a format worth handing to ImageMagick at all, decided
        # from what the platform said and then from the name.
        def shrinkable?(mime_type: nil, filename: nil)
          type = mime_type.to_s.downcase.split(";").first.to_s.strip
          return MIME_TYPES.include?(type) unless type.empty?

          EXTENSIONS.include?(File.extname(filename.to_s).downcase)
        end

        # Walked in Ruby rather than through `command -v`, which is a shell
        # builtin with no binary behind it on a Debian image.
        def executable?(name)
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject(&:empty?).any? do |dir|
            File.executable?(File.join(dir, name))
          end
        end

        # Whether a JPEG came out of the encoder carrying no metadata: this is
        # what turns the privacy claim into something checked rather than
        # trusted, since -strip is asked for and then the answer is read back
        # before the picture is allowed anywhere; a file that somehow kept its
        # EXIF is refused and the caller links it instead. APP0 (JFIF) says
        # nothing about provenance; every other APPn does (APP1 is EXIF/XMP,
        # APP2 is ICC, APP13 is IPTC), and so does a comment segment.
        def metadata_free?(path)
          File.open(path, "rb") { |file| walk_segments(file) }
        rescue StandardError
          false
        end

        private

        def walk_segments(file)
          return false unless file.read(2) == SOI.b

          loop do
            marker = file.read(2)
            # Anything unparseable stops the walk rather than passing the file:
            # the point is to be sure, and a truncated header is not sure.
            return false if marker.nil? || marker.bytesize < 2 || marker.getbyte(0) != 0xFF

            code = marker.getbyte(1)
            # From the scan onwards it is entropy coded pixels, not segments.
            return true if [SOS, EOI].include?(code)
            return false if metadata_segment?(code)

            length = file.read(2)
            return false if length.nil? || length.bytesize < 2

            file.seek(length.unpack1("n") - 2, IO::SEEK_CUR)
          end
        end

        def metadata_segment?(code) = code.between?(0xE1, 0xEF) || code == 0xFE
      end

      # @param binary [String, nil] the ImageMagick executable to spawn.
      #   Defaults to whichever of {BINARIES} is on PATH.
      def initialize(binary: nil, timeout: DEFAULT_TIMEOUT, logger: nil)
        @binary = binary || self.class.binary
        @logger = logger
        @command = BoundedCommand.new(timeout: timeout, memory_bytes: MEMORY_BYTES, logger: logger)
      end

      attr_reader :binary

      # Re encode +source+ until it fits +ceiling+ bytes, and yield the result.
      #
      # @param filename [String, nil] only used to give the input an extension,
      #   since some decoders want one
      # @yieldparam [File] the re encoded image, open for reading
      # @return [Object, nil] whatever the block returns, or nil when the image
      #   could not be brought under the ceiling
      def shrink(source, ceiling:, filename: nil)
        return nil if @binary.nil? || ceiling.to_i < 1

        Dir.mktmpdir("rubotty-shrink") do |dir|
          input = write_input(dir, source, filename)
          output = attempt_ladder(input, dir, ceiling.to_i)
          next nil if output.nil?

          File.open(output, "rb") { |file| yield file }
        end
      rescue StandardError => e
        # Deliberately broad: a failure here costs a link, never the message.
        @logger&.warn { "could not shrink an image: #{e.class}: #{e.message}" }
        nil
      end

      private

      def write_input(dir, source, filename)
        extension = File.extname(filename.to_s)
        extension = "" unless EXTENSIONS.include?(extension.downcase)
        path = File.join(dir, "source#{extension}")
        File.open(path, "wb") { |file| IO.copy_stream(source, file) }
        path
      end

      # @return [String, nil] the path of the first output that fits and carries
      #   no metadata
      def attempt_ladder(input, dir, ceiling)
        LADDER.each_with_index do |(edge, quality), index|
          output = File.join(dir, "shrunk-#{index}#{OUTPUT_EXTENSION}")
          next unless run(argv(input, output, edge, quality))
          next unless File.exist?(output) && File.size(output).positive?
          next unless File.size(output) <= ceiling
          return output if metadata_free?(output)
        end
        @logger&.info { "an image would not come under #{ceiling} bytes, so it is being linked instead" }
        nil
      end

      # A picture that came back still carrying its EXIF is refused rather than
      # relayed, since dropping it is half the reason to choose this path.
      def metadata_free?(output)
        return true if self.class.metadata_free?(output)

        @logger&.warn { "a re encoded image still carried metadata, so it is being linked instead" }
        false
      end

      # +[0]+ takes the first frame only, so a multi page TIFF cannot turn one
      # attachment into a directory of them. -auto-orient has to run before
      # -strip, since it is the EXIF orientation tag that -strip then removes.
      def argv(input, output, edge, quality)
        [
          @binary, "#{input}[0]",
          "-auto-orient",
          "-strip",
          "-resize", "#{edge}x#{edge}>",
          "-quality", quality.to_s,
          "-sampling-factor", "4:2:0",
          "-interlace", "none",
          "JPEG:#{output}"
        ]
      end

      # Spawned rather than shelled out to, so a path ImageMagick reads as an
      # option or a filename with a space in it is an argument and nothing else.
      def run(argv)
        result = @command.run(argv)
        return true if result.ok?

        @logger&.info { "#{@binary} refused an image: #{result.stderr}" } unless result.timed_out?
        false
      end
    end
  end
end
