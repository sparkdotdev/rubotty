# frozen_string_literal: true

require "spec_helper"
require "rubotty"
require "tmpdir"

# A container sets no locale, so Ruby picks US-ASCII for Encoding.default_external, and
# every bare File.read inherits it; one accented character is then enough to raise
# ArgumentError. The failure is invisible on a developer machine with a locale set, so this
# spec asserts the property rather than trusting the environment to have it.
RSpec.describe "the default external encoding" do
  it "is UTF-8, whatever the host's locale says" do
    expect(Encoding.default_external).to eq(Encoding::UTF_8)
  end

  # Left alone on purpose: forcing a transcode on every read would change what a
  # byte sequence we did not author turns into.
  it "leaves the internal encoding unset" do
    expect(Encoding.default_internal).to be_nil
  end

  it "reads a file holding non-ASCII without annotating the call" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "note.md")
      File.write(path, "Bridging a room in Köln, naïvely. Ação.\n")

      expect { File.read(path).match?(/K/) }.not_to raise_error
      expect(File.read(path)).to include("Köln")
    end
  end

  # The two documents the web surface renders, which are the ones that took it
  # down. Read the way the renderer reads them.
  it "reads the documents the dashboard serves" do
    names = %w[README.md LICENSE.MD CONTRIBUTING.md]
    begin
      File.lstat(File.expand_path("../docs/scripting.md", __dir__))
      names << "docs/scripting.md"
    rescue Errno::ENOENT
      # The private reference is intentionally absent from source catalogues.
    end
    names.each do |name|
      path = File.expand_path("../#{name}", __dir__)

      expect { File.read(path).scan(/^#/) }.not_to raise_error, "#{name} could not be scanned"
    end
  end
end
