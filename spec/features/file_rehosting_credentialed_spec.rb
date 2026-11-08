# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# Matrix, IRC and XMPP all declare no max_attachment_bytes, the same as
# Fakes::RecordingAdapter used here. Features::Bridge#rehost_oversized used
# to bail out on that nil ceiling before ever asking whether the source URL
# carried a credential, so a credentialed file could never be rehosted here.
RSpec.describe "rehosting a credentialed source url with no declared ceiling", :control_plane do
  # Stands in for Util::MediaFetcher on the same #with(url, filename:) contract, so nothing
  # here touches the network. Named apart from file_rehosting_spec.rb's own FakeFetcher: a
  # bare class statement inside a describe block reopens a top level constant rather than
  # scoping to the example group, so an identically named class here would edit that one.
  class CredentialedFakeFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  # Enough of a Snapshot::Community for the bridge's per-room feature lookup. See
  # CredentialedFakeFetcher above for why this is not just named RehostCommunity.
  class CredentialedRehostCommunity
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

  around do |example|
    Dir.mktmpdir("rubotty-rehost-credentialed") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }

  let(:tg) { endpoint("tg") }
  # No max_attachment_bytes declared, matching Matrix, IRC and XMPP.
  let(:target) { endpoint("mx", adapter: :matrix, label: "Matrix") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { Fakes::RecordingAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:payload) { "photo bytes" }
  let(:rehoster) do
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { CredentialedFakeFetcher.new(payload) },
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", tg, target)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, rehoster: rehoster
    )
  end

  def credentialed_url = "https://api.telegram.org/file/bot123456789:AAHqwertyuiop-asdfghjkl/photos/f_1.jpg"

  def credentialed_file
    Rubotty::Core::Attachment.new(
      kind: :photo, url: credentialed_url, filename: "f_1.jpg", mime_type: "image/jpeg", size: payload.bytesize
    )
  end

  def safe_file
    Rubotty::Core::Attachment.new(
      kind: :photo, url: "https://cdn.example.test/a.png", filename: "a.png",
      mime_type: "image/png", size: 4_000
    )
  end

  def relay(attachments:, enabled: true, text: "look at this")
    community = CredentialedRehostCommunity.new(id: community_row.id, enabled: enabled)
    bridge.call(
      Rubotty::Features::Context.new(
        message: message(tg, text: text, attachments: attachments), community: community
      )
    )
  end

  def delivered = adapter.delivered.map(&:last)

  describe "when the room has the feature on" do
    it "relays the credentialed file as a real attachment despite the target declaring no ceiling" do
      relay(attachments: [credentialed_file])
      sent = delivered.first

      expect(sent.attachments.length).to eq(1)
      expect(sent.attachments.first.url).to match(%r{\Ahttps://rubotty\.test/filestorage/[0-9a-f-]{36}\.jpg\z})
      expect(sent.body.text).to eq("look at this")
      expect(sent.body.text).not_to include("AAHqwertyuiop")
    end

    # A file rehosted only for its credential, not its size, must not claim it
    # "was too large": that would be untrue and would mislead an operator.
    it "does not say the file was too large" do
      relay(attachments: [credentialed_file])
      expect(delivered.first.body.text).not_to include("too large")
    end

    it "leaves a safe url exactly where it was" do
      relay(attachments: [safe_file])
      sent = delivered.first

      expect(sent.attachments.map(&:filename)).to eq(["a.png"])
      expect(sent.body.text).to eq("look at this")
      expect(models.rehosted_file.count).to be_zero
    end
  end

  describe "when the room has not turned it on" do
    it "relays the credentialed url untouched, same as before the feature existed" do
      relay(attachments: [credentialed_file], enabled: false)
      sent = delivered.first

      expect(models.rehosted_file.count).to be_zero
      expect(sent.attachments.map(&:filename)).to eq(["f_1.jpg"])
      expect(sent.body.text).to eq("look at this")
    end
  end

  # Telegram's file_size is documented as optional, so attachment.size.to_i
  # reads a file of unknown size as 0, which oversized? never flags as too
  # big. Nothing upstream re-checks the real byte count, so the only thing
  # stopping a half-stored copy is the fetcher itself refusing mid-download.
  describe "when a credentialed file reports no size and turns out too big to store" do
    # Honors +limit+, unlike CredentialedFakeFetcher above, so it can stand in for
    # Util::MediaFetcher refusing mid-stream rather than trusting whatever size the platform
    # (or nothing at all) claimed.
    class UnknownSizeFakeFetcher
      def initialize(bytes, limit) = (@bytes = bytes; @limit = limit)

      def with(_url, filename: nil)
        return nil if @limit && @bytes.bytesize > @limit

        io = StringIO.new(@bytes)
        io.define_singleton_method(:original_filename) { filename || "file" }
        yield io
      end
    end

    # Larger than the community's own cap below, standing in for a file the platform never
    # reported a size for and that turns out too big once actually downloaded.
    let(:huge_payload) { "x" * 5000 }
    let(:rehoster) do
      Rubotty::Core::AttachmentRehoster.new(
        files: files, fetcher_for: ->(limit) { UnknownSizeFakeFetcher.new(huge_payload, limit) },
        env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
      )
    end

    def unknown_size_credentialed_file
      Rubotty::Core::Attachment.new(
        kind: :document, url: credentialed_url, filename: "f_1.jpg", mime_type: "image/jpeg", size: nil
      )
    end

    def relay_unknown_size
      community = CredentialedRehostCommunity.new(id: community_row.id, enabled: true,
                                                   config: { "max_bytes" => 1024 })
      bridge.call(
        Rubotty::Features::Context.new(
          message: message(tg, text: "look at this", attachments: [unknown_size_credentialed_file]),
          community: community
        )
      )
    end

    it "never raises and never stores a partial copy" do
      outcome = relay_unknown_size

      expect(outcome).to be_halt
      expect(models.rehosted_file.count).to be_zero
    end

    it "still delivers the message rather than dropping it" do
      relay_unknown_size

      expect(delivered.first).not_to be_nil
    end
  end

  # A relayed message is plain text with no page of its own to resolve a relative path
  # against, so an unset or malformed RUBOTTY_FILE_STORAGE_URL used to build a notice around a bare
  # "/filestorage/<uuid>.ext" path nobody reading the room could ever follow.
  describe "when RUBOTTY_FILE_STORAGE_URL is not set to an http(s) base" do
    let(:rehoster) do
      Rubotty::Core::AttachmentRehoster.new(
        files: files, fetcher_for: ->(_limit) { CredentialedFakeFetcher.new(payload) }, env: {}
      )
    end

    it "never sends a bare path where a link should be, and skips rehosting entirely" do
      relay(attachments: [credentialed_file])
      sent = delivered.first

      # Whatever the notice text turns out to be, any URL-shaped segment in it
      # is a real absolute URL or the notice says nothing at all; a bare
      # "/filestorage/<uuid>.ext" must never reach the room.
      urls = sent.body.text.scan(%r{\S*/filestorage/\S+})
      expect(urls).to all(match(%r{\Ahttps?://\S+\z}))
      expect(sent.body.text).to eq("look at this")
      expect(models.rehosted_file.count).to be_zero
    end
  end
end
