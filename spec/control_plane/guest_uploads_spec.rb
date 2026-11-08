# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "stringio"

# The guest-upload store, whose bytes live in Storage::ObjectStore rather than
# the database, under a serve secret minted fresh per upload.
RSpec.describe Rubotty::ControlPlane::GuestUploads, :control_plane do
  around do |example|
    with_object_store_root do |root|
      @root = root
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }
  let(:room) { models.room.where(community_id: community.id, room_key: "general").first }

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }

  let(:invites) { Rubotty::ControlPlane::GuestInvites.new(models: models) }
  before do
    Rubotty::ControlPlane::FeatureControls.new(models: models)
                                          .enable(community: community, selector: "general", feature: "guest_portal")
  end
  let(:invite) do
    invites.issue(community: community, room: room, nickname: "Sam", ttl_seconds: 3600).invite
  end

  subject(:uploads) { described_class.new(models: models, store: store) }

  # Crosses the store's 64 KiB chunk boundary several times, so the round trip
  # exercises the streaming path.
  let(:payload) { "a photo a guest dropped into the room. " * 20_000 }

  def store!(bytes: payload, filename: "photo.png", content_type: "image/png", **rest)
    uploads.store_file(invite: invite, source: StringIO.new(bytes), filename: filename,
                       content_type: content_type, **rest)
  end

  describe "#store_file and #fetch" do
    it "round-trips the exact bytes, filename, type and size under a fresh secret" do
      stored = store!
      expect(stored.secret).not_to be_empty
      expect(stored.byte_size).to eq(payload.bytesize)

      row = uploads.fetch(secret: stored.secret)
      expect(row.filename).to eq("photo.png")
      expect(row.content_type).to eq("image/png")

      out = +""
      uploads.stream(row, secret: stored.secret) { |chunk| out << chunk }
      expect(out).to eq(payload)
    end

    it "mints a distinct secret per upload" do
      expect(store!(bytes: "a").secret).not_to eq(store!(bytes: "b").secret)
    end

    it "scopes the stored row to the invite's room, no single channel (issue #156)" do
      stored = store!(bytes: "a")
      row = uploads.fetch(secret: stored.secret)
      expect(row.room_id).to eq(room.id)
      expect(row.channel_id).to be_nil
    end

    it "is nil for an unknown secret, revealing nothing" do
      expect(uploads.fetch(secret: SecureRandom.uuid)).to be_nil
      expect(uploads.fetch(secret: "")).to be_nil
      expect(uploads.fetch(secret: nil)).to be_nil
    end

    it "reduces a path-bearing filename to its basename" do
      expect(store!(bytes: "x", filename: "../../etc/passwd").filename).to eq("passwd")
    end

    it "normalises a missing content type to a safe generic" do
      expect(store!(bytes: "x", filename: "f", content_type: "").content_type)
        .to eq("application/octet-stream")
    end

    it "refuses a source past the caller's limit, leaving nothing behind" do
      expect { store!(bytes: "x" * 5_000, limit: 1_000) }
        .to raise_error(Rubotty::Storage::ObjectStore::TooLarge)
      expect(models.guest_upload.count).to eq(0)
      expect(stored_objects(@root, "guest-upload")).to be_empty
    end
  end

  # What the row keeps must not be enough to open the file.
  describe "what the database is left holding" do
    it "stores the digest of the serve secret and never the secret" do
      stored = store!(bytes: "PNGDATA")
      row = models.guest_upload.first

      expect(row.token_hash).to eq(Rubotty::Storage::ObjectStore.digest(stored.secret))
      expect(row.values.values.map(&:to_s)).not_to include(stored.secret)
    end

    it "has no column carrying the bytes, only where they are and how big" do
      store!(bytes: "PNGDATA")
      row = models.guest_upload.first

      expect(row.values).not_to have_key(:data)
      expect(row.object_key).to start_with("guest-upload/#{community.id}/")
      expect(row.byte_size).to eq("PNGDATA".bytesize)
      expect(row.sealed_bytes).to be_positive
    end

    it "keeps a guest's bytes out of the rehosted namespace on disk" do
      store!(bytes: "PNGDATA")
      expect(Dir.children(@root) - [Rubotty::Storage::ObjectStore::SENTINEL]).to eq(["guest-upload"])
    end

    it "refuses to unseal with the wrong secret, rather than handing back rubbish" do
      stored = store!
      row = uploads.fetch(secret: stored.secret)

      expect { uploads.stream(row, secret: SecureRandom.uuid) { |_chunk| nil } }
        .to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end

    it "writes a blob that is not the plaintext, so the disk gives nothing away" do
      store!(bytes: "a guest said something private here")
      blob = stored_objects(@root, "guest-upload").first

      expect(File.binread(blob)).not_to include("private")
    end
  end

  describe "#forget_bytes" do
    it "keeps cleanup retryable when the mounted store's sentinel disappears" do
      stored = store!(bytes: "PNGDATA")
      row = uploads.fetch(secret: stored.secret)
      File.delete(File.join(@root, Rubotty::Storage::ObjectStore::SENTINEL))
      expect(uploads.forget_bytes(row, missing_ok: true)).to be(false)
      expect(store.exist?(row.object_key)).to be(true)
    end

    it "can confirm absence while keeping unlink errors retryable" do
      stored = store!(bytes: "PNGDATA")
      row = uploads.fetch(secret: stored.secret)
      path = File.join(@root, row.object_key)
      allow(File).to receive(:delete).with(path).and_raise(Errno::EACCES)
      expect(uploads.forget_bytes(row, missing_ok: true)).to be(false)
      allow(File).to receive(:delete).with(path).and_call_original
      expect(uploads.forget_bytes(row, missing_ok: true)).to be(true)
      expect(uploads.forget_bytes(row, missing_ok: true)).to be(true)
    end

    it "unlinks the object, leaving the row for the caller to delete" do
      stored = store!(bytes: "PNGDATA")
      row = uploads.fetch(secret: stored.secret)

      expect(uploads.forget_bytes(row)).to be(true)
      expect(store.exist?(row.object_key)).to be(false)
      expect(models.guest_upload.count).to eq(1)
    end

    it "is quiet about a row whose bytes have already gone" do
      stored = store!(bytes: "PNGDATA")
      row = uploads.fetch(secret: stored.secret)
      uploads.forget_bytes(row)

      expect(uploads.forget_bytes(row)).to be(false)
    end
  end

  describe "#sweep_orphans" do
    it "removes old unreferenced objects while preserving current rows and recent writes" do
      stored = store!(bytes: "referenced")
      row = uploads.fetch(secret: stored.secret)
      old = store.put(namespace: described_class::NAMESPACE, scope: community.id, source: StringIO.new("orphan"))
      recent = store.put(namespace: described_class::NAMESPACE, scope: community.id, source: StringIO.new("recent"))
      now = Time.now
      [row.object_key, old.key].each do |key|
        File.utime(now - 7200, now - 7200, File.join(@root, key))
      end
      expect(uploads.sweep_orphans(now: now)).to eq(1)
      expect(store.exist?(old.key)).to be(false)
      expect(store.exist?(recent.key)).to be(true)
      expect(store.exist?(row.object_key)).to be(true)
    end
  end
end
