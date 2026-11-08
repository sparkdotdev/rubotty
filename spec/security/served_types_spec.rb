# frozen_string_literal: true

require "spec_helper"
require "rubotty"

RSpec.describe Rubotty::Security::ServedTypes do
  describe ".normalise" do
    it "keeps a well-formed type" do
      expect(described_class.normalise("image/png")).to eq("image/png")
    end

    it "lowercases and trims" do
      expect(described_class.normalise("  IMAGE/PNG ")).to eq("image/png")
    end

    it "drops parameters, so a charset cannot ride along into a comparison" do
      expect(described_class.normalise("text/plain; charset=utf-8")).to eq("text/plain")
    end

    it "falls back to bytes for a blank type" do
      expect(described_class.normalise("")).to eq("application/octet-stream")
      expect(described_class.normalise(nil)).to eq("application/octet-stream")
    end

    it "falls back to bytes for anything that is not a media type" do
      ["not a type", "image", "image/", "/png", "image/png\nX-Evil: 1", "a" * 300].each do |bad|
        expect(described_class.normalise(bad)).to eq("application/octet-stream"), bad.inspect
      end
    end
  end

  describe ".inline?" do
    it "allows the image, audio and video types on the list" do
      expect(described_class.inline?("image/png")).to be(true)
      expect(described_class.inline?("audio/mpeg")).to be(true)
      expect(described_class.inline?("video/mp4")).to be(true)
      expect(described_class.inline?("text/plain")).to be(true)
    end

    it "refuses the scripting contexts" do
      %w[
        text/html application/xhtml+xml image/svg+xml text/javascript
        application/javascript application/pdf application/xml text/xml
      ].each do |type|
        expect(described_class.inline?(type)).to be(false), type
      end
    end

    it "refuses a scripting type dressed in a parameter" do
      expect(described_class.inline?("text/html; charset=utf-8")).to be(false)
    end

    it "refuses an unknown type rather than guessing" do
      expect(described_class.inline?("application/zip")).to be(false)
    end
  end

  describe ".disposition" do
    it "renders what is on the list and downloads the rest" do
      expect(described_class.disposition("image/png")).to eq("inline")
      expect(described_class.disposition("text/html")).to eq("attachment")
    end
  end

  describe ".allowed" do
    it "announces a renderable type as itself" do
      expect(described_class.allowed("image/png")).to eq("image/png")
    end

    it "announces everything else as bytes, whatever the row says" do
      expect(described_class.allowed("text/html")).to eq("application/octet-stream")
      expect(described_class.allowed("image/svg+xml")).to eq("application/octet-stream")
    end
  end
end
