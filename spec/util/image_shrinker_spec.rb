# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# The shrinker is driven here by a stand-in for ImageMagick rather than the real
# thing, so the suite is the same everywhere and no example waits on a real
# encoder. What is real is everything around it: the spawn, the deadline, the
# kill, the ladder, and the metadata check the output has to pass.
RSpec.describe Rubotty::Util::ImageShrinker do
  around do |example|
    Dir.mktmpdir("rubotty-shrinker-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  # A JPEG built segment by segment, so an example can say exactly what metadata
  # the encoder is pretending to have left behind.
  def jpeg(segments: [], padding: 0)
    body = segments.map { |code, content| [0xFF, code].pack("C2") + [content.bytesize + 2].pack("n") + content }
    scan = "\xFF\xDA".b + [12].pack("n") + ("\x00".b * (10 + padding)) + "\xFF\xD9".b
    "\xFF\xD8".b + body.join.b + scan
  end

  def jfif = [0xE0, "JFIF\0\x01\x02\0\0\x01\0\x01\0\0"]

  # APP1, which is where a camera writes the GPS coordinates a photo was taken at.
  def exif = [0xE1, "Exif\0\0#{"\x00" * 60}"]

  # A shell script standing in for `magick`. It writes +writes+ (a hash of ladder
  # edge to output bytes) and records every argument list it was given.
  def fake_magick(writes:, sleep_for: nil, exit_code: 0)
    log = File.join(@dir, "argv.log")
    script = File.join(@dir, "fake-magick")
    payloads = writes.transform_values { |bytes| [bytes].pack("m0") }
    File.write(script, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{log}
      #{sleep_for ? "sleep #{sleep_for}" : ""}
      edge=$(printf '%s\\n' "$@" | grep -E '^[0-9]+x[0-9]+>$' | head -1 | cut -dx -f1)
      out=$(printf '%s\\n' "$@" | grep '^JPEG:' | sed 's/^JPEG://')
      case "$edge" in
      #{payloads.map { |edge, b64| "  #{edge}) printf '%s' '#{b64}' | base64 -d > \"$out\" ;;" }.join("\n")}
      esac
      exit #{exit_code}
    SH
    File.chmod(0o755, script)
    [script, log]
  end

  def argv_lines(log) = File.exist?(log) ? File.read(log).lines.map(&:strip) : []

  def shrink(shrinker, bytes: "original", ceiling: 1000, filename: "holiday.jpg")
    shrinker.shrink(StringIO.new(bytes), ceiling: ceiling, filename: filename) do |file|
      [file.read, file.size]
    end
  end

  describe ".shrinkable?" do
    it "takes the still raster formats a platform actually renders" do
      expect(described_class.shrinkable?(mime_type: "image/jpeg")).to be(true)
      expect(described_class.shrinkable?(mime_type: "image/png; charset=binary")).to be(true)
      expect(described_class.shrinkable?(filename: "SCREENSHOT.WEBP")).to be(true)
    end

    # Flattening an animation to one frame loses the thing that made it worth
    # sending, so it is linked whole instead.
    it "leaves animation and video alone" do
      expect(described_class.shrinkable?(mime_type: "image/gif")).to be(false)
      expect(described_class.shrinkable?(mime_type: "video/mp4")).to be(false)
      expect(described_class.shrinkable?(filename: "clip.mp4")).to be(false)
    end

    it "reads the name only when the platform said nothing about the type" do
      expect(described_class.shrinkable?(mime_type: "application/octet-stream",
                                         filename: "a.jpg")).to be(false)
      expect(described_class.shrinkable?(mime_type: "", filename: "a.jpg")).to be(true)
    end
  end

  describe ".metadata_free?" do
    def written(content)
      path = File.join(@dir, "sample-#{rand(1 << 32)}.jpg")
      File.binwrite(path, content)
      path
    end

    it "passes a JPEG carrying nothing but its JFIF header" do
      expect(described_class.metadata_free?(written(jpeg(segments: [jfif])))).to be(true)
    end

    # The whole reason to prefer shrinking a photo over linking it: the EXIF
    # block, and the GPS fix inside it, does not survive the re encode.
    it "refuses one that still carries an EXIF block" do
      expect(described_class.metadata_free?(written(jpeg(segments: [jfif, exif])))).to be(false)
    end

    it "refuses an ICC profile and a comment as well" do
      icc = [0xE2, "ICC_PROFILE\0#{"\x00" * 20}"]
      comment = [0xFE, "taken on a phone"]

      expect(described_class.metadata_free?(written(jpeg(segments: [jfif, icc])))).to be(false)
      expect(described_class.metadata_free?(written(jpeg(segments: [jfif, comment])))).to be(false)
    end

    it "refuses anything it cannot read as a JPEG at all" do
      expect(described_class.metadata_free?(written("this is not an image"))).to be(false)
      expect(described_class.metadata_free?(File.join(@dir, "absent.jpg"))).to be(false)
    end
  end

  describe "#shrink" do
    it "asks for a strip, and asks for the orientation first so it survives it" do
      binary, log = fake_magick(writes: { 2048 => jpeg(segments: [jfif]) })

      shrink(described_class.new(binary: binary, logger: Rubotty::Log.null))
      args = argv_lines(log).first.split

      expect(args).to include("-strip")
      expect(args.index("-auto-orient")).to be < args.index("-strip")
      expect(args).to include("-resize", "2048x2048>")
      expect(args).to include("-quality", "85")
    end

    it "hands back the re encoded bytes and their real size" do
      small = jpeg(segments: [jfif])
      binary, = fake_magick(writes: { 2048 => small })

      expect(shrink(described_class.new(binary: binary, logger: Rubotty::Log.null),
                    ceiling: small.bytesize + 100))
        .to eq([small, small.bytesize])
    end

    # The encoder is never trusted to have hit a size: every rung is measured,
    # which is what makes this work the same on any build of ImageMagick.
    it "measures each rung rather than asking the encoder to hit a target" do
      binary, log = fake_magick(writes: { 2048 => jpeg(padding: 4000, segments: [jfif]) })

      expect(shrink(described_class.new(binary: binary, logger: Rubotty::Log.null), ceiling: 200))
        .to be_nil
      expect(argv_lines(log).first).not_to include("extent")
    end

    # A photo whose detail will not compress drops the quality, then the
    # dimensions, before the whole thing is given up on.
    it "walks down the dimension and quality ladder until something fits" do
      binary, log = fake_magick(
        writes: { 2048 => jpeg(padding: 4000, segments: [jfif]), 1600 => jpeg(segments: [jfif]) }
      )

      result = shrink(described_class.new(binary: binary, logger: Rubotty::Log.null), ceiling: 200)
      tried = argv_lines(log).map { |line| line.split }

      expect(result).not_to be_nil
      # 2048 at 85, 2048 again at 70, then 1600 at 70, which is the one that fits.
      expect(tried.length).to eq(3)
      expect(tried.map { |args| args[args.index("-quality") + 1] }).to eq(%w[85 70 70])
    end

    it "spends dimensions before quality, so a picture stays sharp while it can" do
      expect(described_class::LADDER.first).to eq([2048, 85])
      expect(described_class::LADDER.map(&:first)).to eq(described_class::LADDER.map(&:first).sort.reverse)
      expect(described_class::LADDER.map(&:last)).to eq(described_class::LADDER.map(&:last).sort.reverse)
    end

    it "gives up when nothing on the ladder comes under the ceiling" do
      writes = described_class::LADDER.to_h { |edge, _| [edge, jpeg(padding: 9000)] }
      binary, log = fake_magick(writes: writes)

      expect(shrink(described_class.new(binary: binary, logger: Rubotty::Log.null), ceiling: 200))
        .to be_nil
      expect(argv_lines(log).length).to eq(described_class::LADDER.length)
    end

    # -strip is asked for, and then the answer is read back. A build of
    # ImageMagick that ignored it would have its output refused rather than a
    # relayed photo quietly keeping the coordinates it was taken at.
    it "refuses an output that came back still carrying EXIF" do
      binary, = fake_magick(writes: { 2048 => jpeg(segments: [jfif, exif]) })

      expect(shrink(described_class.new(binary: binary, logger: Rubotty::Log.null))).to be_nil
    end

    it "gives up when the encoder refuses the file" do
      binary, = fake_magick(writes: { 2048 => jpeg(segments: [jfif]) }, exit_code: 1)

      expect(shrink(described_class.new(binary: binary, logger: Rubotty::Log.null))).to be_nil
    end

    # The deadline is what stops a decoder handed something pathological from
    # holding the room worker it is running on.
    it "kills a child that overruns its deadline and answers nil" do
      binary, = fake_magick(writes: { 2048 => jpeg(segments: [jfif]) }, sleep_for: 30)
      shrinker = described_class.new(binary: binary, timeout: 0.4, logger: Rubotty::Log.null)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(shrink(shrinker)).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
    end

    it "answers nil rather than spawning anything when there is no binary" do
      expect(described_class.new(binary: nil).shrink(StringIO.new("x"), ceiling: 100) { |f| f })
        .to be_nil
    end

    it "answers nil for a target with no ceiling to aim at" do
      binary, log = fake_magick(writes: { 2048 => jpeg(segments: [jfif]) })

      expect(shrink(described_class.new(binary: binary), ceiling: 0)).to be_nil
      expect(argv_lines(log)).to be_empty
    end
  end

  describe ".binary" do
    after { described_class.reset_binary! }

    it "finds the ImageMagick 7 name in PATH ahead of the 6 one" do
      %w[magick convert].each do |name|
        path = File.join(@dir, name)
        File.write(path, "#!/bin/sh\n")
        File.chmod(0o755, path)
      end
      described_class.reset_binary!

      with_path(@dir) { expect(described_class.binary).to eq("magick") }
    end

    # A deployment whose image has no ImageMagick reports so, and the caller
    # links the file instead of discovering it at the first oversized photo.
    it "answers nil, and unavailable, when neither name is installed" do
      described_class.reset_binary!

      with_path(File.join(@dir, "empty")) do
        expect(described_class.binary).to be_nil
        expect(described_class).not_to be_available
      end
    end
  end

  def with_path(dir)
    previous = ENV.fetch("PATH", nil)
    ENV["PATH"] = dir
    yield
  ensure
    ENV["PATH"] = previous
  end
end
