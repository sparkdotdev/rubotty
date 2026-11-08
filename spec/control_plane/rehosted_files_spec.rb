# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# The first thing in rubotty that keeps member-uploaded file content, so the promises
# made in exchange are what matter: no key in the database, an expiry that deletes the
# bytes, and no reading across communities.
RSpec.describe Rubotty::ControlPlane::RehostedFiles, :control_plane do
  around do |example|
    Dir.mktmpdir("rubotty-rehosted") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:seeded) { seeded_sample }
  let(:models) { seeded[1] }
  let(:community) { models.community.where(slug: "sample").first }

  let(:other) do
    now = Time.now
    models.community.create(slug: "other-co", name: "Other Co", status: "active",
                            settings: "{}", created_at: now, updated_at: now)
  end

  let(:store) { Rubotty::Storage::ObjectStore.new(root: @root) }
  # Local rather than UTC: a timestamp comes back naive on SQLite and is read in the
  # process's own zone, so a UTC fixture would compare an hour out off UTC.
  let(:now) { Time.new(2026, 7, 30, 12, 0, 0) }
  let(:files) { described_class.new(models: models, store: store, clock: -> { now }) }

  let(:payload) { "a video nobody can send on Discord. " * 5_000 }

  def keep(bytes = payload, community_id: community.id, **rest)
    files.store_file(community_id: community_id, source: StringIO.new(bytes), room_key: "general",
                     filename: "clip.mp4", content_type: "video/mp4", **rest)
  end

  def read(stored, secret: stored.secret)
    out = +""
    files.stream(stored.file, secret: secret) { |chunk| out << chunk }
    out
  end

  describe "storing and fetching" do
    it "brings the exact bytes back through the whole round trip" do
      stored = keep

      found = files.fetch(secret: stored.secret)
      expect(found.id).to eq(stored.file.id)
      expect(read(stored)).to eq(payload)
    end

    it "records the metadata a reader needs without unsealing anything" do
      stored = keep

      expect(stored.file.filename).to eq("clip.mp4")
      expect(stored.file.content_type).to eq("video/mp4")
      expect(stored.file.byte_size).to eq(payload.bytesize)
      expect(stored.file.sealed_bytes).to be_positive
    end

    # The row is the lock and the link is the key, so a row holding both undoes the seal.
    it "stores only a digest of the secret, never the secret" do
      stored = keep
      row = models.rehosted_file[stored.file.id]

      expect(row.token_hash).to eq(Rubotty::Storage::ObjectStore.digest(stored.secret))
      expect(row.values.values.map(&:to_s)).not_to include(stored.secret)
    end

    it "refuses a wrong secret" do
      stored = keep

      expect(files.fetch(secret: SecureRandom.uuid)).to be_nil
      expect { read(stored, secret: SecureRandom.uuid) }
        .to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end

    it "refuses a file over the cap without storing anything" do
      expect { keep(limit: 1024) }.to raise_error(Rubotty::Storage::ObjectStore::TooLarge)
      expect(models.rehosted_file.count).to be_zero
    end
  end

  # A community's total-stored-bytes ceiling, distinct from the per-file cap
  # above: a file well under max_bytes on its own can still be refused for what
  # it would push the community's running total over.
  describe "the community quota" do
    def set_quota(bytes, community_id: community.id)
      models.feature_setting.create(
        community_id: community_id, room_id: nil, feature: "file_rehosting", enabled: true,
        config: Rubotty::ControlPlane::Models.dump_json({ "quota_bytes" => bytes }),
        created_at: Time.now, updated_at: Time.now
      )
    end

    it "defaults to a generous quota that an ordinary file never comes near" do
      expect(described_class::DEFAULT_QUOTA_BYTES).to be > described_class::DEFAULT_MAX_BYTES
      expect { keep(limit: payload.bytesize) }.not_to raise_error
    end

    it "accepts a file that fits under a community's own smaller quota" do
      set_quota(payload.bytesize + 10)

      expect { keep(limit: payload.bytesize) }.not_to raise_error
    end

    it "refuses a file that would push the total over quota, naming the quota rather than the file cap" do
      set_quota(payload.bytesize - 10)

      expect { keep(limit: payload.bytesize) }
        .to raise_error(described_class::QuotaExceeded, /quota/)
      expect(models.rehosted_file.count).to be_zero
    end

    it "counts what is already stored before accepting another file" do
      keep
      used = files.sealed_bytes_for(community_id: community.id)
      set_quota(used + 10)

      expect { keep(limit: payload.bytesize) }.to raise_error(described_class::QuotaExceeded)
    end

    it "scopes the quota to one community, so a full neighbour does not block this one" do
      set_quota(payload.bytesize - 10, community_id: community.id)

      expect { keep(limit: payload.bytesize, community_id: other.id) }.not_to raise_error
    end
  end

  describe "the free space guard" do
    it "refuses a write when the store reports too little free space left" do
      allow(store).to receive(:free_bytes).and_return(described_class::MIN_FREE_BYTES)

      expect { keep(limit: payload.bytesize) }
        .to raise_error(described_class::InsufficientSpace, /free/)
      expect(models.rehosted_file.count).to be_zero
    end

    it "is silent when the store cannot answer how much space is free" do
      allow(store).to receive(:free_bytes).and_return(nil)

      expect { keep(limit: payload.bytesize) }.not_to raise_error
    end

    it "allows a write that leaves the reserve intact" do
      allow(store).to receive(:free_bytes).and_return(described_class::MIN_FREE_BYTES + payload.bytesize + 10)

      expect { keep(limit: payload.bytesize) }.not_to raise_error
    end
  end

  # Only the digest is stored, so no fresh link can be derived from a row: the caller
  # supplies the secret it holds and the object is written out again under a new key.
  describe "rotating a link" do
    it "returns a new secret that reads the identical bytes" do
      stored = keep

      rotated = files.rotate(secret: stored.secret)

      expect(rotated.secret).not_to eq(stored.secret)
      expect(read(rotated)).to eq(payload)
    end

    it "kills the old secret" do
      stored = keep

      files.rotate(secret: stored.secret)

      expect(files.fetch(secret: stored.secret)).to be_nil
    end

    it "is the same file afterwards, not a second one" do
      stored = keep

      rotated = files.rotate(secret: stored.secret)

      expect(rotated.file.id).to eq(stored.file.id)
      expect(rotated.file.filename).to eq("clip.mp4")
      expect(rotated.file.byte_size).to eq(payload.bytesize)
      expect(models.rehosted_file.count).to eq(1)
    end

    it "really re-encrypts, rather than pointing at the same bytes" do
      stored = keep
      previous = stored.file.object_key

      rotated = files.rotate(secret: stored.secret)

      expect(rotated.file.object_key).not_to eq(previous)
      expect(store.exist?(previous)).to be(false)
      expect(store.exist?(rotated.file.object_key)).to be(true)
    end

    # Rotating weekly must not hold a file forever, so the expiry stays where it was.
    it "leaves the expiry where it was" do
      stored = keep(ttl_days: 3)
      before = stored.file.expires_at

      rotated = files.rotate(secret: stored.secret)

      expect(rotated.file.expires_at).to eq(before)
    end

    # 64 KiB is the store's own chunk, so this crosses the boundary often enough to
    # prove the move is streamed.
    it "moves a file far larger than one chunk" do
      big = "0123456789abcdef" * 40_000
      stored = keep(big)

      rotated = files.rotate(secret: stored.secret)

      expect(read(rotated)).to eq(big)
    end

    it "answers nil for a secret that names nothing" do
      expect(files.rotate(secret: SecureRandom.uuid)).to be_nil
    end

    it "answers nil for another community's file, and leaves it readable" do
      theirs = keep(community_id: other.id)

      expect(files.rotate(secret: theirs.secret, community_id: community.id)).to be_nil
      expect(read(theirs)).to eq(payload)
    end
  end

  describe "marking one expired" do
    it "brings the expiry forward so the next sweep takes it" do
      stored = keep

      files.mark_expired(secret: stored.secret)

      expect(stored.file.refresh.expires_at.to_time).to be_within(1).of(now)
    end

    # Waiting for the sweep would leave a leaked link working for up to a day.
    it "kills the link immediately, before any sweep runs" do
      stored = keep

      files.mark_expired(secret: stored.secret)

      expect(files.fetch(secret: stored.secret)).to be_nil
      expect(store.exist?(stored.file.object_key)).to be(true)
    end

    # Deletion stays in one place, so only one piece of code orders bytes before row.
    it "leaves the bytes for the sweep, which then takes them" do
      stored = keep
      files.mark_expired(secret: stored.secret)

      files.expire(now: now + 1)

      expect(store.exist?(stored.file.object_key)).to be(false)
      expect(models.rehosted_file.count).to be_zero
    end

    it "answers nil for a secret that names nothing" do
      expect(files.mark_expired(secret: SecureRandom.uuid)).to be_nil
    end

    it "answers nil for another community's file, and leaves it alone" do
      theirs = keep(community_id: other.id)

      expect(files.mark_expired(secret: theirs.secret, community_id: community.id)).to be_nil
      expect(files.fetch(secret: theirs.secret)).not_to be_nil
    end
  end

  describe "retention" do
    # The default sits at the ceiling, because a link that dies while the
    # conversation is still being read was the common complaint.
    it "defaults to a year" do
      stored = keep

      expect(described_class::DEFAULT_TTL_DAYS).to eq(described_class::MAX_TTL_DAYS)
      expect(stored.file.expires_at.to_time)
        .to be_within(1).of(now + (described_class::DEFAULT_TTL_DAYS * 86_400))
    end

    it "takes a community's own retention" do
      stored = keep(ttl_days: 3)

      expect(stored.file.expires_at.to_time).to be_within(1).of(now + (3 * 86_400))
    end

    # Shortening is free, lengthening is bounded, since the bytes sit on rubotty's disk.
    it "clamps a retention nobody should be able to set" do
      stored = keep(ttl_days: 10_000)

      expect(stored.file.expires_at.to_time)
        .to be_within(1).of(now + (described_class::MAX_TTL_DAYS * 86_400))
    end

    it "falls back to the default for a nonsensical value" do
      expect(files.clamp_ttl(0)).to eq(described_class::DEFAULT_TTL_DAYS)
      expect(files.clamp_ttl(-5)).to eq(described_class::DEFAULT_TTL_DAYS)
    end
  end

  describe "expiry" do
    # A row marked expired while its blob sits on disk is only unreachable, which is
    # less than the retention promises.
    it "deletes the bytes from the store, not only the row" do
      stored = keep(ttl_days: 1)
      key = stored.file.object_key
      expect(store.exist?(key)).to be(true)

      later = described_class.new(models: models, store: store, clock: -> { now + (2 * 86_400) })
      expect(later.expire).to eq(1)

      expect(store.exist?(key)).to be(false)
      expect(models.rehosted_file[stored.file.id]).to be_nil
      expect { read(stored) }.to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end

    it "leaves a file that is still inside its retention alone" do
      stored = keep(ttl_days: 30)

      expect(files.expire).to be_zero
      expect(read(stored)).to eq(payload)
    end

    # A file stops downloading the moment it lapses, whether or not the daily job ran.
    it "stops answering for a lapsed file before the job has run" do
      stored = keep(ttl_days: 1)

      later = described_class.new(models: models, store: store, clock: -> { now + (2 * 86_400) })
      expect(later.fetch(secret: stored.secret)).to be_nil
    end
  end

  describe "multi-tenancy" do
    it "will not fetch one community's file under another's scope" do
      stored = keep

      expect(files.fetch(secret: stored.secret, community_id: other.id)).to be_nil
      expect(files.fetch(secret: stored.secret, community_id: community.id)).not_to be_nil
    end

    it "lists only the asking community's files" do
      keep
      keep(community_id: other.id)

      expect(files.list(community_id: community.id).size).to eq(1)
      expect(files.list(community_id: other.id).size).to eq(1)
    end

    # The object key begins with the owning community's id, bounding what a row names.
    it "files a community's bytes under its own subtree" do
      mine = keep
      theirs = keep(community_id: other.id)

      expect(mine.file.object_key).to start_with("rehosted/#{community.id}/")
      expect(theirs.file.object_key).to start_with("rehosted/#{other.id}/")
    end

    it "removes one community's files and leaves the other's" do
      mine = keep
      theirs = keep(community_id: other.id)

      files.forget_community(community_id: community.id)

      expect(store.exist?(mine.file.object_key)).to be(false)
      expect(store.exist?(theirs.file.object_key)).to be(true)
    end
  end

  # A rehosted link served anyone holding it, unlimited times, for the whole
  # retention window. #store_file sizes each row's serve_limit once, up front,
  # and #record_serve is the only thing that ever spends it.
  describe "the serve ceiling" do
    def counting_adapter(count)
      adapter = double("adapter")
      allow(adapter).to receive(:community_member_count).and_return(count)
      adapter
    end

    it "defaults to the flat ceiling with no adapters wired to size it from" do
      stored = keep

      expect(stored.file.serve_limit).to eq(described_class::SERVE_LIMIT_FLAT)
      expect(stored.file.served_count).to eq(0)
    end

    it "takes an explicit override instead of computing one" do
      stored = keep(serve_limit: 7)

      expect(stored.file.serve_limit).to eq(7)
    end

    it "sizes the ceiling from every connected platform's live membership when every one answers" do
      adapters = { [:telegram, "telegram"] => counting_adapter(30), [:discord, "discord"] => counting_adapter(15) }
      sized = described_class.new(models: models, store: store, clock: -> { now }, adapters: adapters)

      stored = sized.store_file(community_id: community.id, source: StringIO.new(payload), room_key: "general",
                                filename: "clip.mp4", content_type: "video/mp4")

      expect(stored.file.serve_limit).to eq(45)
    end

    it "caps a large sum at the flat ceiling rather than issuing an unbounded link" do
      adapters = { [:telegram, "telegram"] => counting_adapter(9_000), [:discord, "discord"] => counting_adapter(1) }
      sized = described_class.new(models: models, store: store, clock: -> { now }, adapters: adapters)

      stored = sized.store_file(community_id: community.id, source: StringIO.new(payload), room_key: "general",
                                filename: "clip.mp4", content_type: "video/mp4")

      expect(stored.file.serve_limit).to eq(described_class::SERVE_LIMIT_FLAT)
    end

    it "falls back to the flat ceiling the moment any one platform cannot answer, never as zero" do
      adapters = { [:telegram, "telegram"] => counting_adapter(3), [:discord, "discord"] => counting_adapter(nil) }
      sized = described_class.new(models: models, store: store, clock: -> { now }, adapters: adapters)

      stored = sized.store_file(community_id: community.id, source: StringIO.new(payload), room_key: "general",
                                filename: "clip.mp4", content_type: "video/mp4")

      expect(stored.file.serve_limit).to eq(described_class::SERVE_LIMIT_FLAT)
    end

    # Rubotards has four members: without a floor, that is the ceiling a
    # naive sum would issue, and the platforms' own preview fetches could
    # exhaust it before anyone saw the file.
    it "floors a tiny community's computed ceiling rather than mint a two or three serve link" do
      adapters = { [:telegram, "telegram"] => counting_adapter(2), [:discord, "discord"] => counting_adapter(2) }
      sized = described_class.new(models: models, store: store, clock: -> { now }, adapters: adapters)

      stored = sized.store_file(community_id: community.id, source: StringIO.new(payload), room_key: "general",
                                filename: "clip.mp4", content_type: "video/mp4")

      expect(stored.file.serve_limit).to eq(described_class::SERVE_LIMIT_FLOOR)
    end

    describe "#exhausted?" do
      it "is false under the ceiling and true once served_count reaches it" do
        stored = keep(serve_limit: 2)

        expect(files.exhausted?(stored.file)).to be(false)
        stored.file.update(served_count: 2)
        expect(files.exhausted?(stored.file.refresh)).to be(true)
      end
    end

    describe "#preview_window?" do
      it "is true right after the row is created" do
        stored = keep

        expect(files.preview_window?(stored.file, now: now + 1)).to be(true)
      end

      it "is false once PREVIEW_GRACE_SECONDS has passed" do
        stored = keep

        expect(files.preview_window?(stored.file, now: now + described_class::PREVIEW_GRACE_SECONDS + 1)).to be(false)
      end
    end

    describe "#record_serve" do
      it "spends one serve and reports success" do
        stored = keep(serve_limit: 3)

        expect(files.record_serve(stored.file)).to be(true)
        expect(stored.file.refresh.served_count).to eq(1)
      end

      it "refuses once the ceiling is reached, writing nothing more" do
        stored = keep(serve_limit: 1)
        files.record_serve(stored.file)

        expect(files.record_serve(stored.file)).to be(false)
        expect(stored.file.refresh.served_count).to eq(1)
      end

      # The increment and the ceiling check are one UPDATE, so two requests
      # racing for the last slot cannot both succeed.
      it "lets only one of two requests racing for the last slot through" do
        stored = keep(serve_limit: 1)

        first = files.record_serve(stored.file)
        second = files.record_serve(stored.file)

        expect([first, second]).to contain_exactly(true, false)
        expect(stored.file.refresh.served_count).to eq(1)
      end
    end

    describe "#serves_remaining" do
      it "counts down from the ceiling and floors at zero" do
        stored = keep(serve_limit: 2)

        expect(files.serves_remaining(stored.file)).to eq(2)
        files.record_serve(stored.file)
        expect(files.serves_remaining(stored.file.refresh)).to eq(1)
        files.record_serve(stored.file.refresh)
        files.record_serve(stored.file.refresh)
        expect(files.serves_remaining(stored.file.refresh)).to eq(0)
      end
    end
  end

  # #rotate repoints the row before it unlinks the old object, so anything that
  # stops the process between the two strands bytes nothing will ever ask for.
  describe "the orphan sweep" do
    def age(key, seconds)
      path = File.join(@root, key)
      File.utime(now - seconds, now - seconds, path)
    end

    it "collects the blob a rotation left behind when the unlink never ran" do
      stored = keep
      orphaned = stored.file.object_key
      allow(store).to receive(:delete).with(orphaned).and_return(false)
      rotated = files.rotate(secret: stored.secret)
      allow(store).to receive(:delete).and_call_original
      expect(store.exist?(orphaned)).to be(true)

      age(orphaned, described_class::ORPHAN_GRACE + 60)
      expect(files.sweep_orphans).to eq(1)

      expect(store.exist?(orphaned)).to be(false)
      expect(store.exist?(rotated.file.object_key)).to be(true)
    end

    it "leaves a blob a row still points at" do
      stored = keep
      age(stored.file.object_key, described_class::ORPHAN_GRACE + 60)

      expect(files.sweep_orphans).to eq(0)
      expect(store.exist?(stored.file.object_key)).to be(true)
    end

    # A large upload writes its bytes before its row, so a sweep racing one must
    # not read the gap as an orphan.
    it "leaves a blob younger than the grace period alone" do
      stored = keep
      orphaned = stored.file.object_key
      allow(store).to receive(:delete).with(orphaned).and_return(false)
      files.rotate(secret: stored.secret)
      allow(store).to receive(:delete).and_call_original

      expect(files.sweep_orphans).to eq(0)
      expect(store.exist?(orphaned)).to be(true)
    end

    it "leaves another namespace's blobs alone" do
      guest = store.put(namespace: "guest", scope: community.id, source: StringIO.new("guest bytes"))
      age(guest.key, described_class::ORPHAN_GRACE + 60)

      expect(files.sweep_orphans).to eq(0)
      expect(store.exist?(guest.key)).to be(true)
    end
  end
end
