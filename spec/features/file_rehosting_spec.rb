# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# Rehosting a file the target platform will not take, through the real bridge, object store
# and row service, with only the download faked. Without it the far side sees nothing.
RSpec.describe "rehosting a file the target will not take", :control_plane do
  # A platform with a ceiling (Discord's, in bytes) and one with none.
  class BoundedAdapter < Fakes::RecordingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: true, replies: true, max_attachment_bytes: 25 * 1024 * 1024
    ).freeze

    def capabilities = CAPABILITIES
  end

  # Enough of a Snapshot::Community for the bridge's per-room feature lookup: is this room
  # on, what is its config, which room is this endpoint in.
  class RehostCommunity
    def initialize(id:, enabled:, config: {}, room_key: "r")
      @id = id
      @enabled = enabled
      @config = config
      @room_key = room_key
    end

    attr_reader :id

    def feature_enabled?(_key, feature) = feature == "file_rehosting" && @enabled

    def feature_config(_key, _feature) = @config

    def room_key_of(_key) = @room_key
  end

  # Stands in for Util::MediaFetcher on the same #with(url, filename:) contract, so nothing
  # here touches the network. Named for this file, since a class opened in a
  # describe block is top level and spec/core/video_rehost_relay_spec.rb
  # declares its own.
  class RehostFakeFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  around do |example|
    Dir.mktmpdir("rubotty-rehost-bridge") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }

  let(:tg) { endpoint("tg") }
  let(:dc) { endpoint("dc", label: "Discord") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { BoundedAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:payload) { "video bytes. " * 3_000 }
  let(:rehoster) do
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { RehostFakeFetcher.new(payload) },
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, rehoster: rehoster
    )
  end

  # 40 MB, which Telegram takes and Discord does not.
  def big_file
    Rubotty::Core::Attachment.new(
      kind: :video, url: "https://cdn.example.test/clip.mp4", filename: "clip.mp4",
      mime_type: "video/mp4", size: 40 * 1024 * 1024
    )
  end

  def small_file
    Rubotty::Core::Attachment.new(
      kind: :photo, url: "https://cdn.example.test/a.png", filename: "a.png",
      mime_type: "image/png", size: 4_000
    )
  end

  def relay(attachments:, enabled: true, config: {}, text: "look at this")
    community = RehostCommunity.new(id: community_row.id, enabled: enabled, config: config)
    bridge.call(
      Rubotty::Features::Context.new(
        message: message(tg, text: text, attachments: attachments), community: community
      )
    )
  end

  def delivered = adapter.delivered.map(&:last)

  describe "when the room has the feature on" do
    it "stores the file and puts a link in the body instead" do
      relay(attachments: [big_file])
      sent = delivered.first

      expect(sent.attachments).to be_empty
      expect(sent.body.text).to include("look at this")
      expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
      expect(sent.body.text).to match(%r{https://rubotty\.test/filestorage/[0-9a-f-]{36}\.mp4})
    end

    it "serves the exact bytes back from the link it posted" do
      relay(attachments: [big_file])
      secret = delivered.first.body.text[%r{/filestorage/([0-9a-f-]{36})\.mp4}, 1]

      row = files.fetch(secret: secret)
      out = +""
      files.stream(row, secret: secret) { |chunk| out << chunk }
      expect(out).to eq(payload)
    end

    it "leaves a file the target can carry exactly where it was" do
      relay(attachments: [small_file])
      sent = delivered.first

      expect(sent.attachments.map(&:filename)).to eq(["a.png"])
      expect(sent.body.text).to eq("look at this")
      expect(models.rehosted_file.count).to be_zero
    end

    it "takes the community's own retention" do
      relay(attachments: [big_file], config: { "retention_days" => 3 })
      row = models.rehosted_file.first

      expect(row.expires_at.to_time - row.created_at.to_time).to be_within(60).of(3 * 86_400)
    end

    # The cap is what stops a community filling a shared disk one video at a time.
    it "refuses a file over the community's cap and relays it untouched" do
      relay(attachments: [big_file], config: { "max_bytes" => 1024 })
      sent = delivered.first

      expect(models.rehosted_file.count).to be_zero
      expect(sent.attachments.map(&:filename)).to eq(["clip.mp4"])
      expect(sent.body.text).to eq("look at this")
    end
  end

  describe "when the room has not turned it on" do
    # This stores member file content, so a community has to opt in deliberately.
    it "is off by its code default" do
      expect(Rubotty::Features::FileRehosting.default_enabled?).to be(false)
    end

    it "stores nothing and relays exactly as it did before the feature existed" do
      relay(attachments: [big_file], enabled: false)
      sent = delivered.first

      expect(models.rehosted_file.count).to be_zero
      expect(sent.attachments.map(&:filename)).to eq(["clip.mp4"])
      expect(sent.body.text).to eq("look at this")
    end
  end

  # #1699: the dashboard's own File Rehosting toggle, independent of File
  # Uploads. rehost_inbound => false stops mirroring on its own, without
  # touching the shared feature's enabled flag File Uploads also depends on.
  describe "when only the File Rehosting half is turned off" do
    it "stores nothing and relays untouched, same as the feature being off entirely" do
      relay(attachments: [big_file], enabled: true, config: { "rehost_inbound" => false })
      sent = delivered.first

      expect(models.rehosted_file.count).to be_zero
      expect(sent.attachments.map(&:filename)).to eq(["clip.mp4"])
      expect(sent.body.text).to eq("look at this")
    end

    it "keeps mirroring when rehost_inbound is unset, the same as before the split" do
      relay(attachments: [big_file], enabled: true, config: {})

      expect(models.rehosted_file.count).to eq(1)
    end
  end

  describe "when there is nothing to rehost with" do
    it "relays untouched with no rehoster at all, the no-control-plane path" do
      plain = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600
      )
      plain.call(
        Rubotty::Features::Context.new(message: message(tg, text: "hi", attachments: [big_file]))
      )

      expect(adapter.delivered.last.last.attachments.map(&:filename)).to eq(["clip.mp4"])
    end

    # A rehost that fails must never cost the room its message.
    it "relays the file untouched when the download blows up" do
      exploding = Rubotty::Core::AttachmentRehoster.new(
        files: files, logger: Rubotty::Log.null,
        fetcher_for: ->(_limit) { raise "the CDN is on fire" }
      )
      bridge = Rubotty::Features::Bridge.new(
        topology: topology(room("r", tg, dc)), adapters: Hash.new(adapter), storage: storage,
        loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, rehoster: exploding
      )
      community = RehostCommunity.new(id: community_row.id, enabled: true)

      outcome = bridge.call(
        Rubotty::Features::Context.new(
          message: message(tg, text: "hi", attachments: [big_file]), community: community
        )
      )

      expect(outcome).to be_halt
      expect(adapter.delivered.last.last.attachments.map(&:filename)).to eq(["clip.mp4"])
    end
  end
end
