# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"

# ffmpeg and ffprobe are stood in for by shell scripts, so the bounds, the two
# passes and the fallbacks are all exercised without an encoder on the machine
# and without a single example taking longer than a moment.
RSpec.describe Rubotty::Util::VideoTranscoder do
  around do |example|
    Dir.mktmpdir("rubotty-transcode-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  # Every slot back, whatever an example did with them.
  after { described_class.free_slots.upto(described_class::DEFAULT_CONCURRENCY - 1) { described_class.release } }

  def script(name, body)
    path = File.join(@dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def fake_ffprobe(duration: 30.0, width: 1920, height: 1080, audio: true, fail: false)
    streams = [{ codec_type: "video", width: width, height: height }]
    streams << { codec_type: "audio" } if audio
    payload = { streams: streams, format: { duration: duration.to_s } }.to_json
    script("ffprobe", fail ? "exit 1" : "cat <<'JSON'\n#{payload}\nJSON")
  end

  # Records each pass's arguments and writes +bytes+ on the second one, which is
  # the pass that produces the file.
  def fake_ffmpeg(bytes: "encoded video", sleep_for: nil, fail_on: nil)
    log = File.join(@dir, "ffmpeg.log")
    script("ffmpeg", <<~SH)
      printf '%s\\n' "$*" >> #{log}
      printf '%s\\0' "$@" >> #{log}.args
      printf '\\0' >> #{log}.args
      #{sleep_for ? "sleep #{sleep_for}" : ""}
      pass=$(printf '%s\\n' "$@" | grep -A1 -x -- '-pass' | tail -1)
      #{fail_on ? "[ \"$pass\" = \"#{fail_on}\" ] && exit 1" : ""}
      if [ "$pass" = "2" ]; then
        out=$(printf '%s\\n' "$@" | tail -1)
        printf '%s' '#{[bytes].pack("m0")}' | base64 -d > "$out"
      fi
      exit 0
    SH
    [File.join(@dir, "ffmpeg"), log]
  end

  def passes(log) = File.exist?(log) ? File.read(log).lines.map(&:strip) : []

  def pass_arguments(log)
    File.binread("#{log}.args").split("\0\0").map { |args| args.split("\0") }
  end

  def transcoder(ffmpeg:, ffprobe: nil, timeout: 20)
    described_class.new(ffmpeg: ffmpeg, ffprobe: ffprobe || fake_ffprobe,
                        timeout: timeout, logger: Rubotty::Log.null)
  end

  def transcode(subject, bytes: "source clip", ceiling: 10 * 1024 * 1024)
    subject.transcode(StringIO.new(bytes), ceiling: ceiling, filename: "clip.mp4") do |file|
      [file.read, file.size]
    end
  end

  describe ".transcodable?" do
    it "takes the video containers a platform actually plays" do
      expect(described_class.transcodable?(mime_type: "video/mp4")).to be(true)
      expect(described_class.transcodable?(mime_type: "video/quicktime")).to be(true)
      expect(described_class.transcodable?(filename: "CLIP.MOV")).to be(true)
    end

    it "leaves stills and documents alone" do
      expect(described_class.transcodable?(mime_type: "image/jpeg")).to be(false)
      expect(described_class.transcodable?(filename: "contract.pdf")).to be(false)
    end
  end

  describe "the bounds it runs under" do
    # Five at once across the deployment, not one and not one per room.
    it "offers five slots by default and hands them out without waiting" do
      expect(described_class::DEFAULT_CONCURRENCY).to eq(5)
      expect(described_class.free_slots).to eq(5)

      5.times { expect(described_class.claim).to be(true) }
      expect(described_class.free_slots).to be_zero
      expect(described_class.claim).to be(false)
    end

    it "gives a slot back when a transcode finishes" do
      ffmpeg, = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg))

      expect(described_class.free_slots).to eq(described_class::DEFAULT_CONCURRENCY)
    end

    # A sixth video links immediately rather than queueing behind five others,
    # since the link is available now and a queue is a slower way to be late.
    it "answers nil at once rather than waiting when every slot is taken" do
      ffmpeg, log = fake_ffmpeg
      described_class::DEFAULT_CONCURRENCY.times { described_class.claim }

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(transcode(transcoder(ffmpeg: ffmpeg))).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(passes(log)).to be_empty
    end

    # Five concurrent jobs each spawning a thread per core is how a thin box
    # ends up thrashing, so each job is told how many it may have.
    it "caps decoder and encoder threads on their respective sides of the input" do
      ffmpeg, log = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg))

      expect(described_class::THREADS).to eq(2)
      arguments = pass_arguments(log)
      expect(arguments.length).to eq(2)
      arguments.each do |args|
        positions = args.each_index.select { |index| args[index] == "-threads" }
        expect(positions.length).to eq(2)
        expect(positions.first).to be < args.index("-i")
        expect(positions.last).to be > args.index("-i")
        expect(positions.map { |index| args[index + 1] }).to eq(%w[2 2])
      end
    end

    it "bounds both filter pools rather than inheriting the host CPU count" do
      ffmpeg, log = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg))

      arguments = pass_arguments(log)
      expect(arguments.length).to eq(2)
      arguments.each do |args|
        %w[-filter_threads -filter_complex_threads].each do |option|
          position = args.index(option)
          expect(position).not_to be_nil
          expect(args[position + 1]).to eq("2")
          expect(position).to be < args.index("-i")
        end
      end
    end

    it "runs below the relay, so the two never want the same core equally" do
      expect(described_class::NICE).to be_positive
    end

    it "holds one job to five minutes of wall clock by default" do
      expect(described_class::DEFAULT_TIMEOUT).to eq(300)
    end

    # Both passes share one budget, so a slow first pass cannot buy the second
    # one a fresh five minutes.
    it "kills a run that overruns the deadline and gives the slot back" do
      ffmpeg, = fake_ffmpeg(sleep_for: 30)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(transcode(transcoder(ffmpeg: ffmpeg, timeout: 0.5))).to be_nil
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      expect(described_class.free_slots).to eq(described_class::DEFAULT_CONCURRENCY)
    end
  end

  describe "the encode itself" do
    # One pass cannot hit a target size, which is the entire reason two pass
    # exists. The first measures the video and the second spends the budget.
    it "runs two passes, and only the second writes a file" do
      ffmpeg, log = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg))
      first, second = passes(log)

      expect(passes(log).length).to eq(2)
      expect(first).to include("-pass 1")
      expect(second).to include("-pass 2")
      expect(first).to include("-an")
    end

    it "restricts both encoder passes to local movie containers" do
      ffmpeg, log = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg))

      passes(log).each do |line|
        expect(line).to include("-protocol_whitelist file,pipe")
        expect(line).to include("-codec_whitelist ")
        expect(line).to include("-format_whitelist mov,matroska,avi,mpeg,mpegts,mpegvideo")
        expect(line.index("-format_whitelist")).to be < line.index("-i ")
      end
    end

    it "applies the same input restrictions before probing an attachment" do
      log = File.join(@dir, "probe-options")
      probe = script("ffprobe", <<~SH)
        printf '%s\\n' "$@" > #{log}
        printf '%s' '{"format":{"duration":"30"},"streams":[{"codec_type":"video","width":640,"height":480}]}'
      SH
      ffmpeg, = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg, ffprobe: probe))

      args = File.readlines(log, chomp: true)
      expect(args[args.index("-protocol_whitelist") + 1]).to eq("file,pipe")
      expect(args[args.index("-format_whitelist") + 1].split(",")).not_to include("dash", "hls", "concat")
      expect(args.index("-format_whitelist")).to be < args.length - 1
      codecs = args[args.index("-codec_whitelist") + 1].split(",")
      expect(codecs).to include("h264", "hevc", "aac", "vp9", "opus")
      expect(codecs).not_to include("cfhd", "rasc", "adpcm_adx", "mace6", "h264_cuvid")
    end

    # -fs looks like a target size and is not: ffmpeg stops writing when it
    # reaches the number, so the video simply ends part way through.
    it "never asks ffmpeg to truncate the output at a size" do
      ffmpeg, log = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg))

      expect(passes(log).join(" ").split).not_to include("-fs")
    end

    it "encodes at the bitrate and the height the arithmetic asked for" do
      ffmpeg, log = fake_ffmpeg
      probe = fake_ffprobe(duration: 60.0, width: 1920, height: 1080)
      transcode(transcoder(ffmpeg: ffmpeg, ffprobe: probe), ceiling: 10 * 1024 * 1024)

      plan = Rubotty::Util::VideoSizeTarget.for(target_bytes: 10 * 1024 * 1024, duration: 60.0,
                                                width: 1920, height: 1080)
      expect(passes(log).first).to include("-b:v #{plan.video_bitrate}")
      expect(passes(log).first).to include("-vf scale=-2:#{plan.height}")
      expect(passes(log).last).to include("-b:a #{plan.audio_bitrate}")
    end

    it "hands back the encoded bytes and their real size" do
      ffmpeg, = fake_ffmpeg(bytes: "smaller clip")

      expect(transcode(transcoder(ffmpeg: ffmpeg))).to eq(["smaller clip", 12])
    end

    it "pays nothing for audio on a video that has none" do
      ffmpeg, log = fake_ffmpeg
      transcode(transcoder(ffmpeg: ffmpeg, ffprobe: fake_ffprobe(audio: false)))

      expect(passes(log).last).to include("-an")
      expect(passes(log).last).not_to include("-c:a")
    end
  end

  describe "when it gives up" do
    it "gives up when either pass fails" do
      first_failed, = fake_ffmpeg(fail_on: 1)
      expect(transcode(transcoder(ffmpeg: first_failed))).to be_nil

      second_failed, = fake_ffmpeg(fail_on: 2)
      expect(transcode(transcoder(ffmpeg: second_failed))).to be_nil
    end

    it "gives up when the probe cannot say how long the video is" do
      ffmpeg, log = fake_ffmpeg
      subject = transcoder(ffmpeg: ffmpeg, ffprobe: fake_ffprobe(fail: true))

      expect(transcode(subject)).to be_nil
      expect(passes(log)).to be_empty
    end

    # A video too long to reach the ceiling at a watchable bitrate is refused
    # before ffmpeg is started at all.
    it "gives up before encoding when the arithmetic refuses the target" do
      ffmpeg, log = fake_ffmpeg
      subject = transcoder(ffmpeg: ffmpeg, ffprobe: fake_ffprobe(duration: 7200.0))

      expect(transcode(subject, ceiling: 2 * 1024 * 1024)).to be_nil
      expect(passes(log)).to be_empty
    end

    # Two pass aims and sometimes overshoots, so the file is measured rather
    # than assumed to have obeyed.
    it "measures the output and refuses one that came back over the ceiling" do
      ffmpeg, = fake_ffmpeg(bytes: "x" * 5_000)

      expect(transcode(transcoder(ffmpeg: ffmpeg), ceiling: 1_000)).to be_nil
    end

    it "answers nil rather than spawning anything with no ffmpeg installed" do
      expect(described_class.new(ffmpeg: nil, ffprobe: nil)
        .transcode(StringIO.new("x"), ceiling: 1000) { |f| f }).to be_nil
      expect(described_class.free_slots).to eq(described_class::DEFAULT_CONCURRENCY)
    end
  end

  describe ".available?" do
    after { described_class.reset_binaries! }

    it "names what is missing, so a boot warning can say which one" do
      described_class.reset_binaries!
      previous = ENV.fetch("PATH", nil)
      ENV["PATH"] = File.join(@dir, "empty")

      expect(described_class).not_to be_available
      expect(described_class.missing).to eq(%w[ffmpeg ffprobe])
    ensure
      ENV["PATH"] = previous
    end
  end
end
