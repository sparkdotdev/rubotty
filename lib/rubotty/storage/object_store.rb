# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "openssl"
require "securerandom"
require "zlib"

module Rubotty
  module Storage
    # The one place this deployment puts bulk bytes: a filesystem object
    # store that compresses then encrypts everything it is given (gzip over
    # an AES-256-GCM sink, so neither form is ever whole in memory) and
    # streams both ways; the database keeps only metadata. The key derives
    # per object from a one-time UUID, returned to the caller once and never
    # written down here, so losing it is unrecoverable on purpose.
    # Encryption matters since the production store is a plain ext4 disk on
    # removable media; {SENTINEL} guards against a missing mount.
    class ObjectStore
      # Raised for anything the store cannot do. A caller catches this one class.
      class Error < Rubotty::Error; end

      # The store directory is missing, unwritable, or looks like an unmounted
      # volume. Raised at startup or on enabling a feature, never at first write.
      class Unavailable < Error; end

      # The object could not be unsealed: a wrong or absent secret, a truncated
      # file, or a blob whose GCM tag does not verify. One class for all three,
      # because a reader must not be able to tell them apart.
      class Unreadable < Error; end

      # A source exceeded the caller's byte limit. Raised mid-stream, so an
      # oversized upload is refused without ever being held whole.
      class TooLarge < Error
        attr_reader :limit

        def initialize(limit)
          @limit = limit
          super("the source is larger than the #{limit} byte limit")
        end
      end

      # How much is moved per read/write, keeping the working set flat.
      CHUNK_BYTES = 64 * 1024

      # HKDF inputs. Changing either makes every existing object unreadable, so
      # a future change bumps the version suffix rather than editing in place.
      SALT = "rubotty.object-store.v1"
      INFO = "rubotty sealed object v1"

      CIPHER = "aes-256-gcm"
      IV_BYTES = 12
      KEY_BYTES = 32

      # Written into the store directory the first time it initialises cleanly,
      # and required from then on. See the class note on the +nofail+ mount.
      SENTINEL = ".rubotty-object-store"

      # Container-local, so development only. Production points
      # behaviour.file_store_path (or {PATH_VAR}) at a mounted disk.
      DEFAULT_PATH = "data/object-store"

      # The environment variable that overrides the configured path. Must
      # name a subdirectory dedicated to this store, never a mount point
      # itself: see {INIT_VAR} for why a bare mount root cannot be told
      # apart from an unmounted disk.
      PATH_VAR = "RUBOTTY_FILE_STORE"

      # Set to 1 for exactly one boot, to claim an existing empty directory
      # as a new store, then unset it again. Off by default because an empty
      # directory is what an unmounted disk looks like: a deployment scope
      # that carries this as a standing variable will re-claim that empty
      # directory as "new" every time the real disk fails to mount, and go
      # on writing sealed objects to whatever filesystem is actually there
      # without ever saying so.
      INIT_VAR = "RUBOTTY_FILE_STORE_INIT"

      # The store directory to use. The environment wins over the configured
      # value because the same config file is deployed to hosts that differ.
      def self.path_from(configured, env = ENV)
        from_env = env[PATH_VAR].to_s.strip
        return from_env unless from_env.empty?

        text = configured.to_s.strip
        text.empty? ? DEFAULT_PATH : text
      end

      # A sealed object, as {#put} hands it back. +secret+ is the one-time UUID,
      # not stored here: a caller that wants the object again keeps it, or keeps
      # {.digest} of it.
      Sealed = Struct.new(:key, :secret, :iv, :auth_tag, :byte_size, :sealed_bytes, keyword_init: true)

      # @param root [String] the directory objects live under, a mounted disk in
      #   production
      # @param logger [#info, #warn, nil]
      def initialize(root:, logger: nil, env: ENV)
        @root = File.expand_path(root.to_s)
        @logger = logger
        @env = env
      end

      attr_reader :root

      # SHA-256 hex digest of a secret, or nil for a blank one. This is what a
      # caller stores for lookup: a database holding both the blob's location
      # and its key would make the sealing worthless.
      def self.digest(secret)
        string = secret.to_s
        return nil if string.empty?

        Digest::SHA256.hexdigest(string)
      end

      # Make sure the store is usable, or raise {Unavailable} saying why.
      # Creates the directory and its sentinel when neither exists, refuses a
      # directory that exists without one (an unmounted volume), and refuses
      # {INIT_VAR} claiming a mount point directly rather than a subdirectory.
      def ready!
        if File.exist?(sentinel_path)
          raise Unavailable, "#{@root} is not writable" unless File.writable?(@root)

          return true
        end

        claiming = Dir.exist?(@root)
        if claiming
          raise Unavailable, mount_root_message if init_requested? && mount_point?(@root)
          raise Unavailable, unmounted_message unless initialisable?
        end

        begin
          FileUtils.mkdir_p(@root)
          File.binwrite(sentinel_path, "rubotty object store\n")
        rescue SystemCallError => e
          raise Unavailable, "could not initialise the object store at #{@root}: #{e.message}"
        end

        if claiming
          # This is the one event {INIT_VAR} exists to gate, so it is worth
          # noticing even when nothing is wrong: confirms the flag did what it
          # was set for, and flags it if the flag was left standing.
          @logger&.warn { "#{INIT_VAR}=1 claimed #{@root} as a new object store; unset it now" }
        else
          @logger&.info { "object store initialised at #{@root}" }
        end
        true
      end

      # Whether {#ready!} would succeed, for a caller that degrades rather than
      # fails, such as the relay.
      def ready?
        ready!
        true
      rescue Unavailable
        false
      end

      # Bytes free on the filesystem {#root} lives on, via +df+ rather than a
      # gem: no platform-specific extension to compile, at the cost of parsing
      # a subprocess's output. nil when that cannot be answered (df missing,
      # unparsed output, root not yet created), which a caller must treat as
      # "unknown", never as "space is free".
      def free_bytes
        target = Dir.exist?(@root) ? @root : File.dirname(@root)
        out, status = Open3.capture2("df", "-Pk", target)
        return nil unless status.success?

        line = out.lines[1]
        fields = line.to_s.split(/\s+/)
        return nil if fields.length < 4

        Integer(fields[3]) * 1024
      rescue StandardError
        nil
      end

      # Seal +source+ into a new object and return its {Sealed} metadata:
      # +source+ is anything answering +read(length)+ with a String or nil
      # at end. Read in {CHUNK_BYTES} chunks and never held whole.
      #
      # @param namespace [String] what KIND of thing this is ("rehosted",
      #   "guest-upload"), keeping two callers from colliding
      # @param limit [Integer, nil] refuse a source larger than this many
      #   plaintext bytes, raising {TooLarge} mid-stream. Nil for no limit.
      def put(namespace:, scope:, source:, limit: nil)
        ready!
        key = new_key(namespace, scope)
        path = path_for(key)
        FileUtils.mkdir_p(File.dirname(path))

        secret = SecureRandom.uuid
        iv = OpenSSL::Random.random_bytes(IV_BYTES)
        cipher = OpenSSL::Cipher.new(CIPHER).encrypt
        cipher.key = self.class.derive_key(secret)
        cipher.iv = iv

        plain_bytes = 0
        begin
          File.open(path, "wb") do |file|
            sink = EncryptingSink.new(file, cipher)
            gzip = Zlib::GzipWriter.new(sink)
            while (chunk = source.read(CHUNK_BYTES))
              break if chunk.empty?

              plain_bytes += chunk.bytesize
              raise TooLarge, limit if limit && plain_bytes > limit

              gzip.write(chunk)
            end
            # #finish rather than #close: the gzip trailer has to be flushed
            # through the sink, but the underlying File is ours to close.
            gzip.finish
            auth_tag = sink.finish
            return Sealed.new(key: key, secret: secret, iv: iv, auth_tag: auth_tag,
                              byte_size: plain_bytes, sealed_bytes: sink.bytes)
          end
        rescue StandardError
          # Nothing else knows the key yet, so a half-written object has no
          # reference anywhere else.
          delete(key)
          raise
        end
      end

      # Stream an object's plaintext back, yielding {CHUNK_BYTES}-ish chunks.
      # Raises {Unreadable} for a wrong or absent secret, a missing or
      # truncated file, or a blob whose GCM tag does not verify; the tag is
      # checked only once the whole ciphertext has been consumed.
      #
      # @yieldparam chunk [String] plaintext, in order
      # @return [Integer] plaintext bytes yielded
      def open(key:, secret:, iv:, auth_tag:)
        path = path_for(key)
        raise Unreadable, "no such object" unless key_ok?(key) && File.file?(path)

        cipher = OpenSSL::Cipher.new(CIPHER).decrypt
        cipher.key = self.class.derive_key(secret)
        cipher.iv = iv.to_s
        cipher.auth_tag = auth_tag.to_s
        written = 0
        File.open(path, "rb") do |file|
          source = DecryptingSource.new(file, cipher, File.size(path))
          gzip = Zlib::GzipReader.new(source)
          while (chunk = gzip.read(CHUNK_BYTES))
            written += chunk.bytesize
            yield chunk
          end
          gzip.finish
          # Force the tag check even if gzip stopped reading before the last
          # ciphertext byte.
          source.finish!
        end
        written
      rescue OpenSSL::Cipher::CipherError, Zlib::Error, ArgumentError, SystemCallError, IOError => e
        raise Unreadable, "the object could not be unsealed (#{e.class})"
      end

      # Whether the object's bytes still authenticate, handing none of them
      # out: {#open} verifies the GCM tag only once the last ciphertext byte
      # is read, so a serving route may have already sent 200 and a
      # Content-Length by the time it finds out. A route that can afford the
      # second pass asks this first, so the status it sends is one it can
      # keep.
      def intact?(key:, secret:, iv:, auth_tag:)
        open(key: key, secret: secret, iv: iv, auth_tag: auth_tag) { |_chunk| nil }
        true
      rescue Unreadable
        false
      end

      # The whole plaintext as a String, for a caller that wants it in memory.
      # Everything on the serving path uses {#open} instead.
      def read(key:, secret:, iv:, auth_tag:)
        out = +""
        open(key: key, secret: secret, iv: iv, auth_tag: auth_tag) { |chunk| out << chunk }
        out
      end

      # Whether the object's bytes are still on disk.
      def exist?(key) = key_ok?(key) && File.file?(path_for(key))

      # Remove an object's bytes, returning true when there were bytes to
      # remove. Idempotent, and never raises: deletion runs from an expiry
      # job that must keep going through one bad row.
      # +missing_ok+ also returns true for ENOENT; other unlink errors stay false.
      def delete(key, missing_ok: false)
        return false unless key_ok?(key)
        return false if missing_ok && !File.file?(sentinel_path)

        File.delete(path_for(key))
        prune_empty_dirs(File.dirname(path_for(key)))
        true
      rescue Errno::ENOENT
        missing_ok && File.file?(sentinel_path)
      rescue SystemCallError => e
        @logger&.warn { "object store could not delete an object: #{e.message}" }
        false
      end

      # Every object key under +namespace+, for a caller reconciling the store
      # against the rows that should point at it. +before+ skips anything
      # written since, so a blob whose row is still being written is not offered
      # up as unreferenced.
      #
      # @return [Array<String>]
      def keys(namespace:, before: nil)
        prefix = segment(namespace)
        dir = File.join(@root, prefix)
        return [] unless Dir.exist?(dir)

        Dir.glob("*/*/*", base: dir).filter_map do |relative|
          key = "#{prefix}/#{relative}"
          path = path_for(key)
          next unless key_ok?(key) && File.file?(path)
          next if before && File.mtime(path) >= before

          key
        end
      rescue SystemCallError => e
        @logger&.warn { "object store could not list #{namespace}: #{e.message}" }
        []
      end

      # The 32-byte AES key a secret derives. Public so a spec can prove the raw
      # UUID is not the key.
      def self.derive_key(secret)
        OpenSSL::KDF.hkdf(secret.to_s, salt: SALT, info: INFO, length: KEY_BYTES, hash: "SHA256")
      end

      private

      def sentinel_path = File.join(@root, SENTINEL)

      # Whether a sentinel-less directory may be adopted. Empty is not enough: an
      # unmounted nofail disk leaves an empty directory behind.
      def initialisable?
        return false unless File.writable?(@root)
        return false unless (Dir.children(@root) - [".", ".."]).empty?

        init_requested?
      rescue SystemCallError
        false
      end

      def init_requested? = @env[INIT_VAR].to_s.strip == "1"

      # Whether +path+ is itself a mount point rather than a subdirectory
      # under one: its device differs from its parent's. Only meaningful
      # while the filesystem in question is actually mounted, which is the
      # normal case for a deliberate {INIT_VAR} boot; it cannot catch the
      # unmounted nofail case this whole class exists to guard, because an
      # unmounted mount point and an ordinary directory are indistinguishable
      # by device. That case is what the {SENTINEL} check above is for.
      def mount_point?(path)
        File.stat(path).dev != File.stat(File.dirname(path)).dev
      rescue SystemCallError
        false
      end

      def mount_root_message
        "#{@root} is a mount point itself, not a subdirectory of one, and #{INIT_VAR}=1 is set. " \
          "Claiming a mount root directly means an unmounted disk and a fresh empty store become " \
          "indistinguishable the next time this boots, which is exactly the failure the #{SENTINEL} " \
          "marker exists to catch. Point #{PATH_VAR} at a subdirectory under the mount instead, the " \
          "way production names #{PATH_VAR}=<mount>/rubotty/object-store, then retry with " \
          "#{INIT_VAR}=1 still set."
      end

      def unmounted_message
        "#{@root} exists but holds no #{SENTINEL} marker. On the production host this directory is " \
          "a mount point, mounted nofail, so an unmounted disk leaves an ordinary empty directory " \
          "behind it: writing there would fill the root filesystem and disappear when the disk " \
          "returns. Mount the volume, or point the store somewhere else. If this really is a new " \
          "store on a disk that is mounted, set #{INIT_VAR}=1 for one boot to claim the directory, " \
          "then take it back out."
      end

      # "namespace/scope/ab/<random>". The two-character level keeps any one
      # directory from growing to hundreds of thousands of entries.
      def new_key(namespace, scope)
        name = SecureRandom.hex(16)
        [segment(namespace), segment(scope), name[0, 2], name].join("/")
      end

      # A path component reduced to what is safe in a filename. The caller
      # supplies namespace and scope, so neither is trusted to be free of "..".
      def segment(value)
        text = value.to_s.gsub(/[^A-Za-z0-9_-]/, "-")[0, 64].to_s
        text.empty? ? "unscoped" : text
      end

      # Keys come back from database rows, so a path is only rebuilt from
      # components matching what {#new_key} writes.
      def key_ok?(key)
        parts = key.to_s.split("/")
        parts.size == 4 && parts.all? { |part| part.match?(/\A[A-Za-z0-9_-]+\z/) }
      end

      def path_for(key) = File.join(@root, key.to_s)

      # So a community whose objects have all expired leaves no empty
      # directories behind.
      def prune_empty_dirs(dir)
        2.times do
          break if dir == @root || !Dir.exist?(dir) || !(Dir.children(dir) - [".", ".."]).empty?

          Dir.rmdir(dir)
          dir = File.dirname(dir)
        end
      rescue SystemCallError
        nil
      end

      # What Zlib::GzipWriter writes into. Every compressed chunk is encrypted on
      # its way to the file.
      class EncryptingSink
        def initialize(io, cipher)
          @io = io
          @cipher = cipher
          @bytes = 0
        end

        # Sealed bytes actually written.
        attr_reader :bytes

        def write(data)
          emit(@cipher.update(data))
          data.bytesize
        end

        # Flush the cipher and return the GCM tag. The caller stores the tag; it
        # is not appended to the file.
        def finish
          emit(@cipher.final)
          @cipher.auth_tag
        end

        private

        def emit(out)
          return if out.nil? || out.empty?

          @io.write(out)
          @bytes += out.bytesize
        end
      end

      # What Zlib::GzipReader reads from. Answers +read+ with decrypted bytes, so
      # the decompressor sees the gzip stream and never the ciphertext.
      class DecryptingSource
        def initialize(io, cipher, remaining)
          @io = io
          @cipher = cipher
          @remaining = remaining
          @finished = false
        end

        def read(length = nil)
          return nil if @finished && @remaining.zero?

          want = length.nil? ? @remaining : [length, @remaining].min
          return finish_as_read if want.zero?

          raw = @io.read(want)
          return finish_as_read if raw.nil? || raw.empty?

          @remaining -= raw.bytesize
          out = @cipher.update(raw)
          out += finish! if @remaining.zero?
          out
        end

        # Consume anything left and verify the GCM tag. Raises when it does not
        # match, which is how a tampered blob fails loudly.
        def finish!
          return "" if @finished

          while @remaining.positive?
            raw = @io.read([CHUNK_BYTES, @remaining].min)
            break if raw.nil? || raw.empty?

            @remaining -= raw.bytesize
            @cipher.update(raw)
          end
          @finished = true
          @cipher.final
        end

        private

        # End of stream for the decompressor: nil, unless the tag check left a
        # final block to hand over first.
        def finish_as_read
          tail = finish!
          tail.empty? ? nil : tail
        end
      end
    end
  end
end
