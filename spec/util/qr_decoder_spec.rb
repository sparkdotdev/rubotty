# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Util::QrDecoder do
  # A 111x111 PNG QR code encoding a WhatsApp invite, generated with
  # `qrencode` and shrunk with ImageMagick; small enough to embed as text
  # rather than checking in a binary fixture. Real QR encoding (version
  # selection, error correction, masking) is not something to hand-roll in a
  # spec, so this is decoded, never built, here.
  QR_FIXTURE_PNG = <<~B64.gsub(/\s+/, "").unpack1("m0")
    iVBORw0KGgoAAAANSUhEUgAAAG8AAABvAQMAAADYCwwjAAAABlBMVEUAAAD///+l2Z/dAAAAAnRS
    TlP//8i138cAAAAJcEhZcwAACxIAAAsSAdLdfvwAAAEnSURBVDiN1dQ7joQwDAZgoxTp4AKWco10
    uRJcAJgLwJXS5RpIXCB0KSK8hpnZRxOnWK200TQf0hDb+g3QjwP/gxFgCurhEcCIPCgPYV90nqiC
    HifCKWGvq9hrGG2u5Oj2CHWk3FsE91VkgdzvEJB/n+0XyOcEWr8NtsAICDaPTi22hvsa1MzXvaoq
    8XS5C7nj4d8XlXkkdRB2tIGtIbY8dm0WLTNqNV9jx+ZZZJFH4CsAnJmfryry1LT6O11JJv+389zC
    9VxkdGq94g1NMCKvqDjoAmeAZPqdApe0U6ogbTzz1kHjjUg+0ebBmwgy78TSDLw+JJJbmJJ5eHMk
    I9PjQJyr93Aq2ATeiCr2ziywAZDMe3+b9FqcMrnf3m2t5RjI/LMv8K/xA9gqJ5+1yOl/AAAAAElF
    TkSuQmCC
  B64

  after { described_class.reset_availability! }

  describe ".available?" do
    it "answers a boolean and memoises it" do
      first = described_class.available?
      expect([true, false]).to include(first)
      expect(described_class.available?).to eq(first)
    end
  end

  describe "#decode" do
    it "answers [] for empty bytes without even checking availability" do
      expect(described_class).not_to receive(:available?)
      expect(described_class.new.decode("")).to eq([])
      expect(described_class.new.decode(nil)).to eq([])
    end

    it "answers [] when libzbar is unavailable, rather than raising" do
      allow(described_class).to receive(:available?).and_return(false)

      expect(described_class.new.decode("some bytes")).to eq([])
    end

    it "answers [] when no ImageMagick binary is on the host" do
      allow(described_class).to receive(:available?).and_return(true)
      decoder = described_class.new(image_binary: nil)

      expect(decoder.decode("some bytes")).to eq([])
    end

    it "answers [] when the ImageMagick conversion fails" do
      allow(described_class).to receive(:available?).and_return(true)
      failing = instance_double(Rubotty::Util::BoundedCommand,
                                 run: Rubotty::Util::BoundedCommand::Result.new(
                                   status: nil, stdout: "", stderr: "boom", timed_out: false
                                 ))
      decoder = described_class.new(image_binary: "magick", command: failing)

      expect(decoder.decode("some bytes")).to eq([])
    end

    it "decodes a real QR code end to end" do
      unless described_class.available? && Rubotty::Util::ImageShrinker.available?
        skip "libzbar or ImageMagick is not on this machine"
      end

      decoded = described_class.new.decode(QR_FIXTURE_PNG, filename: "invite.png")

      expect(decoded).to eq(["https://chat.whatsapp.com/AbCdEfGhIjKlMnOpQrSt"])
    end
  end
end
