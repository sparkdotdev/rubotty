# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The shape {Util::ImageShrinker} and {Util::VideoTranscoder} both build on: a
# deadline enforced from outside, a process group killed on expiry, and now an
# environment the child does not get to inherit whole. Driven here against a
# stand-in encoder, so nothing waits on ffmpeg or ImageMagick being installed.
RSpec.describe Rubotty::Util::BoundedCommand do
  around do |example|
    Dir.mktmpdir("rubotty-bounded-command-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  # A shell script standing in for an encoder: a real executable, spawned the
  # same way, that reports what it can see of its own environment.
  def fake_encoder(script_body)
    script = File.join(@dir, "fake-encoder")
    File.write(script, "#!/bin/sh\n#{script_body}\n")
    File.chmod(0o755, script)
    script
  end

  %w[stdout stderr].each do |stream|
    it "stops excessive #{stream} before the relay retains unbounded output" do
      redirect = stream == "stderr" ? ">&2" : ""
      binary = fake_encoder("head -c #{described_class::OUTPUT_LIMIT + 8192} /dev/zero #{redirect}")

      result = described_class.new(timeout: 5).run([binary])

      expect(result.ok?).to be(false)
      expect(result.timed_out?).to be(false)
      expect(result.stdout).to eq("")
      expect(result.stderr).to eq("encoder output limit exceeded")
    end
  end

  it "enforces its deadline after the child closes both output pipes" do
    binary = fake_encoder("exec 1>&- 2>&-\nsleep 5")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = described_class.new(timeout: 0.1).run([binary])

    expect(result).to be_timed_out
    expect(result).not_to be_ok
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
  end

  describe "the child's environment" do
    around do |example|
      original_token = ENV.fetch("RUBOTTY_TEST_TOKEN", nil)
      original_tmpdir = ENV.fetch("TMPDIR", nil)
      ENV["RUBOTTY_TEST_TOKEN"] = "do-not-leak-this-token"
      ENV["TMPDIR"] = "/tmp/rubotty-bounded-command-test-tmpdir"
      example.run
    ensure
      original_token.nil? ? ENV.delete("RUBOTTY_TEST_TOKEN") : ENV["RUBOTTY_TEST_TOKEN"] = original_token
      original_tmpdir.nil? ? ENV.delete("TMPDIR") : ENV["TMPDIR"] = original_tmpdir
    end

    it "does not hand an encoder subprocess this process's tokens" do
      binary = fake_encoder(<<~SH)
        echo "TOKEN=$RUBOTTY_TEST_TOKEN"
        echo "PATH_SET=${PATH:+yes}"
      SH

      result = described_class.new(timeout: 5).run([binary])

      expect(result.stdout).to include("TOKEN=\n")
      expect(result.stdout).to include("PATH_SET=yes")
    end

    it "uses the bundled image policy even when the parent selects another policy" do
      previous = ENV.fetch("MAGICK_CONFIGURE_PATH", nil)
      ENV["MAGICK_CONFIGURE_PATH"] = @dir
      binary = fake_encoder('printf "%s" "$MAGICK_CONFIGURE_PATH"')

      result = described_class.new(timeout: 5).run([binary])

      expect(result.stdout).to eq(File.expand_path("../../config/imagemagick", __dir__))
      expect(File.file?(File.join(result.stdout, "policy.xml"))).to be(true)
    ensure
      previous.nil? ? ENV.delete("MAGICK_CONFIGURE_PATH") : ENV["MAGICK_CONFIGURE_PATH"] = previous
    end

    # ffmpeg and ImageMagick can spill scratch data past the input and output
    # paths this class already hands them, so TMPDIR rides along rather than
    # being dropped with the rest of ENV.
    it "passes TMPDIR through, unlike the rest of this process's environment" do
      binary = fake_encoder('echo "TMPDIR=$TMPDIR"')

      result = described_class.new(timeout: 5).run([binary])

      expect(result.stdout).to include("TMPDIR=/tmp/rubotty-bounded-command-test-tmpdir")
    end
  end
end
