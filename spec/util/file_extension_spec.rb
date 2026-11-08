# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Util::FileExtension do
  describe ".for" do
    it "keeps a filename's own extension when it looks safe" do
      expect(described_class.for(filename: "clip.MP4", content_type: "video/quicktime")).to eq("mp4")
    end

    it "falls back to the content type when the filename has none" do
      expect(described_class.for(filename: "clip", content_type: "video/mp4")).to eq("mp4")
    end

    it "falls back to the content type when the filename's own extension is not a safe token" do
      expect(described_class.for(filename: "report.final draft", content_type: "application/pdf")).to eq("pdf")
    end

    it "ignores a path or query string smuggled into the filename" do
      expect(described_class.for(filename: "../../etc/passwd", content_type: "image/png")).to eq("png")
    end

    it "reads the content type past its parameters" do
      expect(described_class.for(filename: nil, content_type: "text/plain; charset=utf-8")).to eq("txt")
    end

    it "falls back to bin with neither a usable filename nor a recognised type" do
      expect(described_class.for(filename: nil, content_type: "application/octet-stream")).to eq("bin")
      expect(described_class.for(filename: nil, content_type: nil)).to eq("bin")
    end
  end

  describe ".split" do
    it "splits a secret from its extension" do
      expect(described_class.split("900931a2-d3a8-4b45-8b5f-173f4e79ca4c.jpg"))
        .to eq(["900931a2-d3a8-4b45-8b5f-173f4e79ca4c", "jpg"])
    end

    it "downcases the extension" do
      expect(described_class.split("abc.JPG")).to eq(["abc", "jpg"])
    end

    it "answers nil for both halves with no dot to split on" do
      expect(described_class.split("abc")).to eq([nil, nil])
    end

    it "answers nil for both halves when the dot leaves either side empty" do
      expect(described_class.split(".jpg")).to eq([nil, nil])
      expect(described_class.split("abc.")).to eq([nil, nil])
    end

    it "splits on the last dot, for a secret that is never expected to carry one" do
      expect(described_class.split("weird.name.png")).to eq(["weird.name", "png"])
    end
  end
end
