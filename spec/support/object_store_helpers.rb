# frozen_string_literal: true

require "tmpdir"

# RUBOTTY_FILE_STORE beats a configured +file_store_path:+, and spec_helper points
# it at one directory for the whole run, so a spec that inspects the disk needs its
# own root for the length of one example.
module ObjectStoreHelpers
  # Run the block with a fresh, empty store root, both configured and in the
  # environment, and put the previous value back afterwards.
  #
  # @yieldparam root [String] the directory, not yet created: an ObjectStore
  #   initialises it.
  def with_object_store_root
    Dir.mktmpdir("rubotty-object-store") do |dir|
      root = File.join(dir, "objects")
      previous = ENV.fetch("RUBOTTY_FILE_STORE", nil)
      ENV["RUBOTTY_FILE_STORE"] = root
      begin
        yield root
      ensure
        ENV["RUBOTTY_FILE_STORE"] = previous
      end
    end
  end

  # Every sealed object under one namespace, so a spec can count what is on disk.
  def stored_objects(root, namespace)
    Dir.glob(File.join(root, namespace, "**", "*")).select { |path| File.file?(path) }
  end

  # Flip the last ciphertext byte of a stored object, so it decrypts and then
  # fails its authentication tag at the very end, which is the case a streaming
  # serve cannot take back.
  def corrupt_last_byte(key)
    path = File.join(ENV.fetch("RUBOTTY_FILE_STORE"), key)
    bytes = File.binread(path)
    bytes[-1] = (bytes.getbyte(-1) ^ 0xff).chr
    File.binwrite(path, bytes)
  end
end

RSpec.configure { |config| config.include(ObjectStoreHelpers) }
