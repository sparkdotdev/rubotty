# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# A Telegram sender's profile photo, copied through the real object store and row
# service with only the download faked. Telegram serves a photo from a URL with
# the bot token in it, so the whole point is that the link handed to another
# platform is a different one.
RSpec.describe Rubotty::Adapters::Telegram::Avatars, :control_plane do
  # Stands in for Util::MediaFetcher on the same #with(url, filename:) contract,
  # so nothing here touches the network.
  class FakePhotoFetcher
    def initialize(bytes) = (@bytes = bytes)

    def with(_url, filename: nil)
      io = StringIO.new(@bytes)
      io.define_singleton_method(:original_filename) { filename || "file" }
      yield io
    end
  end

  # What the rehoster sees when the download is refused.
  class RefusingPhotoFetcher
    def with(_url, **_options) = nil
  end

  around do |example|
    Dir.mktmpdir("rubotty-telegram-avatars") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community_id) { models.community.where(slug: "sample").first[:id] }

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  let(:files) { Rubotty::ControlPlane::RehostedFiles.new(models: models, store: store) }
  let(:fetcher) { FakePhotoFetcher.new("png bytes " * 100) }
  let(:rehoster) do
    Rubotty::Core::AttachmentRehoster.new(
      files: files, fetcher_for: ->(_limit) { fetcher },
      env: { "RUBOTTY_FILE_STORAGE_URL" => "https://rubotty.test" }
    )
  end

  # The URL Telegram really answers with, bot token and all.
  let(:telegram_url) { "https://api.telegram.org/file/bot123:ABCDEF/photos/file_1.jpg" }

  let(:photo_calls) { [] }

  # Both Bot API seams read an instance variable when they run, so an example can
  # change what Telegram says between one drain and the next.
  subject(:avatars) do
    described_class.new(
      photos: ->(user_id) { @photos.call(user_id) },
      file_url: ->(file_id) { @file_url.call(file_id) },
      rehoster: rehoster, logger: Rubotty::Log.null, clock: -> { @now }, worker: false
    )
  end

  before do
    @now = Time.utc(2026, 8, 5, 12, 0, 0)
    @photos = lambda do |user_id|
      photo_calls << user_id
      photos_answer("photo-1")
    end
    @file_url = ->(file_id) { "https://api.telegram.org/file/bot123:ABCDEF/photos/#{file_id}.jpg" }
  end

  # The Bot API answer for somebody with one photo, smallest size first.
  def photos_answer(file_id)
    {
      "total_count" => 1,
      "photos" => [[{ "file_id" => "#{file_id}-small", "width" => 160 },
                    { "file_id" => file_id, "width" => 640 }]]
    }
  end

  def stored_rows = models.rehosted_file.where(community_id: community_id).all

  describe "the first sighting of somebody" do
    # The relay is never held up by two Bot API calls and a download, so the
    # message that triggers the copy goes out without a picture and the next one
    # has it.
    it "answers nothing, copies on the next drain, and serves it from then on" do
      expect(avatars.url_for(55, community_id)).to be_nil
      expect(photo_calls).to be_empty

      expect(avatars.drain).to eq(1)

      expect(avatars.url_for(55, community_id)).to start_with("https://rubotty.test/filestorage/")
      expect(photo_calls).to eq(%w[55])
    end

    it "asks Telegram once and stores one copy, however many messages follow" do
      avatars.url_for(55, community_id)
      avatars.drain
      5.times { avatars.url_for(55, community_id) }
      avatars.drain

      expect(photo_calls).to eq(%w[55])
      expect(stored_rows.size).to eq(1)
    end

    it "records the copy as the sender's, with no room and no name on it" do
      avatars.url_for(55, community_id)
      avatars.drain

      row = stored_rows.first
      expect(row[:created_by]).to eq("telegram:55")
      expect(row[:filename]).to eq("avatar.jpg")
      expect(row[:content_type]).to eq("image/jpeg")
      expect(row[:room_key]).to be_nil
    end

    # The copy is scoped to the community that keeps it, so the same person
    # speaking in two communities has one copy in each.
    it "keeps a separate copy per community" do
      now = Time.now
      other = models.community.insert(slug: "other", name: "Other", status: "active",
                                      created_at: now, updated_at: now)
      avatars.url_for(55, community_id)
      avatars.url_for(55, other)
      avatars.drain

      expect(models.rehosted_file.count).to eq(2)
      expect(avatars.url_for(55, community_id)).not_to eq(avatars.url_for(55, other))
    end
  end

  describe "keeping the copy current" do
    before do
      avatars.url_for(55, community_id)
      avatars.drain
    end

    it "asks Telegram again once the check window has passed" do
      @now += described_class::CHECK_AFTER + 1
      avatars.url_for(55, community_id)
      avatars.drain

      expect(photo_calls).to eq(%w[55 55])
    end

    # The whole reason for keying on the file id: somebody who has not changed
    # their picture costs a copy of nothing.
    it "keeps the same link and stores nothing new when the photo is unchanged" do
      first = avatars.url_for(55, community_id)
      @now += described_class::CHECK_AFTER + 1
      avatars.url_for(55, community_id)
      avatars.drain

      expect(avatars.url_for(55, community_id)).to eq(first)
      expect(stored_rows.size).to eq(1)
    end

    it "makes a fresh copy when Telegram reports a different file id" do
      first = avatars.url_for(55, community_id)
      @now += described_class::CHECK_AFTER + 1
      @photos = ->(_user_id) { photos_answer("photo-2") }
      avatars.url_for(55, community_id)
      avatars.drain

      expect(avatars.url_for(55, community_id)).not_to eq(first)
      expect(stored_rows.size).to eq(2)
    end

    # The bytes are deleted on the retention the row was written under, so a link
    # older than that stops being handed out whether or not anything refreshed it.
    it "stops serving a link once the copy it points at has expired" do
      @now += (Rubotty::ControlPlane::RehostedFiles::DEFAULT_TTL_DAYS * 86_400) + 1

      expect(avatars.url_for(55, community_id)).to be_nil
    end

    # The community's own retention decides when the bytes go, so the cache has
    # to expire on the same clock rather than a fixed one of its own.
    it "honours a shorter retention the community configured" do
      other = 77
      avatars.url_for(other, community_id, retention_days: 2)
      avatars.drain
      expect(avatars.url_for(other, community_id, retention_days: 2)).not_to be_nil

      @now += (2 * 86_400) + 1
      expect(avatars.url_for(other, community_id, retention_days: 2)).to be_nil
    end
  end

  describe "somebody with no picture to copy" do
    before { @photos = ->(user_id) { photo_calls << user_id and { "total_count" => 0, "photos" => [] } } }

    it "relays with no avatar and stores nothing" do
      avatars.url_for(55, community_id)
      avatars.drain

      expect(avatars.url_for(55, community_id)).to be_nil
      expect(stored_rows).to be_empty
    end

    # A miss is remembered too, so somebody with no photo is not two Bot API
    # calls on every message they send.
    it "remembers the miss rather than asking again on the next message" do
      avatars.url_for(55, community_id)
      avatars.drain
      10.times { avatars.url_for(55, community_id) }
      avatars.drain

      expect(photo_calls).to eq(%w[55])
    end

    it "asks again once the shorter miss window has passed" do
      avatars.url_for(55, community_id)
      avatars.drain
      @now += described_class::RECHECK_MISS_AFTER + 1
      avatars.url_for(55, community_id)
      avatars.drain

      expect(photo_calls).to eq(%w[55 55])
    end
  end

  describe "when something goes wrong" do
    context "with a download that is refused" do
      let(:fetcher) { RefusingPhotoFetcher.new }

      it "answers nothing and does not raise" do
        avatars.url_for(55, community_id)

        expect { avatars.drain }.not_to raise_error
        expect(avatars.url_for(55, community_id)).to be_nil
        expect(stored_rows).to be_empty
      end
    end

    it "answers nothing when the store itself fails" do
      allow(files).to receive(:store_file).and_raise(Rubotty::ControlPlane::RehostedFiles::Invalid,
                                                     "the file store is not usable")
      avatars.url_for(55, community_id)

      expect { avatars.drain }.not_to raise_error
      expect(avatars.url_for(55, community_id)).to be_nil
    end

    it "answers nothing when Telegram refuses to say what the photo is" do
      @photos = lambda do |_user_id|
        raise Rubotty::AdapterError.new("Telegram getUserProfilePhotos failed (400): Bad Request",
                                        adapter: :telegram)
      end
      avatars.url_for(55, community_id)

      expect { avatars.drain }.not_to raise_error
      expect(avatars.url_for(55, community_id)).to be_nil
      expect(stored_rows).to be_empty
    end

    it "answers nothing when getFile gives no URL to pull from" do
      @file_url = ->(_file_id) { nil }
      avatars.url_for(55, community_id)
      avatars.drain

      expect(avatars.url_for(55, community_id)).to be_nil
      expect(stored_rows).to be_empty
    end

    it "answers nothing when the Bot API returns something the wrong shape" do
      @photos = ->(_user_id) { "not a response object" }
      avatars.url_for(55, community_id)

      expect { avatars.drain }.not_to raise_error
      expect(avatars.url_for(55, community_id)).to be_nil
    end
  end

  describe "what may be handed out" do
    # The one thing this must never do. SafeUrl already refuses such a URL at
    # every outbound path, so caching one would only ever produce a silent nil,
    # and the refusal belongs here as well.
    it "refuses a credentialed URL even if the rehoster somehow answered one" do
      allow(rehoster).to receive(:rehost).and_return(telegram_url)
      avatars.url_for(55, community_id)
      avatars.drain

      expect(avatars.url_for(55, community_id)).to be_nil
    end

    # Without RUBOTTY_FILE_STORAGE_URL the download link has no host, and a relative URL
    # is not something another platform can fetch.
    it "refuses a link with no host, which is what an unset portal URL produces" do
      allow(rehoster).to receive(:rehost).and_return("/filestorage/abcdef.jpg")
      avatars.url_for(55, community_id)
      avatars.drain

      expect(avatars.url_for(55, community_id)).to be_nil
    end

    it "answers nothing without a community to keep the copy for" do
      expect(avatars.url_for(55, nil)).to be_nil
      expect(avatars.drain).to eq(0)
    end
  end

  describe "the background worker" do
    subject(:avatars) do
      described_class.new(
        photos: ->(user_id) { @photos.call(user_id) },
        file_url: ->(file_id) { @file_url.call(file_id) },
        rehoster: rehoster, logger: Rubotty::Log.null, clock: -> { @now }
      )
    end

    # #stop closes the queue, which lets the worker finish what is already on it
    # and then end, so a shutdown neither hangs nor drops a copy half made.
    it "runs a queued refresh on its own thread and finishes it on stop" do
      avatars.url_for(55, community_id)
      avatars.stop

      expect(avatars.url_for(55, community_id)).to start_with("https://rubotty.test/filestorage/")
    end

    it "is safe to stop having never been asked for anything" do
      expect { avatars.stop }.not_to raise_error
    end
  end
end
