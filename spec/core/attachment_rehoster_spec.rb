# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# The base URL half of AttachmentRehoster, isolated from the strategy and
# shrink logic spec/features/file_rehosting*_spec.rb already cover.
# RUBOTTY_FILE_STORAGE_URL unset or malformed used to still build a bare
# "/f/<uuid>" link with no scheme or host: inert once it reaches a chat platform.
RSpec.describe Rubotty::Core::AttachmentRehoster, :control_plane do
  class RehosterFakeFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  around do |example|
    Dir.mktmpdir("rubotty-attachment-rehoster-spec") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_row) { models.community.where(slug: "sample").first }
  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:payload) { "photo bytes" }

  def rehoster(env)
    described_class.new(files: files, fetcher_for: ->(_limit) { RehosterFakeFetcher.new(payload) }, env: env)
  end

  def photo
    Rubotty::Core::Attachment.new(
      kind: :photo, url: "https://cdn.example.test/a.jpg", filename: "a.jpg", mime_type: "image/jpeg",
      size: payload.bytesize
    )
  end

  describe "#rehost" do
    it "builds an absolute download url on a configured RUBOTTY_FILE_STORAGE_URL, ending in the file's own extension" do
      url = rehoster("RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test")
            .rehost(attachment: photo, community_id: community_row.id, room_key: "r")

      expect(url).to match(%r{\Ahttps://rubotty\.test/filestorage/[0-9a-f-]{36}\.jpg\z})
    end

    it "falls back to the content type's own extension when the filename has none to reuse" do
      nameless = photo.with(filename: nil)
      url = rehoster("RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test")
            .rehost(attachment: nameless, community_id: community_row.id, room_key: "r")

      expect(url).to match(/\.jpg\z/)
    end

    it "refuses to rehost, rather than hand back a bare path, when RUBOTTY_FILE_STORAGE_URL is unset" do
      url = rehoster({}).rehost(attachment: photo, community_id: community_row.id, room_key: "r")

      expect(url).to be_nil
      expect(models.rehosted_file.count).to be_zero
    end

    it "refuses to rehost when RUBOTTY_FILE_STORAGE_URL is set to something that is not an http(s) base" do
      url = rehoster("RUBOTTY_FILE_STORAGE_URL" => "guest-chat.example").rehost(
        attachment: photo, community_id: community_row.id, room_key: "r"
      )

      expect(url).to be_nil
    end

    it "strips a trailing slash the same way whether or not the base is usable" do
      url = rehoster("RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test/")
            .rehost(attachment: photo, community_id: community_row.id, room_key: "r")

      expect(url).to match(%r{\Ahttps://rubotty\.test/filestorage/})
    end
  end

  describe "#place" do
    it "returns nil, the bridge's existing 'nothing could be done' signal, with no usable base" do
      placement = rehoster({}).place(
        attachment: photo, community_id: community_row.id, ceiling: nil, strategy: :link
      )

      expect(placement).to be_nil
    end

    it "returns a linked placement with a real url once a base is configured" do
      placement = rehoster("RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test").place(
        attachment: photo, community_id: community_row.id, ceiling: nil, strategy: :link
      )

      expect(placement).to be_linked
      expect(placement.url).to match(%r{\Ahttps://rubotty\.test/filestorage/})
    end
  end

  describe "#notice" do
    let(:url) { "https://rubotty.test/filestorage/900931a2-d3a8-4b45-8b5f-173f4e79ca4c.jpg" }

    # notice() only formats whatever url it is handed; the regression this
    # class actually needed was upstream, in what #rehost ever hands it. This
    # pins the contract the other examples above rely on: given a real url,
    # the notice carries it whole, never a fragment of it.
    it "never produces a bare path when handed a real absolute url" do
      text = rehoster("RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test").notice(url: url).to_s

      expect(text).to include(url)
      expect(text).not_to match(%r{[\s\[]/f/})
    end

    it "reads as the url followed by a parenthetical note, in the maintainer's own words" do
      text = rehoster({}).notice(url: url).to_s

      expect(text).to eq(
        "#{url} (File re-hosted automatically by Rubotty to avoid platform limitations; " \
        "the link works a limited number of times.)"
      )
    end

    it "italicises the note but not the url or the surrounding parentheses" do
      rich = rehoster({}).notice(url: url)
      note = "File re-hosted automatically by Rubotty to avoid platform limitations; " \
             "the link works a limited number of times."
      note_at = rich.text.index(note)

      expect(rich.spans.length).to eq(1)
      expect(rich.spans.first.kind).to eq(:italic)
      expect(rich.spans.first.begin_index).to eq(note_at)
      expect(rich.spans.first.end_index).to eq(note_at + note.length)
    end
  end

  describe "#unfetchable_notice" do
    it "names the file, the target and the origin's own ceiling, with no url to give" do
      text = rehoster({}).unfetchable_notice(
        attachment: photo, target_label: "Discord", origin_label: "Telegram", ceiling: 20 * 1024 * 1024
      ).to_s

      expect(text).to include("a.jpg")
      expect(text).to include("could not reach Discord")
      expect(text).to include("Telegram will not let a bot download a file over 20.0 MB")
    end

    it "italicises its own closing note" do
      rich = rehoster({}).unfetchable_notice(
        attachment: photo, target_label: "Discord", origin_label: "Telegram", ceiling: 20 * 1024 * 1024
      )

      expect(rich.spans.length).to eq(1)
      expect(rich.spans.first.kind).to eq(:italic)
    end
  end
end
