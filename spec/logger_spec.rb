# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Rubotty::RingBuffer do
  subject(:buffer) { described_class.new(capacity: 3) }

  def formatted(severity, msg, time: Time.utc(2026, 7, 27, 12, 0, 0))
    "#{time.iso8601} #{severity.ljust(5)} #{msg}\n"
  end

  it "stores a formatted line, parsing its timestamp and level back out" do
    buffer << formatted("WARN", "something happened")
    entry = buffer.entries.first
    expect(entry[:level]).to eq("WARN")
    expect(entry[:time]).to eq(Time.utc(2026, 7, 27, 12, 0, 0))
    expect(entry[:text]).to include("something happened")
  end

  it "keeps only the most recent `capacity` entries, oldest dropped first" do
    4.times { |i| buffer << formatted("INFO", "line #{i}") }
    expect(buffer.entries.map { |e| e[:text] }).to eq(
      [formatted("INFO", "line 1").chomp, formatted("INFO", "line 2").chomp, formatted("INFO", "line 3").chomp]
    )
  end

  it "is a no-op for a blank line" do
    buffer << "\n"
    expect(buffer.entries).to be_empty
  end

  it "stores an unparseable line rather than dropping it, with a nil time and level" do
    buffer << "not in the expected shape\n"
    entry = buffer.entries.first
    expect(entry[:level]).to be_nil
    expect(entry[:time]).to be_nil
    expect(entry[:text]).to eq("not in the expected shape")
  end

  describe "#entries" do
    before do
      buffer << formatted("DEBUG", "debug line")
      buffer << formatted("INFO", "info line")
      buffer << formatted("ERROR", "error line")
    end

    it "filters to a level and anything more severe, not an exact match" do
      levels = buffer.entries(level: "info").map { |e| e[:level] }
      expect(levels).to eq(%w[INFO ERROR])
    end

    it "caps to the last N entries" do
      expect(buffer.entries(limit: 2).map { |e| e[:level] }).to eq(%w[INFO ERROR])
    end
  end

  it "is thread-safe under concurrent writes" do
    buffer = described_class.new(capacity: 1000)
    threads = Array.new(20) { |t| Thread.new { 20.times { |i| buffer << formatted("INFO", "t#{t}-#{i}") } } }
    threads.each(&:join)
    expect(buffer.entries.size).to eq(400)
  end
end

RSpec.describe Rubotty::TeeIO do
  it "writes through to the underlying IO and appends to the ring buffer" do
    io = StringIO.new
    buffer = Rubotty::RingBuffer.new
    tee = described_class.new(io, buffer)

    tee.write("2026-07-27T12:00:00Z WARN  hello\n")

    expect(io.string).to eq("2026-07-27T12:00:00Z WARN  hello\n")
    expect(buffer.entries.first[:text]).to include("hello")
  end
end

RSpec.describe Rubotty::Log do
  describe ".build with a ring_buffer" do
    it "tees every logged line into the buffer while still writing to io" do
      io = StringIO.new
      buffer = Rubotty::RingBuffer.new
      logger = described_class.build(level: "info", io: io, ring_buffer: buffer)

      logger.warn { "disk is getting full" }

      expect(io.string).to include("disk is getting full")
      entry = buffer.entries.first
      expect(entry[:level]).to eq("WARN")
      expect(entry[:text]).to include("disk is getting full")
    end

    it "writes only to io, with no buffer at all, when ring_buffer is omitted" do
      io = StringIO.new
      logger = described_class.build(level: "info", io: io)
      logger.info { "ordinary line" }
      expect(io.string).to include("ordinary line")
    end
  end
end
