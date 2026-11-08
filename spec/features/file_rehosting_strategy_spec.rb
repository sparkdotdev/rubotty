# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# The three answers a community can give to a file the target will not take, through the
# real bridge, rehoster, object store and row service. Only the download and the encoder
# are stood in for.
RSpec.describe "shrinking a file the target will not take", :control_plane do
  # One adapter class per ceiling, so a room can fan a message into two targets
  # that disagree about how big a file may be. Telegram's fetch ceiling is here
  # too, since it is what the honest refusal is read from.
  def bounded_adapter(upload:, fetch: nil)
    Class.new(Fakes::RecordingAdapter) do
      define_method(:capabilities) do
        @capabilities ||= Rubotty::Adapters::Capabilities.new(
          edits: true, deletes: true, replies: true,
          max_attachment_bytes: upload, max_fetch_bytes: fetch
        )
      end
    end
  end

  # Enough of a Snapshot::Community for the per-room feature lookup.
  class StrategyCommunity
    def initialize(id:, config: {})
      @id = id
      @config = config
    end

    attr_reader :id

    def feature_enabled?(_key, feature) = feature == "file_rehosting"

    def feature_config(_key, _feature) = @config

    def room_key_of(_key) = "r"
  end

  # Util::MediaFetcher's #with(url, filename:) contract, without a network.
  class StrategyFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  # Util::ImageShrinker's contract, without an encoder. Every ceiling it was
  # asked to hit is recorded, which is how "once per distinct limit" is checked,
  # and the ceiling is written into the bytes so an example can tell one
  # target's copy from another's. Deliberately small: a fake that produced
  # megabytes would put real compression and encryption behind every example for
  # nothing.
  class CountingShrinker
    SIZE = 1_000

    def initialize = (@ceilings = [])

    attr_reader :ceilings

    def shrink(source, ceiling:, filename: nil)
      @ceilings << ceiling
      source.read
      smaller = StringIO.new("shrunk to #{ceiling}".ljust(SIZE, "."))
      smaller.define_singleton_method(:size) { string.bytesize }
      yield smaller
    end
  end

  # One that can never get anything small enough, which is what separates
  # shrink from shrink_then_link.
  class RefusingShrinker
    def initialize = (@calls = 0)

    attr_reader :calls

    def shrink(_source, ceiling:, filename: nil)
      @calls += 1
      nil
    end
  end

  # Stands in for Core::VideoRehostRelay so the delivery-gated half of the video-shrink flow
  # can be checked without an encoder anywhere near it: every #enqueue call is recorded,
  # which is how "asked only once delivery has actually happened" is checked.
  class FakeVideoRelay
    def initialize(available: true)
      @available = available
      @calls = []
    end

    attr_reader :calls

    def available? = @available

    def enqueue(**kwargs)
      @calls << kwargs
      @calls.length
    end
  end

  around do |example|
    Dir.mktmpdir("rubotty-shrink-bridge") do |dir|
      @dir = dir
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }

  let(:tg) { endpoint("tg", label: "Telegram") }
  let(:dc) { endpoint("dc", adapter: :discord, label: "Discord") }
  let(:mx) { endpoint("mx", adapter: :matrix, label: "Matrix") }

  let(:storage) { Rubotty::Storage::Memory.new }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }
  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:payload) { "original photo bytes. " * 2_000 }
  let(:shrinker) { CountingShrinker.new }

  # Telegram in, Discord at 10 MB and Matrix at 50 MB out.
  let(:origin_adapter) { bounded_adapter(upload: 50 * 1024 * 1024, fetch: 20 * 1024 * 1024).new }
  let(:discord) { bounded_adapter(upload: 10 * 1024 * 1024).new(own_id: "bot-dc") }
  let(:matrix) { bounded_adapter(upload: 50 * 1024 * 1024).new(own_id: "bot-mx") }

  # Keyed the way Bridge#adapter_for looks one up: adapter name and account.
  let(:adapters) do
    { [:fake, "default"] => origin_adapter,
      [:discord, "default"] => discord,
      [:matrix, "default"] => matrix }
  end

  let(:rehoster) do
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { StrategyFetcher.new(payload) },
      shrinker: shrinker, logger: Rubotty::Log.null,
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  def bridge(targets, rehoster: self.rehoster)
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, *targets)), adapters: adapters, storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, rehoster: rehoster
    )
  end

  # 30 MB, which Matrix takes and Discord does not.
  def photo(size: 30 * 1024 * 1024, url: "https://cdn.example.test/holiday.jpg")
    Rubotty::Core::Attachment.new(
      kind: :photo, url: url, filename: "holiday.jpg", mime_type: "image/jpeg", size: size
    )
  end

  def clip
    Rubotty::Core::Attachment.new(
      kind: :video, url: "https://cdn.example.test/clip.mp4", filename: "clip.mp4",
      mime_type: "video/mp4", size: 30 * 1024 * 1024
    )
  end

  def relay(attachments:, strategy: nil, targets: [dc], rehoster: self.rehoster, config: {})
    config = config.merge("strategy" => strategy.to_s) if strategy
    bridge(targets, rehoster: rehoster).call(
      Rubotty::Features::Context.new(
        message: message(tg, text: "look at this", attachments: attachments),
        community: StrategyCommunity.new(id: community_row.id, config: config)
      )
    )
  end

  def sent_to(adapter) = adapter.delivered.map(&:last).first

  describe "the setting itself" do
    it "links by default, so a community that never touches it sees no change" do
      expect(Rubotty::Features::FileRehosting.strategy({})).to eq(:link)
      expect(Rubotty::Features::FileRehosting.strategy("strategy" => "shrink")).to eq(:shrink)
      expect(Rubotty::Features::FileRehosting.strategy(strategy: :shrink_then_link))
        .to eq(:shrink_then_link)
    end

    it "reads a value nothing in the schema produced as the default" do
      expect(Rubotty::Features::FileRehosting.strategy("strategy" => "obliterate")).to eq(:link)
      expect(Rubotty::Features::FileRehosting.strategy("strategy" => "")).to eq(:link)
    end

    it "offers exactly the three answers, and the schema agrees" do
      field = Rubotty::Features::FileRehosting.config_schema.fields[:strategy]

      expect(Rubotty::Features::FileRehosting::STRATEGIES).to eq(%i[link shrink shrink_then_link])
      expect(field.one_of).to eq(Rubotty::Features::FileRehosting::STRATEGIES)
      expect(field.default).to eq(:link)
    end

    # The feature owns the names an admin types and the rehoster owns what each
    # one does, so the two lists have to name the same three things.
    it "leaves the rehoster no strategy it does not know what to do with" do
      known = Rubotty::Core::AttachmentRehoster::SHRINKING |
              Rubotty::Core::AttachmentRehoster::LINKING

      expect(known).to match_array(Rubotty::Features::FileRehosting::STRATEGIES)
    end
  end

  describe "link, which is what this feature always did" do
    it "stores the file whole and puts a line in the body in its place" do
      relay(attachments: [photo], strategy: :link)
      sent = sent_to(discord)

      expect(shrinker.ceilings).to be_empty
      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
      expect(sent.body.text).to match(%r{https://rubotty\.test/filestorage/[0-9a-f-]{36}\.jpg})
    end
  end

  describe "shrink" do
    it "sends the picture as a picture, with no line in the body at all" do
      relay(attachments: [photo], strategy: :shrink)
      sent = sent_to(discord)

      expect(sent.body.text).to eq("look at this")
      expect(sent.attachments.length).to eq(1)
      expect(sent.attachments.first.mime_type).to eq("image/jpeg")
      expect(sent.attachments.first.url).to match(%r{https://rubotty\.test/filestorage/[0-9a-f-]{36}\.jpg})
      expect(sent.attachments.first.size).to be <= 10 * 1024 * 1024
    end

    it "serves the shrunk bytes back from the link the attachment points at" do
      relay(attachments: [photo], strategy: :shrink)
      secret = sent_to(discord).attachments.first.url[%r{/filestorage/([0-9a-f-]{36})\.jpg}, 1]

      out = +""
      files.stream(files.fetch(secret: secret), secret: secret) { |chunk| out << chunk }
      expect(out).to start_with("shrunk to #{10 * 1024 * 1024}")
      expect(out).not_to eq(payload)
    end

    # The width and height described the picture that arrived, not the one being
    # sent on, so carrying them forward would be a lie.
    it "forgets the dimensions and renames the file to what it now is" do
      wide = photo.with(width: 4032, height: 3024)
      relay(attachments: [wide], strategy: :shrink)
      sent = sent_to(discord).attachments.first

      expect([sent.width, sent.height]).to eq([nil, nil])
      expect(sent.filename).to eq("holiday.jpg")
      expect(sent.kind).to eq(:photo)
    end

    # shrink means shrink. A file it cannot help is relayed exactly as it would
    # be with the feature switched off, rather than quietly becoming a link.
    it "leaves a file it cannot shrink completely alone" do
      refusing = RefusingShrinker.new
      relay(attachments: [photo], strategy: :shrink, rehoster: shrinking_rehoster(refusing))
      sent = sent_to(discord)

      expect(refusing.calls).to eq(1)
      expect(sent.attachments.map(&:filename)).to eq(["holiday.jpg"])
      expect(sent.body.text).to eq("look at this")
      expect(models.rehosted_file.count).to be_zero
    end

    # Video is not something this can help with yet, so it is not pretended at.
    it "does not hand a video to the image encoder" do
      relay(attachments: [clip], strategy: :shrink)

      expect(shrinker.ceilings).to be_empty
      expect(sent_to(discord).attachments.map(&:filename)).to eq(["clip.mp4"])
    end
  end

  describe "shrink_then_link" do
    it "shrinks when it can" do
      relay(attachments: [photo], strategy: :shrink_then_link)
      sent = sent_to(discord)

      expect(sent.attachments.length).to eq(1)
      expect(sent.body.text).to eq("look at this")
    end

    it "falls back to the link when the picture will not come down far enough" do
      refusing = RefusingShrinker.new
      relay(attachments: [photo], strategy: :shrink_then_link,
            rehoster: shrinking_rehoster(refusing))
      sent = sent_to(discord)

      expect(refusing.calls).to eq(1)
      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
      expect(sent.body.text).to match(%r{/filestorage/[0-9a-f-]{36}\.jpg})
    end

    it "falls back to the link for a video, which it cannot shrink at all" do
      relay(attachments: [clip], strategy: :shrink_then_link)
      sent = sent_to(discord)

      expect(shrinker.ceilings).to be_empty
      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
      expect(sent.body.text).to match(%r{/filestorage/[0-9a-f-]{36}\.mp4})
    end
  end

  # A video cannot be shrunk before the message it belongs to has to cross, so with a
  # background relay wired in it is linked at once, whatever the strategy says, and the
  # relay is asked to try for something smaller only once that link has actually gone out.
  describe "video, once a background relay can shrink it" do
    let(:video_relay) { FakeVideoRelay.new }
    let(:rehoster_with_video) do
      Rubotty::Core::AttachmentRehoster.new(
        files: files, fetcher_for: ->(_limit) { StrategyFetcher.new(payload) },
        shrinker: shrinker, video: video_relay, logger: Rubotty::Log.null,
        env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
      )
    end

    it "still links at once under shrink_then_link, the strategy that already linked a video" do
      relay(attachments: [clip], strategy: :shrink_then_link, rehoster: rehoster_with_video)
      sent = sent_to(discord)

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
      expect(video_relay.calls.length).to eq(1)
    end

    # Plain shrink never falls back to a link for a file it cannot shrink (see "leaves a
    # file it cannot shrink completely alone" above), but a video's shrink outcome is not
    # known yet at delivery time, so it links now and the background relay decides
    # afterwards whether that link stands or gets replaced.
    it "links at once under plain shrink too, since the room cannot wait to find out" do
      relay(attachments: [clip], strategy: :shrink, rehoster: rehoster_with_video)
      sent = sent_to(discord)

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
      expect(video_relay.calls.length).to eq(1)
    end

    it "asks the relay only once delivery has actually happened, with a real ref to improve on" do
      relay(attachments: [clip], strategy: :shrink_then_link, rehoster: rehoster_with_video)
      call = video_relay.calls.first

      expect(call[:target_endpoint_id]).to eq("dc")
      expect(call[:notice_native_id]).not_to be_nil
      expect(call[:source_ref]).to eq(Rubotty::Core::MessageRef.new("tg", "1"))
      expect(call[:ceiling]).to eq(10 * 1024 * 1024)
      expect(call[:body_text]).to eq("look at this\n#{call[:notice_line]}")
      expect(call[:notice_line]).to include("File re-hosted automatically by Rubotty")
    end

    it "leaves an image on the ordinary synchronous shrink path untouched" do
      relay(attachments: [photo], strategy: :shrink, rehoster: rehoster_with_video)
      sent = sent_to(discord)

      expect(sent.attachments.length).to eq(1)
      expect(video_relay.calls).to be_empty
    end

    it "does not ask a relay that says it is not available" do
      unavailable = Rubotty::Core::AttachmentRehoster.new(
        files: files, fetcher_for: ->(_limit) { StrategyFetcher.new(payload) },
        shrinker: shrinker, video: FakeVideoRelay.new(available: false), logger: Rubotty::Log.null,
        env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
      )
      relay(attachments: [clip], strategy: :shrink_then_link, rehoster: unavailable)
      sent = sent_to(discord)

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
    end
  end

  describe "one file, several targets" do
    # The limit belongs to the platform being sent to, so a room bridged into
    # two platforms that disagree needs two different answers.
    it "aims at each target's own limit rather than at the message" do
      relay(attachments: [photo(size: 60 * 1024 * 1024)], strategy: :shrink, targets: [dc, mx])

      expect(shrinker.ceilings.sort).to eq([10 * 1024 * 1024, 50 * 1024 * 1024])
      # Two encodes, two stored copies, and each target pointed at its own.
      expect(models.rehosted_file.count).to eq(2)
      expect(sent_to(discord).attachments.first.url)
        .not_to eq(sent_to(matrix).attachments.first.url)
    end

    it "leaves the target that can carry it as it is" do
      relay(attachments: [photo], strategy: :shrink, targets: [dc, mx])

      expect(shrinker.ceilings).to eq([10 * 1024 * 1024])
      expect(sent_to(matrix).attachments.map(&:filename)).to eq(["holiday.jpg"])
      expect(sent_to(matrix).attachments.first.url).to eq("https://cdn.example.test/holiday.jpg")
    end

    # Two targets that happen to agree are one encode and two references to it,
    # not the same work done twice.
    it "shrinks once and reuses it when two targets share a limit" do
      twin = endpoint("dc2", adapter: :discord, label: "Discord (the other one)")
      relay(attachments: [photo], strategy: :shrink, targets: [dc, twin])

      expect(shrinker.ceilings).to eq([10 * 1024 * 1024])
      expect(models.rehosted_file.count).to eq(1)
      expect(discord.delivered.map { |_, sent| sent.attachments.first.url }.uniq.length).to eq(1)
    end
  end

  describe "when the origin platform will not hand over the bytes" do
    # Telegram's getFile stops at 20 MB, so a bigger file arrives with no URL to
    # pull it through and there is nothing to shrink or store.
    def unfetchable
      Rubotty::Core::Attachment.new(
        kind: :video, url: nil, native_ref: "BAADBAADrwADBREAAWCpvYqUCw", filename: "long.mp4",
        mime_type: "video/mp4", size: 30 * 1024 * 1024
      )
    end

    it "says so rather than letting the file disappear" do
      relay(attachments: [unfetchable], strategy: :shrink_then_link)
      sent = sent_to(discord)

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("long.mp4")
      expect(sent.body.text).to include("could not reach Discord")
      expect(sent.body.text).to include("Telegram will not let a bot download a file over 20.0 MB")
      expect(models.rehosted_file.count).to be_zero
    end

    it "says the same thing under link, since the reason has nothing to do with the strategy" do
      relay(attachments: [unfetchable], strategy: :link)

      expect(sent_to(discord).body.text).to include("will not let a bot download")
    end

    # A file with no URL that the origin platform never claimed to cap is a
    # different problem, and guessing at it would be worse than saying nothing.
    it "stays quiet when the origin declares no download ceiling" do
      adapters[[:fake, "default"]] = bounded_adapter(upload: 50 * 1024 * 1024).new

      relay(attachments: [unfetchable], strategy: :shrink_then_link)
      sent = sent_to(discord)

      expect(sent.body.text).to eq("look at this")
      expect(sent.attachments.map(&:filename)).to eq(["long.mp4"])
    end
  end

  describe "when the image binary is not installed" do
    # The deployment said so at boot, and every shrink strategy becomes the one
    # thing it can still do.
    it "links under shrink_then_link rather than failing at the first photo" do
      relay(attachments: [photo], strategy: :shrink_then_link,
            rehoster: shrinking_rehoster(nil))
      sent = sent_to(discord)

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
    end

    it "relays the file untouched under shrink, which has no link to fall back on" do
      relay(attachments: [photo], strategy: :shrink, rehoster: shrinking_rehoster(nil))
      sent = sent_to(discord)

      expect(sent.attachments.map(&:filename)).to eq(["holiday.jpg"])
      expect(sent.body.text).to eq("look at this")
      expect(models.rehosted_file.count).to be_zero
    end

    it "reports that it cannot shrink, which is what the boot warning reads" do
      expect(shrinking_rehoster(nil).shrinks?).to be(false)
      expect(rehoster.shrinks?).to be(true)
    end
  end

  # Everything above stands in for Util::ImageShrinker so an example can say what
  # came back. This one uses the real class, with only the encoder itself stood
  # in for, so the whole chain is exercised once end to end.
  describe "through the real shrinker" do
    def fake_magick(output)
      script = File.join(@dir, "fake-magick")
      File.write(script, <<~SH)
        #!/bin/sh
        out=$(printf '%s\\n' "$@" | grep '^JPEG:' | sed 's/^JPEG://')
        printf '%s' '#{[output].pack("m0")}' | base64 -d > "$out"
      SH
      File.chmod(0o755, script)
      Rubotty::Util::ImageShrinker.new(binary: script, logger: Rubotty::Log.null)
    end

    def jpeg(*segments)
      body = segments.map { |code, text| [0xFF, code].pack("C2") + [text.bytesize + 2].pack("n") + text }
      "\xFF\xD8".b + body.join.b + "\xFF\xDA".b + [12].pack("n") + ("\x00".b * 10) + "\xFF\xD9".b
    end

    def jfif = [0xE0, "JFIF\0\x01\x02\0\0\x01\0\x01\0\0"]

    it "puts the re encoded picture in the store and points the attachment at it" do
      stripped = jpeg(jfif)
      relay(attachments: [photo], strategy: :shrink, rehoster: shrinking_rehoster(fake_magick(stripped)))
      sent = sent_to(discord).attachments.first
      secret = sent.url[%r{/filestorage/([0-9a-f-]{36})\.jpg}, 1]

      out = +""
      files.stream(files.fetch(secret: secret), secret: secret) { |chunk| out << chunk }
      expect(out).to eq(stripped)
      expect(sent.size).to eq(stripped.bytesize)
    end

    # The EXIF block is where a camera writes the coordinates a photo was taken
    # at. An encoder that somehow kept it has its output refused rather than the
    # bridge relaying the fix onward.
    it "refuses a re encode that still carries EXIF, and links instead" do
      exif = [0xE1, "Exif\0\0#{"\x00" * 60}"]
      shrinker = fake_magick(jpeg(jfif, exif))
      relay(attachments: [photo], strategy: :shrink_then_link,
            rehoster: shrinking_rehoster(shrinker))
      sent = sent_to(discord)

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
    end
  end

  def shrinking_rehoster(with)
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { StrategyFetcher.new(payload) },
      shrinker: with, logger: Rubotty::Log.null,
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end
end
