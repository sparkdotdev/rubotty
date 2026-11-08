# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# The schedule is cleared and rebuilt on every start, so a deployment that
# redeploys more often than the interval would never reach its own retention,
# which is why the first run has to be soon rather than a full day out.
RSpec.describe Rubotty::Core::Runtime, "rehosted file wiring", :control_plane do
  # The store's path comes from the real process environment, so it is pointed at
  # this example's own directory and put back afterwards.
  around do |example|
    Dir.mktmpdir("rubotty-runtime-files") do |dir|
      @root = File.join(dir, "objects")
      previous = ENV.fetch("RUBOTTY_FILE_STORE", nil)
      ENV["RUBOTTY_FILE_STORE"] = @root
      begin
        example.run
      ensure
        ENV["RUBOTTY_FILE_STORE"] = previous
      end
    end
  end

  let(:config) { sample_model }

  def sequel_store
    db = Sequel.sqlite
    store = Rubotty::Storage::SequelStore.new(db: db, description: "test sqlite")
    store.migrate!
    store
  end

  def runtime
    described_class.new(config: config, logger: Rubotty::Log.null, storage: sequel_store,
                        env: ControlPlaneHelpers::CONFIG_ENV).build
  end

  def feature_of(built, klass)
    built.router.instance_variable_get(:@pipeline).features.find { |candidate| candidate.is_a?(klass) }
  end

  it "builds a ready object store, marker and all" do
    built = runtime

    expect(built.instance_variable_get(:@object_store)).to be_a(Rubotty::Storage::ObjectStore)
    expect(File.file?(File.join(@root, Rubotty::Storage::ObjectStore::SENTINEL))).to be(true)
  end

  it "builds the row service and the ticket service over that store" do
    built = runtime

    expect(built.instance_variable_get(:@rehosted_files)).to be_a(Rubotty::ControlPlane::RehostedFiles)
    expect(built.instance_variable_get(:@upload_tickets)).to be_a(Rubotty::ControlPlane::UploadTickets)
  end

  # The same Hash the runtime fills in later, not a snapshot taken before any
  # adapter exists: a new file's serve ceiling is only ever sized at
  # #store_file time, well after adapters are live.
  it "hands the row service the runtime's own live adapter map" do
    built = runtime

    expect(built.instance_variable_get(:@rehosted_files).instance_variable_get(:@adapters))
      .to equal(built.instance_variable_get(:@adapters))
  end

  it "hands the bridge a rehoster, so an oversized file has somewhere to go" do
    expect(feature_of(runtime, Rubotty::Features::Bridge).instance_variable_get(:@rehoster))
      .to be_a(Rubotty::Core::AttachmentRehoster)
  end

  it "gives the /upload command its ticket service" do
    feature = feature_of(runtime, Rubotty::Features::UploadCommand)

    expect(feature.instance_variable_get(:@tickets)).to be_a(Rubotty::ControlPlane::UploadTickets)
  end

  it "registers the announcer that posts a finished /upload into its room" do
    built = runtime

    expect(built.instance_variable_get(:@upload_announcer)).to be_a(Rubotty::ControlPlane::UploadAnnouncer)
    expect(built.durable_scheduler.handler?(Rubotty::ControlPlane::UploadAnnouncer::KIND)).to be(true)
  end

  describe "the daily deletion" do
    # Read off the scheduled_jobs row, since the scheduler only counts and the
    # recurrence and first run time are not visible any other way.
    def expiry_job(built)
      Rubotty::ControlPlane::Boot.db_of(built.storage)[:scheduled_jobs]
        .where(kind: Rubotty::ControlPlane::RehostedFiles::EXPIRY_KIND, status: "pending").first
    end

    it "is on the durable scheduler, exactly once, with a handler behind it" do
      built = runtime

      expect(built.durable_scheduler.pending(kind: Rubotty::ControlPlane::RehostedFiles::EXPIRY_KIND)).to eq(1)
      expect(built.durable_scheduler.handler?(Rubotty::ControlPlane::RehostedFiles::EXPIRY_KIND)).to be(true)
    end

    it "recurs once a day" do
      expect(expiry_job(runtime)[:recurrence].to_i).to eq(Rubotty::ControlPlane::RehostedFiles::EXPIRY_INTERVAL)
    end

    it "runs shortly after boot rather than a full day out" do
      job = expiry_job(runtime)

      expect(job[:run_at].to_time).to be_within(120).of(Time.now + described_class::REHOSTED_FILES_FIRST_EXPIRY)
      expect(described_class::REHOSTED_FILES_FIRST_EXPIRY)
        .to be < Rubotty::ControlPlane::RehostedFiles::EXPIRY_INTERVAL
    end
  end

  # A deployment finds out whether it can shrink a picture at boot, not at the
  # first oversized photo somebody posts into a room.
  describe "the image shrinker" do
    def booted_with_path(dir)
      log = StringIO.new
      previous = ENV.fetch("PATH", nil)
      Rubotty::Util::ImageShrinker.reset_binary!
      ENV["PATH"] = dir
      built = described_class.new(config: config, logger: Rubotty::Log.build(level: "info", io: log),
                                  storage: sequel_store, env: ControlPlaneHelpers::CONFIG_ENV).build
      [built.instance_variable_get(:@rehoster), log.string]
    ensure
      ENV["PATH"] = previous
      Rubotty::Util::ImageShrinker.reset_binary!
    end

    def with_magick(dir)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "magick")
      File.write(path, "#!/bin/sh\n")
      File.chmod(0o755, path)
      dir
    end

    it "is wired in where ImageMagick is installed" do
      rehoster, log = booted_with_path(with_magick(File.join(@root, "..", "bin")))

      expect(rehoster.shrinks?).to be(true)
      expect(log).to include("images can be shrunk")
    end

    # Nothing fails to boot and nothing raises later: the strategies simply have
    # only linking left, and the log says why.
    it "says so at boot and falls back to linking where it is not" do
      rehoster, log = booted_with_path(File.join(@root, "..", "nothing-here"))

      expect(rehoster).to be_a(Rubotty::Core::AttachmentRehoster)
      expect(rehoster.shrinks?).to be(false)
      expect(log).to include("no magick or convert on PATH")
      expect(log).to include("file_rehosting will link an oversized image rather than shrink it")
    end
  end

  # A deployment finds out whether it can shrink a video the same way, at
  # boot rather than at the first oversized clip somebody posts.
  describe "the video transcoder" do
    def booted_with_path(dir)
      log = StringIO.new
      previous = ENV.fetch("PATH", nil)
      Rubotty::Util::VideoTranscoder.reset_binaries!
      ENV["PATH"] = dir
      built = described_class.new(config: config, logger: Rubotty::Log.build(level: "info", io: log),
                                  storage: sequel_store, env: ControlPlaneHelpers::CONFIG_ENV).build
      [built.instance_variable_get(:@rehoster), log.string]
    ensure
      ENV["PATH"] = previous
      Rubotty::Util::VideoTranscoder.reset_binaries!
    end

    def with_ffmpeg(dir)
      FileUtils.mkdir_p(dir)
      %w[ffmpeg ffprobe].each do |name|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\n")
        File.chmod(0o755, path)
      end
      dir
    end

    it "is wired in where ffmpeg and ffprobe are both installed" do
      rehoster, log = booted_with_path(with_ffmpeg(File.join(@root, "..", "bin")))

      expect(rehoster.shrinks_video?).to be(true)
      expect(log).to include("video can be shrunk")
    end

    # Nothing fails to boot and nothing raises later: the strategies simply
    # link a video instead, and the log says why.
    it "says so at boot and falls back to linking where either binary is missing" do
      rehoster, log = booted_with_path(File.join(@root, "..", "nothing-here"))

      expect(rehoster).to be_a(Rubotty::Core::AttachmentRehoster)
      expect(rehoster.shrinks_video?).to be(false)
      expect(log).to include("no ffmpeg or ffprobe on PATH")
      expect(log).to include("file_rehosting will link an oversized video rather than shrink it")
    end
  end

  # A store that cannot be made ready switches rehosting off, leaving the relay.
  describe "when the store directory looks like an unmounted volume" do
    it "leaves rehosting inert and the relay untouched" do
      FileUtils.mkdir_p(@root)
      File.binwrite(File.join(@root, "stray.bin"), "not ours")

      built = runtime

      expect(built.instance_variable_get(:@object_store)).to be_nil
      expect(built.instance_variable_get(:@rehosted_files)).to be_nil
      expect(feature_of(built, Rubotty::Features::Bridge).instance_variable_get(:@rehoster)).to be_nil
      expect(built.router).not_to be_nil
    end
  end
end
