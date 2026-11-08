# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"

# The sealed object store, the one place this deployment puts bulk bytes. A blob on
# disk is only opaque if a wrong key cannot open it and a tampered one cannot pass,
# and a mount that did not come up has to be an error rather than a fresh empty
# store, so those refusals are spelled out below alongside the round trip.
RSpec.describe Rubotty::Storage::ObjectStore do
  around do |example|
    Dir.mktmpdir("rubotty-object-store") do |dir|
      @root = File.join(dir, "objects")
      example.run
    end
  end

  let(:store) { described_class.new(root: @root) }

  def put(bytes, **rest)
    store.put(namespace: "rehosted", scope: 7, source: StringIO.new(bytes), **rest)
  end

  def read(sealed, secret: sealed.secret)
    store.read(key: sealed.key, secret: secret, iv: sealed.iv, auth_tag: sealed.auth_tag)
  end

  # One payload that compresses, so the sealed size says something, and one that
  # does not, so nothing here depends on compressible input.
  let(:repetitive) { "rubotty relays messages. " * 20_000 }
  let(:incompressible) { OpenSSL::Random.random_bytes(200_000) }

  describe "the round trip" do
    it "gives back exactly the bytes it was given" do
      sealed = put(repetitive)

      expect(read(sealed)).to eq(repetitive)
      expect(sealed.byte_size).to eq(repetitive.bytesize)
    end

    it "gives back bytes that do not compress, unchanged" do
      sealed = put(incompressible)

      expect(read(sealed)).to eq(incompressible)
    end

    # Compress THEN encrypt: ciphertext is indistinguishable from random and would
    # not compress at all the other way round.
    it "compresses before it encrypts, so a repetitive file lands much smaller" do
      sealed = put(repetitive)

      expect(sealed.sealed_bytes).to be < (repetitive.bytesize / 10)
    end

    it "streams rather than buffering, yielding the file in pieces" do
      sealed = put(repetitive)
      pieces = []
      store.open(key: sealed.key, secret: sealed.secret, iv: sealed.iv, auth_tag: sealed.auth_tag) do |chunk|
        pieces << chunk.bytesize
      end

      expect(pieces.size).to be > 1
      expect(pieces.sum).to eq(repetitive.bytesize)
      expect(pieces.max).to be <= described_class::CHUNK_BYTES
    end
  end

  describe "the secret" do
    # The row stores this and never the secret itself, so a database dump plus a
    # copy of the disk still yields nothing.
    it "hashes to a digest that is not the secret" do
      digest = described_class.digest("a-secret")

      expect(digest).to match(/\A[0-9a-f]{64}\z/)
      expect(digest).not_to include("a-secret")
      expect(described_class.digest("")).to be_nil
    end

    # HKDF rather than the raw UUID bytes, a UUID being 122 bits of entropy in a
    # fixed textual layout.
    it "derives a 32-byte key that is not the UUID itself" do
      secret = SecureRandom.uuid
      key = described_class.derive_key(secret)

      expect(key.bytesize).to eq(32)
      expect(key).not_to eq(secret)
      expect(key).not_to eq(secret.delete("-"))
    end

    it "refuses a wrong secret rather than handing back rubbish" do
      sealed = put(repetitive)

      expect { read(sealed, secret: SecureRandom.uuid) }
        .to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end

    it "refuses an absent secret" do
      sealed = put(repetitive)

      expect { read(sealed, secret: nil) }.to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
      expect { read(sealed, secret: "") }.to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end
  end

  describe "tampering" do
    it "fails the authentication tag when a byte of the blob is changed" do
      sealed = put(repetitive)
      path = File.join(@root, sealed.key)
      bytes = File.binread(path)
      middle = bytes.bytesize / 2
      bytes[middle] = (bytes[middle].ord ^ 0xff).chr
      File.binwrite(path, bytes)

      expect { read(sealed) }.to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end

    it "fails when the stored tag does not match the blob" do
      sealed = put(repetitive)
      wrong = sealed.auth_tag.dup
      wrong[0] = (wrong[0].ord ^ 0x01).chr

      expect { store.read(key: sealed.key, secret: sealed.secret, iv: sealed.iv, auth_tag: wrong) }
        .to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end

    it "fails when the blob is truncated" do
      sealed = put(repetitive)
      path = File.join(@root, sealed.key)
      bytes = File.binread(path)
      File.binwrite(path, bytes[0, bytes.bytesize - 32])

      expect { read(sealed) }.to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end
  end

  # #open only checks the tag once the last ciphertext byte is read, which is
  # after a serving route has sent 200 and a Content-Length. A route that can
  # afford the second pass asks first.
  describe "#intact?" do
    def intact?(sealed, secret: sealed.secret)
      store.intact?(key: sealed.key, secret: secret, iv: sealed.iv, auth_tag: sealed.auth_tag)
    end

    it "is true for an object that still authenticates" do
      expect(intact?(put(repetitive))).to be(true)
    end

    it "is false for a byte changed near the end, where a stream finds out too late" do
      sealed = put(repetitive)
      path = File.join(@root, sealed.key)
      bytes = File.binread(path)
      bytes[-1] = (bytes.getbyte(-1) ^ 0xff).chr
      File.binwrite(path, bytes)

      expect(intact?(sealed)).to be(false)
    end

    it "is false for a wrong secret, a missing object and a wrong tag" do
      sealed = put(repetitive)

      expect(intact?(sealed, secret: SecureRandom.uuid)).to be(false)
      expect(store.intact?(key: "rehosted/7/nope", secret: sealed.secret,
                           iv: sealed.iv, auth_tag: sealed.auth_tag)).to be(false)
    end
  end

  describe "the size cap" do
    # Enforced WHILE streaming, so an oversized source is refused without ever being
    # held whole, which is what makes it usable on a browser upload.
    it "refuses a source larger than the limit" do
      expect { put(repetitive, limit: 1024) }.to raise_error(Rubotty::Storage::ObjectStore::TooLarge)
    end

    it "leaves nothing behind when it refuses" do
      begin
        put(repetitive, limit: 1024)
      rescue Rubotty::Storage::ObjectStore::TooLarge
        nil
      end

      files = Dir.glob(File.join(@root, "**", "*"), File::FNM_DOTMATCH).reject { |path| File.directory?(path) }
      expect(files.map { |path| File.basename(path) }).to eq([described_class::SENTINEL])
    end

    it "accepts a source exactly at the limit" do
      sealed = put("x" * 1024, limit: 1024)

      expect(read(sealed).bytesize).to eq(1024)
    end
  end

  describe "deletion" do
    it "removes the bytes from the disk, not only the reference" do
      sealed = put(repetitive)
      path = File.join(@root, sealed.key)
      expect(File.file?(path)).to be(true)

      expect(store.delete(sealed.key)).to be(true)
      expect(File.file?(path)).to be(false)
      expect(store.exist?(sealed.key)).to be(false)
    end

    it "is a harmless no-op the second time" do
      sealed = put(repetitive)
      store.delete(sealed.key)

      expect(store.delete(sealed.key)).to be(false)
    end
  end

  describe "namespacing" do
    # Two callers must not collide, and one community's objects have to form a
    # subtree so they can be found and removed together.
    it "files an object under its namespace and its scope" do
      sealed = store.put(namespace: "rehosted", scope: 42, source: StringIO.new("hi"))

      expect(sealed.key).to start_with("rehosted/42/")
      expect(File.file?(File.join(@root, sealed.key))).to be(true)
    end

    it "refuses to let a namespace or scope escape the root" do
      sealed = store.put(namespace: "../../etc", scope: "../..", source: StringIO.new("hi"))

      expect(sealed.key).not_to include("..")
      expect(File.expand_path(File.join(@root, sealed.key))).to start_with(@root)
    end

    it "will not read a key that did not come from it" do
      expect { store.read(key: "../../etc/passwd", secret: "x", iv: "y", auth_tag: "z") }
        .to raise_error(Rubotty::Storage::ObjectStore::Unreadable)
    end
  end

  # The production directory is a mount, mounted nofail, so a disk that did not come
  # up leaves an ordinary empty directory behind it. Writing there would fill the
  # root filesystem and vanish when the disk returned, so a directory with no marker
  # has to be an error rather than a fresh start.
  describe "the mount check" do
    it "initialises a fresh store and leaves its marker" do
      expect(store.ready!).to be(true)
      expect(File.file?(File.join(@root, described_class::SENTINEL))).to be(true)
    end

    # The case the whole check exists for: an unmounted disk leaves an EMPTY
    # directory, and adopting one on sight filled the root filesystem. env is named
    # here rather than inherited, spec_helper setting the claim flag suite-wide.
    it "refuses an empty directory it was not told to claim" do
      FileUtils.mkdir_p(@root)
      unclaimed = described_class.new(root: @root, env: {})

      expect { unclaimed.ready! }.to raise_error(Rubotty::Storage::ObjectStore::Unavailable, /marker/)
      expect(File.exist?(File.join(@root, described_class::SENTINEL))).to be(false)
    end

    it "claims an empty directory when the operator says to" do
      FileUtils.mkdir_p(@root)
      claiming = described_class.new(root: @root, env: { described_class::INIT_VAR => "1" })

      expect(claiming.ready!).to be(true)
      expect(File.file?(File.join(@root, described_class::SENTINEL))).to be(true)
    end

    # Claiming is for one boot: once the marker is down the flag is spent.
    it "needs the flag only once, since the marker answers afterwards" do
      FileUtils.mkdir_p(@root)
      described_class.new(root: @root, env: { described_class::INIT_VAR => "1" }).ready!

      expect(store.ready!).to be(true)
    end

    it "still refuses a directory holding files, flag or no flag" do
      FileUtils.mkdir_p(@root)
      File.binwrite(File.join(@root, "something.bin"), "not ours")
      claiming = described_class.new(root: @root, env: { described_class::INIT_VAR => "1" })

      expect { claiming.ready! }.to raise_error(Rubotty::Storage::ObjectStore::Unavailable, /marker/)
    end

    it "refuses a directory that has content but no marker, which is an unmounted volume" do
      FileUtils.mkdir_p(@root)
      File.binwrite(File.join(@root, "something.bin"), "not ours")

      expect { store.ready! }.to raise_error(Rubotty::Storage::ObjectStore::Unavailable, /marker/)
      expect(store.ready?).to be(false)
    end

    it "refuses to store anything into a store it will not initialise" do
      FileUtils.mkdir_p(@root)
      File.binwrite(File.join(@root, "something.bin"), "not ours")

      expect { put("hi") }.to raise_error(Rubotty::Storage::ObjectStore::Unavailable)
    end

    # A pinned INIT_VAR pointed at a mount root, rather than a subdirectory
    # of one, is the exact preview misconfiguration issue #1764 is about:
    # fail loudly on the boots where the disk IS mounted, rather than only
    # discovering it on the rare unmounted one.
    it "refuses a mount point itself even with the claim flag set" do
      FileUtils.mkdir_p(@root)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(@root).and_return(instance_double(File::Stat, dev: 1))
      allow(File).to receive(:stat).with(File.dirname(@root)).and_return(instance_double(File::Stat, dev: 2))
      claiming = described_class.new(root: @root, env: { described_class::INIT_VAR => "1" })

      expect { claiming.ready! }
        .to raise_error(Rubotty::Storage::ObjectStore::Unavailable, /mount point itself/)
      expect(File.exist?(File.join(@root, described_class::SENTINEL))).to be(false)
    end

    it "still claims a subdirectory of a mount, same device as its parent" do
      FileUtils.mkdir_p(@root)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(@root).and_return(instance_double(File::Stat, dev: 1))
      allow(File).to receive(:stat).with(File.dirname(@root)).and_return(instance_double(File::Stat, dev: 1))
      claiming = described_class.new(root: @root, env: { described_class::INIT_VAR => "1" })

      expect(claiming.ready!).to be(true)
    end

    it "logs loudly when the claim flag actually claims a directory" do
      FileUtils.mkdir_p(@root)
      logger = instance_double(Logger, warn: nil, info: nil)
      claiming = described_class.new(root: @root, logger: logger, env: { described_class::INIT_VAR => "1" })

      claiming.ready!

      expect(logger).to have_received(:warn)
      expect(logger).not_to have_received(:info)
    end

    it "logs quietly for a directory that never existed, no claim involved" do
      logger = instance_double(Logger, warn: nil, info: nil)
      fresh = described_class.new(root: @root, logger: logger, env: {})

      fresh.ready!

      expect(logger).to have_received(:info)
      expect(logger).not_to have_received(:warn)
    end
  end

  describe "the configured path" do
    it "prefers the environment, so a deployment names its own mount" do
      expect(described_class.path_from("/from/config", { "RUBOTTY_FILE_STORE" => "/mnt/bulk-storage" }))
        .to eq("/mnt/bulk-storage")
    end

    it "falls back to the configured value, then to the default" do
      expect(described_class.path_from("/from/config", {})).to eq("/from/config")
      expect(described_class.path_from(nil, {})).to eq(described_class::DEFAULT_PATH)
      expect(described_class.path_from("  ", {})).to eq(described_class::DEFAULT_PATH)
    end
  end

  describe "#free_bytes" do
    it "answers a positive byte count for a real, existing filesystem" do
      expect(store.free_bytes).to be_a(Integer).and be_positive
    end

    # Asserted against the df invocation itself rather than two live byte counts:
    # a busy disk can genuinely answer two df calls moments apart with slightly
    # different numbers, which made this flaky without saying anything false.
    it "reads off the parent directory when the store root does not exist yet" do
      expect(Open3).to receive(:capture2).with("df", "-Pk", File.dirname(@root))
                                          .and_call_original

      store.free_bytes
    end

    it "answers nil rather than raise when df cannot be found" do
      allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT)

      expect(store.free_bytes).to be_nil
    end

    it "answers nil rather than raise when df's own output will not parse" do
      allow(Open3).to receive(:capture2).and_return(["not df output\n", instance_double(Process::Status, success?: true)])

      expect(store.free_bytes).to be_nil
    end
  end
end
