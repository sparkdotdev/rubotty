# frozen_string_literal: true

require "logger"
require "time"

module Rubotty
  # Thin wrapper over stdlib Logger. Heroku and Coolify collect stdout, so that
  # is the default sink and there is no file logging or rotation.
  module Log
    LEVELS = {
      "debug" => ::Logger::DEBUG,
      "info" => ::Logger::INFO,
      "warn" => ::Logger::WARN,
      "error" => ::Logger::ERROR,
      "fatal" => ::Logger::FATAL
    }.freeze

    module_function

    # @param level [String, Symbol]
    # @param io [IO]
    # @param ring_buffer [RingBuffer, nil] when given, every formatted line is
    #   also appended here as well as written to +io+
    # @return [::Logger]
    def build(level: "info", io: $stdout, ring_buffer: nil)
      logger = ::Logger.new(ring_buffer ? TeeIO.new(io, ring_buffer) : io)
      logger.level = LEVELS.fetch(level.to_s.downcase, ::Logger::INFO)
      logger.formatter = proc do |severity, time, progname, msg|
        prefix = progname ? "[#{progname}] " : ""
        "#{time.utc.iso8601} #{severity.ljust(5)} #{prefix}#{msg}\n"
      end
      logger
    end

    # A logger that prefixes every line with a component name, without a new
    # sink.
    def tagged(logger, tag)
      TaggedLogger.new(logger, tag)
    end

    # A logger that discards everything, for specs and for embedders with their
    # own logging.
    def null
      build(level: "fatal", io: IO::NULL)
    end
  end

  # Delegates to a real logger, adding a component tag.
  class TaggedLogger
    def initialize(logger, tag)
      @logger = logger
      @tag = tag
    end

    %i[debug info warn error fatal].each do |level|
      define_method(level) do |message = nil, &block|
        @logger.public_send(level, @tag) { block ? block.call : message }
      end
    end

    def level = @logger.level

    def debug? = @logger.debug?

    def tagged(sub) = TaggedLogger.new(@logger, "#{@tag}.#{sub}")
  end

  # Wraps an IO so every #write also appends the text to a {RingBuffer} before
  # writing through unchanged.
  class TeeIO
    def initialize(io, ring_buffer)
      @io = io
      @ring_buffer = ring_buffer
    end

    def write(message)
      @ring_buffer << message
      @io.write(message)
    end

    def close
      @io.close
    end
  end

  # A bounded, thread-safe store of recently-logged lines, what {Log.build} tees
  # into when given a ring_buffer. In-memory and per-process, so a restart clears
  # it.
  class RingBuffer
    DEFAULT_CAPACITY = 500

    # Matches {Log.build}'s formatter output, "<iso8601> <SEVERITY> <rest>".
    LINE = /\A(\S+)\s+(\S+)\s+(.*)\z/m

    # @param capacity [Integer] how many recent lines to keep before the oldest
    #   is dropped
    def initialize(capacity: DEFAULT_CAPACITY)
      @capacity = capacity
      @entries = []
      @mutex = Mutex.new
    end

    # Append one already-formatted log line, newline included, as Logger hands it
    # to a LogDevice. A blank flush is a no-op rather than an empty entry.
    #
    # @param line [String]
    def <<(line)
      text = line.to_s.chomp
      return self if text.empty?

      @mutex.synchronize do
        @entries << parse(text)
        @entries.shift if @entries.size > @capacity
      end
      self
    end

    # The stored entries, oldest first, optionally filtered to +level+ and
    # anything more severe, capped to the last +limit+ of those.
    #
    # @param level [String, Symbol, nil]
    # @param limit [Integer, nil]
    # @return [Array<Hash>] { time: Time|nil, level: String|nil, text: String }
    def entries(level: nil, limit: nil)
      snapshot = @mutex.synchronize { @entries.dup }
      if level
        floor = Log::LEVELS.fetch(level.to_s.downcase, 0)
        snapshot = snapshot.select { |entry| entry[:level] && Log::LEVELS.fetch(entry[:level].downcase, 0) >= floor }
      end
      limit ? snapshot.last(limit.to_i) : snapshot
    end

    private

    def parse(text)
      match = LINE.match(text)
      return { time: nil, level: nil, text: text } unless match

      time = begin
        Time.iso8601(match[1])
      rescue ArgumentError
        nil
      end
      # A leading token that is not a real timestamp means the line was never in
      # {Log.build}'s shape, so the level match[2] captured is discarded too.
      return { time: nil, level: nil, text: text } if time.nil?

      { time: time, level: match[2], text: text }
    end
  end
end
