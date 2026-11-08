# frozen_string_literal: true

require "spec_helper"
require "open3"
require "stringio"
require "tmpdir"
require "zlib"

RSpec.describe "Media parser restrictions" do
  around do |example|
    Dir.mktmpdir("rubotty-media-policy") do |dir|
      @dir = dir
      example.run
    end
  end

  def input(name, bytes)
    File.join(@dir, name).tap { |path| File.binwrite(path, bytes) }
  end

  def chunk(kind, bytes)
    [bytes.bytesize].pack("N") + kind + bytes + [Zlib.crc32(kind + bytes)].pack("N")
  end

  def png
    "\x89PNG\r\n\x1a\n".b + chunk("IHDR", [8, 8, 8, 2, 0, 0, 0].pack("NNC5")) +
      chunk("IDAT", Zlib.deflate(("\0" + "\x40\x80\xc0".b * 8) * 8)) + chunk("IEND", "")
  end

  def convert(bytes)
    skip "ImageMagick is not installed" unless Rubotty::Util::ImageShrinker.available?

    command = Rubotty::Util::BoundedCommand.new(timeout: 10)
    command.run([Rubotty::Util::ImageShrinker.binary, input("claimed.png", bytes), File.join(@dir, "result.jpg")])
  end

  it "converts an ordinary PNG through the real raster policy" do
    skip "ImageMagick is not installed" unless Rubotty::Util::ImageShrinker.available?

    result = Rubotty::Util::ImageShrinker.new.shrink(StringIO.new(png), ceiling: 100_000, filename: "photo.png") do |file|
      Rubotty::Util::ImageShrinker.metadata_free?(file.path)
    end

    expect(result).to be(true)
  end

  it "refuses an EXR header disguised with a PNG filename before decoding it" do
    policy = File.read(File.join(Rubotty::Util::BoundedCommand::IMAGE_POLICY_DIRECTORY, "policy.xml"))
    expect(policy).to include('<policy domain="module" rights="none" pattern="*"/>')
    expect(policy).not_to match(/domain="module" rights="read \| write" pattern="[^"]*\bEXR\b/)
    installed = raster_decoder?("EXR")

    result = convert([0x01312f76, 2].pack("V2") + "\0")

    expect(result.ok?).to be(false)
    expect(File.exist?(File.join(@dir, "result.jpg"))).to be(false)
    if installed
      expect(result.stderr).to match(/security policy|not authorized/i)
      expect(result.stderr).to include("EXR")
    else
      expect(result.stderr).to match(/no decode delegate|no decoder|unrecognized image format|improper image header/i)
    end
  end

  def raster_decoder?(name)
    skip "ImageMagick is not installed" unless Rubotty::Util::ImageShrinker.available?

    # Listing through the application's policy hides forbidden modules. Query
    # only installed format metadata with an empty configuration directory;
    # actual input conversion above always uses the enforced application policy.
    result = Rubotty::Util::BoundedCommand.new(timeout: 10).run([
      "env", "MAGICK_CONFIGURE_PATH=#{@dir}", Rubotty::Util::ImageShrinker.binary, "-list", "format"
    ])
    expect(result.ok?).to be(true), result.stderr
    result.stdout.match?(/^\s*#{Regexp.escape(name)}\*?\s/)
  end

  it "refuses XML vector input disguised with a PNG filename" do
    result = convert('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>')

    expect(result.ok?).to be(false)
    expect(result.stderr).to match(/security policy|not authorized/i)
  end

  def probe(bytes, format:)
    binary = Rubotty::Util::VideoTranscoder.binary(Rubotty::Util::VideoTranscoder::FFPROBE)
    skip "ffprobe is not installed" if binary.nil?

    Rubotty::Util::BoundedCommand.new(timeout: 10).run([
      binary, "-v", "error", "-f", format, *Rubotty::Util::VideoTranscoder::INPUT_OPTIONS, input("claimed.mp4", bytes)
    ])
  end

  it "refuses a DASH XML manifest even when its parser is explicitly selected" do
    binary = Rubotty::Util::VideoTranscoder.binary(Rubotty::Util::VideoTranscoder::FFPROBE)
    skip "ffprobe is not installed" if binary.nil?

    formats = Rubotty::Util::BoundedCommand.new(timeout: 10).run([binary, "-hide_banner", "-demuxers"])
    expect(formats.ok?).to be(true), formats.stderr
    dash = formats.stdout.lines.any? { |line| line.split[0] == "D" && line.split[1].to_s.split(",").include?("dash") }
    result = probe('<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT1S"><Period/></MPD>', format: "dash")

    expect(result.ok?).to be(false)
    expect(result.stdout).to be_empty
    if dash
      expect(result.stderr).to match(/not on whitelist/i)
    else
      expect(result.stderr).to match(/unknown input format|demuxer not found/i)
    end
  end

  it "refuses a local-file playlist disguised with a movie filename" do
    result = probe("#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXTINF:1,\nfile:///nonexistent-media-fixture\n#EXT-X-ENDLIST\n", format: "hls")

    expect(result.ok?).to be(false)
    expect(result.stderr).to match(/not on whitelist/i)
  end

  it "refuses a legacy AVI decoder even inside an allowed movie container" do
    skip "ffmpeg and ffprobe are not installed" unless Rubotty::Util::VideoTranscoder.available?

    original = File.join(@dir, "legacy.avi")
    _out, error, status = Open3.capture3(
      Rubotty::Util::VideoTranscoder.binary(Rubotty::Util::VideoTranscoder::FFMPEG),
      "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=10",
      "-t", "1", "-c:v", "cfhd", "-pix_fmt", "yuv422p10le", original
    )
    expect(status.success?).to be(true), error
    result = Rubotty::Util::BoundedCommand.new(timeout: 10).run([
      Rubotty::Util::VideoTranscoder.binary(Rubotty::Util::VideoTranscoder::FFPROBE),
      "-v", "error", *Rubotty::Util::VideoTranscoder::INPUT_OPTIONS, original
    ])

    expect(result.stderr).to match(/cfhd.*not on.*whitelist/i)
    result = File.open(original, "rb") do |source|
      Rubotty::Util::VideoTranscoder.new.transcode(source, ceiling: 1_000_000, filename: "legacy.avi") { true }
    end
    expect(result).to be_nil
  end

  it "still probes and converts a real local MP4" do
    skip "ffmpeg and ffprobe are not installed" unless Rubotty::Util::VideoTranscoder.available?

    original = File.join(@dir, "original.mp4")
    _out, error, status = Open3.capture3(
      Rubotty::Util::VideoTranscoder.binary(Rubotty::Util::VideoTranscoder::FFMPEG),
      "-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi", "-i", "color=c=blue:s=64x64:r=10",
      "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", original
    )
    expect(status.success?).to be(true), error
    result = File.open(original, "rb") do |source|
      Rubotty::Util::VideoTranscoder.new.transcode(source, ceiling: 1_000_000, filename: "original.mp4") do |file|
        file.size
      end
    end

    expect(result).to be_a(Integer)
    expect(result).to be_between(1, 1_000_000)
  end
end
