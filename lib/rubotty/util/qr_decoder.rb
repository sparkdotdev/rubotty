# frozen_string_literal: true

require "tmpdir"

module Rubotty
  module Util
    # Decodes a QR (or other barcode) out of a still image via libzbar, the
    # C library the zbar gem binds through FFI. libzbar only reads its own
    # raw formats directly, so every image is normalised to PGM with
    # ImageMagick first, reusing {ImageShrinker}'s magick/convert lookup.
    #
    # `require "zbar"` raises LoadError at load time when libzbar is not on
    # the host. {.available?} makes that require exactly once, remembering
    # the answer and logging the miss for the life of the process.
    class QrDecoder
      # Wall clock and address space for the ImageMagick conversion: one
      # image, not {ImageShrinker}'s ladder, so both are smaller.
      TIMEOUT = 10
      MEMORY_BYTES = 256 * 1024 * 1024

      class << self
        # @return [Boolean] whether libzbar loaded. Computed once; a miss is
        #   remembered rather than re-probed on every photo.
        def available?(logger: nil)
          return @available if defined?(@available)

          ensure_zbar_lib_env
          require "zbar"
          @available = true
        rescue LoadError => e
          logger&.warn { "QR decoding unavailable: #{e.message.to_s.lines.first&.strip}" }
          @available = false
        end

        # Only a spec needs this: forget a cached answer, including a cached
        # absence.
        def reset_availability!
          remove_instance_variable(:@available) if defined?(@available)
        end

        private

        # The zbar gem resolves libzbar through a glob of hardcoded multiarch
        # triplets that covers x86_64 and i386 but not aarch64, so an ARM64
        # host with libzbar0 installed still fails to load it. ldconfig
        # knows the real path on any architecture; this runs once, and
        # leaves ENV['ZBAR_LIB'] alone if already set.
        def ensure_zbar_lib_env
          return if ENV["ZBAR_LIB"]
          return unless RUBY_PLATFORM.include?("linux")

          found = `ldconfig -p 2>/dev/null`.lines.find { |line| line.include?("libzbar.so") }
          ENV["ZBAR_LIB"] = found.split("=> ").last.to_s.strip if found
        rescue StandardError
          nil
        end
      end

      def initialize(logger: nil, image_binary: nil, command: nil)
        @logger = logger
        @image_binary = image_binary || ImageShrinker.binary
        @command = command || BoundedCommand.new(timeout: TIMEOUT, memory_bytes: MEMORY_BYTES, logger: logger)
      end

      # @param bytes [String] raw image bytes, any format ImageMagick reads
      # @param filename [String, nil] only used to give the input an
      #   extension, since some decoders want one
      # @return [Array<String>] every string a code in the image decodes to;
      #   [] when libzbar or ImageMagick is unavailable, the image carries no
      #   code, or anything about it fails
      def decode(bytes, filename: nil)
        return [] if bytes.to_s.empty?
        return [] unless self.class.available?(logger: @logger)
        return [] if @image_binary.nil?

        pgm = to_pgm(bytes, filename)
        return [] if pgm.nil?

        ZBar::Image.from_pgm(pgm).process.filter_map do |symbol|
          data = symbol.data.to_s
          data unless data.empty?
        end
      rescue StandardError => e
        @logger&.warn { "QR decode failed: #{e.class}: #{e.message}" }
        []
      end

      private

      # @return [String, nil] the converted image's raw PGM bytes, or nil
      #   when ImageMagick refused the input or ran past its deadline
      def to_pgm(bytes, filename)
        Dir.mktmpdir("rubotty-qr") do |dir|
          input = write_input(dir, bytes, filename)
          output = File.join(dir, "source.pgm")
          result = @command.run([@image_binary, "#{input}[0]", "-colorspace", "Gray", "-depth", "8", output])
          next nil unless result.ok? && File.exist?(output) && !File.empty?(output)

          File.binread(output)
        end
      end

      def write_input(dir, bytes, filename)
        extension = File.extname(filename.to_s)
        extension = "" unless ImageShrinker::EXTENSIONS.include?(extension.downcase)
        path = File.join(dir, "source#{extension}")
        File.binwrite(path, bytes)
        path
      end
    end
  end
end
