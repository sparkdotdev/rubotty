# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# Telegram's outbound never uploads a relayed attachment's bytes itself, it
# hands the Bot API a URL and lets Telegram fetch it, capped tighter than
# Telegram's own 50 MB upload ceiling: 5 MB for a photo, 20 MB for
# everything else. A file clearing 50 MB but not those numbers stays a link.
RSpec.describe "relaying a credentialed file to Telegram past its url-fetch reach", :control_plane do
  # Mirrors Telegram::Adapter::CAPABILITIES: a real upload ceiling well above what a url-based
  # send can actually reach.
  class TelegramLikeAdapter < Fakes::RecordingAdapter
    CAPABILITIES = Rubotty::Adapters::Capabilities.new(
      edits: true, deletes: true, replies: true, max_attachment_bytes: 50 * 1024 * 1024,
      url_relay_bytes: { photo: 5 * 1024 * 1024, default: 20 * 1024 * 1024 }
    ).freeze

    def capabilities = CAPABILITIES
  end

  class TelegramUrlRelayCommunity
    def initialize(id:, room_key: "r")
      @id = id
      @room_key = room_key
    end

    attr_reader :id

    def feature_enabled?(_key, feature) = feature == "file_rehosting"

    def feature_config(_key, _feature) = {}

    def room_key_of(_key) = @room_key
  end

  # Stands in for Util::MediaFetcher on the same #with(url, filename:) contract, so nothing
  # here touches the network.
  class TelegramUrlRelayFakeFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  around do |example|
    Dir.mktmpdir("rubotty-rehost-telegram-url-relay") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }

  let(:origin) { endpoint("src") }
  let(:target) { endpoint("tg", adapter: :telegram, label: "Telegram") }
  let(:storage) { Rubotty::Storage::Memory.new }
  let(:adapter) { TelegramLikeAdapter.new(own_id: "bot-1") }
  let(:loop_guard) { Rubotty::Core::LoopGuard.new(storage: storage) }

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:payload) { "x" * 1000 }
  let(:rehoster) do
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { TelegramUrlRelayFakeFetcher.new(payload) },
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  let(:bridge) do
    Rubotty::Features::Bridge.new(
      topology: topology(room("r", origin, target)), adapters: Hash.new(adapter), storage: storage,
      loop_guard: loop_guard, logger: Rubotty::Log.null, ttl: 3600, rehoster: rehoster
    )
  end

  def credentialed_url = "https://api.telegram.org/file/bot123456789:AAHqwertyuiop-asdfghjkl/photos/f_1.jpg"

  def credentialed(kind:, size:)
    Rubotty::Core::Attachment.new(
      kind: kind, url: credentialed_url, filename: "f_1.dat", mime_type: "application/octet-stream", size: size
    )
  end

  def relay(attachments:)
    community = TelegramUrlRelayCommunity.new(id: community_row.id)
    bridge.call(
      Rubotty::Features::Context.new(
        message: message(origin, text: "look at this", attachments: attachments), community: community
      )
    )
  end

  def delivered = adapter.delivered.map(&:last)

  it "links instead of relaying a photo that clears the upload ceiling but not the 5 MB url-fetch one" do
    relay(attachments: [credentialed(kind: :photo, size: 10 * 1024 * 1024)])
    sent = delivered.first

    expect(sent.attachments).to be_empty
    expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
    expect(sent.body.text).to match(%r{https://rubotty\.test/filestorage/[0-9a-f-]{36}\.dat})
  end

  it "links instead of relaying a document that clears the upload ceiling but not the 20 MB url-fetch one" do
    relay(attachments: [credentialed(kind: :document, size: 30 * 1024 * 1024)])
    sent = delivered.first

    expect(sent.attachments).to be_empty
    expect(sent.body.text).to include("File re-hosted automatically by Rubotty")
  end

  it "still relays a photo verbatim once it fits the tighter url-fetch ceiling too" do
    relay(attachments: [credentialed(kind: :photo, size: 2 * 1024 * 1024)])
    sent = delivered.first

    expect(sent.attachments.length).to eq(1)
    expect(sent.attachments.first.url).to match(%r{\Ahttps://rubotty\.test/filestorage/[0-9a-f-]{36}\.dat\z})
    expect(sent.body.text).to eq("look at this")
  end
end
