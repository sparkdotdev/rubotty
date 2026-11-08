# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Util::OcrReader do
  # A small 1-bit PNG reading "RUBOTTYINVITECODE" in a monospace font,
  # generated with ImageMagick; small enough to embed as text rather than
  # checking in a binary fixture.
  OCR_FIXTURE_PNG = <<~B64.gsub(/\s+/, "").unpack1("m0")
    iVBORw0KGgoAAAANSUhEUgAAAcwAAABGAQAAAABp/JkhAAABZUlEQVRYw+3UsW7CMBAG4EMZPGZl
    82tkqOSxz4H6Eh0QEerA6Efoq1AxeOQVEnlgjcVylVxfLxAgUJKaLl1sL5bsbzj7PwP9dTSQaKKJ
    JproDxqg1K4StPSQAZjwBIUyEhtoIAcReKIgEPepYjohONDNDcWJz3AyRKdSu3odpvOWWj+HQhrd
    0byZ4QzXJeR3qcq1szhfKOS1Q7LI1JEmS5LqL4foS3m/VqWZ+gG6IaZBDdFVS19JthQdU32hhnjr
    Abo1xvYpyTGKeKT+ham5UD1Ouda66tPdiULe0ZEbrrKOBsHUmt0uioJsI9FRypnujTVxtOzVeqDu
    RH+rtVC9G27PxlMlbyma/TaehuKKOh39ONfUP5+peZh+vscF0fTif6BBnOkv8efs3FKUcU1nP97q
    ajEtj9RDQcJLPsGREKdWFwO0EhUQUJ+qjo5/MNzesspo2aOrMx391h4diSaaaKKJ/jP9Bsz/s68d
    CwppAAAAAElFTkSuQmCC
  B64

  after { described_class.reset_availability! }

  describe ".available?" do
    it "answers a boolean and memoises it" do
      first = described_class.available?
      expect([true, false]).to include(first)
      expect(described_class.available?).to eq(first)
    end
  end

  def with_tesseract(body)
    Dir.mktmpdir("rubotty-ocr-command") do |dir|
      binary = File.join(dir, "tesseract")
      File.write(binary, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, binary)
      previous = ENV.fetch("PATH", "")
      ENV["PATH"] = dir + File::PATH_SEPARATOR + previous
      described_class.reset_availability!
      yield
    ensure
      ENV["PATH"] = previous
      described_class.reset_availability!
    end
  end

  describe "#read" do
    it "answers \"\" for empty bytes without even checking availability" do
      expect(described_class).not_to receive(:available?)
      expect(described_class.new.read("")).to eq("")
      expect(described_class.new.read(nil)).to eq("")
    end

    it "answers \"\" when no tesseract binary is on the host, rather than raising" do
      allow(described_class).to receive(:available?).and_return(false)

      expect(described_class.new.read("some bytes")).to eq("")
    end

    it "answers \"\" rather than raising when tesseract fails on unreadable input" do
      skip "tesseract is not on this machine" unless described_class.available?

      expect(described_class.new.read("not an image")).to eq("")
    end

    it "does not hand the OCR executable platform credentials" do
      previous = ENV.fetch("RUBOTTY_OCR_TEST_SECRET", nil)
      ENV["RUBOTTY_OCR_TEST_SECRET"] = "fixture-only-secret"
      with_tesseract('printf "%s" "${RUBOTTY_OCR_TEST_SECRET-unset}"') do
        expect(described_class.new.read("fixture image")).to eq("unset")
      end
    ensure
      previous.nil? ? ENV.delete("RUBOTTY_OCR_TEST_SECRET") : ENV["RUBOTTY_OCR_TEST_SECRET"] = previous
    end

    it "stops an OCR executable that overruns its deadline" do
      with_tesseract("sleep 30") do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(described_class.new(timeout: 0.1).read("fixture image")).to eq("")
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      end
    end

    it "uses bounded argument-based execution and the requested language" do
      allow(described_class).to receive(:available?).and_return(true)
      command = instance_double(Rubotty::Util::BoundedCommand)
      result = Rubotty::Util::BoundedCommand::Result.new(
        status: instance_double(Process::Status, success?: true), stdout: " detected text \n", stderr: ""
      )
      expect(command).to receive(:run) do |argv|
        expect(argv.values_at(0, 2, 3, 4)).to eq(["tesseract", "stdout", "-l", "fra"])
        expect(File.binread(argv[1])).to eq("fixture image")
        result
      end

      expect(described_class.new(language: "fra", command: command).read("fixture image")).to eq("detected text")
    end

    it "returns no text when a bounded OCR invocation is refused" do
      allow(described_class).to receive(:available?).and_return(true)
      command = instance_double(Rubotty::Util::BoundedCommand,
                                run: Rubotty::Util::BoundedCommand::Result.new(timed_out: true, stdout: "partial"))

      expect(described_class.new(command: command).read("fixture image")).to eq("")
    end

    it "reads real text off a real image end to end" do
      skip "tesseract is not on this machine" unless described_class.available?

      text = described_class.new.read(OCR_FIXTURE_PNG, filename: "invite.png")

      expect(text.gsub(/\s+/, "")).to include("RUBOTTYINVITECODE")
    end
  end
end
