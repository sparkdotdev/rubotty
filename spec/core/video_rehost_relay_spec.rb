# frozen_string_literal: true

require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require "securerandom"

# ffmpeg and ffprobe are stood in for by shell scripts, the same technique
# spec/util/video_transcoder_spec.rb uses, so the whole background half runs
# with no encoder on the machine and no example waiting on a real one.
RSpec.describe Rubotty::Core::VideoRehostRelay do
  include Builders

  class VideoListScheduler
    Job = Struct.new(:kind, :run_at, :payload, :community, keyword_init: true)

    def initialize
      @jobs = []
      @handler = nil
    end

    attr_reader :jobs

    def register(kind, max_age: nil, priority: nil, &block)
      @handler = block
      self
    end

    def schedule(kind:, run_at:, payload: {}, community: nil, recurrence: nil)
      @jobs << Job.new(kind: kind.to_s, run_at: run_at, payload: payload, community: community)
    end

    def run_all
      @jobs.shift.tap { |job| @handler.call(job) } until @jobs.empty?
    end
  end

  # Rubotty::ControlPlane::RehostedFiles's #store_file contract, without a
  # database or a real object store behind it. Stored#file carries just enough
  # of the real row, filename and content_type, for download_url to pick an
  # extension the way it does off the real thing.
  class FakeFiles
    Row = Struct.new(:filename, :content_type)
    Stored = Struct.new(:secret, :file)

    def initialize
      @calls = []
    end

    attr_reader :calls

    def store_file(**kwargs)
      @calls << kwargs
      Stored.new(SecureRandom.hex(8), Row.new(kwargs[:filename], kwargs[:content_type]))
    end
  end

  # Util::MediaFetcher's #with(url, filename:) contract, without a network.
  # Named for this file, since a class opened in a describe block is top
  # level and spec/features/file_rehosting_spec.rb declares its own.
  class VideoFakeFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  around do |example|
    Dir.mktmpdir("rubotty-video-relay-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  # Every slot back, whatever an example did with them: the same cleanup
  # spec/util/video_transcoder_spec.rb runs, since {Util::VideoTranscoder::SLOTS}
  # is one queue shared by every spec in the process.
  after do
    ceiling = Rubotty::Util::VideoTranscoder::DEFAULT_CONCURRENCY - 1
    Rubotty::Util::VideoTranscoder.free_slots.upto(ceiling) { Rubotty::Util::VideoTranscoder.release }
  end

  def script(name, body)
    path = File.join(@dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def fake_ffprobe(duration: 30.0, width: 1920, height: 1080)
    payload = { streams: [{ codec_type: "video", width: width, height: height }],
               format: { duration: duration.to_s } }.to_json
    script("ffprobe", "cat <<'JSON'\n#{payload}\nJSON")
  end

  def fake_ffmpeg(bytes: "smaller clip", fail: false)
    script("ffmpeg", <<~SH)
      pass=$(printf '%s\\n' "$@" | grep -A1 -x -- '-pass' | tail -1)
      #{fail ? "exit 1" : ""}
      if [ "$pass" = "2" ]; then
        out=$(printf '%s\\n' "$@" | tail -1)
        printf '%s' '#{[bytes].pack("m0")}' | base64 -d > "$out"
      fi
      exit 0
    SH
  end

  def transcoder(bytes: "smaller clip", fail: false, ffprobe: nil)
    Rubotty::Util::VideoTranscoder.new(
      ffmpeg: fake_ffmpeg(bytes: bytes, fail: fail), ffprobe: ffprobe || fake_ffprobe,
      logger: Rubotty::Log.null
    )
  end

  # One class per edit capability, the same shape file_rehosting_strategy_spec's
  # own bounded_adapter takes.
  def bounded_adapter(edits: true)
    Class.new(Fakes::RecordingAdapter) do
      define_method(:capabilities) do
        @capabilities ||= Rubotty::Adapters::Capabilities.new(edits: edits, deletes: true)
      end
    end
  end

  let(:ep) { endpoint("dc", adapter: :fake, account: "default") }
  let(:room_obj) { room("r", ep) }
  let(:topology_obj) { topology(room_obj) }
  let(:adapter) { bounded_adapter.new }
  let(:adapters) { { [:fake, "default"] => adapter } }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:scheduler) { VideoListScheduler.new }
  let(:files) { FakeFiles.new }
  let(:payload_bytes) { "original clip bytes" }

  def clip
    Rubotty::Core::Attachment.new(
      kind: :video, url: "https://cdn.example.test/clip.mp4", filename: "clip.mp4",
      mime_type: "video/mp4", size: 30 * 1024 * 1024
    )
  end

  def relay(video_transcoder: transcoder)
    described_class.new(
      scheduler: scheduler, transcoder: video_transcoder, files: files, storage: storage,
      topology: topology_obj, adapters: adapters, loop_guard: loop_guard,
      fetcher_for: ->(_limit) { VideoFakeFetcher.new(payload_bytes) }, logger: Rubotty::Log.null,
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  # The plain text a real notice_line arrives as: Features::Bridge only ever
  # hands VideoRehostRelay the flattened #to_s of whatever AttachmentRehoster
  # built, never the RichText itself.
  def default_notice_line
    "https://rubotty.test/filestorage/old.mp4 (File re-hosted automatically by Rubotty " \
      "to avoid platform limitations.)"
  end

  def enqueue(on:, notice_line: default_notice_line, body_text: "look at this\n#{notice_line}")
    on.enqueue(
      attachment: clip, community_id: 9, room_key: "r", ceiling: 10 * 1024 * 1024,
      source_ref: ref("tg", "1"), target_endpoint_id: "dc", notice_native_id: "notice-1",
      notice_line: notice_line, body_text: body_text, retention_days: 3
    )
  end

  it "does nothing without a scheduler" do
    inert = described_class.new(scheduler: nil, transcoder: transcoder, files: files, storage: storage,
                                topology: topology_obj, adapters: adapters)

    expect(inert.available?).to be(false)
    expect(enqueue(on: inert)).to be_nil
  end

  it "does nothing without ffmpeg on PATH" do
    inert = described_class.new(scheduler: scheduler, transcoder: nil, files: files, storage: storage,
                                topology: topology_obj, adapters: adapters)

    expect(inert.available?).to be(false)
  end

  it "is available with both a scheduler and a transcoder" do
    expect(relay.available?).to be(true)
  end

  describe "when the transcode lands under the ceiling" do
    it "delivers the smaller video as its own message" do
      enqueue(on: relay)
      scheduler.run_all

      endpoint_id, message = adapter.delivered.last
      expect(endpoint_id).to eq("dc")
      expect(message.attachments.length).to eq(1)
      expect(message.attachments.first.mime_type).to eq("video/mp4")
      expect(message.attachments.first.url).to match(%r{https://rubotty\.test/filestorage/[^/]+\.mp4\z})
    end

    it "edits the link's own line out of the original notice, leaving the caption" do
      enqueue(on: relay)
      scheduler.run_all

      endpoint_id, native_id, message = adapter.edited.last
      expect(endpoint_id).to eq("dc")
      expect(native_id).to eq("notice-1")
      expect(message.body.text).to eq("look at this")
    end

    it "collapses to a short marker when the notice was the whole message" do
      enqueue(on: relay, body_text: default_notice_line)
      scheduler.run_all

      expect(adapter.edited.last.last.body.text).to eq("[clip.mp4 crossed as a video below.]")
    end

    it "records the copy in the shared message map and the loop guard's ledger" do
      enqueue(on: relay)
      scheduler.run_all

      copy = storage.counterparts(ref("tg", "1"), endpoint_id: "dc").first
      expect(copy).not_to be_nil
      expect(loop_guard.recently_delivered?(copy)).to be(true)
    end

    it "leaves the notice alone on a target that cannot edit" do
      no_edits = bounded_adapter(edits: false).new
      adapters[[:fake, "default"]] = no_edits
      enqueue(on: relay)
      scheduler.run_all

      expect(no_edits.delivered.length).to eq(1)
      expect(no_edits.edited).to be_empty
    end
  end

  describe "when the transcode does not land" do
    it "delivers nothing and edits nothing when ffmpeg fails" do
      enqueue(on: relay(video_transcoder: transcoder(fail: true)))
      scheduler.run_all

      expect(adapter.delivered).to be_empty
      expect(adapter.edited).to be_empty
    end

    it "delivers nothing when the shrunk file still comes in over the ceiling" do
      enqueue(on: relay(video_transcoder: transcoder(bytes: "x" * (11 * 1024 * 1024))))
      scheduler.run_all

      expect(adapter.delivered).to be_empty
      expect(adapter.edited).to be_empty
    end
  end

  it "does nothing for a target no longer in the topology" do
    gone = described_class.new(
      scheduler: scheduler, transcoder: transcoder, files: files, storage: storage,
      topology: topology, adapters: adapters, loop_guard: loop_guard,
      fetcher_for: ->(_limit) { VideoFakeFetcher.new(payload_bytes) }, logger: Rubotty::Log.null
    )
    enqueue(on: gone)

    expect { scheduler.run_all }.not_to raise_error
    expect(adapter.delivered).to be_empty
  end
end
