# frozen_string_literal: true

require "tmpdir"

module Rubotty
  module Util
    # Reads image text in a separate, bounded process. Its environment excludes
    # platform credentials, and its deadline, memory and output bounds match
    # the other native media tools. Availability checks do not fork while a
    # writable database connection is open.
    class OcrReader
      BINARY = "tesseract"
      DEFAULT_TIMEOUT = 20
      MEMORY_BYTES = 512 * 1024 * 1024

      class << self
        def available?(logger: nil)
          return @available if defined?(@available)

          @available = executable?(BINARY)
          logger&.warn { "OCR unavailable: no #{BINARY} binary found on PATH" } unless @available
          @available
        end

        # Only a spec needs this: forget a cached answer, including a cached
        # absence.
        def reset_availability!
          remove_instance_variable(:@available) if defined?(@available)
        end

        private

        def executable?(name)
          ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).reject(&:empty?).any? do |dir|
            File.executable?(File.join(dir, name))
          end
        end
      end

      def initialize(logger: nil, language: "eng", timeout: DEFAULT_TIMEOUT, command: nil)
        @logger = logger
        @language = language
        @command = command || BoundedCommand.new(timeout: timeout, memory_bytes: MEMORY_BYTES,
                                                  nice: 15, logger: logger)
      end

      # @param bytes [String] raw image bytes
      # @param filename [String, nil] only used to give the input an
      #   extension
      # @return [String] the text tesseract reads off the image, "" when
      #   tesseract is unavailable, the image carries no readable text, or
      #   anything about it fails
      def read(bytes, filename: nil)
        return "" if bytes.to_s.empty?
        return "" unless self.class.available?(logger: @logger)

        Dir.mktmpdir("rubotty-ocr") do |dir|
          path = write_input(dir, bytes, filename)
          result = @command.run([BINARY, path, "stdout", "-l", @language])
          result.ok? ? result.stdout.to_s.strip : ""
        end
      rescue StandardError => e
        @logger&.warn { "OCR failed: #{e.class}: #{e.message}" }
        ""
      end

      private

      def write_input(dir, bytes, filename)
        extension = File.extname(filename.to_s)
        extension = ".png" if extension.empty?
        path = File.join(dir, "source#{extension}")
        File.binwrite(path, bytes)
        path
      end
    end
  end
end
