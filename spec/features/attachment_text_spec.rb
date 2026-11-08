# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubotty::Features::AttachmentText do
  # A fetcher standing in for Util::MediaFetcher: hands the block the bytes
  # +files+ maps the attachment's url to, or answers nil (a refused
  # download, MediaFetcher#with's own contract) for a url the map does not
  # carry, and records every url it was asked for.
  def fake_fetcher(files: {})
    Class.new do
      define_method(:initialize) { @files = files; @calls = [] }
      attr_reader :calls

      # `yield` inside a define_method block binds to whatever block was in
      # scope where define_method itself was written, not to the block a
      # caller of #with passes, so the block is taken explicitly instead.
      define_method(:with) do |url, filename: nil, &block|
        @calls << url
        bytes = @files[url]
        next nil if bytes.nil?

        block.call(Struct.new(:bytes) { def read = bytes }.new(bytes))
      end
    end.new
  end

  # Stands in for Util::QrDecoder / Util::OcrReader, recording every call so a
  # spec can assert a photo is decoded or OCR'd at most once.
  def fake_qr_decoder(result: [])
    Class.new do
      define_method(:initialize) { @result = result; @calls = [] }
      attr_reader :calls

      define_method(:decode) { |bytes, filename: nil| @calls << bytes; @result }
    end.new
  end

  def fake_ocr_reader(result: "")
    Class.new do
      define_method(:initialize) { @result = result; @calls = [] }
      attr_reader :calls

      define_method(:read) { |bytes, filename: nil| @calls << bytes; @result }
    end.new
  end

  # A fetcher that raises instead of returning bytes, for the "the download
  # itself blows up" path.
  def raising_fetcher
    Class.new { def with(*) = raise("boom") }.new
  end

  def msg(attachments: [])
    message(endpoint("tg"), attachments: attachments)
  end

  describe "a message with no photo attachment" do
    it "answers an empty string and never downloads or decodes anything" do
      fetcher = fake_fetcher
      qr = fake_qr_decoder
      extractor = described_class.new(msg, fetcher: fetcher, qr_decoder: qr)

      expect(extractor.text(ocr: true)).to eq("")
      expect(fetcher.calls).to be_empty
      expect(qr.calls).to be_empty
    end

    it "ignores an attachment of another kind, even with a resolvable url" do
      document = Rubotty::Core::Attachment.new(kind: :document, url: "https://cdn.example/f.pdf")
      fetcher = fake_fetcher
      extractor = described_class.new(msg(attachments: [document]), fetcher: fetcher)

      expect(extractor.text).to eq("")
      expect(fetcher.calls).to be_empty
    end

    it "ignores a photo with no resolvable url" do
      unresolved = Rubotty::Core::Attachment.new(kind: :photo, native_ref: "file123")
      fetcher = fake_fetcher
      extractor = described_class.new(msg(attachments: [unresolved]), fetcher: fetcher)

      expect(extractor.text).to eq("")
      expect(fetcher.calls).to be_empty
    end
  end

  describe "the QR pass" do
    it "decodes a photo attachment and includes what it finds" do
      photo = photo_attachment(url: "https://cdn.example/qr.jpg")
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      qr = fake_qr_decoder(result: ["https://chat.whatsapp.com/AbC"])
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, qr_decoder: qr)

      expect(extractor.qr_text).to eq("https://chat.whatsapp.com/AbC")
      expect(extractor.text).to eq("https://chat.whatsapp.com/AbC")
    end

    it "runs unconditionally: text(ocr: false) still carries the QR decode" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      qr = fake_qr_decoder(result: ["a-code"])
      ocr = fake_ocr_reader(result: "should not appear")
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, qr_decoder: qr, ocr_reader: ocr)

      expect(extractor.text(ocr: false)).to eq("a-code")
      expect(ocr.calls).to be_empty
    end

    it "decodes only once no matter how many times it is asked" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      qr = fake_qr_decoder(result: ["a-code"])
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, qr_decoder: qr)

      3.times { extractor.text }
      expect(qr.calls.size).to eq(1)
      expect(fetcher.calls.size).to eq(1)
    end

    it "joins several photo attachments' codes with a newline" do
      one = photo_attachment(url: "https://cdn.example/1.jpg")
      two = photo_attachment(url: "https://cdn.example/2.jpg")
      fetcher = fake_fetcher(files: { one.url => "a", two.url => "b" })
      qr = Class.new { def decode(bytes, filename: nil) = [bytes == "a" ? "first-code" : "second-code"] }.new
      extractor = described_class.new(msg(attachments: [one, two]), fetcher: fetcher, qr_decoder: qr)

      expect(extractor.qr_text).to eq("first-code\nsecond-code")
    end

    it "caps how many photo attachments one message scans" do
      photos = (1..6).map { |n| photo_attachment(url: "https://cdn.example/#{n}.jpg") }
      files = photos.to_h { |p| [p.url, "bytes-#{p.url}"] }
      fetcher = fake_fetcher(files: files)
      qr = fake_qr_decoder(result: ["x"])
      extractor = described_class.new(msg(attachments: photos), fetcher: fetcher, qr_decoder: qr)

      extractor.qr_text
      expect(qr.calls.size).to eq(described_class::MAX_ATTACHMENTS)
    end
  end

  describe "the OCR pass" do
    it "is not run unless something asks for ocr: true" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      ocr = fake_ocr_reader(result: "read off the image")
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, ocr_reader: ocr)

      extractor.text(ocr: false)
      expect(ocr.calls).to be_empty
    end

    it "adds its result under the QR decode when asked for" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      qr = fake_qr_decoder(result: ["a-code"])
      ocr = fake_ocr_reader(result: "some visible text")
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, qr_decoder: qr, ocr_reader: ocr)

      expect(extractor.text(ocr: true)).to eq("a-code\nsome visible text")
    end

    it "OCRs only once no matter how many times ocr: true is asked for" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      ocr = fake_ocr_reader(result: "text")
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, ocr_reader: ocr)

      3.times { extractor.text(ocr: true) }
      expect(ocr.calls.size).to eq(1)
    end

    it "downloads a photo once and reuses the bytes for both the QR and the OCR pass" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: { photo.url => "bytes" })
      qr = fake_qr_decoder(result: ["a-code"])
      ocr = fake_ocr_reader(result: "text")
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, qr_decoder: qr, ocr_reader: ocr)

      extractor.text(ocr: true)
      expect(fetcher.calls.size).to eq(1)
      expect(qr.calls).to eq(["bytes"])
      expect(ocr.calls).to eq(["bytes"])
    end
  end

  describe "graceful degradation" do
    it "answers empty rather than raising when the download is refused" do
      photo = photo_attachment
      fetcher = fake_fetcher(files: {}) # url not in the map: MediaFetcher#with's own contract for a refusal
      extractor = described_class.new(msg(attachments: [photo]), fetcher: fetcher, logger: Rubotty::Log.null)

      expect(extractor.text(ocr: true)).to eq("")
    end

    it "answers empty rather than raising when the fetcher itself raises" do
      photo = photo_attachment
      extractor = described_class.new(msg(attachments: [photo]), fetcher: raising_fetcher, logger: Rubotty::Log.null)

      expect { extractor.text(ocr: true) }.not_to raise_error
      expect(extractor.text(ocr: true)).to eq("")
    end
  end
end
