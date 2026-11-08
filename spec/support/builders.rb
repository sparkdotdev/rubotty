# frozen_string_literal: true

# Small constructors so specs read as intent rather than as object graphs.
module Builders
  def endpoint(id, adapter: :fake, account: "default", settings: { room_key: "k" }, **rest)
    Rubotty::Core::Endpoint.new(
      id: id, adapter_name: adapter, account: account, settings: settings, **rest
    )
  end

  def room(id, *endpoints, **rest)
    Rubotty::Core::Room.new(id: id, endpoints: endpoints, **rest)
  end

  def topology(*rooms)
    Rubotty::Core::Topology.new(rooms)
  end

  def author(**overrides)
    Rubotty::Core::Author.new(
      **{ native_id: "u1", first_name: "Ada", username: "ada" }.merge(overrides)
    )
  end

  def message(origin, text: "hello", native_id: "1", kind: :chat, **rest)
    Rubotty::Core::Message.new(
      kind: kind,
      ref: Rubotty::Core::MessageRef.new(origin.id, native_id),
      origin: origin,
      author: rest.delete(:author) || author,
      body: text.is_a?(Rubotty::Core::RichText) ? text : Rubotty::Core::RichText.plain(text),
      **rest
    )
  end

  def span(kind, from, to, **attributes)
    Rubotty::Core::Span.new(kind: kind, begin_index: from, end_index: to, attributes: attributes)
  end

  def rich(text, *spans)
    Rubotty::Core::RichText.new(text, spans)
  end

  def ref(endpoint_id, native_id)
    Rubotty::Core::MessageRef.new(endpoint_id, native_id)
  end

  def photo_attachment(url: "https://cdn.example/photo.jpg", filename: "photo.jpg", **rest)
    Rubotty::Core::Attachment.new(kind: :photo, url: url, filename: filename, **rest)
  end

  # A stand-in for {Rubotty::Features::AttachmentText}, for a spec that cares
  # what link_filter or word_filter does with QR/OCR text (issues #857, #858)
  # without decoding or OCRing a real image.
  def stub_attachment_text(qr: "", ocr: "")
    FakeAttachmentText.new(qr: qr, ocr: ocr)
  end

  class FakeAttachmentText
    def initialize(qr: "", ocr: "")
      @qr = qr.to_s
      @ocr = ocr.to_s
    end

    def qr_text = @qr

    def ocr_text = @ocr

    def text(ocr: false)
      return @qr unless ocr

      [@qr, @ocr].reject(&:empty?).join("\n")
    end
  end
end

RSpec.configure { |config| config.include Builders }
